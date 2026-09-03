from __future__ import annotations

from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from water_api_collector.collector import Collector, SourceConfig
from water_api_collector.config import load_runtime_config
from water_api_collector.state import CursorStore


class FakeApi:
    def __init__(self, pages: list[list[dict[str, object]]]) -> None:
        self.pages = pages
        self.calls: list[tuple[int, datetime, datetime]] = []

    def fetch_page(
        self, source: SourceConfig, start: datetime, end: datetime, page_index: int
    ) -> tuple[list[dict[str, object]], int]:
        self.calls.append((page_index, start, end))
        return self.pages[page_index - 1], len(self.pages)


class FakePublisher:
    def __init__(self, fail: bool = False) -> None:
        self.fail = fail
        self.messages: list[tuple[str, dict[str, object], str]] = []

    def publish(self, topic: str, payload: dict[str, object], client_id: str) -> None:
        if self.fail:
            raise RuntimeError("broker unavailable")
        self.messages.append((topic, payload, client_id))


class CollectorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.source = SourceConfig(
            source_id="zouma_inlet",
            device_code="12891230",
            plant_id="plant_cq_jlp_zouma_rehousing",
            point_id="pt_cq_jlp_zouma_rehousing_inlet",
            device_id="dev_cq_jlp_zouma_rehousing_inlet_01",
            initial_start_time=datetime.fromisoformat("2026-08-01T00:00:00+08:00"),
        )
        self.now = datetime.fromisoformat("2026-08-27T12:00:00+08:00")

    def test_maps_paginated_records_to_canonical_mqtt_messages(self) -> None:
        api = FakeApi(
            [
                [
                    {
                        "deviceCode": "12891230",
                        "collectTime": "2026-08-02 03:04:05",
                        "waterTemperature": 29.9,
                        "turbidity": None,
                        "suspendedSubstance": 2231,
                        "cod": 80.3,
                        "ammoniaNitrogen": 39.9,
                    }
                ],
                [
                    {
                        "deviceCode": "12891230",
                        "collectTime": "2026-08-02 03:04:06",
                        "turbidity": 456,
                    }
                ],
            ]
        )
        publisher = FakePublisher()
        with TemporaryDirectory() as directory:
            collector = Collector(api, publisher, CursorStore(Path(directory) / "state.json"))
            collector.collect_once(self.source, self.now)

        self.assertEqual(len(api.calls), 2)
        self.assertEqual(len(publisher.messages), 2)
        topic, payload, client_id = publisher.messages[0]
        self.assertEqual(topic, "water/v1/plant_cq_jlp_zouma_rehousing/pt_cq_jlp_zouma_rehousing_inlet/dev_cq_jlp_zouma_rehousing_inlet_01/telemetry")
        self.assertEqual(client_id, self.source.device_id)
        self.assertEqual(
            payload,
            {
                "_observed_at": "2026-08-02T03:04:05+08:00",
                "watert": 29.9,
                "ss": 2231.0,
                "cod": 80.3,
                "amnitro": 39.9,
            },
        )

    def test_uses_cursor_overlap_and_caps_a_backfill_window_at_30_days(self) -> None:
        api = FakeApi([[]])
        publisher = FakePublisher()
        with TemporaryDirectory() as directory:
            state = CursorStore(Path(directory) / "state.json")
            state.save(self.source.source_id, datetime.fromisoformat("2026-08-20T00:00:00+08:00"))
            collector = Collector(api, publisher, state, overlap_seconds=300)
            collector.collect_once(self.source, self.now)

        _, start, end = api.calls[0]
        self.assertEqual(start, datetime.fromisoformat("2026-08-19T23:55:00+08:00"))
        self.assertEqual(end, self.now)

    def test_converts_utc_poll_time_to_the_source_timezone_before_querying(self) -> None:
        api = FakeApi([[]])
        publisher = FakePublisher()
        with TemporaryDirectory() as directory:
            collector = Collector(api, publisher, CursorStore(Path(directory) / "state.json"))
            collector.collect_once(self.source, datetime.fromisoformat("2026-08-27T04:00:00+00:00"))

        self.assertEqual(api.calls[0][2].isoformat(), "2026-08-27T12:00:00+08:00")

    def test_does_not_advance_cursor_when_mqtt_publish_fails(self) -> None:
        api = FakeApi([[{"deviceCode": "12891230", "collectTime": "2026-08-02 03:04:05", "cod": 80.3}]])
        with TemporaryDirectory() as directory:
            state = CursorStore(Path(directory) / "state.json")
            collector = Collector(api, FakePublisher(fail=True), state)
            with self.assertRaisesRegex(RuntimeError, "broker unavailable"):
                collector.collect_once(self.source, self.now)
            self.assertIsNone(state.load(self.source.source_id))

    def test_loads_the_zouma_source_mapping_from_json(self) -> None:
        with TemporaryDirectory() as directory:
            config_path = Path(directory) / "sources.json"
            config_path.write_text(
                """{
                  "api": {"base_url": "http://example.test/waterdata"},
                  "sources": [{
                    "source_id": "zouma_inlet",
                    "device_code": "12891230",
                    "plant_id": "plant_cq_jlp_zouma_rehousing",
                    "point_id": "pt_cq_jlp_zouma_rehousing_inlet",
                    "device_id": "dev_cq_jlp_zouma_rehousing_inlet_01",
                    "initial_start_time": "2026-01-01T00:00:00+08:00"
                  }]
                }""",
                encoding="utf-8",
            )
            config = load_runtime_config(config_path)

        self.assertEqual(config.api_base_url, "http://example.test/waterdata")
        self.assertEqual(config.sources[0].device_id, self.source.device_id)


if __name__ == "__main__":
    unittest.main()
