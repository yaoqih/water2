from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ReadQueryFrame:
    address: int
    function_code: int
    start_register: int
    register_count: int


@dataclass(frozen=True)
class ReadResponseFrame:
    address: int
    function_code: int
    byte_count: int
    data: bytes


def sanitize_hex_payload(payload_hex: str) -> str:
    normalized = "".join(payload_hex.split()).lower()
    if not normalized:
        raise ValueError("payload must not be empty")
    if len(normalized) % 2 != 0:
        raise ValueError("payload hex length must be even")
    if any(ch not in "0123456789abcdef" for ch in normalized):
        raise ValueError("payload must contain only hexadecimal characters")
    return normalized


def normalize_payload_hex(payload: str | bytes) -> str:
    if isinstance(payload, str):
        return sanitize_hex_payload(payload)

    try:
        decoded = payload.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return payload.hex()

    try:
        return sanitize_hex_payload(decoded)
    except ValueError:
        return payload.hex()


def crc16_modbus(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xA001
            else:
                crc >>= 1
    return crc


def validate_crc(frame: bytes) -> bool:
    if len(frame) < 3:
        return False
    expected = crc16_modbus(frame[:-2]).to_bytes(2, "little")
    return frame[-2:] == expected


def split_query_and_response_frames(payload_hex: str | bytes) -> tuple[bytes, bytes]:
    payload = bytes.fromhex(normalize_payload_hex(payload_hex))
    if len(payload) < 13:
        raise ValueError("payload is too short for query and response frames")

    query = payload[:8]
    response = payload[8:]

    if not validate_crc(query):
        raise ValueError("CRC mismatch in query frame")
    if not validate_crc(response):
        raise ValueError("CRC mismatch in response frame")

    byte_count = response[2]
    expected_response_len = 3 + byte_count + 2
    if len(response) != expected_response_len:
        raise ValueError("response frame length does not match byte count")

    return query, response


def parse_read_frames(payload_hex: str | bytes) -> tuple[ReadQueryFrame, ReadResponseFrame]:
    query_bytes, response_bytes = split_query_and_response_frames(payload_hex)

    query = ReadQueryFrame(
        address=query_bytes[0],
        function_code=query_bytes[1],
        start_register=int.from_bytes(query_bytes[2:4], "big"),
        register_count=int.from_bytes(query_bytes[4:6], "big"),
    )
    response = ReadResponseFrame(
        address=response_bytes[0],
        function_code=response_bytes[1],
        byte_count=response_bytes[2],
        data=response_bytes[3:-2],
    )

    if query.function_code not in {0x03, 0x04}:
        raise ValueError(f"unsupported Modbus function code: {query.function_code:#04x}")
    if query.address != response.address:
        raise ValueError("query and response addresses do not match")
    if query.function_code != response.function_code:
        raise ValueError("query and response function codes do not match")
    if response.byte_count != len(response.data):
        raise ValueError("response byte count does not match payload length")
    if query.register_count * 2 != response.byte_count:
        raise ValueError("response byte count does not match requested register count")

    return query, response
