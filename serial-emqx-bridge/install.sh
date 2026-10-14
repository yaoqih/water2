#!/usr/bin/env bash
set -euo pipefail
pip install paho_mqtt-2.1.0-py3-none-any.whl
pip install pyserial-3.5-py2.py3-none-any.whl
[[ $EUID -eq 0 ]] || { echo 'Run as root: sudo ./install.sh'; exit 1; }
[[ -x /usr/bin/python3 ]] || { echo 'Missing /usr/bin/python3 (Python 3.10+ required).'; exit 1; }
if ! PYTHONNOUSERSITE=1 /usr/bin/python3 - <<'PY'
import sys

if sys.version_info < (3, 10):
    sys.exit('Python 3.10+ is required.')

import serial
import paho.mqtt.client as mqtt

mqtt.CallbackAPIVersion.VERSION2
PY
then
    echo 'Install pyserial==3.5 and paho-mqtt==2.1.0 system-wide for /usr/bin/python3, then retry.'
    exit 1
fi
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR=/opt/serial-emqx-bridge
install -d -o root -g root "$INSTALL_DIR"
cp -a "$SRC_DIR/serial_emqx_bridge" "$SRC_DIR/requirements.txt" "$INSTALL_DIR/"
id serial-emqx >/dev/null 2>&1 || useradd --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin serial-emqx
install -o root -g root -m 0640 "$SRC_DIR/.env" /etc/serial-emqx-bridge.env
install -o root -g root -m 0644 "$SRC_DIR/serial-emqx-bridge.service" /etc/systemd/system/serial-emqx-bridge.service
usermod -a -G dialout serial-emqx
chown -R root:root "$INSTALL_DIR"
systemctl daemon-reload
systemctl enable --now serial-emqx-bridge.service
echo 'Installed. Edit /etc/serial-emqx-bridge.env and restart: systemctl restart serial-emqx-bridge'
