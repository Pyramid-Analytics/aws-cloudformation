#!/bin/bash
baseStackName=${1}
bucketAndFolder=${2}
subnet=${3}
region=${4}
clearOldServers=${5:-true}

set -o errexit

sharedFileSystemEFS=`aws ssm get-parameter --name "/Pyramid/$baseStackName/SharedFileSystem" --region $region --output text | cut -f 7`
if [[ -z "${sharedFileSystemEFS}" ]] ; then
  echo "sharedFileSystemEFS not set"
  exit 1
fi

mtSecurityGroup=`aws ssm get-parameter --name "/Pyramid/$baseStackName/MountTargetSecurityGroup" --region $region --output text | cut -f 7`
if [[ -z "${mtSecurityGroup}" ]] ; then
  echo "mtSecurityGroup not set"
  exit 1
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
  echo "No /mnt/pyramid-backup/repoBackup directory. Exiting..."
  exit 1
fi

# get the latest dump file
dumpFile=`ls -t1 /mnt/pyramid-backup/repoBackup/*.dump |  tail -n 1`

if [[ -z "${dumpFile}" ]] ; then
  echo "No *.dump files in /mnt/pyramid-backup/repoBackup directory. Exiting..."
  exit 1
fi

rdsAddress=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseAddress" --region $region --output text | cut -f 7`
rdsPort=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabasePort" --region $region --output text | cut -f 7`
rdsName=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseName" --region $region --output text | cut -f 7`
rdsUsername=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseUsername" --region $region --output text | cut -f 7`

rdsPassword=`aws secretsmanager get-secret-value --secret-id /Pyramid/$baseStackName/RepositoryDatabasePassword --region $region --output text | cut -f 4`

echo "restoring $dumpFile to database $rdsName on service $rdsAddress"

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

umount /mnt/pyramid-backup
rm -rf /mnt/pyramid-backup
