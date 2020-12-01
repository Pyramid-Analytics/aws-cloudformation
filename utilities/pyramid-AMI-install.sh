#!/bin/bash
# to be run in a Pyramid Marketplace image with the product code set: 
# 3w1qq13u1dkldetc1i2g22vzv
# the license machinery in the Pyramid installer expects this exact product code
# to be avaialble
pwd
ls -lsa
amazon-linux-extras enable nginx1 R3.4 epel postgresql10
yum clean metadata

yum -y install amazon-efs-utils amazon-cloudwatch-agent postgresql nginx yum-cron
yum -y update

chkconfig yum-cron on
systemctl start yum-cron 

if [ ! -d /usr/src/pyramid ] ; then
  mkdir -p /usr/src/pyramid
fi

if [ -f ./*.run ] ; then
  if [ -f /usr/src/pyramid/*.run ] ; then
    rm -rf /usr/src/pyramid/*.run
  fi 
  mv *.run /usr/src/pyramid
  chmod 744 /usr/src/pyramid/*.run
fi

this_file_name="${0##*/}"
rsync -avr --exclude="$this_file_name" *.sh /usr/src/pyramid
chmod 744 /usr/src/pyramid/*.sh

chown root:root /usr/src/pyramid/*

ls -lsa /usr/src/pyramid

rm -rf *.run
rm -f $(find . -maxdepth 1 -type f -name "*.sh" ! -name "$this_file_name")

find /root/.*history /home/*/.*history -exec rm -f {} \;
find /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys -exec rm -f {} \;
