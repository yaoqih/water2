# Serial to EMQX Bridge

Reads water-quality frames from a serial port and publishes JSON telemetry to EMQX over MQTT. Tested design target: Ubuntu 22.04.

## Protocol

Frames start with `BG` and end with `ED`:

```text
BG,TEMP:+00238,ZD:00695,XFW:02524,COD:00972,AD:01982,JY:03299,ED

```

Scaling is applied as follows: `TEMP`, `ZD`, `XFW`, `COD`, and `JY` divide by 10; `AD` divides by 100. The published payload includes the scaled values and the original integer values.

## Run locally

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
python -m serial_emqx_bridge
```

Set `SERIAL_DRY_RUN=1` to parse `SERIAL_SAMPLE` without opening a serial device.

## Install as a service on Ubuntu 22.04

Copy this directory to the target host, review `.env`, then run as root:

```bash
sudo ./install.sh
```

The installer creates `/opt/serial-emqx-bridge`, a restricted `serial-emqx` user, and enables `serial-emqx-bridge.service`.

## Example decoded payload

The sample above becomes `TEMP=23.8`, `ZD=69.5`, `XFW=252.4`, `COD=97.2`, `AD=19.82`, and `JY=3299.0`.
