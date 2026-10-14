#!/usr/bin/env python3
"""独立的 RS232 排障工具；依赖 pyserial，支持 Linux / Windows / macOS。"""

import argparse
import contextlib
import datetime as dt
import itertools
import json
import math
import os
from pathlib import Path
import re
import sys
import threading
import time


class TestError(Exception):
    """配置或串口操作错误。"""


def positive_int(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("必须是正整数")
    return number


def nonnegative_float(value):
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise argparse.ArgumentTypeError("必须是有限的非负数")
    return number


def positive_float(value):
    number = nonnegative_float(value)
    if number == 0:
        raise argparse.ArgumentTypeError("必须大于 0")
    return number


def parse_hex(value):
    """接受 01 03、0103、0x01,0x03，拒绝残缺的半字节。"""
    tokens = [token for token in re.split(r"[\s,:;\-]+", value.strip()) if token]
    if not tokens:
        raise TestError("HEX 数据不能为空")
    normalized = []
    for token in tokens:
        token = re.sub(r"^0x", "", token, flags=re.IGNORECASE)
        if not re.fullmatch(r"(?:[0-9a-fA-F]{2})+", token):
            raise TestError("HEX 格式错误：每个字节必须有两位，例如 01 03 FF")
        normalized.append(token)
    return bytes.fromhex("".join(normalized))


def modbus_crc(data):
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc.to_bytes(2, "little")


def make_payload(args):
    if args.hex_data is not None:
        payload = parse_hex(args.hex_data)
    else:
        payload = args.text.encode(args.encoding)
    suffix = {"none": b"", "cr": b"\r", "lf": b"\n", "crlf": b"\r\n"}
    if args.hex_data is not None and args.newline != "none":
        raise TestError("--newline 仅用于文本；HEX 中请直接写 0D 或 0A")
    payload += suffix[args.newline]
    if not payload:
        raise TestError("发送数据不能为空")
    if args.modbus_crc:
        payload += modbus_crc(payload)
    return payload


def expected_payload(args):
    if args.expect_hex is not None:
        return parse_hex(args.expect_hex)
    if args.expect_text is not None:
        expected = args.expect_text.encode(args.encoding)
        if not expected:
            raise TestError("预期响应不能为空")
        return expected
    return None


def serial_api():
    try:
        import serial
    except ImportError as exc:
        raise TestError("缺少 pyserial，请运行：python3 -m pip install pyserial") from exc
    if not hasattr(serial, "serial_for_url"):
        raise TestError("安装的 serial 不是 pyserial，请检查 Python 环境并安装 pyserial")
    return serial


def available_ports():
    serial_api()
    from serial.tools import list_ports

    return sorted(list_ports.comports(), key=lambda port: port.device)


def show_ports():
    ports = available_ports()
    if not ports:
        print("没有自动发现串口。Linux 板载串口可手动指定 /dev/ttyS0 或 /dev/ttyAMA0。")
    for index, port in enumerate(ports, 1):
        print(f"{index}. {port.device}  {port.description}")
        print(f"   {port.hwid}")
    return ports


def settings_label(args):
    return f"{args.baud} {args.bytesize}{args.parity}{args.stopbits:g} 流控={args.flow}"


@contextlib.contextmanager
def open_port(args, name):
    if args.flow == "rtscts" and args.rts is not None:
        raise TestError("RTS 已由 rtscts 硬件流控管理，请去掉 --rts")
    if args.flow == "dsrdtr" and args.dtr is not None:
        raise TestError("DTR 已由 dsrdtr 硬件流控管理，请去掉 --dtr")
    api = serial_api()
    port = api.serial_for_url(
        name,
        baudrate=args.baud,
        bytesize=args.bytesize,
        parity=args.parity,
        stopbits=args.stopbits,
        timeout=0.05,
        write_timeout=args.timeout,
        xonxoff=args.flow == "xonxoff",
        rtscts=args.flow == "rtscts",
        dsrdtr=args.flow == "dsrdtr",
        do_not_open=True,
    )
    try:
        if sys.platform.startswith("linux") and hasattr(port, "exclusive"):
            port.exclusive = True
        if args.dtr is not None:
            port.dtr = args.dtr == "on"
        if args.rts is not None:
            port.rts = args.rts == "on"
        port.open()
        print(f"已打开 {name}：{settings_label(args)}")
        yield port
    finally:
        port.close()


class TrafficLog:
    """终端输出可截短，JSONL 始终保存完整收发字节。"""

    def __init__(self, args):
        self.encoding = args.encoding
        self.limit = args.display_bytes
        self.lock = threading.Lock()
        self.file = None
        if args.log:
            path = Path(args.log).expanduser()
            path.parent.mkdir(parents=True, exist_ok=True)
            self.file = path.open("a", encoding="utf-8")
            print(f"收发日志（追加）：{path.resolve()}")

    def frame(self, direction, port, data):
        if not data:
            return
        timestamp = dt.datetime.now().astimezone().isoformat(timespec="milliseconds")
        visible = data if self.limit == 0 else data[:self.limit]
        suffix = f" …（另 {len(data) - len(visible)} 字节）" if len(visible) < len(data) else ""
        record = {
            "timestamp": timestamp,
            "direction": direction,
            "port": port,
            "length": len(data),
            "hex": data.hex(" ").upper(),
            "text": data.decode(self.encoding, errors="replace"),
        }
        with self.lock:
            print(f"[{timestamp}] {direction} {port} {len(data)} 字节", flush=True)
            print(f"  HEX : {visible.hex(' ').upper()}{suffix}", flush=True)
            print(f"  TEXT: {visible.decode(self.encoding, errors='replace')!r}{suffix}", flush=True)
            if self.file:
                self.file.write(json.dumps(record, ensure_ascii=False) + "\n")
                self.file.flush()

    def close(self):
        if self.file:
            self.file.close()


def send_bytes(port, data, log):
    written = port.write(data)
    log.frame("TX", port.port, data[:written])
    if written != len(data):
        raise TestError(f"发送不完整：{written}/{len(data)} 字节")
    # 不调用可能无限等待硬件流控的 flush()；接收期限另计线上传输时间。


def wire_seconds(args, size):
    bits = 1 + args.bytesize + (args.parity != "N") + args.stopbits
    return size * bits / args.baud


def receive_window(port, seconds, log, collect=True):
    """seconds=0 持续监听；collect=False 防止长时间监听累积内存。"""
    deadline = time.monotonic() + seconds if seconds else None
    chunks = []
    total = 0
    while deadline is None or time.monotonic() < deadline:
        remaining = 0.05 if deadline is None else min(0.05, max(0, deadline - time.monotonic()))
        if remaining <= 0:
            break
        port.timeout = remaining
        data = port.read(4096)
        if data:
            log.frame("RX", port.port, data)
            total += len(data)
            if collect:
                chunks.append(data)
    return b"".join(chunks) if collect else total


def receive_exact(port, size, seconds, log):
    deadline = time.monotonic() + seconds
    result = bytearray()
    while len(result) < size:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        port.timeout = min(0.05, remaining)
        chunk = port.read(min(4096, size - len(result)))
        log.frame("RX", port.port, chunk)
        result.extend(chunk)
    # 已在输入缓冲中的多余字节也参与比较，避免误判为完全一致。
    waiting = min(port.in_waiting, 4096)
    if waiting:
        chunk = port.read(waiting)
        log.frame("RX", port.port, chunk)
        result.extend(chunk)
    return bytes(result)


def report_comparison(expected, received, label):
    if expected == received:
        print(f"PASS {label}：{len(received)} 字节全部一致")
        return True
    if not received:
        print(f"FAIL {label}：未收到数据")
    else:
        print(f"FAIL {label}：发送 {len(expected)} 字节，收到 {len(received)} 字节")
        difference = next((i for i, (a, b) in enumerate(zip(expected, received)) if a != b), None)
        if difference is not None:
            print(f"  第 {difference + 1} 字节不同：TX={expected[difference]:02X} RX={received[difference]:02X}")
        else:
            print("  已收到部分与发送一致，但长度不符")
    return False


def test_packet(size, bytesize=8, flow="none"):
    # 覆盖当前数据位可表达的字节；软件流控的 XON/XOFF 不能作为普通载荷。
    alphabet = [value for value in range(1 << bytesize) if flow != "xonxoff" or value not in (0x11, 0x13)]
    prefix = bytes(alphabet[value % len(alphabet)] for value in os.urandom(min(size, 16)))
    pattern = bytes(alphabet)
    return prefix + (pattern * ((size + len(pattern) - 1) // len(pattern)))[:size - len(prefix)]


def cmd_listen(args, log):
    print("监听中，Ctrl+C 停止。接收分块仅用于显示，不等同于协议帧。")
    with open_port(args, args.port) as port:
        total = receive_window(port, args.duration, log, collect=False)
    print(f"监听结束，共收到 {total} 字节")
    return 0


def cmd_send(args, log):
    payload = make_payload(args)
    expected = expected_payload(args)
    successes = 0
    with open_port(args, args.port) as port:
        for index in range(args.repeat):
            print(f"发送 {index + 1}/{args.repeat}")
            port.reset_input_buffer()
            send_bytes(port, payload, log)
            received = receive_window(port, args.timeout + wire_seconds(args, len(payload)), log)
            if expected is not None:
                passed = expected in received
                print("PASS：响应包含预期字节" if passed else "FAIL：响应未包含预期字节")
            else:
                passed = bool(received)
                print("已收到响应（尚未验证协议内容）" if passed else "未收到响应")
            successes += passed
            if index + 1 < args.repeat:
                time.sleep(args.interval)
    print(f"收到{'预期' if expected is not None else ''}响应：{successes}/{args.repeat}")
    if successes != args.repeat:
        print("检查设备地址、协议、帧结束符和超时；设备不一定会回应任意文本。")
    return 0 if successes == args.repeat else 1


def run_transfer(args, sender, receiver, log, label):
    sender.reset_input_buffer()
    if sender is not receiver:
        receiver.reset_input_buffer()
    payload = test_packet(args.size, args.bytesize, args.flow)
    send_bytes(sender, payload, log)
    received = receive_exact(receiver, len(payload), args.timeout + wire_seconds(args, len(payload)), log)
    return report_comparison(payload, received, label)


def cmd_loopback(args, log):
    print("接线：断开外接设备，在被测 RS232 DB9 接口上短接 2、3 脚。")
    passes = 0
    with open_port(args, args.port) as port:
        for index in range(args.count):
            passes += run_transfer(args, port, port, log, f"回环 {index + 1}/{args.count}")
    print(f"回环结果：{passes}/{args.count} 通过")
    return 0 if passes == args.count else 1


def same_port(first, second):
    if "://" in first or "://" in second:
        return first == second
    return os.path.normcase(os.path.realpath(first)) == os.path.normcase(os.path.realpath(second))


def cmd_pair(args, log):
    if same_port(args.port_a, args.port_b):
        raise TestError("双串口测试必须指定两个不同串口")
    print("常见 DB9 DTE 互测接线：A2—B3、A3—B2、A5—B5。请核对设备针脚定义。")
    forward = backward = 0
    with open_port(args, args.port_a) as first, open_port(args, args.port_b) as second:
        for index in range(args.count):
            forward += run_transfer(args, first, second, log, f"A→B {index + 1}/{args.count}")
            backward += run_transfer(args, second, first, log, f"B→A {index + 1}/{args.count}")
    print(f"双向结果：A→B {forward}/{args.count}，B→A {backward}/{args.count}")
    return 0 if forward == backward == args.count else 1


def cmd_scan(args, log):
    if args.hex_data is not None or args.text is not None:
        payload = make_payload(args)
        print("主动扫描：每个参数组合发送一次指定数据。")
    else:
        payload = None
        if args.modbus_crc or args.newline != "none":
            raise TestError("--modbus-crc / --newline 需要配合 --hex 或 --text")
        print("被动扫描：等待设备自行上报；如果设备只应答查询，请提供 --hex 或 --text。")
    expected = expected_payload(args)
    rows = []
    parities = args.parities or [args.parity]
    for rate, parity in itertools.product(args.rates, parities):
        candidate = argparse.Namespace(**vars(args))
        candidate.baud, candidate.parity = rate, parity
        with open_port(candidate, candidate.port) as port:
            port.reset_input_buffer()
            if payload is not None:
                send_bytes(port, payload, log)
            window = args.duration + (wire_seconds(candidate, len(payload)) if payload else 0)
            received = receive_window(port, window, log)
        printable = sum(byte in (9, 10, 13) or 32 <= byte <= 126 for byte in received)
        ratio = f"{printable / len(received):.0%}" if received else "—"
        match = expected in received if expected is not None else None
        rows.append((rate, parity, len(received), ratio, match))
    print("\n波特率    校验  收到字节  ASCII可打印比例  预期响应")
    for rate, parity, length, ratio, match in rows:
        result = "匹配" if match else "未匹配" if match is not None else "未设置"
        print(f"{rate:<10}{parity:<6}{length:<10}{ratio:<17}{result}")
    print("收到数据或可打印比例高，均不能单独证明参数正确；应核对协议帧或预期响应。")
    if expected is not None:
        return 0 if any(row[4] for row in rows) else 1
    return 0 if any(row[2] for row in rows) else 1


def read_signal(port, name):
    try:
        return "1" if getattr(port, name) else "0"
    except (OSError, ValueError, NotImplementedError):
        return "不支持"


def cmd_signals(args, log):
    print("RTS/DTR 是输出；CTS/DSR/CD/RI 是输入。0 或不支持不代表收发线路损坏。")
    with open_port(args, args.port) as port:
        deadline = time.monotonic() + args.duration
        previous = None
        while True:
            current = tuple(read_signal(port, name) for name in ("rts", "dtr", "cts", "dsr", "cd", "ri"))
            if current != previous:
                print(f"[{dt.datetime.now().isoformat(timespec='milliseconds')}] " + "  ".join(
                    f"{name}={value}" for name, value in zip(("RTS", "DTR", "CTS", "DSR", "CD", "RI"), current)
                ))
                previous = current
            if args.duration == 0 or time.monotonic() >= deadline:
                break
            time.sleep(min(0.1, max(0, deadline - time.monotonic())))
    return 0


def cmd_terminal(args, log):
    print("输入文本后回车发送；/hex 01 03 FF 发送 HEX；/quit 退出。")
    print(f"文本结尾={args.newline}，编码={args.encoding}。Ctrl+C 也可退出。")
    stop = threading.Event()
    errors = []
    with open_port(args, args.port) as port:
        def reader():
            try:
                while not stop.is_set():
                    chunk = port.read(4096)
                    log.frame("RX", port.port, chunk)
            except (OSError, ValueError) as exc:
                errors.append(exc)
                stop.set()
                print(f"接收错误：{exc}。按回车退出。", flush=True)

        thread = threading.Thread(target=reader, daemon=True)
        thread.start()
        try:
            while not stop.is_set():
                try:
                    line = input("TX> ")
                except EOFError:
                    break
                if stop.is_set() or line == "/quit":
                    break
                if not line:
                    continue
                try:
                    payload = parse_hex(line[5:]) if line.startswith("/hex ") else (
                        line.encode(args.encoding) + {"none": b"", "cr": b"\r", "lf": b"\n", "crlf": b"\r\n"}[args.newline]
                    )
                    send_bytes(port, payload, log)
                except TestError as exc:
                    print(f"输入错误：{exc}")
        finally:
            stop.set()
            thread.join(timeout=1)
        if errors:
            raise TestError(str(errors[0]))
    return 0


def add_common(parser, single_port=True):
    if single_port:
        parser.add_argument("-p", "--port", required=True, help="如 /dev/ttyUSB0、COM3、/dev/cu.usbserial-xxx")
    parser.add_argument("-b", "--baud", type=positive_int, default=9600, help="波特率，默认 9600")
    parser.add_argument("--bytesize", type=int, choices=(5, 6, 7, 8), default=8, help="数据位，默认 8")
    parser.add_argument("--parity", type=str.upper, choices=("N", "E", "O", "M", "S"), default="N", help="N无/E偶/O奇/M标记/S空格")
    parser.add_argument("--stopbits", type=float, choices=(1, 1.5, 2), default=1, help="停止位，默认 1")
    parser.add_argument("--flow", choices=("none", "rtscts", "xonxoff", "dsrdtr"), default="none", help="流控，默认关闭")
    parser.add_argument("--timeout", type=positive_float, default=1, help="写入/响应超时秒数；响应另加发送数据在线时间，默认 1")
    parser.add_argument("--dtr", choices=("on", "off"), help="打开端口时设置 DTR")
    parser.add_argument("--rts", choices=("on", "off"), help="打开端口时设置 RTS")
    parser.add_argument("--encoding", default="utf-8", help="文本编码，如 utf-8、gbk、ascii")
    parser.add_argument("--display-bytes", type=int, default=64, help="每块最多显示的字节数，0 全部显示；日志不截短")
    parser.add_argument("--log", help="追加完整 TX/RX JSONL 日志的路径")


def add_data(parser, required):
    group = parser.add_mutually_exclusive_group(required=required)
    group.add_argument("--hex", dest="hex_data", help='十六进制数据，如 "01 03 00 00 00 02"')
    group.add_argument("--text", help="文本数据")
    parser.add_argument("--newline", choices=("none", "cr", "lf", "crlf"), default="none", help="文本结尾，默认不追加")
    parser.add_argument("--modbus-crc", action="store_true", help="追加 Modbus RTU CRC16（输入数据不要含 CRC）")
    expected = parser.add_mutually_exclusive_group()
    expected.add_argument("--expect-hex", help="成功条件：响应包含这些 HEX 字节")
    expected.add_argument("--expect-text", help="成功条件：响应包含这些文本字节")


def build_parser():
    parser = argparse.ArgumentParser(
        description="RS232 串口排障：不带参数进入中文菜单；各子命令支持 --help。",
        epilog="默认参数 9600 8N1、无流控。公母接口不能判断直通/交叉线序。",
    )
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("ports", help="列出串口及 USB 标识")
    listen = sub.add_parser("listen", help="只接收并显示 HEX/文本")
    add_common(listen)
    listen.add_argument("--duration", type=nonnegative_float, default=0, help="监听秒数，0 表示直到 Ctrl+C")
    send = sub.add_parser("send", help="发送指定数据并等待响应")
    add_common(send)
    add_data(send, required=True)
    send.add_argument("--repeat", type=positive_int, default=1, help="发送次数，默认 1")
    send.add_argument("--interval", type=nonnegative_float, default=0.5, help="每轮响应窗口结束后等待的秒数")
    loopback = sub.add_parser("loopback", help="短接 TX/RX 后自动回环对比")
    add_common(loopback)
    pair = sub.add_parser("pair", help="两个串口自动双向对测")
    add_common(pair, single_port=False)
    pair.add_argument("--port-a", required=True, help="串口 A")
    pair.add_argument("--port-b", required=True, help="串口 B")
    for command in (loopback, pair):
        command.add_argument("--count", type=positive_int, default=5, help="每方向测试轮数，默认 5")
        command.add_argument("--size", type=positive_int, default=272, help="每轮字节数，默认 272（随机前缀 + 00..FF）")
    scan = sub.add_parser("scan", help="被动或主动扫描波特率/校验位")
    add_common(scan)
    add_data(scan, required=False)
    scan.add_argument("--rates", nargs="+", type=positive_int, default=[1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200], help="待测波特率列表")
    scan.add_argument("--parities", nargs="+", type=str.upper, choices=("N", "E", "O", "M", "S"), help="待测校验位列表；默认只用 --parity")
    scan.add_argument("--duration", type=positive_float, default=1, help="每组监听秒数，默认 1")
    signals = sub.add_parser("signals", help="查看控制信号；可通过 --dtr/--rts 设置输出")
    add_common(signals)
    signals.add_argument("--duration", type=nonnegative_float, default=0, help="监测变化的秒数，0 表示只读取一次")
    terminal = sub.add_parser("terminal", help="交互收发终端")
    add_common(terminal)
    terminal.add_argument("--newline", choices=("none", "cr", "lf", "crlf"), default="none", help="文本结尾，默认不追加")
    crc = sub.add_parser("crc", help="计算并追加 Modbus RTU CRC16，不打开串口")
    crc.add_argument("--hex", dest="hex_data", required=True, help="不含 CRC 的 HEX 数据")
    return parser


def execute(args):
    if args.command == "ports":
        show_ports()
        return 0
    if args.command == "crc":
        data = parse_hex(args.hex_data)
        crc = modbus_crc(data)
        print(f"CRC（低字节在前）：{crc.hex(' ').upper()}")
        print(f"完整帧：{(data + crc).hex(' ').upper()}")
        return 0
    if args.display_bytes < 0:
        raise TestError("--display-bytes 不能小于 0")
    if getattr(args, "size", 0) > 65536:
        raise TestError("单轮测试最多 65536 字节")
    # 在打开串口前验证编码名。
    import codecs

    codecs.lookup(args.encoding)
    handlers = {
        "listen": cmd_listen, "send": cmd_send, "loopback": cmd_loopback,
        "pair": cmd_pair, "scan": cmd_scan, "signals": cmd_signals, "terminal": cmd_terminal,
    }
    log = TrafficLog(args)
    try:
        return handlers[args.command](args, log)
    finally:
        log.close()


def prompt(label, default=""):
    hint = f" [{default}]" if default != "" else ""
    value = input(f"{label}{hint}: ").strip()
    return value or str(default)


def choose_port(label="串口"):
    ports = show_ports()
    value = prompt(f"{label}：输入编号或设备路径", "1" if ports else "")
    if value.isdecimal() and 1 <= int(value) <= len(ports):
        return ports[int(value) - 1].device
    if not value:
        raise TestError("必须指定串口")
    if value.isdecimal():
        raise TestError("串口编号不存在，请输入设备路径")
    return value


def menu(parser):
    defaults = ["--baud", "9600", "--bytesize", "8", "--parity", "N", "--stopbits", "1", "--flow", "none", "--timeout", "1"]
    print("RS232 排障工具。默认 9600 8N1、无流控；参数需与被测设备一致。")
    while True:
        print("\n1 列出串口   2 监听   3 发送/响应   4 单口回环   5 双口对测")
        print("6 收发终端   7 参数扫描   8 控制信号   9 修改默认参数/日志   0 退出")
        try:
            choice = prompt("选择", "1")
            if choice == "0":
                return 0
            if choice == "1":
                show_ports()
                continue
            if choice == "9":
                baud = prompt("波特率", "9600")
                framing = prompt("格式（如 8N1、7E1）", "8N1").upper()
                match = re.fullmatch(r"([5-8])([NEOMS])(1\.5|1|2)", framing)
                if not match:
                    raise TestError("格式应为 8N1、7E1 等")
                flow = prompt("流控 none/rtscts/xonxoff/dsrdtr", "none")
                timeout = prompt("响应/写入超时秒数", "1")
                encoding = prompt("文本编码", "utf-8")
                path = prompt("日志路径（留空不保存）")
                candidate = ["--baud", baud, "--bytesize", match[1], "--parity", match[2], "--stopbits", match[3], "--flow", flow, "--timeout", timeout, "--encoding", encoding]
                if path:
                    candidate += ["--log", path]
                parsed = parser.parse_args(["signals", "-p", "validation-only"] + candidate)
                import codecs

                codecs.lookup(parsed.encoding)
                defaults = candidate
                print(f"默认参数已更新：{settings_label(parsed)}")
                continue
            commands = {"2": "listen", "3": "send", "4": "loopback", "5": "pair", "6": "terminal", "7": "scan", "8": "signals"}
            if choice not in commands:
                print("请输入 0 到 9")
                continue
            command = commands[choice]
            argv = [command] + defaults
            if command == "pair":
                argv += ["--port-a", choose_port("串口 A"), "--port-b", choose_port("串口 B")]
            else:
                argv += ["--port", choose_port()]
            if command in ("loopback", "pair"):
                argv += ["--count", prompt("测试轮数", "5"), "--size", prompt("每轮字节数", "272")]
            elif command == "listen":
                argv += ["--duration", prompt("监听秒数（0 为持续）", "10")]
            elif command == "send":
                kind = prompt("数据类型：1 HEX / 2 文本", "1")
                if kind not in ("1", "2"):
                    raise TestError("数据类型请选择 1 或 2")
                argv += ["--hex" if kind == "1" else "--text", input("发送数据: ")]
                if kind == "2":
                    argv += ["--newline", prompt("文本结尾 none/cr/lf/crlf", "none")]
                if prompt("追加 Modbus RTU CRC？y/n", "n").lower() == "y":
                    argv += ["--modbus-crc"]
                argv += ["--repeat", prompt("发送次数", "1")]
            elif command == "terminal":
                argv += ["--newline", prompt("文本结尾 none/cr/lf/crlf", "none")]
            elif command == "scan":
                argv += ["--rates"] + prompt("波特率列表（空格分隔）", "4800 9600 19200 38400 115200").split()
                argv += ["--parities"] + prompt("校验位列表（空格分隔）", "N").upper().split()
                argv += ["--duration", prompt("每组监听秒数", "1")]
                data = prompt("主动扫描 HEX（留空为被动监听）")
                if data:
                    argv += ["--hex", data]
                    if prompt("追加 Modbus RTU CRC？y/n", "n").lower() == "y":
                        argv += ["--modbus-crc"]
            elif command == "signals":
                argv += ["--duration", prompt("监测秒数（0 为读取一次）", "0")]
            execute(parser.parse_args(argv))
        except KeyboardInterrupt:
            print("\n本次测试停止，返回菜单。")
        except EOFError:
            return 0
        except SystemExit as exc:
            if exc.code:
                print("参数错误，请重新输入。")
        except (TestError, OSError, ValueError, LookupError) as exc:
            print(f"错误：{exc}")


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command is None:
            if sys.stdin.isatty():
                return menu(parser)
            parser.print_help()
            return 0
        return execute(args)
    except KeyboardInterrupt:
        print("\n已停止。")
        return 130
    except (TestError, OSError, ValueError, LookupError) as exc:
        print(f"错误：{exc}", file=sys.stderr)
        print("如果无法打开端口，请检查设备路径、权限和串口是否被其他程序占用。", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
