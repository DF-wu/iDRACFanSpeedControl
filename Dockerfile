# Dockerfile
# Use Alpine  as the base image for its small size
FROM alpine:lastest⁠

# Install required packages (ipmitool, bash, bc for hex conversion)
RUN apk add --no-cache --version bash ipmitool bc

# Copy the fan control script into the container
COPY src/FanControlWithEsxiSmart.sh /usr/local/bin/fan_control.sh

# Copy the set IDRAC fan speed script into the container
COPY src/setIdracFanSpeed.sh /usr/local/bin/set_idrac_fan_speed.sh
RUN chmod 755 /usr/local/bin/set_idrac_fan_speed.sh

# Copy the environment file into the container
COPY .env /usr/local/bin/.env

# optional
# Set the environment variables (you can override these during runtime)
# ENV IDRAC_IP="REPLACE_TO_YOUR_IDRAC_IP"
# ENV IDRAC_ID="REPLACE_TO_YOUR_IDRAC_ID"
# ENV IDRAC_PASSWORD="REPLACE_TO_YOUR_IDRAC_PASSWORD"
# ENV DRIVE_DEVICE="t10.NVMe____KCD61LUL7T68_________________________"
# ENV OPERATION_MODE="auto"

# Set the working directory to /usr/local/bin
WORKDIR /usr/local/bin

# Set the entrypoint to the fan control script
ENTRYPOINT ["/usr/local/bin/fan_control.sh"]