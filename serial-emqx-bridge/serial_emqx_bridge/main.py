import json
import logging
import os
import time

from .parser import FrameBuffer, parse_frame

LOG = logging.getLogger("serial-emqx-bridge")


def env(name: str, default: str) -> str:
    return os.environ.get(name, default)


def publish(client, payload: dict) -> None:
    topic = env("MQTT_TOPIC", "water/serial/v1/telemetry")
    info = client.publish(topic, json.dumps(payload, separators=(",", ":")), qos=int(env("MQTT_QOS", "1")))
    info.wait_for_publish()


def run() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if env("SERIAL_DRY_RUN", "0") == "1":
        result = parse_frame(env("SERIAL_SAMPLE", ""))
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return
    import paho.mqtt.client as mqtt
    import serial

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=env("MQTT_CLIENT_ID", ""))
    username = env("MQTT_USERNAME", "device_user")
    if username:
        client.username_pw_set(username, env("MQTT_PASSWORD", "0ebec348c00d38f7c9ab32f2"))
    client.connect(env("MQTT_HOST", "water.blenet.top"), int(env("MQTT_PORT", "1883")), 60)
    client.loop_start()
    buffer = FrameBuffer()
    while True:
        try:
            with serial.Serial(env("SERIAL_PORT", "/dev/ttyS0"), int(env("SERIAL_BAUDRATE", "115200")), timeout=float(env("SERIAL_TIMEOUT", "1"))) as port:
                LOG.info("reading %s", port.port)
                while True:
                    for frame in buffer.feed(port.read(port.in_waiting or 1)):
                        try:
                            result = parse_frame(frame)
                            publish(client, result)
                            LOG.info("published telemetry: %s", result["values"])
                        except ValueError as exc:
                            LOG.warning("discarding invalid frame: %s (%s)", frame, exc)
        except (serial.SerialException, OSError) as exc:
            LOG.error("serial device unavailable: %s; retrying in 5s", exc)
            time.sleep(5)


if __name__ == "__main__":
    run()
