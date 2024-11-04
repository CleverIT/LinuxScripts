#!/bin/bash
# Gemaakt door MC, vraag hem voor meer info!
set -e

if [[ $# -ne 2 ]] ; then
    echo -e '\e[1;33mUSAGE: resize.sh [DEVICE] [PARTITIONNUMBER]'
    echo -e "ie: resize.sh /dev/sda 3\e[0m"
    exit 1
fi

DEVICE=$1
PARTNR=$2

echo "Dit script gaat nu ${DEVICE}${PARTNR} vergoten naar de rest van de disk"
echo "Misschien snapshot maken, gebruik op eigen risico!"
echo -e "\e[1;4;31mLET OP! Werkt waarschijnlijk alleen als de uit te breiden partitie de laatste partitie op de disk is!!!!!!!!"
echo -e "*******Controleer nu ZELF of ${DEVICE}${PARTNR} in de kolom start het hoogste nummer heeft****\e[0m"
fdisk -l
echo "Druk op een toets als alles goed is of ctrl+c om af te sluiten"
read -n 1 -s


echo "Bezig met disk rescan..."
for scsi in /sys/class/scsi_device/*; do
    echo 1 > ${scsi}/device/rescan
done
sleep 5

MAXSIZEMB=`printf %s\\n 'unit MB print list' | parted | grep "Disk ${DEVICE}" | cut -d' ' -f3 | tr -d MB`

echo "Disk is ${MAXSIZEMB} MB groot."
echo "Druk op een toets om de partitie te vergroten"
echo "CJ: Indien 'Error: Invalid number' dan komt dit door andere syntax van het parted commando. Gebruik parted ${DEVICE} resizepart ${PARTNR} ${MAXSIZEMB}"

read -n 1 -s
parted ${DEVICE} resizepart ${PARTNR} ${MAXSIZEMB}

echo "Partitie is vergroot, nu nog even filesystem resizen"
resize2fs ${DEVICE}${PARTNR}
echo "Klaar!"
