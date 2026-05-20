#!/bin/bash
# Based on script by William Lam - http://engineering.ucsb.edu/~duonglt/vmware/
# Found at http://askubuntu.com/questions/764620/how-do-you-hotplug-enable-new-cpu-and-ram-in-a-virtual-machine

CPUS_ADDED=0
CPUS_ADDED_LIST=()
MEM_BLOCKS_ADDED=0
MEM_BLOCK_SIZE_BYTES=0
if [ -f /sys/devices/system/memory/block_size_bytes ]; then
        MEM_BLOCK_SIZE_BYTES=$((16#$(cat /sys/devices/system/memory/block_size_bytes)))
fi

# Bring CPUs online
for CPU in $(ls /sys/devices/system/cpu/ |grep -E '(cpu[0-9])')
do
        CPU_DIR="/sys/devices/system/cpu/${CPU}"
        echo "Found cpu: \"${CPU_DIR}\" ..."
        CPU_STATE_FILE="${CPU_DIR}/online"
        if [ -f "${CPU_STATE_FILE}" ]; then
                STATE=$(cat "${CPU_STATE_FILE}" | grep 1)
                if [ "${STATE}" == "1" ]; then
                        echo -e "\t${CPU} already online"
                else
                         echo -e "\t${CPU} is new cpu, onlining cpu ..."
                         echo 1 > "${CPU_STATE_FILE}"
                         CPUS_ADDED=$((CPUS_ADDED+1))
                         CPUS_ADDED_LIST+=("${CPU}")
                fi
        else
                echo -e "\t${CPU} already configured prior to hot-add"
        fi
done

# Bring all new Memory online
for RAM in $(grep line /sys/devices/system/memory/*/state)
do
        echo "Found ram: ${RAM} ..."
        if [[ "${RAM}" == *":offline" ]]; then
                echo "Bringing online"
                echo $RAM | sed "s/:offline$//"|sed "s/^/echo online > /"|source /dev/stdin
                MEM_BLOCKS_ADDED=$((MEM_BLOCKS_ADDED+1))
        else
                echo "Already online"
        fi
done

MEM_ADDED_BYTES=$((MEM_BLOCKS_ADDED * MEM_BLOCK_SIZE_BYTES))
MEM_ADDED_MB=$((MEM_ADDED_BYTES / 1024 / 1024))

echo ""
echo "===== Summary ====="
if [ "${CPUS_ADDED}" -gt 0 ]; then
        echo "CPUs brought online: ${CPUS_ADDED} (${CPUS_ADDED_LIST[*]})"
else
        echo "CPUs brought online: 0"
fi
if [ "${MEM_BLOCKS_ADDED}" -gt 0 ]; then
        echo "Memory brought online: ${MEM_BLOCKS_ADDED} block(s) = ${MEM_ADDED_MB} MB"
else
        echo "Memory brought online: 0 MB"
fi

