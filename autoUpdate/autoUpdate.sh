#!/bin/bash
PATH=/usr/bin:/bin:/usr/sbin:/sbin

../firewall/firewall-enable

#Server zonder spaties
servert=$HOSTNAME


err=0
subject=""
from="autoUpdate-"$servert"@cleverit.nl"

apt-get update
if [[ $? > 0 ]]
then
        err=1
fi

apt-get -y upgrade
if [[ $? > 0 ]]
then
        err=1
fi

apt-get autoclean
if [[ $? > 0 ]]
then
        err=1
fi

if [[ $err > 0 ]]
then
    subject="ERROR - HELP linux autoUpdate voor server: $servert is mislukt!!!"
    echo "HELP ER IS EEN FOUT!!!" > ./email.txt
    echo "Server: $servert" >> ./email.txt
else
    subject="HOERA - Linux autoUpdate voor server: $servert is succesvol!!!"
    echo "HOERA het is GOED!!!" > ./email.txt
    echo "Server: $servert" >> ./email.txt
fi

cat /etc/*-release >> ./email.txt

cat ./updatelog.log >> ./email.txt
cat ./email.txt | mail -aFrom:"autoUpdate-"$servert"@cleverit.nl" -s "$subject" backup@cleverit.nl
