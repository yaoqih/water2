import unittest

from decoder_aggregator.modbus import normalize_payload_hex, parse_read_frames


class ModbusPayloadCompatibilityTest(unittest.TestCase):
    def test_accepts_ascii_hex_bytes_payload(self) -> None:
        payload = b"040300000002c45e0403044392772b7cb5"

        normalized = normalize_payload_hex(payload)
        query, response = parse_read_frames(payload)

        self.assertEqual(normalized, "040300000002c45e0403044392772b7cb5")
        self.assertEqual(query.address, 4)
        self.assertEqual(query.register_count, 2)
        self.assertEqual(response.byte_count, 4)

    def test_accepts_binary_modbus_payload(self) -> None:
        payload = bytes.fromhex("040300000002c45e0403044392772b7cb5")

        normalized = normalize_payload_hex(payload)
        query, response = parse_read_frames(payload)

        self.assertEqual(normalized, "040300000002c45e0403044392772b7cb5")
        self.assertEqual(query.address, 4)
        self.assertEqual(query.register_count, 2)
        self.assertEqual(response.byte_count, 4)


if __name__ == "__main__":
    unittest.main()
