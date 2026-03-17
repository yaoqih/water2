import json
import shutil
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from decoder_aggregator.aggregation import DecodedTelemetry
from decoder_aggregator.service import DecoderAggregatorService, RuntimeSettings


class _FakePublishInfo:
    def __init__(self, rc: int = 0, wait_error: Exception | None = None) -> None:
        self.rc = rc
        self._wait_error = wait_error

    def wait_for_publish(self) -> None:
        if self._wait_error is not None:
            raise self._wait_error


class _FakeClient:
    def __init__(self, publish_info: _FakePublishInfo | None = None) -> None:
        self.publish_info = publish_info or _FakePublishInfo()
        self.on_connect = None
        self.on_message = None
        self.published: list[tuple[str, str, int, bool]] = []

    def username_pw_set(self, username: str, password: str) -> None:
        del username, password

    def enable_logger(self, logger) -> None:
        del logger

    def connect(self, host: str, port: int, keepalive: int) -> int:
        del host, port, keepalive
        return 0

    def loop_start(self) -> None:
        return None

    def loop_stop(self) -> None:
        return None

    def disconnect(self) -> None:
        return None

    def subscribe(self, topic: str, qos: int = 0) -> None:
        del topic, qos

    def publish(self, topic: str, payload: str, qos: int, retain: bool) -> _FakePublishInfo:
        self.published.append((topic, payload, qos, retain))
        return self.publish_info


class DecoderAggregatorServiceTest(unittest.TestCase):
    def test_publish_failure_keeps_bucket_for_retry_and_does_not_crash(self) -> None:
        settings = self._build_settings()
        mqtt_module = SimpleNamespace(Client=lambda client_id: _FakeClient(), MQTT_ERR_SUCCESS=0)

        with patch("decoder_aggregator.service._require_paho", return_value=mqtt_module):
            service = DecoderAggregatorService(settings)

        try:
            service.aggregator.record(
                DecodedTelemetry(
                    plant_id="plant_a",
                    point_id="pt_a",
                    device_id="dev_out_01",
                    observed_at=datetime(2026, 3, 16, 12, 0, 10, tzinfo=UTC),
                    metrics={"ss": 123.4},
                )
            )
            service._publisher_clients["dev_out_01"] = _FakeClient(
                publish_info=_FakePublishInfo(
                    wait_error=RuntimeError("Message publish failed: The client is not currently connected.")
                )
            )

            service._publish_ready()

            retry_items = service.aggregator.flush_ready(datetime.now(UTC))
            self.assertEqual(len(retry_items), 1)
            self.assertEqual(retry_items[0].metrics, {"ss": 123.4})
            self.assertNotIn("dev_out_01", service._publisher_clients)
        finally:
            service.close()

    def _build_settings(self) -> RuntimeSettings:
        tmp_dir = tempfile.mkdtemp()
        self.addCleanup(lambda: shutil.rmtree(tmp_dir, ignore_errors=True))
        config_path = Path(tmp_dir) / "devices.json"
        config_path.write_text(json.dumps({"devices": {}}), encoding="utf-8")
        return RuntimeSettings(
            mqtt_host="emqx",
            mqtt_port=1883,
            mqtt_username="decoder_user",
            mqtt_password="secret",
            raw_topic_pattern="water/raw/v1/+/+/+/telemetry",
            config_path=str(config_path),
            subscriber_client_id="decoder_test_sub",
            subscribe_qos=1,
            publish_qos=1,
            flush_delay_sec=5,
            keepalive_sec=30,
            flush_poll_sec=1.0,
        )


if __name__ == "__main__":
    unittest.main()
