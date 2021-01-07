#!/bin/bash

# Assumes PostgreSQL and Microsoft SQL Server command line tools
# are available on the instance

label=$1
baseStackName=$2
bucketName=$3
bucketFolder=${4:-}

set -o errexit

TOKEN=`curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`

mac=`curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" -s  http://169.254.169.254/latest/meta-data/mac`

subnet=`curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/$mac/subnet-id`

region=`curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep -oP '\"region\"[[:space:]]*:[[:space:]]*\"\K[^\"]+'`

partition=`curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/services/partition`

mtSecurityGroup=`aws ssm get-parameter --name "/Pyramid/$baseStackName/MountTargetSecurityGroup" --region $region --output text | cut -f 7`
sharedFileSystemEFS=`aws ssm get-parameter --name "/Pyramid/$baseStackName/SharedFileSystem" --region $region --output text | cut -f 7`

pyramidMountExisted=true
if [ ! -d /mnt/pyramid ] ; then
  pyramidMountExisted=false
  /usr/src/pyramid/mnt-efs.sh \
    --subnet $subnet \
    --securityGroup $mtSecurityGroup \
    --efsId $sharedFileSystemEFS \S
    --region $region
fi

rdsType=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseType" --region $region --output text | cut -f 7`

if [[ -z "${rdsType}" ]] ; then
  rdsType='PostgreSQL'
fi

rdsAddress=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseAddress" --region $region --output text | cut -f 7`
rdsPort=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabasePort" --region $region --output text | cut -f 7`
rdsName=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseName" --region $region --output text | cut -f 7`
rdsUsername=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseUsername" --region $region --output text | cut -f 7`

rdsPassword=`aws secretsmanager get-secret-value --secret-id /Pyramid/$baseStackName/RepositoryDatabasePassword --region $region --output text | cut -f 4`

if [ ! -d /mnt/pyramid/repoBackup ] ; then
  mkdir -p /mnt/pyramid/repoBackup
fi
echo "backing up $rdsName from service $rdsAddress:$rdsPort"

case "${rdsType}" in
PostgreSQL)
  # dump the repository into the shared file system
  export PGPASSWORD=$rdsPassword
  pg_dump -F c -U $rdsUsername -h $rdsAddress -p $rdsPort $rdsName > "/mnt/pyramid/repoBackup/$baseStackName-repository-$label.dump"
  ;;
MicrosoftSQLServer)
  if [ ! -z "${bucketFolder}"] ; then
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
  # Line 1: column names
  # task_id, task_type, database_name, % complete, duration(mins), lifecycle, task_info, last_updated,
  # created_at, S3_object_arn,
  # overwrite_S3_backup_file KMS_master_key_arn, filepath, overwrite_file

  # line 2: column headers. minuses

  # line 3: data
  # 2
  # BACKUP_DB
  # pyramid 
  # 100
  # 1
  # SUCCESS
  # ^M[2021-01-04 14:15:22.133] Task execution has started.^M^M[2021-01-04 14:15:22.540] 5 percent processed.^M[2021-01-04 14:15:22.680] 10 percent processed.^M[2021-01-04 14:15:22.803] 15 percent processed.^M[2021-01-04 14:15:23.040] 20 percent processed.^M[2021-01-0
  # 2021-01-04 14:16:22.350
  # 2021-01-04 14:15:14.103
  # arn:aws:s3:::repo-sqlserver-10-backup-s3bucket-1knzsal625x78/test-1/repoBackup/repo-sqlserver-10-repository-test-1.bak
  # 0
  # NULL
  # NULL
  # 0

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
  # sqlcmd -S tcp:$rdsAddress,$rdsPort -U $rdsUsername -P $rdsPassword \
  #   -Q "BACKUP DATABASE [$rdsName] TO DISK = N'/mnt/pyramid/repoBackup/$baseStackName-repository-$label.bak' WITH STATS = 10"
  ;;
*)
  echo "invalid database type <$rdsType>"
  exit 1
esac

# catch the 2020-13 release approach of having an EFS volume per IMDB
# dump each IMDB file system to s3
ssmParams=`aws ssm get-parameters-by-path --path "/Pyramid/$baseStackName" --recursive --region $region --output text`
# looking for SSM parameters of the forms:
#    '/Pyramid/$baseStackName/${AWS::StackName}/IMDBFileSystem'
while read line ; do
  # name is cut -f 1
  name=`echo $line | cut -d " " -f 5`
  endPortion=`echo $name | cut -d '/' -f 5`

  # echo "<$name> **** <$endPortion>"
  if [[ "${endPortion}" == "IMDBFileSystem" ]] ; then
    # value is cut -f 3
    fileSystemId=`echo $line | cut -d " " -f 7`
    # echo "fileSystemId - $fileSystemId"
    /usr/src/pyramid/mnt-efs.sh \
      --mountPoint /mnt/pyramid-temp-imdb/$fileSystemId \
      --subnet $subnet \
      --securityGroup $mtSecurityGroup \
      --efsId $fileSystemId \
      --region $region

    mkdir -p /mnt/pyramid/imdb/$fileSystemId
    echo "copying $fileSystemId to $sharedFileSystemEFS /imdb/$fileSystemId"
    # cp -p -R /mnt/pyramid-imdb/$fileSystemId/. /mnt/pyramid/imdb/$fileSystemId
    # --remove-source-files \
    rsync \
      --chown=pyramid:pyramid \
      /mnt/pyramid-temp-imdb/$fileSystemId /mnt/pyramid/imdb/$fileSystemId
    umount /mnt/pyramid-temp-imdb/$fileSystemId
    rm -rf /mnt/pyramid-temp-imdb/$fileSystemId
  fi
done <<< "$ssmParams"

# deal with an EFS volume without a /shared directory
if [ ! -d /mnt/pyramid/shared ] ; then
  mkdir /mnt/pyramid/shared
  find /mnt/pyramid/ -type f -maxdepth 1  -exec cp -t /mnt/pyramid/shared/ {} +
fi

if [ ! -z "${bucketFolder}"] ; then
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

aws s3 sync --no-progress /mnt/pyramid/repoBackup $s3Destination/repoBackup

# remove the repo dump from the EFS mount
rm -rf /mnt/pyramid/repoBackup/$baseStackName-repository-$label.*

if [ $pyramidMountExisted = false ] ; then
  umount /mnt/pyramid
  rm -rf /mnt/pyramid
fi
