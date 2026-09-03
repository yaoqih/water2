from __future__ import annotations

import json
from datetime import datetime
from typing import Any
from urllib.parse import urlencode
from urllib.request import urlopen

from .collector import SourceConfig, WaterApi


class PublicWaterApi(WaterApi):
    def __init__(self, base_url: str, page_size: int = 1000, timeout_seconds: int = 30) -> None:
        self.base_url = base_url
        self.page_size = page_size
        self.timeout_seconds = timeout_seconds

    def fetch_page(
        self, source: SourceConfig, start: datetime, end: datetime, page_index: int
    ) -> tuple[list[dict[str, object]], int]:
        query = urlencode(
            {
                "deviceCodes": source.device_code,
                "startTime": start.strftime("%Y-%m-%d %H:%M:%S"),
                "endTime": end.strftime("%Y-%m-%d %H:%M:%S"),
                "pageIndex": page_index,
                "pageSize": self.page_size,
            }
        )
        with urlopen(f"{self.base_url}?{query}", timeout=self.timeout_seconds) as response:
            body: dict[str, Any] = json.load(response)
        if body.get("code") not in (0, 200):
            raise RuntimeError(f"water API failure: {body.get('code')} {body.get('message')}")
        data = body.get("data")
        if not isinstance(data, dict) or not isinstance(data.get("items"), list):
            raise RuntimeError("water API returned an invalid page")
        total_count = data.get("totalCount")
        if not isinstance(total_count, int):
            raise RuntimeError("water API page has no totalCount")
        total_pages = max(1, (total_count + self.page_size - 1) // self.page_size)
        return data["items"], total_pages
