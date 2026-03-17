from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import Sequence

from .modbus import ReadQueryFrame, ReadResponseFrame, parse_read_frames


@dataclass(frozen=True)
class ModbusReadMatch:
    address: int | None = None
    function_code: int | None = None
    start_register: int | None = None
    register_count: int | None = None

    def matches(self, query: ReadQueryFrame) -> bool:
        return (
            (self.address is None or query.address == self.address)
            and (self.function_code is None or query.function_code == self.function_code)
            and (self.start_register is None or query.start_register == self.start_register)
            and (self.register_count is None or query.register_count == self.register_count)
        )


@dataclass(frozen=True)
class DeviceProfile:
    device_id: str
    profile_type: str
    sensor_range: int | float | None = None
    source_device_id: str | None = None
    modbus_match: ModbusReadMatch | None = None
    modbus_matches: tuple[ModbusReadMatch, ...] | None = None
    target_device_id: str | None = None
    publish_metrics: tuple[str, ...] | None = None
    metric_aliases: dict[str, str] | None = None

    @property
    def output_device_id(self) -> str:
        return self.target_device_id or self.device_id

    @property
    def input_device_id(self) -> str:
        return self.source_device_id or self.device_id

    @property
    def query_matches(self) -> tuple[ModbusReadMatch, ...]:
        if self.modbus_matches is not None:
            return self.modbus_matches
        if self.modbus_match is not None:
            return (self.modbus_match,)
        return ()

    def matches_query(self, query: ReadQueryFrame) -> bool:
        matches = self.query_matches
        if not matches:
            return True
        return any(match.matches(query) for match in matches)

    def transform_metrics(self, metrics: dict[str, float]) -> dict[str, float]:
        allowed_metrics = set(self.publish_metrics) if self.publish_metrics is not None else None
        aliases = self.metric_aliases or {}
        transformed: dict[str, float] = {}

        for metric, value in metrics.items():
            if allowed_metrics is not None and metric not in allowed_metrics:
                continue

            output_metric = aliases.get(metric, metric)
            if output_metric in transformed:
                raise ValueError(
                    f"profile {self.device_id} maps multiple metrics to output metric {output_metric}"
                )
            transformed[output_metric] = value

        return transformed


def _register_u16(registers: dict[int, bytes], address: int) -> int:
    return int.from_bytes(registers[address], "big", signed=False)


def _register_s16(registers: dict[int, bytes], address: int) -> int:
    return int.from_bytes(registers[address], "big", signed=True)


def _register_float32_be(registers: dict[int, bytes], address: int) -> float:
    raw = registers[address] + registers[address + 1]
    return struct.unpack(">f", raw)[0]


def _require_sensor_range(profile: DeviceProfile) -> int | float:
    if profile.sensor_range is None:
        raise ValueError(f"profile {profile.device_id} requires sensor_range")
    return profile.sensor_range


def _decode_rs_ss(profile: DeviceProfile, registers: dict[int, bytes]) -> dict[str, float]:
    del profile
    metrics: dict[str, float] = {}
    if 0 in registers and 1 in registers:
        metrics["ss"] = _register_float32_be(registers, 0)
    if 2 in registers and 3 in registers:
        metrics["temperature"] = _register_float32_be(registers, 2)
    return metrics


def _decode_rs_cod(profile: DeviceProfile, registers: dict[int, bytes]) -> dict[str, float]:
    del profile
    metrics: dict[str, float] = {}
    if 0 in registers:
        metrics["cod"] = _register_u16(registers, 0) / 10.0
    if 1 in registers:
        metrics["temperature"] = _register_s16(registers, 1) / 10.0
    if 2 in registers:
        metrics["turbidity"] = _register_u16(registers, 2) / 10.0
    if 16 in registers:
        metrics["toc"] = _register_u16(registers, 16) / 10.0
    return metrics


def _decode_rs_zd_turbidity(profile: DeviceProfile, registers: dict[int, bytes]) -> dict[str, float]:
    sensor_range = _require_sensor_range(profile)
    if sensor_range == 50:
        turbidity_scale = 100.0
    elif sensor_range in {200, 1000}:
        turbidity_scale = 10.0
    elif sensor_range == 4000:
        turbidity_scale = 1.0
    else:
        raise ValueError(f"unsupported turbidity sensor_range: {sensor_range}")

    metrics: dict[str, float] = {}
    if 0 in registers:
        metrics["turbidity"] = _register_u16(registers, 0) / turbidity_scale
    if 1 in registers:
        metrics["temperature"] = _register_s16(registers, 1) / 10.0
    return metrics


def _decode_rs_nhn_amnitro(profile: DeviceProfile, registers: dict[int, bytes]) -> dict[str, float]:
    sensor_range = _require_sensor_range(profile)
    if sensor_range in {10, 100}:
        amnitro_scale = 100.0
    elif sensor_range == 1000:
        amnitro_scale = 10.0
    else:
        raise ValueError(f"unsupported ammonia sensor_range: {sensor_range}")

    metrics: dict[str, float] = {}
    if 0 in registers:
        metrics["amnitro"] = _register_u16(registers, 0) / amnitro_scale
    if 1 in registers:
        metrics["ph_compensation"] = _register_u16(registers, 1) / 100.0
    if 2 in registers:
        metrics["temperature"] = _register_s16(registers, 2) / 10.0
    return metrics


PROFILE_DECODERS = {
    "rs_ss": _decode_rs_ss,
    "rs_cod": _decode_rs_cod,
    "rs_zd_turbidity": _decode_rs_zd_turbidity,
    "rs_nhn_amnitro": _decode_rs_nhn_amnitro,
}

PROFILE_METRICS = {
    "rs_ss": frozenset({"ss", "temperature"}),
    "rs_cod": frozenset({"cod", "temperature", "turbidity", "toc"}),
    "rs_zd_turbidity": frozenset({"turbidity", "temperature"}),
    "rs_nhn_amnitro": frozenset({"amnitro", "ph_compensation", "temperature"}),
}


def decode_read_frames(
    profile: DeviceProfile,
    query: ReadQueryFrame,
    response: ReadResponseFrame,
) -> dict[str, float]:
    registers = {
        query.start_register + index: response.data[index * 2 : (index + 1) * 2]
        for index in range(query.register_count)
    }
    try:
        decoder = PROFILE_DECODERS[profile.profile_type]
    except KeyError as exc:
        raise ValueError(f"unsupported profile_type: {profile.profile_type}") from exc
    return decoder(profile, registers)


def decode_hex_payload(profile: DeviceProfile, payload_hex: str) -> dict[str, float]:
    query, response = parse_read_frames(payload_hex)
    return decode_read_frames(profile, query, response)


def select_profile(profiles: Sequence[DeviceProfile], query: ReadQueryFrame) -> DeviceProfile:
    if not profiles:
        raise ValueError("no decoder profiles available")

    matched = [profile for profile in profiles if profile.matches_query(query)]
    if len(matched) == 1:
        return matched[0]

    source_device_id = profiles[0].input_device_id
    if not matched:
        raise ValueError(
            "no matching decoder profile for "
            f"source_device_id={source_device_id} "
            f"address={query.address} function_code={query.function_code} "
            f"start_register={query.start_register} register_count={query.register_count}"
        )

    raise ValueError(
        "multiple decoder profiles match "
        f"source_device_id={source_device_id}: {', '.join(profile.device_id for profile in matched)}"
    )
