# iDRACFanSpeedControl
This is an easy interactive script to set up your Dell PowerEdge server fan Speed via ipmi command in local LAN.
I have tested it with my R730XD server and it works well. My R730XD is with **iDRAC 8**.
This script is written down as a `shell`. That's you can run it in `shell` enviroment.


## Guide
+ This script is written down as a `shell`. That's you can run it in `shell` enviroment.
  + If you are Windows user, the ipmi is also command works with windows supported ipmi binary.
1. For the very first step. You need `ipmitool` and `bc` installed. Fortunately, it's easy to find out in most package repository.
   + For `Arch-Linux` user: `sudo pacman -S ipmitool bc`.
   + For `Debian` or `Ubuntu` users: `sudo apt install ipmitool bc`.
2. Enable your iDRAC ipmi LAN function:
   + In my iDRAC 8 interface, it seems like:
     + ![Alt text](/imgaes/image.png)
3. clone this repo or just download the script.
4. Replace the variable `iDRAC_IP`,`IDRAC_ID` and `IDRAC_PASSWORD` with your iDRAC secret.
   + The result should seem like `iDRAC_IP=192.168.10.9` and etc. blababla.
5. execute the shell. `sh ./setIdracFanSpeed.` and follow the script prompt.
