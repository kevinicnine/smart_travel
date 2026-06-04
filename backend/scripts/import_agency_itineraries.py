"""
Normalize travel-agency itinerary drafts into historical itinerary samples.

This script is intentionally conservative:
- It does not crawl websites directly.
- It expects raw, structured itinerary drafts in JSON.
- It tries to match stop names to existing place ids in backend/data/db.json.
- Unmatched items are kept in a separate report for manual review.

Usage:
  python3 backend/scripts/import_agency_itineraries.py

Optional env:
  RAW_AGENCY_ITINERARIES_PATH=backend/data/agency_itineraries_raw.json
  PLACES_DB_PATH=backend/data/db.json
  PLACES_SOURCE=auto|local|remote
  PLACES_EXPORT_URL=https://.../api/admin/export
  PLACES_EXPORT_TOKEN=admin-token
  OUTPUT_PATH=backend/data/historical_itineraries.imported.json
  REPORT_PATH=backend/data/agency_itinerary_match_report.json
"""
from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from datetime import datetime
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any
from urllib import error as urllib_error
from urllib import request as urllib_request

ROOT = Path(__file__).resolve().parents[1]
DOTENV_PATH = ROOT.parent / ".env.local"
RAW_PATH = Path(
    os.environ.get(
        "RAW_AGENCY_ITINERARIES_PATH",
        str(ROOT / "data" / "agency_itineraries_raw.json"),
    )
)
PLACES_DB_PATH = Path(
    os.environ.get("PLACES_DB_PATH", str(ROOT / "data" / "db.json"))
)
OUTPUT_PATH = Path(
    os.environ.get(
        "OUTPUT_PATH",
        str(ROOT / "data" / "historical_itineraries.imported.json"),
    )
)
REPORT_PATH = Path(
    os.environ.get(
        "REPORT_PATH",
        str(ROOT / "data" / "agency_itinerary_match_report.json"),
    )
)
_DOTENV_OVERRIDES: dict[str, str] | None = None

_SKIP_TYPES = {
    "arrival",
    "departure",
    "hotel",
    "lodging",
    "note",
    "transport_note",
}

_PLACE_LIKE_TYPES = {
    "place",
    "scenic",
    "market",
    "night_market",
    "museum",
    "park",
    "trail",
    "shopping",
    "campus",
}

_SLOT_RANGES = (
    (0, 11, "morning"),
    (11, 14, "noon"),
    (14, 18, "afternoon"),
    (18, 22, "evening"),
    (22, 24, "night"),
)


@dataclass(frozen=True)
class PlaceCandidate:
    place_id: str
    name: str
    normalized: str


def _load_dotenv_overrides() -> dict[str, str]:
    global _DOTENV_OVERRIDES
    if _DOTENV_OVERRIDES is not None:
        return _DOTENV_OVERRIDES
    values: dict[str, str] = {}
    if DOTENV_PATH.exists():
        for raw_line in DOTENV_PATH.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key:
                values[key] = value
    _DOTENV_OVERRIDES = values
    return values


def _env_value(key: str, default: str | None = None) -> str | None:
    value = os.environ.get(key)
    if value is not None and str(value).strip():
        return str(value).strip()
    return _load_dotenv_overrides().get(key, default)


def _load_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise FileNotFoundError(f"找不到檔案：{path}")
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise ValueError(f"JSON 根節點必須是 object: {path}")
    return raw


def _normalize_name(value: Any) -> str:
    text = str(value or "").strip().lower()
    text = text.replace("台", "臺")
    text = re.sub(r"（.*?）|\(.*?\)", "", text)
    text = re.sub(r"\bcheck\s*in\b", "", text)
    text = re.sub(r"outlet\s+mall", "outlet", text)
    text = re.sub(r"outlet\s+park", "outlet", text)
    text = re.sub(r"[^0-9a-zA-Z\u4e00-\u9fff]+", "", text)
    return text


def _string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [str(item).strip() for item in value if str(item).strip()]


def _default_remote_export_url() -> str | None:
    base = _env_value("RENDER_API_BASE")
    if not base:
        return None
    return base.rstrip("/") + "/api/admin/export"


def _load_places_payload() -> tuple[dict[str, Any], str]:
    source_mode = (_env_value("PLACES_SOURCE", "auto") or "auto").strip().lower()
    if source_mode not in {"auto", "local", "remote"}:
        source_mode = "auto"

    remote_url = _env_value("PLACES_EXPORT_URL") or _default_remote_export_url()
    remote_token = _env_value("PLACES_EXPORT_TOKEN") or _env_value("ADMIN_TOKEN")

    if source_mode in {"auto", "remote"} and remote_url and remote_token:
        request = urllib_request.Request(
            remote_url,
            headers={
                "x-admin-token": remote_token,
                "accept": "application/json",
            },
            method="GET",
        )
        try:
            with urllib_request.urlopen(request, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
            if not isinstance(payload, dict):
                raise ValueError("遠端匯出內容不是 object")
            return payload, "remote"
        except (urllib_error.URLError, urllib_error.HTTPError, TimeoutError, ValueError) as exc:
            if source_mode == "remote":
                raise RuntimeError(f"讀取遠端景點匯出失敗：{exc}") from exc
            print(f"[warn] 遠端景點匯出不可用，改用本機 db.json：{exc}")

    return _load_json(PLACES_DB_PATH), "local"


def _load_place_candidates() -> tuple[list[PlaceCandidate], str]:
    data, source_label = _load_places_payload()
    places = data.get("places")
    if not isinstance(places, list):
        raise ValueError("db.json 缺少 places 陣列")
    output: list[PlaceCandidate] = []
    for item in places:
        if not isinstance(item, dict):
            continue
        place_id = str(item.get("id") or "").strip()
        name = str(item.get("name") or "").strip()
        normalized = _normalize_name(name)
        if not place_id or not name or not normalized:
            continue
        output.append(
            PlaceCandidate(
                place_id=place_id,
                name=name,
                normalized=normalized,
            )
        )
    return output, source_label


def _parse_minutes(value: str | None) -> int | None:
    raw = str(value or "").strip()
    if not raw:
        return None
    try:
        dt = datetime.strptime(raw, "%H:%M")
    except ValueError:
        return None
    return dt.hour * 60 + dt.minute


def _slot_for_time(value: str | None) -> str | None:
    minutes = _parse_minutes(value)
    if minutes is None:
        return None
    hour = minutes // 60
    for start, end, label in _SLOT_RANGES:
        if start <= hour < end:
            return label
    return "night"


def _stay_minutes(item: dict[str, Any]) -> int | None:
    explicit = item.get("stayMinutes")
    if isinstance(explicit, (int, float)) and explicit > 0:
        return int(explicit)
    arrival = _parse_minutes(str(item.get("arrivalTime") or ""))
    departure = _parse_minutes(str(item.get("departureTime") or ""))
    if arrival is not None and departure is not None and departure > arrival:
        return departure - arrival
    return None


def _choose_match(name: str, candidates: list[PlaceCandidate]) -> tuple[PlaceCandidate | None, list[dict[str, Any]]]:
    normalized = _normalize_name(name)
    if not normalized:
        return None, []

    exact = [candidate for candidate in candidates if candidate.normalized == normalized]
    if exact:
        return exact[0], [
            {"placeId": item.place_id, "name": item.name, "score": 1.0}
            for item in exact[:3]
        ]

    scored: list[tuple[float, PlaceCandidate]] = []
    for candidate in candidates:
        if normalized in candidate.normalized or candidate.normalized in normalized:
            score = 0.96 if normalized != candidate.normalized else 1.0
        else:
            score = SequenceMatcher(None, normalized, candidate.normalized).ratio()
        if score >= 0.60:
            scored.append((score, candidate))
    scored.sort(key=lambda item: item[0], reverse=True)
    top = [
        {
            "placeId": candidate.place_id,
            "name": candidate.name,
            "score": round(score, 4),
        }
        for score, candidate in scored[:5]
    ]
    if not scored:
        return None, top
    best_score, best_candidate = scored[0]
    if best_score < 0.84:
        return None, top
    return best_candidate, top


def _normalize_context(source: dict[str, Any]) -> dict[str, Any]:
    context = source.get("context")
    if not isinstance(context, dict):
        context = {}
    return {
        "interests": _string_list(context.get("interests")),
        "tripPurpose": str(context.get("tripPurpose") or "explore").strip() or "explore",
        "travelBehavior": str(context.get("travelBehavior") or "general").strip() or "general",
        "targetPrice": str(context.get("targetPrice") or "mid").strip() or "mid",
        "destinationCities": _string_list(context.get("destinationCities")),
    }


def main() -> None:
    raw = _load_json(RAW_PATH)
    sources = raw.get("sources")
    if not isinstance(sources, list):
        raise ValueError("agency_itineraries_raw.json 缺少 sources 陣列")

    candidates, places_source = _load_place_candidates()
    output_samples: list[dict[str, Any]] = []
    report_sources: list[dict[str, Any]] = []
    matched_count = 0
    unmatched_count = 0
    skipped_count = 0

    for source in sources:
        if not isinstance(source, dict):
            continue
        source_id = str(source.get("id") or "").strip() or "agency-sample"
        days = source.get("days")
        if not isinstance(days, list):
            continue

        sample_days: list[dict[str, Any]] = []
        source_report = {
            "id": source_id,
            "title": source.get("title"),
            "url": source.get("url"),
            "matchedItems": [],
            "unmatchedItems": [],
            "skippedItems": [],
        }

        for day in days:
            if not isinstance(day, dict):
                continue
            items = day.get("items")
            if not isinstance(items, list):
                continue

            normalized_items: list[dict[str, Any]] = []
            previous_departure: str | None = None
            for item in items:
                if not isinstance(item, dict):
                    continue
                item_type = str(item.get("type") or "place").strip().lower()
                item_name = str(item.get("name") or "").strip()
                if not item_name:
                    continue
                if item_type in _SKIP_TYPES:
                    skipped_count += 1
                    source_report["skippedItems"].append(
                        {
                            "name": item_name,
                            "type": item_type,
                            "reason": "item_type_skipped",
                        }
                    )
                    previous_departure = str(item.get("departureTime") or item.get("arrivalTime") or previous_departure or "")
                    continue
                if item_type not in _PLACE_LIKE_TYPES and item_type != "meal":
                    skipped_count += 1
                    source_report["skippedItems"].append(
                        {
                            "name": item_name,
                            "type": item_type,
                            "reason": "item_type_not_supported",
                        }
                    )
                    previous_departure = str(item.get("departureTime") or item.get("arrivalTime") or previous_departure or "")
                    continue

                matched, top_candidates = _choose_match(item_name, candidates)
                if matched is None:
                    unmatched_count += 1
                    source_report["unmatchedItems"].append(
                        {
                            "name": item_name,
                            "type": item_type,
                            "arrivalTime": item.get("arrivalTime"),
                            "departureTime": item.get("departureTime"),
                            "candidates": top_candidates,
                        }
                    )
                    previous_departure = str(item.get("departureTime") or item.get("arrivalTime") or previous_departure or "")
                    continue

                arrival = str(item.get("arrivalTime") or "").strip() or None
                departure = str(item.get("departureTime") or "").strip() or None
                normalized_item = {
                    "placeId": matched.place_id,
                    "stayMinutes": _stay_minutes(item) or 60,
                }
                if arrival:
                    normalized_item["arrivalTime"] = arrival
                    normalized_item["slot"] = _slot_for_time(arrival)
                if departure:
                    normalized_item["departureTime"] = departure
                if previous_departure and arrival:
                    previous_minutes = _parse_minutes(previous_departure)
                    arrival_minutes = _parse_minutes(arrival)
                    if (
                        previous_minutes is not None
                        and arrival_minutes is not None
                        and arrival_minutes >= previous_minutes
                    ):
                        normalized_item["transitMinutesFromPrevious"] = arrival_minutes - previous_minutes
                normalized_items.append(normalized_item)
                matched_count += 1
                source_report["matchedItems"].append(
                    {
                        "sourceName": item_name,
                        "matchedPlaceId": matched.place_id,
                        "matchedPlaceName": matched.name,
                    }
                )
                previous_departure = departure or arrival or previous_departure

            if normalized_items:
                sample_days.append(
                    {
                        "date": day.get("date"),
                        "dayStartTime": day.get("dayStartTime"),
                        "items": normalized_items,
                    }
                )

        if sample_days:
            output_samples.append(
                {
                    "id": source_id,
                    "weight": float(source.get("weight") or 1.0),
                    "context": _normalize_context(source),
                    "days": sample_days,
                }
            )
        report_sources.append(source_report)

    output = {
        "notes": "由 agency_itineraries_raw.json 轉換而成；只保留成功對應 placeId 的景點項目。",
        "samples": output_samples,
    }
    report = {
        "generatedAt": datetime.utcnow().isoformat() + "Z",
        "source": str(RAW_PATH),
        "placesSource": places_source,
        "samplesGenerated": len(output_samples),
        "matchedItems": matched_count,
        "unmatchedItems": unmatched_count,
        "skippedItems": skipped_count,
        "sources": report_sources,
    }

    OUTPUT_PATH.write_text(
        json.dumps(output, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    REPORT_PATH.write_text(
        json.dumps(report, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(
        "已輸出旅行社行程訓練樣本："
        f"{OUTPUT_PATH} (samples={len(output_samples)}, matched={matched_count}, "
        f"unmatched={unmatched_count}, skipped={skipped_count}, places_source={places_source})"
    )


if __name__ == "__main__":
    main()
