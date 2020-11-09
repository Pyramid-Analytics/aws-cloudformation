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
# Specific logic for mounting the IMDB file system.
#
# Parameters:
# mode=${mode:-imdbPostInstall}
# efsId=${efsId}
# mountPoint=${mountPoint:-/mnt/pyramid}
# subnet
# securityGroup
# installLocation=${installLocation:-/opt/Pyramid}
# dataLocation=${dataLocation:-/opt/Pyramid/repository}
#
# So minimal use is:
# mnt-efs-helper-imdb.sh --efsId fs-24334234 --subnet subnet-055fb67972f8052d2 --securityGroup sg-0667a5ea299a0e03c
#
# Run before Pyramid install (--mode mountOnly):
#   Assumes that there is no content on the instance to be saved to the new mount.
#   Eg.: --mode mountOnly --efsId fs-2347290 --mountPoint <mount point directory>
#   In the unattended install file,
#   Set the data-location=/mnt/pyramid
#
#   The full set of files of the data-location will be on the EFS mount.
#
# Run post Pyrmaid install - the default (--mode imdbPost):
#   Only sets the mount for the imdata in the data-location
#   Eg.: --mode imdbPost --efsId fs-2347290 --mountPoint <mount point directory> --dataLocation <data-location> --installLocation <install-location>
#
# This script can only run on an AWS instance. It must run as root, and be
# invoked at instance startup: cf-init, user data
#
 
set -o errexit

# ----------------------------------------------------------------------------
# Set and validate parameters
# ----------------------------------------------------------------------------

mode=${mode:-imdbPostInstall}
efsId=${efsId}
mountPoint=${mountPoint:-/mnt/pyramid}
installLocation=${installLocation:-/opt/Pyramid}
dataLocation=${dataLocation:-/opt/Pyramid/repository}
subnet=
securityGroup=
region=

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

if [[ "${mode}" != 'imdbPostInstall' && "${mode}" != 'mountOnly' ]] ; then
  echo "--mode must be 'imdbPostInstall' or 'mountOnly'"
  exit 1
fi

if [[ -z "${efsId}" ]] ; then
  echo "efsId not set"
  exit 1
fi

if [[ -z "${subnet}" ]] ; then
  echo "subnet not set"
  exit 1
fi

if [[ -z "${securityGroup}" ]] ; then
  echo "securityGroup not set"
  exit 1
fi

if [[ -z "${region}" ]] ; then
  echo "region not set"
  exit 1
fi

# create a mount target group if needed
create_mount_target $efsId $subnet $securityGroup $region
if [ $? -ne 0 ] ; then
 echo "create_mount_target failed"
 exit 1
fi

if [ "${mode}" = 'imdbPostInstall' ] ; then
  if [[ ! -f "${installLocation}/config.ini" ]] ; then
    echo "Pyramid install in ${installLocation} does not exist. exiting..."
    exit 1
  fi
  if [[ ! -d "${dataLocation}" ]] ; then
    echo "Pyramid data-location in ${dataLocation} does not exist. exiting..."
    exit 1
  fi

  # Stop the IMDB service
  systemctl stop pyramidIMDB
fi
 
# ----------------------------------------------------------------------------
# Create mount point directory
# ----------------------------------------------------------------------------
# if the mountPoint directory does not exist
if [ ! -d "${mountPoint}" ] ; then
  mkdir -p "${mountPoint}"
else
  # fail if the mountPoint already exists
  echo "mountPoint directory ${mountPoint} already exists. exiting..."
  exit 1
fi

echo "About to mount $efsId to $mountPoint"

# Mount the EFS volume using the AWS EFS helper
# IAM is used for authentication to EFS
sleepTime=20
maxTimes=40
notificationCount=5
count=0
while true
do
  mount -t efs -o tls,iam $efsId $mountPoint && break
  count=$(( count + 1  ))
  if [ "$count" -ge "$maxTimes" ] ; then
    echo "Mount did not succeed after ${maxTimes} tries, waiting ${sleepTime} seconds between tries... Exiting"
    exit 1
  elif  ! (( count % notificationCount )) ; then
      echo "Mount did not succeed ...continuing to wait"
  fi
  sleep $sleepTime
done

echo "Mounted EFS $efsId to $mountPoint"

# work is done for mountOnly
if [ "${mode}" = 'mountOnly' ] ; then
  exit 0
fi

# Only imdbPostInstall from now on

# Copy current imdata into the EFS volume 
if [[ "$(ls -A ${dataLocation}/imdata)" ]] ; then
  cp -p -R "${dataLocation}/imdata"/. "${mountPoint}"
  echo "Moved on-instance IMDATA to EFS"
fi

# Update the config.ini reference for the IMDB datadirlocal= to the mountPoint
sed -i "s|datadirlocal=.*|datadirlocal=$mountPoint|" "$installLocation/config.ini"


# Restart the IMDB service
systemctl start pyramidIMDB

