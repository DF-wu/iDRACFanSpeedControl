#!/bin/bash
# 2023.7.22 D.F.
# This is for setting up idrac 8 fan speed. 
# input a 1~100 decimal to determin the fan duty cycle
# example:
# iDRAC_IP=192.168.10.9
IDRAC_IP=REPLACE_TO_YOUR_IDRAC_IP
IDRAC_ID=REPLACE_TO_YOUR_IDARC_ID
IDRAC_PASSWORD=REPLACE_TO_YOUR_IDRAC_PASSWORD

echo "This is for setting up idrac 8 fan speed."
echo "input a 1~100 decimal to determin the fan duty cycle."
read fanSpeed
hexFanSpeed=$(echo "obase=16;$fanSpeed" | bc)
echo "Your input is ${fanSpeed}. The hexadecimal value is ${hexFanSpeed}."

#set fan control to manual
ipmitool -I lanplus  -H ${IDRAC_IP}  -U ${IDRAC_ID} -P ${IDRAC_PASSWORD} raw 0x30 0x30 0x01 0x00
# replace raw config 
rawConfigCommand="0x30 0x30 0x02 0xff 0x"${hexFanSpeed}
#set fan speed to target duty cycle
# ipmitool -I lanplus  -H 192.168.10.9  -U root -P zxcv6319 raw 0x30 0x30 0x02 0xff 0x25
ipmitool -I lanplus  -H ${IDRAC_IP} -U ${IDRAC_ID} -P ${IDRAC_PASSWORD} raw ${rawConfigCommand}
echo "done"
