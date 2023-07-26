#!/bin/bash
# 2023.7.22 D.F.
# This is for setting up idrac 8 fan speed. 
# input a 1~100 decimal to determin the fan duty cycle
echo "This is for setting up idrac 8 fan speed.\n"
echo "input a 1~100 decimal to determin the fan duty cycle\n"
read fanSpeed
hexFanSpeed=$(echo "obase=16;$fanSpeed" | bc)
echo "Your input is ${fanSpeed}. The hexadecimal value is ${hexFanSpeed}."


#set fan control to manual
ipmitool -I lanplus  -H 192.168.10.9  -U root -P zxcv6319 raw 0x30 0x30 0x01 0x00
# replace raw config 
rawConfigCommand="0x30 0x30 0x02 0xff 0x"${hexFanSpeed}
#set fan speed to target duty cycle
# ipmitool -I lanplus  -H 192.168.10.9  -U root -P zxcv6319 raw 0x30 0x30 0x02 0xff 0x25
ipmitool -I lanplus  -H 192.168.10.9  -U root -P zxcv6319 raw ${rawConfigCommand}
echo "done"
