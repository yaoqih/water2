import unittest

from serial_emqx_bridge.parser import FrameBuffer, parse_frame


class ParserTests(unittest.TestCase):
    def test_scaling(self):
        data = parse_frame("BG,TEMP:+00238,ZD:00695,XFW:02524,COD:00972,AD:01982,JY:03299,ED\r\n")
        self.assertEqual(data["values"], {"TEMP": 23.8, "ZD": 69.5, "XFW": 252.4, "COD": 97.2, "AD": 19.82, "JY": 329.9})

    def test_split_and_multiple_frames(self):
        b = FrameBuffer()
        self.assertEqual(b.feed("BG,TEMP:+00001,"), [])
        chunk = "ZD:00002,XFW:00003,COD:00004,AD:00005,JY:00006,ED\r\n"
        self.assertEqual(len(b.feed(chunk)), 1)

    def test_invalid(self):
        with self.assertRaises(ValueError):
            parse_frame("BG,TEMP:1,ED")


if __name__ == "__main__":
    unittest.main()
