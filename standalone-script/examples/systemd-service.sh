#!/bin/bash
# Generate systemd service unit for redpanda-tune.sh
#
# Usage: ./systemd-service.sh > /etc/systemd/system/redpanda-tune.service
#        systemctl daemon-reload
#        systemctl enable redpanda-tune.service

SCRIPT_PATH="${SCRIPT_PATH:-/usr/local/bin/redpanda-tune.sh}"
LOG_FILE="${LOG_FILE:-/var/log/redpanda-tune.log}"

cat <<EOF
[Unit]
Description=Redpanda Node Tuning
Documentation=https://docs.redpanda.com/
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH --log-level info
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
