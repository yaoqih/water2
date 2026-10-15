import unittest

from serial_emqx_bridge.parser import FrameBuffer, parse_frame

SAMPLE = "BG,TEMP:+00238,ZD:00695,XFW:02524,COD:00972,AD:01982,JY:03299,ED"


class ParserTests(unittest.TestCase):
    def test_scaling(self):
        data = parse_frame(SAMPLE + "\r\n")
        self.assertEqual(data, {"watert": 23.8, "turbidity": 69.5, "ss": 252.4, "cod": 97.2, "amnitro": 19.82})

    def test_split_and_multiple_frames(self):
        for split in range(1, len(SAMPLE)):
            with self.subTest(split=split):
                b = FrameBuffer()
                self.assertEqual(b.feed(SAMPLE[:split].encode("ascii")), [])
                self.assertEqual(b.feed((SAMPLE[split:] + "\r\n" + SAMPLE).encode("ascii")), [SAMPLE, SAMPLE])

    def test_recovers_from_partial_frame_and_noise(self):
        b = FrameBuffer()
        self.assertEqual(b.feed("noiseBG,TEMP:unfinished"), [])
        self.assertEqual(b.feed(SAMPLE), [SAMPLE])
        self.assertEqual(b.feed("x" * 5000 + "B"), [])
        self.assertEqual(b.feed(SAMPLE[1:]), [SAMPLE])

    def test_rejects_corrupted_bytes(self):
        corrupted = SAMPLE.encode("ascii").replace(b"+00238", b"+00\xff238")
        frame, = FrameBuffer().feed(corrupted)
        with self.assertRaises(ValueError):
            parse_frame(frame)

    def test_fixed_start_and_end_markers(self):
        for invalid in (SAMPLE.replace("BG", "bg"), SAMPLE.replace("ED", "ed"), SAMPLE[:-2], SAMPLE + "tail"):
            with self.subTest(frame=invalid), self.assertRaises(ValueError):
                parse_frame(invalid)

    def test_negative_temperature_checksum(self):
        prefix = "BG,TEMP:-00125,ZD:00000,XFW:00000,COD:00000,AD:00000,JY:"
        frame = prefix + f"{sum(prefix.encode('ascii')):05d},ED"
        self.assertEqual(parse_frame(frame), {"watert": -12.5, "turbidity": 0, "ss": 0, "cod": 0, "amnitro": 0})

    def test_invalid(self):
        with self.assertRaises(ValueError):
            parse_frame("BG,TEMP:1,ED")

    def test_rejects_bad_checksum(self):
        with self.assertRaisesRegex(ValueError, "checksum"):
            parse_frame("BG,TEMP:+00238,ZD:00695,XFW:02524,COD:00972,AD:01982,JY:00000,ED")

    def test_rejects_non_fixed_field_order(self):
        with self.assertRaises(ValueError):
            parse_frame("BG,ZD:00695,TEMP:+00238,XFW:02524,COD:00972,AD:01982,JY:03299,ED")


if __name__ == "__main__":
    unittest.main()
