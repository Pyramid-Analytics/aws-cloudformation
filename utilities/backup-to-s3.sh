#!/bin/bash
label=$1
baseStackName=$2
subnet=$3
mtSecurityGroup=$4
sharedFileSystemEFS=$5
region=$6
bucketName=$7
bucketFolder=${8:-}

set -o errexit

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
echo "backing up $rdsName on service $rdsAddress"
# dump the repository into the shared file system
export PGPASSWORD=$rdsPassword
pg_dump -F c -U $rdsUsername -h $rdsAddress -p $rdsPort $rdsName > "/mnt/pyramid/repoBackup/$baseStackName-repository-$label.dump"

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
      --mountPoint /mnt/pyramid-imdb/$fileSystemId \
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
      /mnt/pyramid-imdb/$fileSystemId /mnt/pyramid/imdb/$fileSystemId
    umount /mnt/pyramid-imdb/$fileSystemId
    rm -rf /mnt/pyramid-imdb/$fileSystemId
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
aws s3 sync --no-progress /mnt/pyramid/imdb $s3Destination/imdb
aws s3 sync --no-progress /mnt/pyramid/repoBackup $s3Destination/repoBackup

# remove the repo dump from the
rm -rf /mnt/pyramid/repoBackup/$baseStackName-repository-$label.dump
umount /mnt/pyramid
rm -rf /mnt/pyramid
