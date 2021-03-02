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

# get current option group 

originalOptionGroup=`/usr/src/pyramid/get-option-group-status.sh $rdsServiceName false`

# copy the existing option group
aTimestamp=$(date +"%Y-%m-%d-%H-%M")

optionGroupCopy="$rdsServiceName-backup-sqlserver-$aTimestamp"

result=`aws rds copy-option-group \
    --source-option-group-identifier $originalOptionGroup \
    --target-option-group-identifier $optionGroupCopy \
    --target-option-group-description "Copy of $originalOptionGroup for backup" \
    --region $region --output text`

# OPTIONGROUP     True    sqlserver-se    14.00   arn:aws:rds:us-east-1:343272018671:og:repo-sqlserver-copy   Copy of currentOptionGroup for backup    repo-sqlserver-copy

if [[ -z "${result}" ]] ; then
    echo "copy option group failed"
    exit 1
fi

# add the SQLSERVER_BACKUP_RESTORE option with role to the copy 

pyramidRole=`aws ssm get-parameter --name "/Pyramid/$baseStackName/PyramidRole" --region $region --output text | cut -f 7`

backupRoleARN="arn:$partition:iam::$accountId:role/$pyramidRole"

result=`aws rds add-option-to-option-group \
  --option-group-name $optionGroupCopy \
  --options "OptionName=SQLSERVER_BACKUP_RESTORE,OptionSettings=[{Name=IAM_ROLE_ARN,Value=$backupRoleARN}]" \
  --apply-immediately \
  --region $region --output text`

if [[ -z "${result}" ]] ; then
    echo "add to option group failed"
    exit 1
fi

# modify_db_instance with the copy
result=`aws rds modify-db-instance \
      --db-instance-identifier $rdsServiceName \
      --option-group-name $optionGroupCopy \
      --apply-immediately \
      --region $region --output text`

if [[ -z "${result}" ]] ; then
    echo "modify-db-instance failed"
    exit 1
fi

result=`/usr/src/pyramid/get-option-group-status.sh $rdsServiceName true $optionGroupCopy`

echo "set option group for RDS service $rdsServiceName to $optionGroupCopy"

echo "$originalOptionGroup" > /tmp/originalOptionGroup
echo "$optionGroupCopy" > /tmp/copyOptionGroup
