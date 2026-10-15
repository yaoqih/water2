import re


# Match the device's ASCII field order, including the fixed BG/ED markers.
_FRAME = re.compile(
    r"^BG,TEMP:(?P<TEMP>[+-]?\d+),ZD:(?P<ZD>[+-]?\d+),"
    r"XFW:(?P<XFW>[+-]?\d+),COD:(?P<COD>[+-]?\d+),"
    r"AD:(?P<AD>[+-]?\d+),JY:(?P<JY>\d+),ED$",
    re.ASCII,
)
_SCALES = {"TEMP": 10.0, "ZD": 10.0, "XFW": 10.0, "COD": 10.0, "AD": 100.0}
_METRIC_NAMES = {
    "TEMP": "watert",
    "ZD": "turbidity",
    "XFW": "ss",
    "COD": "cod",
    "AD": "amnitro",
}


def parse_frame(frame: str) -> dict[str, float]:
    """Validate one fixed BG...ED frame and return server metric names.

    JY is the decimal sum of every ASCII byte from BG through the ``JY:``
    label, excluding the checksum digits themselves.  It is a transport
    checksum and is deliberately omitted from the telemetry payload.
    """
    text = frame.strip()
    match = _FRAME.fullmatch(text)
    if not match:
        raise ValueError("frame must match BG,TEMP:...,ZD:...,XFW:...,COD:...,AD:...,JY:...,ED")

    expected_checksum = sum(text[:match.start("JY")].encode("ascii"))
    received_checksum = int(match.group("JY"))
    if received_checksum != expected_checksum:
        raise ValueError(
            f"invalid JY checksum: received {received_checksum}, expected {expected_checksum}"
        )

    return {
        _METRIC_NAMES[key]: int(match.group(key)) / _SCALES[key]
        for key in _SCALES
    }


class FrameBuffer:
    """Extract complete frames from arbitrary serial chunks (including split frames)."""

    def __init__(self) -> None:
        self._buffer = ""

    def feed(self, chunk: bytes | str) -> list[str]:
        self._buffer += chunk.decode("ascii", errors="replace") if isinstance(chunk, bytes) else chunk
        frames: list[str] = []
        while True:
            start = self._buffer.find("BG")
            if start < 0:
                # Keep a split start marker while discarding serial noise.
                self._buffer = "B" if self._buffer.endswith("B") else ""
                break
            self._buffer = self._buffer[start:]
            end = self._buffer.find("ED", 2)
            next_start = self._buffer.find("BG", 2)
            if next_start >= 0 and (end < 0 or next_start < end):
                self._buffer = self._buffer[next_start:]
                continue
            if end < 0:
                if len(self._buffer) > 4096:
                    self._buffer = "B" if self._buffer.endswith("B") else ""
                break
            frames.append(self._buffer[: end + 2])
            self._buffer = self._buffer[end + 2 :]
        return frames
