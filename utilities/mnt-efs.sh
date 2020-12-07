#!/bin/bash
#
# Set up an EFS mount on an instance.
#
# Create the mount target if one has not been created for
# the AZ the subnet is attached to.
# 
# Create the  --mountPoint <mount point directory> and mount an Elastic File
# System (EFS) id --efsId <EFS ID> to it.
#
# Parameters:
# efsId=${efsId}
# mountPoint=${mountPoint:-/mnt/pyramid}
# efsRootDirectory=${efsRootDirectory:-/}
# ownership=${ownership:-pyramid:pyramid}
# subnet
# securityGroup
# region
# baseStackName
#
# So minimal use is:
# mnt-efs.sh \
#   --efsId fs-24334234 \
#   --subnet subnet-055fb67972f8052d2 \
#   --securityGroup sg-0667a5ea299a0e03c \
#   --region us-east-1
# or
# mnt-efs.sh \
#   --baseStackName Pyramid-2020-14-existing-db-4 \
#   --subnet subnet-055fb67972f8052d2 \
#   --region us-east-1
##
# This script can only run on an AWS instance. It must run as root, and be
# invoked at instance startup: cf-init, user data
#

set -o errexit

# ----------------------------------------------------------------------------
# Set and validate parameters
# ----------------------------------------------------------------------------

efsId=${efsId}
efsRootDirectory=${efsRootDirectory:-/}
mountPoint=${mountPoint:-/mnt/pyramid}
ownership=${ownership:-pyramid:pyramid}
# subnet=
securityGroup=
# region=
baseStackName=

wait_for_mount_target_availability() {
  local mountTarget=${1}
  local region=${2}

  echo "Waiting for mount target $mountTarget to be available"
  local maxTimes=30
  local sleepTime=10
  local count=0
  local notificationCount=5
  while true
  do
    describeMT=`aws efs describe-mount-targets --mount-target-id $mountTarget --region $region --output text`
    mt_status=$( echo "$describeMT" | cut -f 6 )
    if [ "${mt_status}" = "available" ] ; then
      break
    fi
    count=$(( count + 1  ))
    if [ "$count" -ge "$maxTimes" ] ; then
      echo "Mount target status is $mt_status. Did not become available after ${maxTimes} tries, waiting ${sleepTime} seconds between tries... Exiting"
      return 1
    elif  ! (( count % notificationCount )) ; then
      echo "Mount target status is $mt_status ...continuing to wait"
    fi
    sleep $sleepTime
  done
  echo "Mount target $mountTarget is available"
  return 0
}

create_mount_target() {
  local efsId=${1}
  local subnet=${2}
  local securityGroup=${3}
  local region=${4}

  # Subnet AZ
  subnetAZ=`aws ec2 describe-subnets --subnet-ids $subnet --region $region --output text | grep '^SUBNETS' | cut -f 3` || return 1
  local foundAZ=1

  allMountTargets=`aws efs describe-mount-targets --file-system-id $efsId --region $region --output text`
  if [ $? -ne 0 ] ; then
    return 1
  fi
  while read line ; do
    az=$( echo "$line" | cut -f 3 )
    mt_status=$( echo "$line" | cut -f 6 )
    mountTarget=$( echo "$line" | cut -f 7 )
    if [ "${az}" = "${subnetAZ}" ] ; then
      if [ "${mt_status}" != 'available' ] ; then
        wait_for_mount_target_availability $mountTarget $region
        if [ $? -ne 0 ] ; then
          return 1
        fi
      fi
      foundAZ=0
      break
    fi
  done <<< "$allMountTargets"

  if [ $foundAZ = 0 ]; then
    echo "Mount target for $efsId in $subnetAZ already existed"
    return 0
  fi
  echo "About to create mount target for file system: $efsId in AZ: $subnetAZ"
  newMountTargetResult=`aws efs create-mount-target \
      --file-system-id $efsId \
      --subnet-id $subnet \
      --security-groups $securityGroup \
      --region $region \
      --output text`
  if [ $? -ne 0 ] ; then
    echo "create-mount-target failed"
    return 1
  fi
  mt_id=$( echo "$newMountTargetResult" | cut -f 6 )

  wait_for_mount_target_availability $mt_id $region
  return $?
}

mount_efs() {
  local efsId=${1}
  local mountPoint=${2}
  local efsRootDirectory=${3:-/}
  local ownership=${4:"pyramid:pyramid"}

  # ----------------------------------------------------------------------------
  # Create mount point directory
  # ----------------------------------------------------------------------------
  # if the mountPoint directory does not exist
  if [ ! -d "${mountPoint}" ] ; then
    mkdir -p "${mountPoint}"
    chown "${ownership}" "${mountPoint}"
  else
    # fail if the mountPoint already exists
    echo "mountPoint directory ${mountPoint} already exists. exiting..."
    exit 1
  fi

  # Mount the EFS volume using the AWS EFS helper
  # IAM is used for authentication to EFS
  local sleepTime=20
  local maxTimes=40
  local notificationCount=5
  local count=0
  while true
  do
    mount -t efs -o tls,iam $efsId:$efsRootDirectory $mountPoint && break
    count=$(( count + 1  ))
    if [ "$count" -ge "$maxTimes" ] ; then
      echo "Mount did not succeed after ${maxTimes} tries, waiting ${sleepTime} seconds between tries... Exiting"
      exit 1
    elif  ! (( count % notificationCount )) ; then
        echo "Mount did not succeed ...continuing to wait"
    fi
    sleep $sleepTime
  done
}

##########################################
# main script

while [ $# -gt 0 ]; do
  if [[ $1 == *"--"* ]]; then
    param="${1/--/}"
    declare $param="$2"
    echo $1 $2 # see the parameter:value result
    shift
  fi
  shift
done

TOKEN=`curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`

mac=`curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/mac`

subnet=`curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/network/interfaces/macs/$mac/subnet-id`

region=`curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep -oP '\"region\"[[:space:]]*:[[:space:]]*\"\K[^\"]+'`

if [[ -z "${subnet}" ]] ; then
  echo "subnet not set"
  exit 1
fi

if [[ -z "${region}" ]] ; then
  echo "region not set"
  exit 1
fi


if [[ -z "${efsId}" ]] ; then
  if [[ ! -z "${baseStackName}" ]] ; then
    efsId=`aws ssm get-parameter --name "/Pyramid/$baseStackName/SharedFileSystem" --region $region --output text | cut -f 7`
  fi
  if [[ -z "${efsId}" ]] ; then
    echo "efsId not set"
    exit 1
  fi
fi

if [[ -z "${securityGroup}" ]] ; then
  if [[ ! -z "${baseStackName}" ]] ; then
    securityGroup=`aws ssm get-parameter --name "/Pyramid/$baseStackName/MountTargetSecurityGroup" --region $region --output text | cut -f 7`
  fi
  if [[ -z "${efsId}" ]] ; then
    echo "securityGroup not set"
    exit 1
  fi
fi


# create a mount target group if needed
create_mount_target $efsId $subnet $securityGroup $region
if [ $? -ne 0 ] ; then
echo "create_mount_target failed"
exit 1
fi

if [[ "$efsRootDirectory" != "/" ]] ; then
  echo "Making sure $efsId:$efsRootDirectory exists"

  tmpMountPoint="/tmp${mountPoint}"
  mount_efs $efsId $tmpMountPoint

  if [ ! -d "${tmpMountPoint}${efsRootDirectory}" ] ; then
    mkdir -p "${tmpMountPoint}${efsRootDirectory}"
    chown pyramid:pyramid "${tmpMountPoint}${efsRootDirectory}"
  fi

  umount $tmpMountPoint
  rm -rf $tmpMountPoint
fi 

echo "About to mount $efsId:$efsRootDirectory to $mountPoint"

mount_efs $efsId $mountPoint $efsRootDirectory

echo "Mounted EFS $efsId:$efsRootDirectory to $mountPoint"
