import unittest

from decoder_aggregator.topics import build_standard_topic, parse_raw_topic


class TopicHelpersTest(unittest.TestCase):
    def test_parse_raw_topic(self) -> None:
        parts = parse_raw_topic("water/raw/v1/plant_a/pt_in/dev_01/telemetry")

        self.assertEqual(parts, ("plant_a", "pt_in", "dev_01"))

    def test_build_standard_topic(self) -> None:
        topic = build_standard_topic("plant_a", "pt_in", "dev_01")

        self.assertEqual(topic, "water/v1/plant_a/pt_in/dev_01/telemetry")

    def test_rejects_invalid_raw_topic(self) -> None:
        with self.assertRaisesRegex(ValueError, "invalid raw topic"):
            parse_raw_topic("water/v1/plant_a/pt_in/dev_01/telemetry")


if __name__ == "__main__":
    unittest.main()
