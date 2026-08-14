# iDRAC Fan Control 日常 Runbook

這份文件給已完成初始設定的操作者。第一次安裝、參數定義與架構請先看 [README.md](README.md)；遇到錯誤則直接跳到 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。

## 每次變更前的安全習慣

```text
編輯 .env → validate → diagnose → manual 小幅測試 → restore → 啟動 auto
```

永遠保留一個能登入 iDRAC Web UI 的工作階段。`diagnose` 只讀取，不等於 `manual` 已在你的機型上驗證；第一次仍應完成一次低速、一次保守速度與一次 restore。

## 每日操作

啟動、查看狀態與持續 log：

```bash
docker compose up -d
docker compose ps
docker logs -f idrac-fan-control
tail -f logs/fan_control.log
```

`fan_control.log` 的每一筆成功 cycle 會包含 status、決策溫度、level、fan 與來源細節。若 container 顯示 `unhealthy`，不要只重啟；先執行：

```bash
docker compose run --rm idrac-fan-control healthcheck
docker compose run --rm idrac-fan-control diagnose
```

執行一次控制（適合維護視窗）：

```bash
docker compose run --rm idrac-fan-control once
```

查看不改變風扇的摘要：

```bash
docker compose run --rm idrac-fan-control config
docker compose run --rm idrac-fan-control status
```

## TUI 設定與變更流程

```bash
make tui
```

TUI 的每個子頁會直接更新 `.env`，退出時不會自動啟動服務。建議順序：

1. `Review redacted configuration` 確認來源、曲線與 fail-safe；密碼只會顯示為 set／長度。
2. `Validate configuration` 修正所有 ERROR；不要把 WARN 當成成功的替代品。
3. `Run read-only diagnostics` 確認每個選取的 source 都是 PASS。
4. 回到 shell，執行 `docker compose up -d`。

如果只要改一個值，手動編輯 `.env` 也可以；不要直接改容器裡的檔案，因為 container 會被重建。

## 手動風扇與還原

先在低風險維護時段測試：

```bash
docker compose run --rm idrac-fan-control manual 30
docker compose run --rm idrac-fan-control status
docker compose run --rm idrac-fan-control manual 70
docker compose run --rm idrac-fan-control restore
```

`manual` 的百分比範圍是 1–100；`restore` 送出 `raw 0x30 0x30 0x01 0x01`，將控制權交還 Dell。不要用 `DRY_RUN=true` 來判斷真實硬體反應，它只會顯示命令而不觸碰 iDRAC。

## 緊急程序

遇到溫度異常、噪音失控、來源讀值不可信或不確定目前狀態時：

1. 立即還原 Dell 自動控制。

   ```bash
   docker compose run --rm idrac-fan-control restore
   ```

2. 停止 controller，避免下一個 cycle 再次覆寫設定。

   ```bash
   docker compose down
   ```

3. 從 iDRAC Web UI 或實體主控台確認溫度與風扇；必要時保持 Dell 自動模式。

4. 保存當下輸出供除錯：

   ```bash
   docker compose run --rm idrac-fan-control config > config-after-incident.txt
   docker compose run --rm idrac-fan-control diagnose 2>&1 | tee diagnose-after-incident.txt
   cp .env .env.after-incident
   chmod 600 .env.after-incident
   ```

5. 修正來源、曲線或管理網路後，重新走一次 `validate → diagnose → manual → restore`，才恢復 `auto`。

## 常見變更

### 改用 iDRAC sensors，不依賴 ESXi

```dotenv
TEMPERATURE_SOURCES=idrac
```

### 混合 ESXi 與 iDRAC

```dotenv
TEMPERATURE_SOURCES=esxi,idrac
ESXI_HOST=192.0.2.20
ESXI_USERNAME=root
ESXI_SSH_KEY=/run/secrets/esxi_ed25519
DRIVE_DEVICE=t10.NVMe____full_identifier
```

準備 key volume（不要提交 `secrets/`）：

```bash
mkdir -p secrets
cp ~/.ssh/esxi_ed25519 secrets/esxi_ed25519
chmod 600 secrets/esxi_ed25519
```

### TrueNAS CD6 與其他 VM 的 GPU

目前 TrueNAS 25.10 主機上的 Kioxia CD6 controller device 是 `/dev/nvme1`。先在 host 唯讀確認：

```bash
sudo smartctl -A -j /dev/nvme1 | jq '.temperature.current'
```

設定 CD6 與多台 NVIDIA VM：

```dotenv
TEMPERATURE_SOURCES=linux_disk,remote_gpu
LINUX_DISK_DEVICES=/dev/nvme1
LINUX_DISK_TEMP_OFFSET=0

REMOTE_GPU_HOSTS=gpu-vm-1,gpu-vm-2
REMOTE_GPU_USERNAME=monitor
REMOTE_GPU_SSH_KEY=/run/secrets/gpu_vms_ed25519
REMOTE_GPU_PASSWORD=
REMOTE_GPU_SSH_PORT=22
REMOTE_GPU_TEMP_OFFSET=15
```

在 `docker-compose.yml` 的 service 加入精確 device mapping：

```yaml
devices:
  - /dev/nvme1:/dev/nvme1
```

每台 GPU VM 必須讓該 SSH 帳號可執行唯讀的 `nvidia-smi --query-gpu=index,temperature.gpu --format=csv,noheader,nounits`。設定後先跑 `validate` 與 `diagnose`；預期同時看到 `source:linux_disk`、`source:remote_gpu` 和 decision preview。詳見 [Temperature source interface](docs/TEMPERATURE_SOURCES.md)。

### 啟用 GPU

```dotenv
TEMPERATURE_SOURCES=idrac,gpu
GPU_TEMP_OFFSET=15
```

同時確認 Compose 的 `gpus: all` 已啟用、主機有 NVIDIA Container Toolkit，再用 `diagnose` 驗證；GPU 失敗不應被悄悄當作 0°C。

### 降低閾值附近的跳速

```dotenv
HYSTERESIS=3
```

Hysteresis 只延遲降檔，不延遲升檔。若溫度持續上升，critical 仍會立即生效。

### 提高感測器失敗時的保護

```dotenv
FAILSAFE_ON_ERROR=true
FAILSAFE_FAN_SPEED=80
```

`FAILSAFE_FAN_SPEED` 必須不低於 `FAN_SPEED_CRITICAL`；`validate` 會拒絕不安全的遞減曲線。

## 更新與回復

```bash
git pull --ff-only
docker compose pull
docker compose up -d
docker compose ps
```

更新前先備份設定（不要提交到 Git）：

```bash
cp .env ".env.backup.$(date +%Y%m%d-%H%M%S)"
chmod 600 .env.backup.*
```

若新 image 行為不符預期，先 `restore`、`down`，再切回已知版本 image 或回復程式碼；不要在風扇已異常時反覆 `up`。

## 維護與驗證

```bash
make test
make validate
make docker-build
```

長時間運行請確認 `logs/` 有輪替策略；專案只負責寫入單一 log，不會替主機設定 logrotate。建議以主機的 logrotate 或 journald retention 管理容量。

文件最後檢視：2026-08-15。
