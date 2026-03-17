from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta


@dataclass(frozen=True)
class DecodedTelemetry:
    plant_id: str
    point_id: str
    device_id: str
    observed_at: datetime
    metrics: dict[str, float]


@dataclass(frozen=True)
class AggregatedTelemetry:
    plant_id: str
    point_id: str
    device_id: str
    bucket_start: datetime
    metrics: dict[str, float]


class MinuteAggregator:
    def __init__(self, flush_delay_sec: int = 5) -> None:
        self.flush_delay_sec = flush_delay_sec
        self._buckets: dict[tuple[str, str, str, datetime], dict[str, list[float]]] = {}

    def record(self, telemetry: DecodedTelemetry) -> None:
        observed_at = telemetry.observed_at.astimezone(UTC)
        bucket_start = observed_at.replace(second=0, microsecond=0)
        key = (telemetry.plant_id, telemetry.point_id, telemetry.device_id, bucket_start)

        bucket = self._buckets.setdefault(key, {})
        for metric, value in telemetry.metrics.items():
            stats = bucket.setdefault(metric, [0.0, 0.0])
            stats[0] += float(value)
            stats[1] += 1.0

    def _build_aggregated(
        self,
        key: tuple[str, str, str, datetime],
        stats_by_metric: dict[str, list[float]],
    ) -> AggregatedTelemetry:
        plant_id, point_id, device_id, bucket_start = key
        metrics = {
            metric: stats[0] / stats[1]
            for metric, stats in stats_by_metric.items()
            if stats[1] > 0
        }
        return AggregatedTelemetry(
            plant_id=plant_id,
            point_id=point_id,
            device_id=device_id,
            bucket_start=bucket_start,
            metrics=metrics,
        )

    def ready_to_flush(self, now: datetime) -> list[AggregatedTelemetry]:
        cutoff = now.astimezone(UTC) - timedelta(seconds=self.flush_delay_sec)
        ready_items: list[AggregatedTelemetry] = []

        for key in sorted(self._buckets.keys(), key=lambda item: item[3]):
            bucket_start = key[3]
            if bucket_start + timedelta(minutes=1) > cutoff:
                continue

            ready_items.append(self._build_aggregated(key, self._buckets[key]))

        return ready_items

    def mark_flushed(self, aggregated: AggregatedTelemetry) -> None:
        key = (
            aggregated.plant_id,
            aggregated.point_id,
            aggregated.device_id,
            aggregated.bucket_start.astimezone(UTC),
        )
        self._buckets.pop(key, None)

    def flush_ready(self, now: datetime) -> list[AggregatedTelemetry]:
        ready_items = self.ready_to_flush(now)
        for aggregated in ready_items:
            self.mark_flushed(aggregated)
        return ready_items
