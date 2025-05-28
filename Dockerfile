# Dockerfile for iDRAC Fan Speed Control with GPU Support
# 基於 NVIDIA 的 Ubuntu 24.04 基礎映像檔以支援 GPU 溫度監控
# 如果不需要 GPU 支援，可以改用 alpine:latest
FROM nvidia/cuda:12.9.0-runtime-ubuntu24.04

# 設定維護者資訊
LABEL maintainer="iDRAC Fan Control Service"
LABEL description="Intelligent fan speed control for Dell servers based on disk and GPU temperatures"

# 設定環境變數以避免互動式安裝
ENV DEBIAN_FRONTEND=noninteractive

# 安裝必要的套件
# - openssh-client: SSH 客戶端，用於連線到 ESXi 主機
# - bash: Bash shell，執行腳本所需
# - ipmitool: IPMI 工具，用於控制 iDRAC 風扇
# - bc: 基本計算器，用於十進位到十六進位轉換
# - sshpass: 提供 SSH 密碼認證功能
# - nvidia-utils-* 已包含在基礎映像檔中，提供 nvidia-smi
RUN apt-get update && apt-get install -y \
    openssh-client \
    bash \
    ipmitool \
    bc \
    sshpass \
    && rm -rf /var/lib/apt/lists/*

# 複製風扇控制腳本到容器內
COPY src/FanControlWithEsxiSmart.sh /usr/local/bin/fan-control.sh

# 設定腳本執行權限
RUN chmod +x /usr/local/bin/fan-control.sh

# 建立日誌目錄
RUN mkdir -p /var/log/fan-control

# 設定工作目錄
WORKDIR /var/log/fan-control

# 環境變數說明 (可在執行時覆蓋)
# IDRAC_IP: iDRAC 的 IP 位址
# IDRAC_ID: iDRAC 登入帳號
# IDRAC_PASSWORD: iDRAC 登入密碼
# DRIVE_DEVICE: 要監控的磁碟設備 ID
# OPERATION_MODE: 操作模式 (auto/manual)
# WITH_GPU_TEMP: 是否啟用 GPU 溫度監控 (true/false)
# CHECK_INTERVAL: 自動模式的檢查間隔 (秒)

# 健康檢查 - 檢查腳本是否能正常執行
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD pgrep -f fan-control.sh || exit 1

# 設定進入點為風扇控制腳本
ENTRYPOINT ["/usr/local/bin/fan-control.sh"]