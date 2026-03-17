import unittest
from datetime import UTC, datetime

from decoder_aggregator.aggregation import AggregatedTelemetry, DecodedTelemetry, MinuteAggregator


class MinuteAggregatorTest(unittest.TestCase):
    def test_aggregates_values_per_metric_and_device_per_minute(self) -> None:
        aggregator = MinuteAggregator(flush_delay_sec=5)

        aggregator.record(
            DecodedTelemetry(
                plant_id="plant_a",
                point_id="pt_a",
                device_id="dev_01",
                observed_at=datetime(2026, 3, 16, 12, 0, 10, tzinfo=UTC),
                metrics={"ss": 100.0, "temperature": 20.0},
            )
        )
        aggregator.record(
            DecodedTelemetry(
                plant_id="plant_a",
                point_id="pt_a",
                device_id="dev_01",
                observed_at=datetime(2026, 3, 16, 12, 0, 40, tzinfo=UTC),
                metrics={"ss": 110.0, "temperature": 22.0},
            )
        )

        ready = aggregator.flush_ready(datetime(2026, 3, 16, 12, 1, 6, tzinfo=UTC))

        self.assertEqual(
            ready,
            [
                AggregatedTelemetry(
                    plant_id="plant_a",
                    point_id="pt_a",
                    device_id="dev_01",
                    bucket_start=datetime(2026, 3, 16, 12, 0, 0, tzinfo=UTC),
                    metrics={"ss": 105.0, "temperature": 21.0},
                )
            ],
        )

    def test_does_not_flush_current_open_bucket(self) -> None:
        aggregator = MinuteAggregator(flush_delay_sec=5)
        aggregator.record(
            DecodedTelemetry(
                plant_id="plant_a",
                point_id="pt_a",
                device_id="dev_01",
                observed_at=datetime(2026, 3, 16, 12, 1, 2, tzinfo=UTC),
                metrics={"cod": 9.0},
            )
        )

        ready = aggregator.flush_ready(datetime(2026, 3, 16, 12, 1, 4, tzinfo=UTC))

        self.assertEqual(ready, [])

    def test_flushes_each_bucket_only_once(self) -> None:
        aggregator = MinuteAggregator(flush_delay_sec=5)
        aggregator.record(
            DecodedTelemetry(
                plant_id="plant_a",
                point_id="pt_a",
                device_id="dev_01",
                observed_at=datetime(2026, 3, 16, 12, 0, 10, tzinfo=UTC),
                metrics={"cod": 10.0},
            )
        )

        first = aggregator.flush_ready(datetime(2026, 3, 16, 12, 1, 6, tzinfo=UTC))
        second = aggregator.flush_ready(datetime(2026, 3, 16, 12, 1, 30, tzinfo=UTC))

        self.assertEqual(len(first), 1)
        self.assertEqual(second, [])

    def test_merges_distinct_metrics_from_multiple_sources_into_same_target_device(self) -> None:
        aggregator = MinuteAggregator(flush_delay_sec=5)
        aggregator.record(
            DecodedTelemetry(
                plant_id="plant_a",
                point_id="pt_a",
                device_id="dev_merge_01",
                observed_at=datetime(2026, 3, 16, 12, 0, 5, tzinfo=UTC),
                metrics={"ss": 100.0},
            )
        )
        aggregator.record(
            DecodedTelemetry(
                plant_id="plant_a",
                point_id="pt_a",
                device_id="dev_merge_01",
                observed_at=datetime(2026, 3, 16, 12, 0, 25, tzinfo=UTC),
                metrics={"cod": 12.5},
            )
        )

        ready = aggregator.flush_ready(datetime(2026, 3, 16, 12, 1, 6, tzinfo=UTC))

        self.assertEqual(
            ready,
            [
                AggregatedTelemetry(
                    plant_id="plant_a",
                    point_id="pt_a",
                    device_id="dev_merge_01",
                    bucket_start=datetime(2026, 3, 16, 12, 0, 0, tzinfo=UTC),
                    metrics={"cod": 12.5, "ss": 100.0},
                )
            ],
        )


if __name__ == "__main__":
    unittest.main()
