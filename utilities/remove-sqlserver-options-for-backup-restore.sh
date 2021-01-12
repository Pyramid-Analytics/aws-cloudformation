#!/bin/bash
baseStackName=$1

TOKEN=`curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`

region=`curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document | grep -oP '\"region\"[[:space:]]*:[[:space:]]*\"\K[^\"]+'`
accountId=`curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document | grep -oP '\"accountId\"[[:space:]]*:[[:space:]]*\"\K[^\"]+'`
partition=`curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/services/partition`

rdsAddress=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseAddress" --region $region --output text | cut -f 7`
if [[ -z "${rdsAddress}" ]] ; then
    echo "rdsAddress parameter at /Pyramid/$baseStackName/RepositoryDatabaseAddress missing"
    exit 1
fi
rdsServiceName=`echo $rdsAddress | cut -d '.' -f 1`

originalOptionGroup=`cat /tmp/originalOptionGroup`
optionGroupCopy=`cat /tmp/copyOptionGroup`

# get current option group 

currentOptionGroup=`/usr/src/pyramid/get-option-group-status.sh $rdsServiceName false`

# should be the copy
if [ "$currentOptionGroup" != "$optionGroupCopy" ] ; then 
    echo "in-sync option group is $currentOptionGroup - not $optionGroupCopy"
    exit 1
fi

# modify_db_instance back to the original
result=`aws rds modify-db-instance \
      --db-instance-identifier $rdsServiceName \
      --option-group-name $originalOptionGroup \
      --apply-immediately \
      --region $region --output text`

if [[ -z "${result}" ]] ; then
    echo "modify-db-instance failed"
    exit 1
fi

# wait for the modification
currentOptionGroup=`/usr/src/pyramid/get-option-group-status.sh $rdsServiceName true $originalOptionGroup`

# delete the option group copy
result=`aws rds delete-option-group \
      --option-group-name $optionGroupCopy \
      --region $region --output text`

if [[ -z "${result}" ]] ; then
    echo "delete-option-group failed"
    exit 1
fi
