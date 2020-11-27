#!/bin/bash
#
# After installation of an IMDB, move the IMDB files to a
# directory on the shared EFS volume.
#
# Parameters:
# mountPoint=${mountPoint:-/mnt/pyramid-imdb}
# installLocation=${installLocation:-/opt/Pyramid}
# dataLocation=${dataLocation:-/opt/Pyramid/repository}
# baseStackName=
# currentStackName=

#
# This script can only run on an AWS instance with Pyramid already installed.
#
set -o errexit

# ----------------------------------------------------------------------------
# Set and validate parameters
# ----------------------------------------------------------------------------

mountPoint=${mountPoint:-/mnt/pyramid-imdb}
installLocation=${installLocation:-/opt/Pyramid}
dataLocation=${dataLocation:-/opt/Pyramid/repository}
baseStackName=
currentStackName=
initialize=${initialize:-false}
##########################################
# main script

while [ $# -gt 0 ]; do
  if [[ $1 == *"--"* ]]; then
    param="${1/--/}"
    declare $param="$2"
    echo $1 $2 # Optional: to see the parameter:value result
    shift
  fi
  shift
done

if [[ -z "${baseStackName}" ]] ; then
  echo "baseStackName not set"
  exit 1
fi

if [[ -z "${currentStackName}" ]] ; then
  echo "currentStackName not set"
  exit 1
fi

if [[ -z "${subnet}" ]] ; then
  echo "subnet not set"
  exit 1
fi

if [[ -z "${region}" ]] ; then
  echo "region not set"
  exit 1
fi

if [[ -z "${mountPoint}" ]] ; then
  echo "mountPoint not set"
  exit 1
fi

if [[ -z "${efsId}" ]] ; then
  efsId=`aws ssm get-parameter --name "/Pyramid/$baseStackName/SharedFileSystem" --region $region --output text | cut -f 7`
  if [[ -z "${efsId}" ]] ; then
    echo "efsId not set"
    exit 1
  fi
fi

if [[ -z "${securityGroup}" ]] ; then
  securityGroup=`aws ssm get-parameter --name "/Pyramid/$baseStackName/MountTargetSecurityGroup" --region $region --output text | cut -f 7`
  if [[ -z "${efsId}" ]] ; then
    echo "securityGroup not set"
    exit 1
  fi
fi

if [[ -z "${installLocation}" ]] ; then
  echo "installLocation not set"
  exit 1
fi

if [[ -z "${dataLocation}" ]] ; then
  echo "dataLocation not set"
  exit 1
fi

if [[ ! -f "${installLocation}/config.ini" ]] ; then
  echo "Pyramid config.ini in ${installLocation} does not exist. exiting..."
  exit 1
fi
if [[ ! -d "${dataLocation}" ]] ; then
  echo "Pyramid data-location directory ${dataLocation} does not exist. exiting..."
  exit 1
fi

# Single EFS volume now
# /mnt/pyramid
#   /imdb/<id>
#     individual imdata directories
#     current list in ssm baseStack/stack/IMDBFileSystem = <id> vs list of imdb/<id>
#     if list of imdb/<id> is longer than baseStack/stack/IMDBFileSystem
#       use next imdb/<id> -> baseStack/stack/IMDBFileSystem
#     else
#       create new imdb/<id>
#     fs:imdb/<id> to /mnt/pyramid-imdb

tempMountPoint="/tmp${mountPoint}"
echo "mounting efs/imdb to /tmp to check what is there"
/usr/src/pyramid/mnt-efs.sh \
  --mountPoint $tempMountPoint \
  --subnet $subnet \
  --securityGroup $securityGroup \
  --efsId $efsId \
  --region $region

if [ ! -d $tempMountPoint/imdb ] ; then 
  mkdir $tempMountPoint/imdb
  chown pyramid:pyramid $tempMountPoint/imdb
fi 
EFSImdbGUIDs=( $(ls -l $tempMountPoint/imdb | grep '^d' | cut -d " " -f 9) )

echo "Current IMDBs in EFS: ${EFSImdbGUIDs}"

# what IMDBs have we already configured for this deployment?

currentDeploymentImdbGUIDs=()

ssmParams=`aws ssm get-parameters-by-path --path "/Pyramid/$baseStackName" --recursive --region $region --output text`
# looking for SSM parameters of the forms:
#    '/Pyramid/$baseStackName/${AWS::StackName}/IMDBFileSystem'

while read line ; do
  name=`echo $line | cut -d " " -f 5`
  endPortion=`echo $name | cut -d '/' -f 5`

  # echo "<$name> **** <$endPortion>"
  if [[ "${endPortion}" = "IMDBFileSystem" ]] ; then
    fileSystemGUID=`echo $line | cut -d " " -f 7`
    currentDeploymentImdbGUIDs+=$fileSystemGUID
  fi
done <<< "$ssmParams"

echo "Current IMDBs deployed against instances: ${EFSImdbGUIDs}"

for target in "${currentDeploymentImdbGUIDs[@]}"; do
  for i in "${!EFSImdbGUIDs[@]}"; do
    if [[ ${EFSImdbGUIDs[i]} = $target ]]; then
      unset 'EFSImdbGUIDs[i]'
    fi
  done
done

echo "Not yet deployed IMDBs in EFS: ${EFSImdbGUIDs}"

EFSImdbGUIDsSize=${#EFSImdbGUIDs[@]}
echo "Number of Not yet deployed IMDBs in EFS: ${EFSImdbGUIDsSize}"

if [[ $EFSImdbGUIDsSize > 0 ]] ; then 
  GUIDToDeploy=${EFSImdbGUIDs[0]}
  echo "Using existing GUID directory for IMDB: $GUIDToDeploy. Containing:"
  ls -l $tempMountPoint/imdb/$GUIDToDeploy
  initialize=false
else
  GUIDToDeploy=`date +"%Y-%m-%d-%H-%m-%s%z"`
  echo "creating GUID directory for new IMDB: $GUIDToDeploy"
  mkdir $tempMountPoint/imdb/$GUIDToDeploy
  chown pyramid:pyramid $tempMountPoint/imdb/$GUIDToDeploy
fi

umount $tempMountPoint
rm -rf $tempMountPoint

echo "mounting $efsId:/imdb/$GUIDToDeploy to $mountPoint"
/usr/src/pyramid/mnt-efs.sh \
  --mountPoint $mountPoint \
  --subnet $subnet \
  --securityGroup $securityGroup \
  --efsId $efsId \
  --efsRootDirectory /imdb/$GUIDToDeploy \
  --region $region

# Stop the IMDB service
systemctl stop pyramidIMDB

# we are going to mount imdata at ${dataLocation}

# If new, Copy current imdata into the EFS volume 
if [[ "${initialize}" == "true" ]] ; then
  cp -p -R $dataLocation/imdata/. $mountPoint
  echo "Initialized IMDB files with on-instance IMDATA"
fi

# Update the config.ini reference for the IMDB datadirlocal= to the mountPoint
sed -i "s|datadirlocal=.*|datadirlocal=$mountPoint|" "$installLocation/config.ini"

echo "IMDB files at $mountPoint are:"
ls -l $mountPoint

# Restart the IMDB service
systemctl start pyramidIMDB

# create SSM param 
aws ssm put-parameter \
  --name "/Pyramid/$baseStackName/$currentStackName/IMDBFileSystemId" \
  --type String \
  --value $GUIDToDeploy \
  --overwrite \
  --region $region
