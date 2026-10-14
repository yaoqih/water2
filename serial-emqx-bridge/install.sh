#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run as root: sudo ./install.sh'; exit 1; }
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR=/opt/serial-emqx-bridge
install -d -o root -g root "$INSTALL_DIR"
cp -a "$SRC_DIR/serial_emqx_bridge" "$SRC_DIR/requirements.txt" "$INSTALL_DIR/"
python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"
id serial-emqx >/dev/null 2>&1 || useradd --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin serial-emqx
install -o root -g root -m 0640 "$SRC_DIR/.env.example" /etc/serial-emqx-bridge.env
install -o root -g root -m 0644 "$SRC_DIR/serial-emqx-bridge.service" /etc/systemd/system/serial-emqx-bridge.service
usermod -a -G dialout serial-emqx
chown -R root:root "$INSTALL_DIR"
systemctl daemon-reload
systemctl enable --now serial-emqx-bridge.service
echo 'Installed. Edit /etc/serial-emqx-bridge.env and restart: systemctl restart serial-emqx-bridge'
