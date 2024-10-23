# Use Alpine as the base image for its small size
FROM alpine:latest

# Install required packages (ipmitool, bash, bc for hex conversion)
RUN apk add --no-cache bash ipmitool bc

# Copy the fan control script into the container
COPY fan_control.sh /usr/local/bin/fan_control.sh

# Make the script executable
RUN chmod +x /usr/local/bin/fan_control.sh

# Set the environment variables (you can override these during runtime)
ENV IDRAC_IP="REPLACE_TO_YOUR_IDRAC_IP"
ENV IDRAC_ID="REPLACE_TO_YOUR_IDRAC_ID"
ENV IDRAC_PASSWORD="REPLACE_TO_YOUR_IDRAC_PASSWORD"
ENV DRIVE_DEVICE="t10.NVMe____KCD61LUL7T68_________________________"
ENV OPERATION_MODE="auto"

# Set the entrypoint to the fan control script
ENTRYPOINT ["/usr/local/bin/fan_control.sh"]
