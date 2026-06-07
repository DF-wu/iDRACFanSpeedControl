ARG BASE_IMAGE=nvidia/cuda:12.9.0-runtime-ubuntu24.04
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="iDRAC Fan Speed Control" \
      org.opencontainers.image.description="Automatic Dell iDRAC fan control using IPMI with ESXi, iDRAC, and optional NVIDIA GPU temperature sources" \
      org.opencontainers.image.source="https://github.com/DF-wu/iDRACFanSpeedControl"

ENV DEBIAN_FRONTEND=noninteractive \
    LOG_DIR=/var/log/fan-control

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    coreutils \
    ipmitool \
    openssh-client \
    procps \
    sshpass \
    tini \
    && rm -rf /var/lib/apt/lists/*

COPY src/FanControlWithEsxiSmart.sh /usr/local/bin/fan-control.sh

RUN chmod +x /usr/local/bin/fan-control.sh \
    && bash -n /usr/local/bin/fan-control.sh \
    && /usr/local/bin/fan-control.sh help >/dev/null \
    && mkdir -p /var/log/fan-control

WORKDIR /var/log/fan-control

HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD /usr/local/bin/fan-control.sh healthcheck || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/fan-control.sh"]
