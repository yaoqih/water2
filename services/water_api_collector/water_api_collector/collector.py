from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Protocol

from .state import CursorStore


METRIC_FIELDS = {
    "waterTemperature": "watert",
    "turbidity": "turbidity",
    "suspendedSubstance": "ss",
    "cod": "cod",
    "ammoniaNitrogen": "amnitro",
}


@dataclass(frozen=True)
class SourceConfig:
    source_id: str
    device_code: str
    plant_id: str
    point_id: str
    device_id: str
    initial_start_time: datetime


class WaterApi(Protocol):
    def fetch_page(
        self, source: SourceConfig, start: datetime, end: datetime, page_index: int
    ) -> tuple[list[dict[str, object]], int]: ...


class Publisher(Protocol):
    def publish(self, topic: str, payload: dict[str, object], client_id: str) -> None: ...


class Collector:
    def __init__(
        self,
        api: WaterApi,
        publisher: Publisher,
        state: CursorStore,
        *,
        overlap_seconds: int = 300,
        maximum_window_days: int = 30,
    ) -> None:
        self.api = api
        self.publisher = publisher
        self.state = state
        self.overlap = timedelta(seconds=overlap_seconds)
        self.maximum_window = timedelta(days=maximum_window_days)

    def collect_once(self, source: SourceConfig, now: datetime) -> int:
        now = now.astimezone(source.initial_start_time.tzinfo)
        cursor = self.state.load(source.source_id)
        start = max(source.initial_start_time, cursor - self.overlap) if cursor else source.initial_start_time
        end = min(start + self.maximum_window, now)
        if end <= start:
            return 0

        records: list[dict[str, object]] = []
        page_index = 1
        total_pages = 1
        while page_index <= total_pages:
            page, total_pages = self.api.fetch_page(source, start, end, page_index)
            records.extend(page)
            page_index += 1

        published = 0
        for record in records:
            payload = self._map_record(record, source)
            if payload is None:
                continue
            topic = f"water/v1/{source.plant_id}/{source.point_id}/{source.device_id}/telemetry"
            self.publisher.publish(topic, payload, source.device_id)
            published += 1

        self.state.save(source.source_id, end)
        return published

    @staticmethod
    def _map_record(record: dict[str, object], source: SourceConfig) -> dict[str, object] | None:
        if str(record.get("deviceCode")) != source.device_code:
            raise ValueError(f"unexpected deviceCode: {record.get('deviceCode')}")
        collect_time = record.get("collectTime")
        if not isinstance(collect_time, str):
            raise ValueError("collectTime is required")
        observed_at = datetime.strptime(collect_time, "%Y-%m-%d %H:%M:%S").replace(
            tzinfo=source.initial_start_time.tzinfo
        )
        payload: dict[str, object] = {"_observed_at": observed_at.isoformat()}
        for source_field, metric in METRIC_FIELDS.items():
            value = record.get(source_field)
            if value is None:
                continue
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise ValueError(f"{source_field} must be numeric or null")
            payload[metric] = float(value)
        return payload if len(payload) > 1 else None
