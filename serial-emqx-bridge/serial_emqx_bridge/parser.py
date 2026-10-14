import re
from typing import Any

FIELDS = {"TEMP": 10, "ZD": 10, "XFW": 10, "COD": 10, "AD": 100, "JY": 10}
_FRAME = re.compile(r"^BG\s*,?(.+?),?ED$")


def parse_frame(frame: str) -> dict[str, Any]:
    """Parse one BG...ED frame and return scaled telemetry plus raw integers."""
    text = frame.strip().replace("\r", "").replace("\n", "")
    match = _FRAME.match(text)
    if not match:
        raise ValueError("frame must start with BG and end with ED")
    values: dict[str, int] = {}
    for item in match.group(1).split(","):
        item = item.strip()
        if not item:
            continue
        if ":" not in item:
            raise ValueError(f"invalid field: {item!r}")
        key, raw = (part.strip() for part in item.split(":", 1))
        if key not in FIELDS or not re.fullmatch(r"[+-]?\d+", raw):
            raise ValueError(f"invalid field value: {item!r}")
        values[key] = int(raw)
    missing = set(FIELDS) - values.keys()
    if missing:
        raise ValueError(f"missing fields: {', '.join(sorted(missing))}")
    return {"values": {key: values[key] / scale for key, scale in FIELDS.items()}, "raw": values}


class FrameBuffer:
    """Extract complete frames from arbitrary serial chunks (including split frames)."""

    def __init__(self) -> None:
        self._buffer = ""

    def feed(self, chunk: bytes | str) -> list[str]:
        self._buffer += chunk.decode("ascii", errors="ignore") if isinstance(chunk, bytes) else chunk
        frames: list[str] = []
        while "BG" in self._buffer:
            self._buffer = self._buffer[self._buffer.index("BG") :]
            end = self._buffer.find("ED", 2)
            if end < 0:
                break
            frames.append(self._buffer[: end + 2])
            self._buffer = self._buffer[end + 2 :]
        if len(self._buffer) > 4096:
            self._buffer = self._buffer[-128:]
        return frames
