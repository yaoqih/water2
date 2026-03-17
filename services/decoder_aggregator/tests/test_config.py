import json
import tempfile
import unittest
from pathlib import Path

from decoder_aggregator.config import load_profiles


class ConfigLoaderTest(unittest.TestCase):
    def test_loads_device_profiles_from_json(self) -> None:
        payload = {
            "devices": {
                "dev_ss_01": {
                    "profile_type": "rs_ss",
                    "sensor_range": 20000,
                    "target_device_id": "dev_merge_01",
                    "publish_metrics": ["ss"],
                },
                "dev_zd_01": {
                    "profile_type": "rs_zd_turbidity",
                    "sensor_range": 1000,
                    "target_device_id": "dev_merge_01",
                    "publish_metrics": ["turbidity"],
                    "metric_aliases": {
                        "turbidity": "ntu",
                    },
                },
            }
        }

        with tempfile.TemporaryDirectory() as tmp_dir:
            config_path = Path(tmp_dir) / "devices.json"
            config_path.write_text(json.dumps(payload), encoding="utf-8")

            profiles = load_profiles(config_path)

        self.assertEqual(set(profiles.profiles_by_id.keys()), {"dev_ss_01", "dev_zd_01"})
        self.assertEqual(profiles.profiles_by_id["dev_ss_01"].profile_type, "rs_ss")
        self.assertEqual(profiles.profiles_by_id["dev_ss_01"].output_device_id, "dev_merge_01")
        self.assertEqual(profiles.profiles_by_id["dev_ss_01"].publish_metrics, ("ss",))
        self.assertEqual(profiles.profiles_by_id["dev_zd_01"].sensor_range, 1000)
        self.assertEqual(profiles.profiles_by_id["dev_zd_01"].metric_aliases, {"turbidity": "ntu"})
        self.assertEqual(profiles.for_source_device("dev_ss_01")[0].device_id, "dev_ss_01")

    def test_rejects_unknown_profile_type(self) -> None:
        payload = {
            "devices": {
                "dev_bad": {
                    "profile_type": "unknown_profile",
                    "sensor_range": 1,
                }
            }
        }

        with tempfile.TemporaryDirectory() as tmp_dir:
            config_path = Path(tmp_dir) / "devices.json"
            config_path.write_text(json.dumps(payload), encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "unsupported profile_type"):
                load_profiles(config_path)

    def test_rejects_duplicate_output_metrics_for_same_target_device(self) -> None:
        payload = {
            "devices": {
                "dev_ss_01": {
                    "profile_type": "rs_ss",
                    "sensor_range": 20000,
                    "target_device_id": "dev_merge_01",
                    "publish_metrics": ["temperature"],
                },
                "dev_zd_01": {
                    "profile_type": "rs_zd_turbidity",
                    "sensor_range": 1000,
                    "target_device_id": "dev_merge_01",
                    "publish_metrics": ["temperature"],
                },
            }
        }

        with tempfile.TemporaryDirectory() as tmp_dir:
            config_path = Path(tmp_dir) / "devices.json"
            config_path.write_text(json.dumps(payload), encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "duplicate output metric"):
                load_profiles(config_path)

    def test_supports_multiple_profiles_on_one_source_device(self) -> None:
        payload = {
            "devices": {
                "mux_ss": {
                    "source_device_id": "dev_mux_01",
                    "profile_type": "rs_ss",
                    "sensor_range": 20000,
                    "target_device_id": "dev_out_01",
                    "publish_metrics": ["ss"],
                    "modbus_match": {
                        "address": 4,
                        "function_code": 3,
                        "start_register": 0,
                    },
                },
                "mux_cod": {
                    "source_device_id": "dev_mux_01",
                    "profile_type": "rs_cod",
                    "sensor_range": 500,
                    "target_device_id": "dev_out_01",
                    "publish_metrics": ["cod"],
                    "modbus_match": {
                        "address": 1,
                        "function_code": 3,
                        "start_register": 0,
                        "register_count": 3,
                    },
                },
            }
        }

        with tempfile.TemporaryDirectory() as tmp_dir:
            config_path = Path(tmp_dir) / "devices.json"
            config_path.write_text(json.dumps(payload), encoding="utf-8")

            profiles = load_profiles(config_path)

        self.assertEqual({profile.device_id for profile in profiles.for_source_device("dev_mux_01")}, {"mux_ss", "mux_cod"})
        self.assertEqual(profiles.profiles_by_id["mux_ss"].input_device_id, "dev_mux_01")

    def test_rejects_shared_source_without_modbus_match(self) -> None:
        payload = {
            "devices": {
                "mux_ss": {
                    "source_device_id": "dev_mux_01",
                    "profile_type": "rs_ss",
                    "sensor_range": 20000,
                    "target_device_id": "dev_out_01",
                    "publish_metrics": ["ss"],
                },
                "mux_cod": {
                    "source_device_id": "dev_mux_01",
                    "profile_type": "rs_cod",
                    "sensor_range": 500,
                    "target_device_id": "dev_out_01",
                    "publish_metrics": ["cod"],
                    "modbus_match": {
                        "address": 1,
                        "function_code": 3,
                        "start_register": 0,
                        "register_count": 3,
                    },
                },
            }
        }

        with tempfile.TemporaryDirectory() as tmp_dir:
            config_path = Path(tmp_dir) / "devices.json"
            config_path.write_text(json.dumps(payload), encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "must define modbus_match"):
                load_profiles(config_path)


if __name__ == "__main__":
    unittest.main()
