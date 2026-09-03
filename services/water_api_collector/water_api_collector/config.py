from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from .collector import SourceConfig


@dataclass(frozen=True)
class RuntimeConfig:
    api_base_url: str
    poll_interval_seconds: int
    overlap_seconds: int
    sources: tuple[SourceConfig, ...]


def load_runtime_config(path: Path) -> RuntimeConfig:
    data = json.loads(path.read_text(encoding="utf-8"))
    api = data.get("api")
    sources = data.get("sources")
    if not isinstance(api, dict) or not isinstance(api.get("base_url"), str):
        raise ValueError("api.base_url is required")
    if not isinstance(sources, list) or not sources:
        raise ValueError("at least one source is required")
    configured_sources = tuple(
        SourceConfig(
            source_id=str(item["source_id"]),
            device_code=str(item["device_code"]),
            plant_id=str(item["plant_id"]),
            point_id=str(item["point_id"]),
            device_id=str(item["device_id"]),
            initial_start_time=datetime.fromisoformat(str(item["initial_start_time"])),
        )
        for item in sources
    )
    if any(source.initial_start_time.tzinfo is None for source in configured_sources):
        raise ValueError("initial_start_time must include a UTC offset")
    return RuntimeConfig(
        api_base_url=api["base_url"],
        poll_interval_seconds=max(1, int(data.get("poll_interval_seconds", 30))),
        overlap_seconds=max(0, int(data.get("overlap_seconds", 300))),
        sources=configured_sources,
    )
