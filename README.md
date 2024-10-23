# iDRACFanSpeedControl
This is an easy interactive script to set up your Dell PowerEdge server fan Speed via ipmi command in local LAN.
I have tested it with my R730XD server and it works well. My R730XD is with **iDRAC 8**.
This script is written in `shell` and some packages are required. That's you can run it in most unix-like OS.

## Guide
### Prerequisites
Before starting, make sure you have `ipmitool` and `bc` installed. You can easily find these packages in most package repositories:
   + For `Arch-Linux` user: `sudo pacman -S ipmitool bc`.
   + For `Debian` or `Ubuntu` users: `sudo apt install ipmitool bc -y`.
If you are Windows user, the ipmi is also command works with windows supported ipmi binary.

### Setup 
1. Enable your iDRAC ipmi LAN function:
   + In my iDRAC 8 interface, it seems like:
     + ![Alt text](/imgaes/image.png)
2. clone this repo or just download the script.
3. Replace the variable `iDRAC_IP`,`IDRAC_ID` and `IDRAC_PASSWORD` with your iDRAC secret.
   + The result should seem like `iDRAC_IP=192.168.10.9` and etc. blababla.
4. execute the shell. `sh ./setIdracFanSpeed.` and follow the script prompt.

### Fan Control With Esxi Smart
This script is designed to control the fan speed of your Dell PowerEdge server based on the temperature of the NVMe drive. It uses the esxcli command to get the temperature of the drive and then sets the fan speed accordingly.

#### Configuration
You can configure the script by setting the following variables:

+ `TEMP_LOW`: The low temperature threshold (default: 45°C)
+ `TEMP_MEDIUM`: The medium temperature threshold (default: 55°C)
+ `TEMP_HIGH`: The high temperature threshold (default: 65°C)
+ `TEMP_CRITICAL`: The critical temperature threshold (default: 70°C)

+ `FAN_SPEED_LOW`: The low fan speed (default: 20%)
+ `FAN_SPEED_MEDIUM`: The medium fan speed (default: 30%)
+ `FAN_SPEED_HIGH`: The high fan speed (default: 40%)
+ `FAN_SPEED_CRITICAL`: The critical fan speed (default: 60%)

### Usage
Docker image is in `ghcr.io/df-wu/idrac-fan-control`. You can simply use it with [Docker](https://docs.docker.com/engine/install).

1. ![dokcer-compose.yml](/docker-compose.yml)
2. rename the `exsample.env` to `.env`.
3. modify the arrtibutes in `.env` according to your system.
4. run `docker-compose up -d`
5. done.
