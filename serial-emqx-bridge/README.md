# Serial to EMQX Bridge

Reads water-quality frames from a serial port and publishes JSON telemetry to EMQX over MQTT. Tested design target: Ubuntu 22.04.

## Protocol

Frames start with `BG` and end with `ED`:

```text
BG,TEMP:+00238,ZD:00695,XFW:02524,COD:00972,AD:01982,JY:03299,ED

```

Scaling is applied as follows: `TEMP`, `ZD`, `XFW`, and `COD` divide by 10; `AD` divides by 100. `JY` is the decimal checksum: sum all ASCII bytes from `BG` through the `JY:` label, excluding the checksum digits, then compare it with the `JY` number. The bridge publishes flat server metric names: `watert`, `turbidity`, `ss`, `cod`, and `amnitro`.

The default destination is `water/raw/v1/plant_cqbb_liaoning53/pt_cqbb_liaoning53_inlet/dev_cqbb_liaoning53_in_04/telemetry`, with MQTT Client ID `dev_cqbb_liaoning53_in_04`, serial port `/dev/ttyS0`, and baud rate `115200`. Invalid frames and checksum mismatches are discarded.

On the server, `rule_water_raw_json_telemetry` in `scripts/stack.sh` removes `/raw` from the topic supplied to `ingest_telemetry()` and preserves the original publisher Client ID. This path writes the already-decoded JSON directly, without creating a second MQTT connection with the same ID. The database must have an enabled device matching the topic. Modbus raw messages still use `decoder-aggregator`.

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

Copy this directory to the target host. The service uses the host's `/usr/bin/python3` (Python 3.10+) with dependencies installed system-wide. Install the dependencies and prepare `.env`:

```bash
sudo /usr/bin/python3 -m pip install -r requirements.txt
cp .env.example .env
# Review .env before installing the service.
sudo ./install.sh
```

For an offline paho-mqtt installation, use the local wheel:

```bash
sudo /usr/bin/python3 -m pip install --no-index ../paho_mqtt-2.1.0-py3-none-any.whl
```

`pyserial==3.5` must also be installed system-wide. The installer checks the Python version and dependencies before creating `/opt/serial-emqx-bridge`, a restricted `serial-emqx` user, and enabling `serial-emqx-bridge.service`.

## Example decoded payload

The sample above becomes `{"watert":23.8,"turbidity":69.5,"ss":252.4,"cod":97.2,"amnitro":19.82}`.
