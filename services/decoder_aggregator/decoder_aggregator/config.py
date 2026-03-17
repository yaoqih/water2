from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from .profiles import DeviceProfile, ModbusReadMatch, PROFILE_DECODERS, PROFILE_METRICS


@dataclass(frozen=True)
class ProfileRegistry:
    profiles_by_id: dict[str, DeviceProfile]
    profiles_by_source_device: dict[str, tuple[DeviceProfile, ...]]

    def for_source_device(self, source_device_id: str) -> tuple[DeviceProfile, ...]:
        return self.profiles_by_source_device.get(source_device_id, ())

    def __len__(self) -> int:
        return len(self.profiles_by_id)


def _require_optional_text(definition: dict[str, object], key: str) -> str | None:
    value = definition.get(key)
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{key} must be a non-empty string when provided")
    return value.strip()


def _require_optional_int(definition: dict[str, object], key: str) -> int | None:
    value = definition.get(key)
    if value is None:
        return None
    if not isinstance(value, int) or value < 0:
        raise ValueError(f"{key} must be a non-negative integer when provided")
    return value


def _parse_modbus_match_object(device_id: str, raw_match: object, key: str) -> ModbusReadMatch:
    if not isinstance(raw_match, dict):
        raise ValueError(f"{key} for {device_id} must be an object")

    match = ModbusReadMatch(
        address=_require_optional_int(raw_match, "address"),
        function_code=_require_optional_int(raw_match, "function_code"),
        start_register=_require_optional_int(raw_match, "start_register"),
        register_count=_require_optional_int(raw_match, "register_count"),
    )
    if (
        match.address is None
        and match.function_code is None
        and match.start_register is None
        and match.register_count is None
    ):
        raise ValueError(f"{key} for {device_id} must contain at least one field")
    return match


def _parse_modbus_matches(device_id: str, definition: dict[str, object]) -> tuple[ModbusReadMatch, ...] | None:
    raw_match = definition.get("modbus_match")
    raw_matches = definition.get("modbus_matches")
    if raw_match is not None and raw_matches is not None:
        raise ValueError(f"{device_id} cannot define both modbus_match and modbus_matches")

    if raw_matches is not None:
        if not isinstance(raw_matches, list) or not raw_matches:
            raise ValueError(f"modbus_matches for {device_id} must be a non-empty array")
        return tuple(
            _parse_modbus_match_object(device_id, raw_item, "modbus_matches")
            for raw_item in raw_matches
        )

    if raw_match is None:
        return None

    return (_parse_modbus_match_object(device_id, raw_match, "modbus_match"),)


def _parse_publish_metrics(
    device_id: str,
    profile_type: str,
    definition: dict[str, object],
) -> tuple[str, ...] | None:
    publish_metrics = definition.get("publish_metrics")
    if publish_metrics is None:
        return None
    if not isinstance(publish_metrics, list) or not publish_metrics:
        raise ValueError(f"publish_metrics for {device_id} must be a non-empty array")

    allowed_metrics = PROFILE_METRICS[profile_type]
    parsed_metrics: list[str] = []
    seen: set[str] = set()
    for raw_metric in publish_metrics:
        if not isinstance(raw_metric, str) or not raw_metric.strip():
            raise ValueError(f"publish_metrics for {device_id} must contain non-empty strings")
        metric = raw_metric.strip()
        if metric not in allowed_metrics:
            raise ValueError(f"unsupported publish_metric for {device_id}: {metric}")
        if metric in seen:
            raise ValueError(f"duplicate publish_metric for {device_id}: {metric}")
        seen.add(metric)
        parsed_metrics.append(metric)

    return tuple(parsed_metrics)


def _parse_metric_aliases(
    device_id: str,
    profile_type: str,
    definition: dict[str, object],
) -> dict[str, str] | None:
    raw_aliases = definition.get("metric_aliases")
    if raw_aliases is None:
        return None
    if not isinstance(raw_aliases, dict):
        raise ValueError(f"metric_aliases for {device_id} must be an object")

    allowed_metrics = PROFILE_METRICS[profile_type]
    aliases: dict[str, str] = {}
    for raw_metric, raw_alias in raw_aliases.items():
        if not isinstance(raw_metric, str) or raw_metric not in allowed_metrics:
            raise ValueError(f"unsupported metric_alias key for {device_id}: {raw_metric}")
        if not isinstance(raw_alias, str) or not raw_alias.strip():
            raise ValueError(f"metric_aliases for {device_id} must map to non-empty strings")
        aliases[raw_metric] = raw_alias.strip()

    return aliases


def _resolved_output_metrics(profile: DeviceProfile) -> tuple[str, ...]:
    source_metrics = profile.publish_metrics or tuple(sorted(PROFILE_METRICS[profile.profile_type]))
    aliases = profile.metric_aliases or {}
    output_metrics: list[str] = []
    seen: set[str] = set()

    for metric in source_metrics:
        output_metric = aliases.get(metric, metric)
        if output_metric in seen:
            raise ValueError(
                f"profile {profile.device_id} maps multiple metrics to output metric {output_metric}"
            )
        seen.add(output_metric)
        output_metrics.append(output_metric)

    return tuple(output_metrics)


def _validate_target_metric_collisions(profiles: dict[str, DeviceProfile]) -> None:
    outputs_by_target: dict[str, dict[str, str]] = {}

    for profile in profiles.values():
        target_device_id = profile.output_device_id
        target_metrics = outputs_by_target.setdefault(target_device_id, {})
        for output_metric in _resolved_output_metrics(profile):
            source_device_id = target_metrics.get(output_metric)
            if source_device_id is not None:
                raise ValueError(
                    "duplicate output metric for target_device_id "
                    f"{target_device_id}: {output_metric} from {source_device_id} and {profile.device_id}"
                )
            target_metrics[output_metric] = profile.device_id


def _validate_source_device_routing(profiles_by_source_device: dict[str, list[DeviceProfile]]) -> None:
    for source_device_id, profiles in profiles_by_source_device.items():
        if len(profiles) <= 1:
            continue

        seen_matches: set[tuple[int | None, int | None, int | None, int | None]] = set()
        for profile in profiles:
            matches = profile.query_matches
            if not matches:
                raise ValueError(
                    f"source_device_id {source_device_id} has multiple profiles; "
                    f"profile {profile.device_id} must define modbus_match or modbus_matches"
                )
            for match in matches:
                signature = (
                    match.address,
                    match.function_code,
                    match.start_register,
                    match.register_count,
                )
                if signature in seen_matches:
                    raise ValueError(
                        f"duplicate modbus_match for source_device_id {source_device_id}: {signature}"
                    )
                seen_matches.add(signature)


def load_profiles(config_path: str | Path) -> ProfileRegistry:
    path = Path(config_path)
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)

    devices = payload.get("devices")
    if not isinstance(devices, dict):
        raise ValueError("config must contain a 'devices' object")

    profiles_by_id: dict[str, DeviceProfile] = {}
    profiles_by_source_device: dict[str, list[DeviceProfile]] = {}
    for device_id, definition in devices.items():
        if not isinstance(definition, dict):
            raise ValueError(f"device config for {device_id} must be an object")

        profile_type = definition.get("profile_type")
        if profile_type not in PROFILE_DECODERS:
            raise ValueError(f"unsupported profile_type for {device_id}: {profile_type}")

        modbus_matches = _parse_modbus_matches(device_id, definition)
        profile = DeviceProfile(
            device_id=device_id,
            profile_type=profile_type,
            sensor_range=definition.get("sensor_range"),
            source_device_id=_require_optional_text(definition, "source_device_id"),
            modbus_match=modbus_matches[0] if modbus_matches and len(modbus_matches) == 1 else None,
            modbus_matches=modbus_matches if modbus_matches and len(modbus_matches) > 1 else None,
            target_device_id=_require_optional_text(definition, "target_device_id"),
            publish_metrics=_parse_publish_metrics(device_id, profile_type, definition),
            metric_aliases=_parse_metric_aliases(device_id, profile_type, definition),
        )
        profiles_by_id[device_id] = profile
        profiles_by_source_device.setdefault(profile.input_device_id, []).append(profile)

    _validate_target_metric_collisions(profiles_by_id)
    _validate_source_device_routing(profiles_by_source_device)
    return ProfileRegistry(
        profiles_by_id=profiles_by_id,
        profiles_by_source_device={
            source_device_id: tuple(group)
            for source_device_id, group in profiles_by_source_device.items()
        },
    )
