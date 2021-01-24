#!/bin/bash
baseStackName=${1}
clearOldServers=${2:-true}
bucket=${3}
folder=${4}
  # command: !Join
  #   - ' '
  #   - - /usr/src/pyramid/restore-from-s3.sh
  #     - !Ref BaseStackName
  #     - true
    #     - !Ref BackupS3Bucket
    #     - !Ref BackupS3Folder

set -o errexit

TOKEN=`curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`

mac=`curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/mac`

subnet=`curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/network/interfaces/macs/$mac/subnet-id`

region=`curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document | grep -oP '\"region\"[[:space:]]*:[[:space:]]*\"\K[^\"]+'`

echo "Restoring:"
echo "baseStackName = $baseStackName"
echo "bucket = $bucket"
echo "folder = $folder"
echo "subnet = $subnet"
echo "region = $region"
echo "clearOldServers = $clearOldServers"

if [[ -z "${baseStackName}" ]] ; then
    echo "baseStackName not set"
    exit 1
fi

if [[ -z "${bucket}" ]] ; then
    echo "bucket not set"
    exit 1
fi

sharedFileSystemEFS=`aws ssm get-parameter --name "/Pyramid/$baseStackName/SharedFileSystem" --region $region --output text | cut -f 7`
if [[ -z "${sharedFileSystemEFS}" ]] ; then
  echo "sharedFileSystemEFS not set"
  exit 1
fi
echo "sharedFileSystemEFS = $sharedFileSystemEFS"

mtSecurityGroup=`aws ssm get-parameter --name "/Pyramid/$baseStackName/MountTargetSecurityGroup" --region $region --output text | cut -f 7`
if [[ -z "${mtSecurityGroup}" ]] ; then
  echo "mtSecurityGroup not set"
  exit 1
fi
echo "mtSecurityGroup = $mtSecurityGroup"

if [[ -z "${folder}" ]] ; then
    bucketAndFolder=$bucket
else
    bucketAndFolder="$bucket/$folder"
fi

/usr/src/pyramid/mnt-efs.sh \
    --mountPoint /mnt/pyramid-backup \
    --subnet $subnet \
    --securityGroup $mtSecurityGroup \
    --efsId $sharedFileSystemEFS \
    --region $region

echo "Synching backup in s3://$bucketAndFolder to EFS $sharedFileSystemEFS"
# dump s3 into the shared file system
aws s3 sync --no-progress s3://$bucketAndFolder/ /mnt/pyramid-backup

if [ ! -d /mnt/pyramid-backup/repoBackup ] ; then
    echo "No /mnt/pyramid-backup/repoBackup directory from s3 $bucketAndFolder. Exiting..."
  exit 1
fi

chown -R pyramid:pyramid /mnt/pyramid-backup

# get the latest dump file
dumpFile=`ls -t1 /mnt/pyramid-backup/repoBackup/*.dump |  tail -n 1`

if [[ -z "${dumpFile}" ]] ; then
    bakFile=`ls -t1 /mnt/pyramid-backup/repoBackup/*.bak |  tail -n 1`
    if [[ -z "${bakFile}" ]] ; then
      echo "No *.dump or *.bak files in /mnt/pyramid-backup/repoBackup directory. Exiting..."
      exit 1
    else
      rdsType=MicrosoftSQLServer
      len=`expr length "/mnt/pyramid-backup/repoBackup/"`
      bakFile=${bakFile:$len}
    fi
else
  rdsType=PostgreSQL
fi

rdsAddress=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseAddress" --region $region --output text | cut -f 7`
rdsPort=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabasePort" --region $region --output text | cut -f 7`
rdsName=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseName" --region $region --output text | cut -f 7`
rdsUsername=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseUsername" --region $region --output text | cut -f 7`

rdsPassword=`aws secretsmanager get-secret-value --secret-id /Pyramid/$baseStackName/RepositoryDatabasePassword --region $region --output text | cut -f 4`

case "${rdsType}" in
PostgreSQL)
    echo "restoring PostgreSQL $dumpFile to database $rdsName on service $rdsAddress"

  # create a new database and restore the repository dump into it
  export PGPASSWORD=$rdsPassword
  createdb -U $rdsUsername -h $rdsAddress -p $rdsPort $rdsName

  # exclude extensions
  pg_restore -l -F c -U $rdsUsername -h $rdsAddress -p $rdsPort $dumpFile | grep -v "EXTENSION" > /tmp/ignore_pg_extensions

  # Compressed. No Owner. No privileges
  pg_restore -F c -O -x -L /tmp/ignore_pg_extensions -U $rdsUsername -h $rdsAddress -p $rdsPort -d $rdsName $dumpFile

  if [ "${clearOldServers}" == "true" ] ; then
    echo "Deleting server_instances"
    psql -U $rdsUsername -h $rdsAddress -p $rdsPort -d $rdsName <<EOF
delete from server_instances;
EOF
  fi
  ;;
MicrosoftSQLServer)
  
    /usr/src/pyramid/set-sqlserver-options-for-backup-restore.sh $baseStackName 

    s3SQLServerBackup="arn:$partition:s3:::$bucketAndFolder/repoBackup/$bakFile"
    echo "restoring SQL Server $s3SQLServerBackup to database $rdsName on service $rdsAddress"

    restoreRequest=`sqlcmd -S tcp:$rdsAddress,$rdsPort -U $rdsUsername -P $rdsPassword -h -1 -s"~"\
    -Q "exec msdb.dbo.rds_restore_database @restore_db_name='$rdsName', @s3_arn_to_restore_from='$s3SQLServerBackup', @type='FULL';"`
    
    # @kms_master_key_arn='arn:aws:kms:us-east-1:123456789012:key/AKIAIOSFODNN7EXAMPLE', 

  if [ $? -ne 0 ] ; then
    echo "rds_restore_database call failed"
    exit 1
  fi

  taskId=
  while IFS="~" read -r c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 ; do
      lifecycle="$(echo -e "${c3}" | tr -d '[:space:]')"
      taskId="$(echo -e "${c1}" | tr -d '[:space:]')"
      echo "found restore state: $lifecycle"
      break
  done <<< "$restoreRequest"

  if [ -z "${taskId}" ] ; then 
    echo "task_id for rds_restore_database call failed"
    exit 1
  else
    echo "restore task id: $taskId"
  fi

  failureStatuses=(ERROR CANCEL_REQUESTED CANCELLED)

  # check backup status
  while true ; do 
  # ======================================

  restoreStatus=`sqlcmd -S tcp:$rdsAddress,$rdsPort -U $rdsUsername -P $rdsPassword -h -1 -s"~" \
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
  done <<< "$restoreStatus"

  if [ -z "${lifecycle}" ] ; then
    echo "rds_task_status failed: no lifecycle"
    exit 1
  elif [ "$lifecycle" = "SUCCESS" ] ; then 
    echo "restore successful"
    break
  elif [[ " ${failureStatuses[@]} " =~ " ${lifecycle} " ]]; then
    echo "restore failed: $lifecycle"
    echo "$c1 $c2 $c3 $c4 $c5 $c6 $c7 $c8 $c9 $c10"
    exit 1
  else 
    echo "restore status: $lifecycle. percent complete: $completePct. waiting 30 secs"
    sleep 30
  fi

  # ======================================
  done 

  if [ "${clearOldServers}" == "true" ] ; then
    echo "Deleting server_instances"
    sqlcmd -S tcp:$rdsAddress,$rdsPort -U $rdsUsername -P $rdsPassword -h -1 -s"~" \
        -d $rdsName \
        -Q "delete from server_instances;"
    if [ $? -ne 0 ] ; then
      echo "rds_task_status execution failed"
      exit 1
    fi
  fi

    /usr/src/pyramid/remove-sqlserver-options-for-backup-restore.sh $baseStackName 
  ;;
*)
  echo "invalid database type <$rdsType>"
  exit 1
esac

umount /mnt/pyramid-backup
rm -rf /mnt/pyramid-backup
