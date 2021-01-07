#!/bin/bash
baseStackName=${1}
bucketAndFolder=${2}
clearOldServers=${3:-true}
  # command: !Join
  #   - ' '
  #   - - /usr/src/pyramid/restore-from-s3.sh
  #     - !Ref BaseStackName
  #     - !Ref BackupS3BucketAndFolder
  #     - !Ref Subnet
  #     - !Sub '${AWS::Region}'
  #     - true

set -o errexit

TOKEN=`curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`

mac=`curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/mac`

subnet=`curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/$mac/subnet-id`

region=`curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep -oP '\"region\"[[:space:]]*:[[:space:]]*\"\K[^\"]+'`

echo "Restoring:"
echo "baseStackName = $baseStackName"
echo "bucketAndFolder = $bucketAndFolder"
echo "subnet = $subnet"
echo "region = $region"
echo "clearOldServers = $clearOldServers"

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

/usr/src/pyramid/mnt-efs.sh \
    --mountPoint /mnt/pyramid-backup \
    --subnet $subnet \
    --securityGroup $mtSecurityGroup \
    --efsId $sharedFileSystemEFS \
    --region $region

# -mountPoint /mnt/pyramid-backup
# 	--subnet subnet-01947522cba134c85
# 	--securityGroup us-east-1
# 	--efsId true
# 	--region

echo "Synching backup in s3://$bucketAndFolder to EFS $sharedFileSystemEFS"
# dump s3 into the shared file system
aws s3 sync --no-progress s3://$bucketAndFolder/ /mnt/pyramid-backup

if [ ! -d /mnt/pyramid-backup/repoBackup ] ; then
  echo "No /mnt/pyramid-backup/repoBackup directory. Exiting..."
  exit 1
fi

# get the latest dump file
dumpFile=`ls -t1 /mnt/pyramid-backup/repoBackup/*.dump |  tail -n 1`

if [[ -z "${dumpFile}" ]] ; then
  dumpFile=`ls -t1 /mnt/pyramid-backup/repoBackup/*.bak |  tail -n 1`
  if [[ -z "${dumpFile}" ]] ; then
    echo "No *.dump files in /mnt/pyramid-backup/repoBackup directory. Exiting..."
    exit 1
  else
  rdsType=MicrosoftSQLServer
  fi
else
  rdsType=PostgreSQL
fi

rdsAddress=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseAddress" --region $region --output text | cut -f 7`
rdsPort=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabasePort" --region $region --output text | cut -f 7`
rdsName=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseName" --region $region --output text | cut -f 7`
rdsUsername=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseUsername" --region $region --output text | cut -f 7`

rdsPassword=`aws secretsmanager get-secret-value --secret-id /Pyramid/$baseStackName/RepositoryDatabasePassword --region $region --output text | cut -f 4`

echo "restoring $dumpFile to database $rdsName on service $rdsAddress"
case "${rdsType}" in
PostgreSQL)

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
  if [ ! -z "${bucketFolder}"] ; then
    s3SQLServerBackup="arn:$partition:s3:::$bucketName/$bucketFolder/$label/repoBackup/$baseStackName-repository-$label.bak"
  else
    s3SQLServerBackup="arn:$partition:s3:::$bucketName/$label/repoBackup/$baseStackName-repository-$label.bak"
  fi
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
  done <<< "$restoreStatus"

  if [ -z "${lifecycle}" ] ; then
    echo "rds_task_status failed: no lifecycle"
    exit 1
  elif [ "$lifecycle" = "SUCCESS" ] ; then 
    echo "restore successful"
    break
  elif [[ " ${failureStatuses[@]} " =~ " ${lifecycle} " ]]; then
    echo "restore failed: $lifecycle"
    exit 1
  else 
    echo "restore status: $lifecycle. percent complete: $completePct. waiting 30 secs"
    sleep 30
  fi

  # ======================================
  done 
  # sqlcmd -S localhost -U SA -Q "RESTORE DATABASE [demodb] FROM DISK = N'/var/opt/mssql/data/demodb.bak' WITH FILE = 1, NOUNLOAD, REPLACE, NORECOVERY, STATS = 5"
  # sqlcmd -S tcp:$rdsAddress,$rdsPort -U $rdsUsername -P $rdsPassword \
  #   -Q "RESTORE DATABASE [$rdsName] FROM DISK = N'$dumpFile' WITH FILE = 1, NOUNLOAD, REPLACE, STATS = 5"

  if [ "${clearOldServers}" == "true" ] ; then
    echo "Deleting server_instances"
    sqlcmd -S tcp:$rdsAddress,$rdsPort -U $rdsUsername -P $rdsPassword -h -1 -s"~" \
	       -Q "delete from [$rdsName].server_instances;"
    if [ $? -ne 0 ] ; then
      echo "rds_task_status execution failed"
      exit 1
    fi
  fi
  ;;
*)
  echo "invalid database type <$rdsType>"
  exit 1
esac

umount /mnt/pyramid-backup
rm -rf /mnt/pyramid-backup
