from __future__ import annotations

import json
import logging
import os
import threading
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from .aggregation import DecodedTelemetry, MinuteAggregator
from .config import load_profiles
from .modbus import parse_read_frames
from .profiles import decode_read_frames, select_profile
from .topics import build_standard_topic, parse_raw_topic

LOG = logging.getLogger(__name__)


def _require_paho() -> Any:
    try:
        import paho.mqtt.client as mqtt
    except ImportError as exc:  # pragma: no cover - exercised in container/runtime
        raise RuntimeError("paho-mqtt is required to run decoder-aggregator") from exc
    return mqtt


@dataclass(frozen=True)
class RuntimeSettings:
    mqtt_host: str
    mqtt_port: int
    mqtt_username: str
    mqtt_password: str
    raw_topic_pattern: str
    config_path: str
    subscriber_client_id: str
    subscribe_qos: int
    publish_qos: int
    flush_delay_sec: int
    keepalive_sec: int
    flush_poll_sec: float

    @classmethod
    def from_env(cls) -> "RuntimeSettings":
        return cls(
            mqtt_host=os.environ.get("DECODER_MQTT_HOST", "emqx"),
            mqtt_port=int(os.environ.get("DECODER_MQTT_PORT", "1883")),
            mqtt_username=os.environ["DECODER_MQTT_USERNAME"],
            mqtt_password=os.environ["DECODER_MQTT_PASSWORD"],
            raw_topic_pattern=os.environ.get("DECODER_RAW_TOPIC", "water/raw/v1/+/+/+/telemetry"),
            config_path=os.environ.get("DECODER_CONFIG_PATH", "/app/config/devices.json"),
            subscriber_client_id=os.environ.get("DECODER_SUBSCRIBER_CLIENT_ID", "decoder_aggregator_sub"),
            subscribe_qos=int(os.environ.get("DECODER_SUBSCRIBE_QOS", "1")),
            publish_qos=int(os.environ.get("DECODER_PUBLISH_QOS", "1")),
            flush_delay_sec=int(os.environ.get("DECODER_FLUSH_DELAY_SEC", "5")),
            keepalive_sec=int(os.environ.get("DECODER_KEEPALIVE_SEC", "30")),
            flush_poll_sec=float(os.environ.get("DECODER_FLUSH_POLL_SEC", "1.0")),
        )


class DecoderAggregatorService:
    def __init__(self, settings: RuntimeSettings) -> None:
        self.settings = settings
        self.profile_registry = load_profiles(settings.config_path)
        self.aggregator = MinuteAggregator(flush_delay_sec=settings.flush_delay_sec)
        self._mqtt = _require_paho()
        self._subscriber = self._create_subscriber_client()
        self._publisher_clients: dict[str, Any] = {}
        self._publishers_lock = threading.Lock()
        self._stop_event = threading.Event()
        self._subscriber_ready = threading.Event()
        self._startup_error: RuntimeError | None = None

    def _create_subscriber_client(self) -> Any:
        client = self._mqtt.Client(client_id=self.settings.subscriber_client_id)
        client.username_pw_set(self.settings.mqtt_username, self.settings.mqtt_password)
        client.on_connect = self._on_connect
        client.on_message = self._on_message
        client.enable_logger(LOG)
        return client

    def _create_publisher_client(self, device_id: str) -> Any:
        client = self._mqtt.Client(client_id=device_id)
        client.username_pw_set(self.settings.mqtt_username, self.settings.mqtt_password)
        client.enable_logger(LOG)
        client.connect(self.settings.mqtt_host, self.settings.mqtt_port, self.settings.keepalive_sec)
        client.loop_start()
        return client

    def _get_publisher(self, device_id: str) -> Any:
        with self._publishers_lock:
            client = self._publisher_clients.get(device_id)
            if client is None:
                client = self._create_publisher_client(device_id)
                self._publisher_clients[device_id] = client
            return client

    def _discard_publisher(self, device_id: str) -> None:
        with self._publishers_lock:
            client = self._publisher_clients.pop(device_id, None)
        if client is None:
            return
        client.loop_stop()
        client.disconnect()

    def _on_connect(self, client: Any, userdata: Any, flags: Any, reason_code: Any, properties: Any = None) -> None:
        del userdata, flags, properties
        if int(reason_code) != 0:
            self._startup_error = RuntimeError(
                f"decoder subscriber failed to connect: reason_code={reason_code}"
            )
            self._stop_event.set()
            return
        client.subscribe(self.settings.raw_topic_pattern, qos=self.settings.subscribe_qos)
        self._subscriber_ready.set()
        LOG.info("Subscribed raw topic pattern %s", self.settings.raw_topic_pattern)

    def _on_message(self, client: Any, userdata: Any, message: Any) -> None:
        del client, userdata
        observed_at = datetime.now(UTC)
        try:
            plant_id, point_id, device_id = parse_raw_topic(message.topic)
            profiles = self.profile_registry.for_source_device(device_id)
            if not profiles:
                LOG.warning("Ignoring raw topic for unknown device_id=%s topic=%s", device_id, message.topic)
                return

            query, response = parse_read_frames(message.payload)
            profile = select_profile(profiles, query)
            metrics = profile.transform_metrics(decode_read_frames(profile, query, response))
            if not metrics:
                LOG.debug("Decoded no publishable metrics for device_id=%s topic=%s", device_id, message.topic)
                return

            self.aggregator.record(
                DecodedTelemetry(
                    plant_id=plant_id,
                    point_id=point_id,
                    device_id=profile.output_device_id,
                    observed_at=observed_at,
                    metrics=metrics,
                )
            )
        except Exception:
            LOG.exception("Failed to decode raw telemetry topic=%s", getattr(message, "topic", "<unknown>"))

    def _publish_ready(self) -> None:
        for aggregated in self.aggregator.ready_to_flush(datetime.now(UTC)):
            topic = build_standard_topic(
                aggregated.plant_id,
                aggregated.point_id,
                aggregated.device_id,
            )
            payload = json.dumps(aggregated.metrics, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
            try:
                publisher = self._get_publisher(aggregated.device_id)
                info = publisher.publish(topic, payload, qos=self.settings.publish_qos, retain=False)
                info.wait_for_publish()
            except Exception:
                self._discard_publisher(aggregated.device_id)
                LOG.exception(
                    "Failed to publish aggregated telemetry device_id=%s topic=%s",
                    aggregated.device_id,
                    topic,
                )
                continue
            if getattr(info, "rc", 0) != self._mqtt.MQTT_ERR_SUCCESS:
                self._discard_publisher(aggregated.device_id)
                LOG.error(
                    "Failed to publish aggregated telemetry device_id=%s topic=%s rc=%s",
                    aggregated.device_id,
                    topic,
                    getattr(info, "rc", None),
                )
                continue
            self.aggregator.mark_flushed(aggregated)
            LOG.info(
                "Published aggregated telemetry device_id=%s bucket_start=%s topic=%s payload=%s",
                aggregated.device_id,
                aggregated.bucket_start.isoformat(),
                topic,
                payload,
            )

    def run(self) -> None:
        LOG.info("Loaded %s decoder profiles from %s", len(self.profile_registry), self.settings.config_path)
        connect_rc = self._subscriber.connect(
            self.settings.mqtt_host,
            self.settings.mqtt_port,
            self.settings.keepalive_sec,
        )
        if connect_rc != self._mqtt.MQTT_ERR_SUCCESS:
            raise RuntimeError(f"decoder subscriber connect() failed: rc={connect_rc}")
        self._subscriber.loop_start()
        try:
            ready_deadline = time.monotonic() + 10.0
            while (
                not self._subscriber_ready.is_set()
                and self._startup_error is None
                and time.monotonic() < ready_deadline
            ):
                time.sleep(0.1)

            if self._startup_error is not None:
                raise self._startup_error
            if not self._subscriber_ready.is_set():
                raise RuntimeError("decoder subscriber did not become ready within 10 seconds")

            while not self._stop_event.is_set():
                self._publish_ready()
                time.sleep(self.settings.flush_poll_sec)
        finally:
            self.close()

    def close(self) -> None:
        self._stop_event.set()
        self._subscriber_ready.clear()
        self._subscriber.loop_stop()
        self._subscriber.disconnect()
        with self._publishers_lock:
            for client in self._publisher_clients.values():
                client.loop_stop()
                client.disconnect()
            self._publisher_clients.clear()


def run_from_env() -> None:
    logging.basicConfig(
        level=os.environ.get("DECODER_LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    settings = RuntimeSettings.from_env()
    service = DecoderAggregatorService(settings)
    service.run()
