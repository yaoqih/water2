from __future__ import annotations

import json
import logging
import os
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .collector import Collector
from .config import load_runtime_config
from .runtime import PublicWaterApi
from .state import CursorStore


class MqttPublisher:
    def __init__(self) -> None:
        try:
            import paho.mqtt.client as mqtt
        except ImportError as exc:  # pragma: no cover - runtime dependency
            raise RuntimeError("paho-mqtt is required to run water-api-collector") from exc
        self._mqtt = mqtt
        self._clients: dict[str, Any] = {}

    def _client_for(self, device_id: str) -> Any:
        client = self._clients.get(device_id)
        if client is not None:
            return client
        client = self._mqtt.Client(client_id=device_id)
        client.username_pw_set(os.environ["WATER_API_MQTT_USERNAME"], os.environ["WATER_API_MQTT_PASSWORD"])
        client.connect(
            os.environ.get("WATER_API_MQTT_HOST", "emqx"),
            int(os.environ.get("WATER_API_MQTT_PORT", "1883")),
            int(os.environ.get("WATER_API_MQTT_KEEPALIVE_SEC", "30")),
        )
        client.loop_start()
        self._clients[device_id] = client
        return client

    def publish(self, topic: str, payload: dict[str, object], client_id: str) -> None:
        result = self._client_for(client_id).publish(
            topic, json.dumps(payload, separators=(",", ":"), sort_keys=True), qos=1
        )
        result.wait_for_publish()
        if result.rc != self._mqtt.MQTT_ERR_SUCCESS:
            raise RuntimeError(f"MQTT publish failed: rc={result.rc}")


def main() -> None:
    logging.basicConfig(level=os.environ.get("WATER_API_LOG_LEVEL", "INFO"))
    config = load_runtime_config(Path(os.environ.get("WATER_API_CONFIG_PATH", "/app/config/sources.json")))
    collector = Collector(
        PublicWaterApi(config.api_base_url),
        MqttPublisher(),
        CursorStore(Path(os.environ.get("WATER_API_STATE_PATH", "/var/lib/water-api-collector/state.json"))),
        overlap_seconds=config.overlap_seconds,
    )
    while True:
        for source in config.sources:
            try:
                published = collector.collect_once(source, datetime.now(UTC))
                logging.info("source=%s published=%s", source.source_id, published)
            except Exception:
                logging.exception("source=%s collection failed", source.source_id)
        time.sleep(config.poll_interval_seconds)


if __name__ == "__main__":
    main()
