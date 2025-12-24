#!/bin/bash

CRON_TIME="0 2 * * *" # 02:00 hàng ngày
CRON_CMD="$INSTALL_DIR/backup_cron_runner.sh"

enable_cron() {
  (crontab -l 2>/dev/null | grep -v "$CRON_CMD"
   echo "$CRON_TIME bash $CRON_CMD >> /var/log/n8n-backup.log 2>&1") | crontab -
  echo "✅ Đã bật backup tự động (02:00 mỗi ngày)"
}

disable_cron() {
  crontab -l 2>/dev/null | grep -v "$CRON_CMD" | crontab -
  echo "🛑 Đã tắt backup tự động"
}

status_cron() {
  crontab -l | grep "$CRON_CMD" || echo "⚠️ Backup tự động chưa bật"
}

case "$1" in
  enable) enable_cron ;;
  disable) disable_cron ;;
  status) status_cron ;;
  *) echo "Usage: $0 {enable|disable|status}" ;;
esac