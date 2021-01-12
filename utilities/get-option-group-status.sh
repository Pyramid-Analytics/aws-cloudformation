  #!/bin/bash
rdsServiceName=$1
waitForInSync=${2:-true}
targetOptionGroup=$3

# return var
# find current in-sync option group
# wait for the $targetOptionGroup to be in-sync

TOKEN=`curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`

region=`curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document | grep -oP '\"region\"[[:space:]]*:[[:space:]]*\"\K[^\"]+'`

# Wait for the modify to work
sleepTime=20
maxTimes=10
notificationCount=5
count=0
while true
do
    currentOptionGroups=`aws rds describe-db-instances --db-instance-identifier $rdsServiceName --region $region --output text  | grep OPTIONGROUPMEMBERSHIPS`

    if [ -z "$currentOptionGroups" ] ; then
	>&2 echo "describe-db-instances failed"
	exit 1
    fi
    currentOptionGroup=
    status=
    returnValue=

    while read -r c1 c2 c3 ; do
        currentOptionGroup="$c2"
        status="$c3"
        >&2 echo "found option group: $currentOptionGroup, status $status"
        if [ "$status" = "in-sync" ] ; then
            if [ "$waitForInSync" != "true" ] ; then
                returnValue=$currentOptionGroup
                break
            elif [[ "$waitForInSync" = "true" && "$currentOptionGroup" = "$targetOptionGroup" ]] ; then
                returnValue=$targetOptionGroup
                break
            fi
        fi
    done <<< "$currentOptionGroups"

    if [ ! -z "$returnValue" ] ; then
        echo "$returnValue"
        break
    fi 

    count=$(( count + 1  ))
    if [ "$count" -ge "$maxTimes" ] ; then
        >&2 echo "Option group update did not succeed after ${maxTimes} tries, waiting ${sleepTime} seconds between tries... Exiting"
        exit 1
    elif  ! (( count % notificationCount )) ; then
        >&2 echo "Option group update in progress: $status ...continuing to wait"
    fi
    sleep $sleepTime
done
