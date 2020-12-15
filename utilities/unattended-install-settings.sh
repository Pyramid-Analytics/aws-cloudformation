#!/bin/bash
baseStackName=${1}
repositoryType=${2}
region=${3}
launching=${4:-Everything}
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

#   ProcessesToExclude:
#     Processes:
#       Router: 'linws,linrte,linte,linimdb,linai'
#       WebServer: 'linrte,linte,linrtr,linimdb,linai'
#       WebServerAndRouter: 'linrte,linte,linimdb,linai'
#       RuntimeEngine: 'linws,linte,linrtr,linimdb,linai'
#       TaskEngine: 'linws,linrte,linrtr,linimdb,linai'
#       RuntimeEngineAndTaskEngine: 'linws,linrtr,linimdb,linai'
#       RuntimeEngineAndAI: 'linws,linte,linrtr,linimdb'
#       TaskEngineAndAI: 'linws,linrte,linrtr,linimdb'
#       RuntimeAndTaskEngineAndAI: 'linws,linrtr,linimdb'
#       AIServer: 'linws,linrte,linte,linrtr,linimdb'
#       InMemoryDB: 'linws,linrte,linte,linrtr,linai'
#       Nothing: 'linws,linrte,linte,linrtr,linimdb,linai'
#       Everything: ''

set -o errexit

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
ProcessesToExclude[Everything]=''

echo "baseStackName=${baseStackName}"
echo "repositoryType=${repositoryType}"
echo "region=${region}"
echo "launching=<${launching}>"

rdsAddress=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseAddress" --region $region --output text | cut -f 7`
if [ -z "$rdsAddress" ] ; then
  echo "get-parameter /Pyramid/$baseStackName/RepositoryDatabaseAddress failed"
  exit 1
fi
rdsPort=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabasePort" --region $region --output text | cut -f 7`
rdsName=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseName" --region $region --output text | cut -f 7`
rdsUsername=`aws ssm get-parameter --name "/Pyramid/$baseStackName/RepositoryDatabaseUsername" --region $region --output text | cut -f 7`

rdsPassword=`aws secretsmanager get-secret-value --secret-id /Pyramid/$baseStackName/RepositoryDatabasePassword --region $region --output text | cut -f 4`
if [ -z "$rdsPassword" ] ; then
  echo "get-secret-value /Pyramid/$baseStackName/RepositoryDatabasePassword failed"
  exit 1
fi

initialUsername=`aws ssm get-parameter --name "/Pyramid/$baseStackName/InitialUsername" --region $region --output text | cut -f 7`
initialUserPassword=`aws secretsmanager get-secret-value --secret-id /Pyramid/$baseStackName/InitialUserPassword --region $region --output text | cut -f 4`

selectRepositoryType='selectCurrentRepository=0'
if [[ "${repositoryType}" == "newremote" ]] ; then
  selectRepositoryType='selectNewRepository=0'
fi

disableComponentsProperty=''
if [[ "${launching}"  != "Everything" ]] ; then
  disableComponentsProperty="disable-components=${ProcessesToExclude[$launching]}"
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

