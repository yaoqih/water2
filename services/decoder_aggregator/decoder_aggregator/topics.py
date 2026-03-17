from __future__ import annotations


def parse_raw_topic(topic: str) -> tuple[str, str, str]:
    parts = topic.split("/")
    if len(parts) != 7 or parts[:3] != ["water", "raw", "v1"] or parts[6] != "telemetry":
        raise ValueError(f"invalid raw topic: {topic}")
    return parts[3], parts[4], parts[5]


def build_standard_topic(plant_id: str, point_id: str, device_id: str) -> str:
    return f"water/v1/{plant_id}/{point_id}/{device_id}/telemetry"

