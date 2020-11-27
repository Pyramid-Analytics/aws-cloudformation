#!/bin/bash
baseStackName=${1}
repositoryType=${2}
region=${3}
disableComponents=${4:-none}
# - - '/usr/src/pyramid/unattended-install-settings.sh'
#   - !Ref RepositoryType
#   - !If
#     - CurrentRepositoryTypeCondition
#     - currentRepository
#     - newRepository
#   - !Ref AWS::Region
#   - !If
#     - DisableComponents
#     - !FindInMap 
#         - ProcessesToExclude
#         - Processes
#         - !Ref PyramidProcess
#     - ''

set -o errexit

echo "baseStackName=${baseStackName}"
echo "repositoryType=${repositoryType}"
echo "region=${region}"
echo "disableComponents=<${disableComponents}>"

rdsAddress=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseAddress" --region $region --output text | cut -f 7`
rdsPort=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabasePort" --region $region --output text | cut -f 7`
rdsName=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseName" --region $region --output text | cut -f 7`
rdsUsername=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseUsername" --region $region --output text | cut -f 7`

rdsPassword=`aws secretsmanager get-secret-value --secret-id /Pyramid/$baseStackName/RepositoryDatabasePassword --region $region --output text | cut -f 4`

initialUsername=`aws ssm get-parameter --name "/Pyramid/$baseStackName/InitialUsername" --region $region --output text | cut -f 7`
initialUserPassword=`aws secretsmanager get-secret-value --secret-id /Pyramid/$baseStackName/InitialUserPassword --region $region --output text | cut -f 4`

selectRepositoryType='selectCurrentRepository=0'
if [[ "${repositoryType}" == "newremote" ]] ; then
  selectRepositoryType='selectNewRepository=0'
fi

disableComponentsProperty=''
if [[ "${disableComponents}"  != "none" ]] ; then
  disableComponentsProperty="disableComponents=${disableComponents}"
fi

cat >/usr/src/pyramid/pyramid-unattended-install.ini\
<<-_EOL_
install-location=/opt/Pyramid
data-location=/opt/Pyramid/repository

$disableComponentsProperty

installation-type=1
$selectRepositoryType
repositoryChoice=$repositoryType
postgreSqlHost=$rdsAddress
postgreSqlPort=$rdsPort
postgreSqlDb=$rdsName
postgreSqlUsername=$rdsUsername
postgreSqlUserPassword=$rdsPassword
initUserName=$initialUsername
initUserPassword=$initialUserPassword
_EOL_

