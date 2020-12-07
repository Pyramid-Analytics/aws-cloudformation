#!/bin/bash
baseStackName=${1}
repositoryType=${2}
# region=${3}
processes=${3:-Everything}
rdsType=${4:-PostgreSQL}
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

# given what you want to deploy, what processes do you want to exclude?
declare -A ProcessesToExclude
ProcessesToExclude[Router]='linws,linrte,linte,linimdb,linai'
ProcessesToExclude[WebServer]='linrte,linte,linrtr,linimdb,linai'
ProcessesToExclude[WebServerAndRouter]='linrte,linte,linimdb,linai'
ProcessesToExclude[RuntimeEngine]='linws,linte,linrtr,linimdb,linai'
ProcessesToExclude[TaskEngine]='linws,linrte,linrtr,linimdb,linai'
ProcessesToExclude[RuntimeEngineAndTaskEngine]='linws,linrtr,linimdb,linai'
ProcessesToExclude[RuntimeEngineAndAI]='linws,linte,linrtr,linimdb'
ProcessesToExclude[TaskEngineAndAI]='linws,linrte,linrtr,linimdb'
ProcessesToExclude[RuntimeAndTaskEngineAndAI]='linws,linrtr,linimdb'
ProcessesToExclude[AIServer]='linws,linrte,linte,linrtr,linimdb'
ProcessesToExclude[InMemoryDB]='linws,linrte,linte,linrtr,linai'
ProcessesToExclude[Nothing]='linws,linrte,linte,linrtr,linimdb,linai'
ProcessesToExclude[EverythingExceptInMemoryDB]='linimdb'
ProcessesToExclude[Everything]=''

TOKEN=`curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`

region=`curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep -oP '\"region\"[[:space:]]*:[[:space:]]*\"\K[^\"]+'`

echo "baseStackName=${baseStackName}"
echo "repositoryType=${repositoryType}"
echo "region=${region}"
echo "processes=<${processes}>"

rdsType=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseType" --region $region --output text | cut -f 7`

if [[ -z "${rdsType}" ]] ; then
  rdsType='PostgreSQL'
fi

rdsAddress=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseAddress" --region $region --output text | cut -f 7`
rdsPort=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabasePort" --region $region --output text | cut -f 7`
rdsName=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseName" --region $region --output text | cut -f 7`
rdsUsername=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseUsername" --region $region --output text | cut -f 7`

rdsPassword=`aws secretsmanager get-secret-value --secret-id /Pyramid/$baseStackName/RepositoryDatabasePassword --region $region --output text | cut -f 4`

initialUsername=`aws ssm get-parameter --name "/Pyramid/$baseStackName/InitialUsername" --region $region --output text | cut -f 7`
initialUserPassword=`aws secretsmanager get-secret-value --secret-id /Pyramid/$baseStackName/InitialUserPassword --region $region --output text | cut -f 4`

case "${rdsType}" in
PostgreSQL)
  databasePrefix='postgreSql'
  databaseLocation='pgLocation'
  databaseType='0'
  ;;
MicrosoftSQLServer)
  databasePrefix='mssql'
  databaseLocation='msLocation'
  databaseType='1'
  ;;
*)
  echo "invalid database type <$rdsType>"
  exit 1
esac


selectRepositoryType="selectCurrentRepository=${databaseType}"
if [[ "${repositoryType}" == "newremote" ]] ; then
  selectRepositoryType="selectNewRepository=${databaseType}"
fi

disableComponentsProperty=''
if [[ "${processes}"  != "Everything" ]] ; then
  disableComponentsProperty="disable-components=${ProcessesToExclude[$processes]}"
fi

cat >/usr/src/pyramid/pyramid-unattended-install.ini\
<<-_EOL_
install-location=/opt/Pyramid
data-location=/opt/Pyramid/repository

${disableComponentsProperty}

installation-type=1
${selectRepositoryType}
repositoryChoice=${repositoryType}
${databasePrefix}Host=${rdsAddress}
${databasePrefix}Port=${rdsPort}
${databasePrefix}Db=${rdsName}
${databasePrefix}Username=${rdsUsername}
${databasePrefix}UserPassword=${rdsPassword}
${databaseLocation}=0
initUserName=${initialUsername}
initUserPassword=${initialUserPassword}
_EOL_
