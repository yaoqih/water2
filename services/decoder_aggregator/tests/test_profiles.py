import unittest

from decoder_aggregator.modbus import parse_read_frames
from decoder_aggregator.profiles import DeviceProfile, ModbusReadMatch, decode_hex_payload, select_profile


class DecodeProfilesTest(unittest.TestCase):
    def test_select_profile_by_modbus_query_for_shared_source_topic(self) -> None:
        profiles = [
            DeviceProfile(
                device_id="mux_zd",
                source_device_id="dev_mux_01",
                profile_type="rs_zd_turbidity",
                sensor_range=1000,
                target_device_id="dev_out_01",
                modbus_match=ModbusReadMatch(address=1, function_code=3, start_register=0, register_count=2),
            ),
            DeviceProfile(
                device_id="mux_cod",
                source_device_id="dev_mux_01",
                profile_type="rs_cod",
                sensor_range=500,
                target_device_id="dev_out_01",
                modbus_match=ModbusReadMatch(address=1, function_code=3, start_register=0, register_count=3),
            ),
        ]

        query, _ = parse_read_frames("01030000000305cb010306000d00ce000eec8f")
        selected = select_profile(profiles, query)

        self.assertEqual(selected.device_id, "mux_cod")

    def test_transform_metrics_can_filter_and_alias(self) -> None:
        profile = DeviceProfile(
            device_id="dev_cod_01",
            profile_type="rs_cod",
            sensor_range=500,
            target_device_id="dev_merged_01",
            publish_metrics=("cod", "temperature"),
            metric_aliases={"temperature": "cod_temperature"},
        )

        metrics = profile.transform_metrics(
            {
                "cod": 12.3,
                "temperature": 20.6,
                "turbidity": 1.4,
            }
        )

        self.assertEqual(
            metrics,
            {
                "cod": 12.3,
                "cod_temperature": 20.6,
            },
        )
        self.assertEqual(profile.output_device_id, "dev_merged_01")

    def test_decode_suspended_solids_float_payload(self) -> None:
        profile = DeviceProfile(
            device_id="dev_ss_01",
            profile_type="rs_ss",
            sensor_range=20000,
        )

        metrics = decode_hex_payload(
            profile,
            "040300000002c45e0403044392772b7cb5",
        )

        self.assertAlmostEqual(metrics["ss"], 292.9309997558594, places=6)
        self.assertEqual(set(metrics.keys()), {"ss"})

    def test_decode_turbidity_and_temperature_payload(self) -> None:
        profile = DeviceProfile(
            device_id="dev_zd_01",
            profile_type="rs_zd_turbidity",
            sensor_range=1000,
        )

        metrics = decode_hex_payload(
            profile,
            "010300000002c40b0103040d2e00dbd8cd",
        )

        self.assertAlmostEqual(metrics["turbidity"], 337.4, places=6)
        self.assertAlmostEqual(metrics["temperature"], 21.9, places=6)

    def test_decode_cod_temperature_and_turbidity_payload(self) -> None:
        profile = DeviceProfile(
            device_id="dev_cod_01",
            profile_type="rs_cod",
            sensor_range=500,
        )

        metrics = decode_hex_payload(
            profile,
            "01030000000305cb010306000d00ce000eec8f",
        )

        self.assertAlmostEqual(metrics["cod"], 1.3, places=6)
        self.assertAlmostEqual(metrics["temperature"], 20.6, places=6)
        self.assertAlmostEqual(metrics["turbidity"], 1.4, places=6)

    def test_decode_ammonia_payload_ignores_ph_compensation(self) -> None:
        profile = DeviceProfile(
            device_id="dev_nhn_01",
            profile_type="rs_nhn_amnitro",
            sensor_range=100,
        )

        metrics = decode_hex_payload(
            profile,
            "020300000002c438020304053402ee091d",
        )

        self.assertAlmostEqual(metrics["amnitro"], 13.32, places=6)
        self.assertEqual(set(metrics.keys()), {"amnitro"})

    def test_selects_and_decodes_live_single_topic_frames(self) -> None:
        profiles = [
            DeviceProfile(
                device_id="mux_ss",
                source_device_id="dev_mux_live",
                profile_type="rs_ss",
                sensor_range=20000,
                target_device_id="dev_out_live",
                modbus_match=ModbusReadMatch(address=4, function_code=3, start_register=0, register_count=2),
            ),
            DeviceProfile(
                device_id="mux_cod",
                source_device_id="dev_mux_live",
                profile_type="rs_cod",
                sensor_range=500,
                target_device_id="dev_out_live",
                modbus_match=ModbusReadMatch(address=1, function_code=3, start_register=0, register_count=2),
            ),
            DeviceProfile(
                device_id="mux_nhn",
                source_device_id="dev_mux_live",
                profile_type="rs_nhn_amnitro",
                sensor_range=100,
                target_device_id="dev_out_live",
                modbus_match=ModbusReadMatch(address=2, function_code=3, start_register=0, register_count=2),
            ),
            DeviceProfile(
                device_id="mux_zd",
                source_device_id="dev_mux_live",
                profile_type="rs_zd_turbidity",
                sensor_range=1000,
                target_device_id="dev_out_live",
                modbus_match=ModbusReadMatch(address=3, function_code=3, start_register=0, register_count=2),
            ),
        ]

        cases = [
            (
                "040300000002c45e040304439fe3de43f1",
                "mux_ss",
                {"ss": 319.78021240234375},
            ),
            (
                "010300000002c40b010304000000b13a47",
                "mux_cod",
                {"cod": 0.0, "temperature": 17.7},
            ),
            (
                "020300000002c438020304032802eec853",
                "mux_nhn",
                {"amnitro": 8.08},
            ),
            (
                "030300000002c5e903030406f100b208fd",
                "mux_zd",
                {"turbidity": 177.7, "temperature": 17.8},
            ),
        ]

        for payload_hex, expected_profile_id, expected_metrics in cases:
            query, response = parse_read_frames(payload_hex)
            profile = select_profile(profiles, query)

            self.assertEqual(profile.device_id, expected_profile_id)
            decoded = profile.transform_metrics(
                decode_hex_payload(profile, payload_hex)
            )

            for metric, expected_value in expected_metrics.items():
                self.assertAlmostEqual(decoded[metric], expected_value, places=6)

    def test_live_device_profiles_accept_both_current_and_expanded_register_ranges(self) -> None:
        from decoder_aggregator.config import load_profiles

        registry = load_profiles("/root/iot-stack/services/decoder_aggregator/config/devices.json")
        profiles = registry.for_source_device("dev_cqbb_liaoning53_in_03")

        cases = [
            (
                "040300000002c45e040304428c4ff44f17",
                "dev_cqbb_liaoning53_in_03_ss",
                {"ss": 70.15615844726562},
            ),
            (
                "040300000004445c040308420eafb541a2f51d4930",
                "dev_cqbb_liaoning53_in_03_ss",
                {"ss": 35.67158889770508, "ss_temperature": 20.36968421936035},
            ),
            (
                "010300000002c40b01030400be009fda7f",
                "dev_cqbb_liaoning53_in_03_cod",
                {"cod": 19.0, "cod_temperature": 15.9},
            ),
            (
                "01030000000305cb01030600be009f00077882",
                "dev_cqbb_liaoning53_in_03_cod",
                {"cod": 19.0, "cod_temperature": 15.9, "cod_turbidity": 0.7},
            ),
            (
                "020300000002c438020304022702eef9ac",
                "dev_cqbb_liaoning53_in_03_nhn",
                {"amnitro": 5.51},
            ),
            (
                "02030000000305f8020306022702ee00b2e198",
                "dev_cqbb_liaoning53_in_03_nhn",
                {"amnitro": 5.51, "amnitro_temperature": 17.8},
            ),
        ]

        for payload_hex, expected_profile_id, expected_metrics in cases:
            query, _ = parse_read_frames(payload_hex)
            profile = select_profile(profiles, query)

            self.assertEqual(profile.device_id, expected_profile_id)
            decoded = profile.transform_metrics(decode_hex_payload(profile, payload_hex))

            for metric, expected_value in expected_metrics.items():
                self.assertAlmostEqual(decoded[metric], expected_value, places=6)

    def test_invalid_crc_raises_value_error(self) -> None:
        profile = DeviceProfile(
            device_id="dev_ss_01",
            profile_type="rs_ss",
            sensor_range=20000,
        )

        with self.assertRaisesRegex(ValueError, "CRC"):
            decode_hex_payload(
                profile,
                "040300000002c45e0403044392772b7c00",
            )


if __name__ == "__main__":
    unittest.main()
