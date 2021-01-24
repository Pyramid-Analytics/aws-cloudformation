#!/bin/bash

# Assumes PostgreSQL and Microsoft SQL Server command line tools
# are available on the instance

label=$1
baseStackName=$2
bucketName=$3
bucketFolder=${4:-}

set -o errexit

TOKEN=`curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`

mac=`curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/mac`

subnet=`curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/network/interfaces/macs/$mac/subnet-id`

region=`curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document | grep -oP '\"region\"[[:space:]]*:[[:space:]]*\"\K[^\"]+'`

partition=`curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/services/partition`

rdsType=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseType" --region $region --output text | cut -f 7`

if [[ -z "${rdsType}" ]] ; then
    rdsType='PostgreSQL'
fi

mtSecurityGroup=`aws ssm get-parameter --name "/Pyramid/$baseStackName/MountTargetSecurityGroup" --region $region --output text | cut -f 7`
sharedFileSystemEFS=`aws ssm get-parameter --name "/Pyramid/$baseStackName/SharedFileSystem" --region $region --output text | cut -f 7`

  /usr/src/pyramid/mnt-efs.sh \
    --subnet $subnet \
    --securityGroup $mtSecurityGroup \
    --efsId $sharedFileSystemEFS \
    --region $region

rdsAddress=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseAddress" --region $region --output text | cut -f 7`
rdsPort=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabasePort" --region $region --output text | cut -f 7`
rdsName=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseName" --region $region --output text | cut -f 7`
rdsUsername=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseUsername" --region $region --output text | cut -f 7`

rdsPassword=`aws secretsmanager get-secret-value --secret-id /Pyramid/$baseStackName/RepositoryDatabasePassword --region $region --output text | cut -f 4`

if [ ! -d /mnt/pyramid/repoBackup ] ; then
  mkdir -p /mnt/pyramid/repoBackup
fi

# deal with an EFS volume without a /shared directory
if [ ! -d /mnt/pyramid/shared ] ; then
    mkdir /mnt/pyramid/shared
    find /mnt/pyramid/ -type f -maxdepth 1  -exec cp -t /mnt/pyramid/shared/ {} +
fi

if [ ! -z "${bucketFolder}" ] ; then
    s3Destination="s3://$bucketName/$bucketFolder/$label"
else
    s3Destination="s3://$bucketName/$label"
fi
echo "Synching to $s3Destination"
# dump EFS to s3
aws s3 sync --no-progress /mnt/pyramid/shared $s3Destination/shared

if [[ -d /mnt/pyramid/imdb ]] ; then
    aws s3 sync --no-progress /mnt/pyramid/imdb $s3Destination/imdb
fi

echo "backing up $rdsName from service $rdsAddress:$rdsPort"

case "${rdsType}" in
PostgreSQL)
  # dump the repository into the shared file system
  export PGPASSWORD=$rdsPassword
  pg_dump -F c -U $rdsUsername -h $rdsAddress -p $rdsPort $rdsName > "/mnt/pyramid/repoBackup/$baseStackName-repository-$label.dump"
    if [ $? -ne 0 ] ; then
      echo "pg_dump failed"
      exit 1
    fi
    aws s3 sync --no-progress /mnt/pyramid/repoBackup $s3Destination/repoBackup
    rm -rf /mnt/pyramid/repoBackup/$baseStackName-repository-$label.dump
  ;;

MicrosoftSQLServer)

    /usr/src/pyramid/set-sqlserver-options-for-backup-restore.sh $baseStackName 

    if [ ! -z "${bucketFolder}" ] ; then
    s3SQLServerDestination="arn:$partition:s3:::$bucketName/$bucketFolder/$label/repoBackup/$baseStackName-repository-$label.bak"
  else
    s3SQLServerDestination="arn:$partition:s3:::$bucketName/$label/repoBackup/$baseStackName-repository-$label.bak"
  fi
  backupRequest=`sqlcmd -S tcp:$rdsAddress,$rdsPort -U $rdsUsername -P $rdsPassword -h -1 -s"~"\
    -Q "exec msdb.dbo.rds_backup_database @source_db_name='$rdsName', @s3_arn_to_backup_to='$s3SQLServerDestination', @type='FULL';"`

    # @kms_master_key_arn='arn:aws:kms:us-east-1:123456789012:key/AKIAIOSFODNN7EXAMPLE', 

  if [ $? -ne 0 ] ; then
    echo "rds_backup_database call failed"
    exit 1
  fi

  taskId=
  while IFS="~" read -r c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 ; do
      lifecycle="$(echo -e "${c3}" | tr -d '[:space:]')"
      taskId="$(echo -e "${c1}" | tr -d '[:space:]')"
      echo "found backup state: $lifecycle"
      break
  done <<< "$backupRequest"

  if [ -z "${taskId}" ] ; then 
    echo "task_id for rds_backup_database call failed"
    exit 1
  else
    echo "backup task id: $taskId"
  fi

  failureStatuses=(ERROR CANCEL_REQUESTED CANCELLED)

  # check backup status
  while true ; do 
  # ======================================

  backupStatus=`sqlcmd -S tcp:$rdsAddress,$rdsPort -U $rdsUsername -P $rdsPassword -h -1 -s"~" \
	  -Q "msdb.dbo.rds_task_status @db_name='$rdsName', @task_id=$taskId;"`
  if [ $? -ne 0 ] ; then
    echo "rds_task_status execution failed"
    exit 1
  fi

  # https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/SQLServer.Procedural.Importing.html

  lifecycle=
  completePct=

  while IFS="~" read -r c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 ; do
    lifecycle="$(echo -e "${c6}" | tr -d '[:space:]')"
    completPct="$(echo -e "${c4}" | tr -d '[:space:]')"
    break
  done <<< "$backupStatus"

  if [ -z "${lifecycle}" ] ; then
    echo "rds_task_status failed: no lifecycle"
    exit 1
  elif [ "$lifecycle" = "SUCCESS" ] ; then 
    echo "backup successful"
    break
  elif [[ " ${failureStatuses[@]} " =~ " ${lifecycle} " ]]; then
    echo "backup failed: $lifecycle"
    exit 1
  else 
    echo "backup status: $lifecycle. percent complete: $completePct. waiting 30 secs"
    sleep 30
  fi

  # ======================================
  done 

    /usr/src/pyramid/remove-sqlserver-options-for-backup-restore.sh $baseStackName 

  ;;
*)
  echo "invalid database type <$rdsType>"
  exit 1
esac

  umount /mnt/pyramid
  rm -rf /mnt/pyramid
