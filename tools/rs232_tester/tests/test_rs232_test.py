"""软件回环 + Unix PTY 集成测试，不需要物理 RS232 设备。"""

import contextlib
import io
import json
import os
from pathlib import Path
import select
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import rs232_test as tester  # noqa: E402


class ProtocolTests(unittest.TestCase):
    def test_hex_formats_and_reject_incomplete_bytes(self):
        for source in ("01 03 ff", "0103FF", "0x01,0x03,0xFF", "01:03:FF"):
            self.assertEqual(tester.parse_hex(source), b"\x01\x03\xff")
        for source in ("", "0x1", "0 1", "ABC", "GG", "0x", "01/03"):
            with self.subTest(source=source), self.assertRaises(tester.TestError):
                tester.parse_hex(source)

    def test_crc_known_vectors(self):
        self.assertEqual(tester.modbus_crc(bytes.fromhex("01 03 00 00 00 02")), bytes.fromhex("C4 0B"))
        self.assertEqual(tester.modbus_crc(b"123456789"), bytes.fromhex("37 4B"))

    def test_payload_format(self):
        parser = tester.build_parser()
        args = parser.parse_args(["send", "-p", "loop://", "--text", "查询", "--encoding", "gbk", "--newline", "crlf"])
        self.assertEqual(tester.make_payload(args), "查询".encode("gbk") + b"\r\n")
        args = parser.parse_args(["send", "-p", "loop://", "--hex", "01 03 00 00 00 02", "--modbus-crc"])
        self.assertEqual(tester.make_payload(args), bytes.fromhex("01 03 00 00 00 02 C4 0B"))
        args.newline = "cr"
        with self.assertRaises(tester.TestError):
            tester.make_payload(args)

    def test_test_data_respects_word_length_and_software_flow(self):
        for bits in (5, 6, 7, 8):
            packet = tester.test_packet(512, bits, "xonxoff")
            self.assertEqual(len(packet), 512)
            self.assertLess(max(packet), 1 << bits)
            self.assertNotIn(0x11, packet)
            self.assertNotIn(0x13, packet)

    def test_loopback_and_complete_json_log(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "nested" / "test.jsonl"
            args = tester.build_parser().parse_args([
                "loopback", "-p", "loop://", "--count", "2", "--display-bytes", "4", "--log", str(path),
            ])
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(tester.execute(args), 0)
            records = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
            self.assertEqual(len(records), 4)
            for tx, rx in zip(records[::2], records[1::2]):
                self.assertEqual(tx["direction"], "TX")
                self.assertEqual(rx["direction"], "RX")
                self.assertEqual(tx["hex"], rx["hex"])
                self.assertEqual(len(bytes.fromhex(tx["hex"])), 272)


@unittest.skipUnless(os.name == "posix", "PTY 集成测试仅支持 Unix")
class SerialIntegrationTests(unittest.TestCase):
    def setUp(self):
        import pty
        import tty

        self.pairs = [pty.openpty(), pty.openpty()]
        for _, slave in self.pairs:
            tty.setraw(slave)
        self.port_a = os.ttyname(self.pairs[0][1])
        self.port_b = os.ttyname(self.pairs[1][1])
        self.stop = threading.Event()
        self.threads = []
        self.worker_errors = []

    def tearDown(self):
        self.stop.set()
        for thread in self.threads:
            thread.join(timeout=1)
            self.assertFalse(thread.is_alive(), "测试后台线程未结束")
        for pair in self.pairs:
            for fd in pair:
                os.close(fd)
        self.assertFalse(self.worker_errors, str(self.worker_errors))

    def start_worker(self, function):
        def guarded():
            try:
                function()
            except Exception as exc:
                self.worker_errors.append(exc)

        thread = threading.Thread(target=guarded, daemon=True)
        self.threads.append(thread)
        thread.start()

    def bridge(self, corrupt_forward=False):
        first, second = self.pairs[0][0], self.pairs[1][0]

        def forward():
            while not self.stop.is_set():
                ready, _, _ = select.select([first, second], [], [], 0.02)
                for source in ready:
                    data = os.read(source, 4096)
                    if corrupt_forward and source == first and data:
                        data = bytes([(data[0] + 1) % 256]) + data[1:]
                    target = second if source == first else first
                    os.write(target, data)

        self.start_worker(forward)

    def responder(self, request, reply):
        master = self.pairs[0][0]

        def respond():
            pending = b""
            while not self.stop.is_set():
                ready, _, _ = select.select([master], [], [], 0.02)
                if ready:
                    pending += os.read(master, 4096)
                    if len(pending) >= len(request):
                        self.assertEqual(pending[:len(request)], request)
                        pending = pending[len(request):]
                        # 拆成两个响应分块，验证预期字节可以跨读取边界。
                        os.write(master, reply[:2])
                        time.sleep(0.02)
                        os.write(master, reply[2:])

        self.start_worker(respond)

    def run_command(self, argv):
        args = tester.build_parser().parse_args(argv)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = tester.execute(args)
        return status, output.getvalue()

    def test_pair_passes_both_directions(self):
        self.bridge()
        status, output = self.run_command([
            "pair", "--port-a", self.port_a, "--port-b", self.port_b, "--count", "3", "--timeout", "0.2",
        ])
        self.assertEqual(status, 0, output)
        self.assertIn("A→B 3/3，B→A 3/3", output)

    def test_pair_detects_corruption_in_one_direction(self):
        self.bridge(corrupt_forward=True)
        status, output = self.run_command([
            "pair", "--port-a", self.port_a, "--port-b", self.port_b, "--count", "2", "--timeout", "0.2",
        ])
        self.assertEqual(status, 1, output)
        self.assertIn("A→B 0/2，B→A 2/2", output)

    def test_fragmented_response_and_repeated_queries(self):
        self.responder(b"STATUS?\r\n", b"prefix OK suffix")
        status, output = self.run_command([
            "send", "-p", self.port_a, "--text", "STATUS?", "--newline", "crlf",
            "--expect-text", "prefix OK suffix", "--timeout", "0.1", "--repeat", "2", "--interval", "0",
        ])
        self.assertEqual(status, 0, output)
        self.assertIn("收到预期响应：2/2", output)

    def test_no_response_reports_failure_and_finishes(self):
        start = time.monotonic()
        status, output = self.run_command(["send", "-p", self.port_a, "--hex", "01 03", "--timeout", "0.1"])
        self.assertEqual(status, 1, output)
        self.assertIn("未收到响应", output)
        self.assertLess(time.monotonic() - start, 2)

    def test_wrong_response_does_not_pass(self):
        self.responder(b"PING", b"ERR")
        status, output = self.run_command([
            "send", "-p", self.port_a, "--text", "PING", "--expect-text", "OK", "--timeout", "0.1",
        ])
        self.assertEqual(status, 1, output)
        self.assertIn("响应未包含预期字节", output)

    def test_active_scan_matches_known_response(self):
        self.responder(b"\x01\x03\x00\x00\x00\x02\xc4\x0b", b"\x01\x03\x04\x00\x01\x00\x02")
        status, output = self.run_command([
            "scan", "-p", self.port_a, "--rates", "9600", "--hex", "01 03 00 00 00 02",
            "--modbus-crc", "--expect-hex", "01 03 04", "--duration", "0.1",
        ])
        self.assertEqual(status, 0, output)
        self.assertIn("匹配", output)

    def test_signals_on_pty_reports_unsupported_without_crashing(self):
        status, output = self.run_command(["signals", "-p", self.port_a])
        self.assertEqual(status, 0, output)
        self.assertIn("CTS=不支持", output)

    def test_same_port_alias_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            alias = Path(folder) / "alias"
            alias.symlink_to(self.port_a)
            with self.assertRaises(tester.TestError):
                self.run_command(["pair", "--port-a", self.port_a, "--port-b", str(alias)])


if __name__ == "__main__":
    unittest.main()
