from __future__ import annotations

import json
import os
import tempfile
from datetime import datetime
from pathlib import Path


class CursorStore:
    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self, source_id: str) -> datetime | None:
        if not self.path.exists():
            return None
        value = json.loads(self.path.read_text(encoding="utf-8")).get(source_id)
        return datetime.fromisoformat(value) if value else None

    def save(self, source_id: str, cursor: datetime) -> None:
        values = json.loads(self.path.read_text(encoding="utf-8")) if self.path.exists() else {}
        values[source_id] = cursor.isoformat()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=self.path.parent, delete=False) as handle:
            json.dump(values, handle, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
            temporary_path = Path(handle.name)
        temporary_path.replace(self.path)
