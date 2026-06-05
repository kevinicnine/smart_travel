#!/usr/bin/env python3
"""Re-run tag classification for existing places in backend/data/db.json.

Usage:
  python3 backend/scripts/reclassify_places.py

Optional env:
  PLACES_DB_PATH=backend/data/db.json
  RECLASSIFY_CITY=臺中市
  RECLASSIFY_MODE=replace|merge   # default: replace

This script recalculates tags from existing place text, with a finer-grained
tag layer mixed into the main `tags` list so current app logic stays compatible.
It also writes `subtags` / `attributes` into db.json for offline training use.
"""

from __future__ import annotations

import json
import os
import re
import unicodedata
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DB_PATH = Path(os.getenv("PLACES_DB_PATH", ROOT / "data" / "db.json")).resolve()
RECLASSIFY_CITY = os.getenv("RECLASSIFY_CITY", "").strip()
RECLASSIFY_MODE = os.getenv("RECLASSIFY_MODE", "replace").strip().lower()


BROAD_KEYWORDS: list[tuple[str, str]] = [
    ("觀光工廠", "creative_park"),
    ("工廠", "creative_park"),
    ("酒廠", "creative_park"),
    ("文創", "creative_park"),
    ("園區", "creative_park"),
    ("夜市", "night_market"),
    ("商圈", "department_store"),
    ("水族館", "aquarium"),
    ("海生館", "aquarium"),
    ("博物館", "museum"),
    ("美術館", "museum"),
    ("文化館", "museum"),
    ("展覽館", "museum"),
    ("歌劇院", "concert_hall"),
    ("劇院", "concert_hall"),
    ("音樂廳", "concert_hall"),
    ("演藝", "concert_hall"),
    ("藝文中心", "concert_hall"),
    ("電影院", "cinema"),
    ("影城", "cinema"),
    ("遊樂園", "amusement"),
    ("主題樂園", "amusement"),
    ("動物園", "zoo"),
    ("野生動物", "zoo"),
    ("咖啡", "cafe"),
    ("餐廳", "restaurant"),
    ("美食", "restaurant"),
    ("餐飲", "restaurant"),
    ("小吃", "street_food"),
    ("路邊攤", "street_food"),
    ("小吃街", "street_food"),
    ("百貨", "department_store"),
    ("商場", "department_store"),
    ("購物", "department_store"),
    ("手作", "handcraft_shop"),
    ("工藝", "handcraft_shop"),
    ("陶藝", "handcraft_shop"),
    ("農場", "farm"),
    ("牧場", "farm"),
    ("休閒農場", "farm"),
    ("露營", "camping"),
    ("野營", "camping"),
    ("自行車", "bike"),
    ("腳踏車", "bike"),
    ("單車", "bike"),
    ("水上活動", "water_sport"),
    ("潛水", "water_sport"),
    ("戲水", "water_sport"),
    ("衝浪", "water_sport"),
    ("划船", "water_sport"),
    ("球場", "ball_sport"),
    ("球類", "ball_sport"),
    ("溫泉", "hot_spring"),
    ("湯屋", "hot_spring"),
    ("瀑布", "waterfall"),
    ("海灘", "beach"),
    ("沙灘", "beach"),
    ("海水浴場", "beach"),
    ("海岸", "beach"),
    ("湖", "lake_river"),
    ("河", "lake_river"),
    ("溪", "lake_river"),
    ("潟湖", "lake_river"),
    ("水庫", "lake_river"),
    ("古厝", "heritage"),
    ("古蹟", "heritage"),
    ("老街", "heritage"),
    ("歷史", "heritage"),
    ("文化", "heritage"),
    ("砲台", "heritage"),
    ("城堡", "heritage"),
    ("城門", "heritage"),
    ("城牆", "heritage"),
    ("故居", "heritage"),
    ("紀念館", "heritage"),
    ("自然", "national_park"),
    ("生態", "national_park"),
    ("山", "national_park"),
    ("步道", "national_park"),
    ("森林", "national_park"),
    ("森林遊樂區", "national_park"),
    ("風景區", "national_park"),
    ("濕地", "national_park"),
    ("宗教", "temple"),
    ("廟", "temple"),
    ("寺", "temple"),
    ("宮", "temple"),
]

FINE_KEYWORDS: list[tuple[str, str]] = [
    ("大學", "campus"),
    ("校園", "campus"),
    ("教堂", "church_landmark"),
    ("觀景台", "viewpoint"),
    ("展望台", "viewpoint"),
    ("觀景平台", "viewpoint"),
    ("濕地", "wetland"),
    ("老街", "old_street"),
    ("商圈", "business_district"),
    ("outlet", "outlet"),
    ("植物園", "botanical_garden"),
    ("市場", "market"),
    ("夜市", "market"),
    ("彩繪", "street_art"),
    ("河濱", "riverside"),
    ("廊道", "riverside"),
    ("溪", "riverside"),
    ("步道", "trail"),
    ("鐵馬道", "bike_trail"),
    ("自行車道", "bike_trail"),
    ("藥局", "lifestyle_store"),
    ("歌劇院", "theater"),
    ("劇院", "theater"),
    ("美術館", "art_space"),
    ("博物館", "exhibition_space"),
]

FINE_TO_BROAD: dict[str, set[str]] = {
    "campus": {"heritage", "national_park"},
    "church_landmark": {"heritage"},
    "viewpoint": {"national_park"},
    "wetland": {"national_park", "lake_river"},
    "old_street": {"heritage", "street_food"},
    "business_district": {"department_store", "street_food"},
    "outlet": {"department_store"},
    "botanical_garden": {"national_park"},
    "market": {"street_food"},
    "street_art": {"creative_park", "heritage"},
    "riverside": {"lake_river", "national_park"},
    "trail": {"national_park"},
    "bike_trail": {"bike", "national_park"},
    "lifestyle_store": set(),
    "theater": {"concert_hall"},
    "art_space": {"museum"},
    "exhibition_space": {"museum"},
}


def _normalize_text(text: str) -> str:
    normalized = unicodedata.normalize("NFKC", text or "")
    normalized = normalized.replace("臺", "台")
    normalized = re.sub(r"\s+", " ", normalized)
    return normalized.strip().lower()


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _load_db(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _save_db(path: Path, data: dict[str, Any]) -> None:
    path.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def _derive_attributes(tags: set[str], subtags: set[str], text: str) -> list[str]:
    attrs: set[str] = set()
    indoor_tags = {
        "museum",
        "cinema",
        "aquarium",
        "department_store",
        "restaurant",
        "cafe",
        "concert_hall",
    }
    outdoor_tags = {
        "national_park",
        "beach",
        "waterfall",
        "lake_river",
        "bike",
        "camping",
        "farm",
        "hot_spring",
    }
    if tags & indoor_tags:
        attrs.add("indoor")
        attrs.add("rainy_day_ok")
    if tags & outdoor_tags or subtags & {"viewpoint", "wetland", "riverside", "trail"}:
        attrs.add("outdoor")
    if tags & {"zoo", "aquarium", "farm", "amusement"}:
        attrs.add("family_friendly")
    if tags & {"cafe", "restaurant", "beach", "waterfall"} or subtags & {
        "viewpoint",
        "campus",
        "church_landmark",
    }:
        attrs.add("couple_friendly")
    if tags & {"heritage", "museum", "creative_park"} or subtags & {
        "viewpoint",
        "old_street",
        "street_art",
        "campus",
    }:
        attrs.add("photo_spot")
    if tags & {"night_market", "cinema", "restaurant", "cafe"}:
        attrs.add("night_activity")
    if subtags & {"old_street", "business_district", "market", "campus"}:
        attrs.add("walkable")
    if "預約" in text or "reservation" in text:
        attrs.add("requires_reservation")
    return sorted(attrs)


def _classify_place(place: dict[str, Any]) -> tuple[list[str], list[str], list[str]]:
    raw_text = " ".join(
        [
            place.get("name", ""),
            place.get("city", ""),
            place.get("address", ""),
            place.get("description", ""),
            " ".join(str(tag) for tag in (place.get("tags") or [])),
        ]
    )
    text = _normalize_text(raw_text)
    broad_tags: set[str] = set()
    fine_tags: set[str] = set()

    for keyword, tag in BROAD_KEYWORDS:
        if _normalize_text(keyword) in text:
            broad_tags.add(tag)

    for keyword, fine_tag in FINE_KEYWORDS:
        if _normalize_text(keyword) in text:
            fine_tags.add(fine_tag)
            broad_tags.update(FINE_TO_BROAD.get(fine_tag, set()))

    existing_tags = {
        _normalize_text(str(tag))
        for tag in (place.get("tags") or [])
        if str(tag).strip()
    }
    if not broad_tags and existing_tags:
        broad_tags.update(existing_tags)

    combined = sorted(tag for tag in (broad_tags | fine_tags) if tag and tag != "other")
    if not combined:
        combined = sorted(existing_tags) or ["other"]
    subtags = sorted(fine_tags)
    attributes = _derive_attributes(set(combined), set(subtags), text)
    return combined, subtags, attributes


def main() -> None:
    if RECLASSIFY_MODE not in {"replace", "merge"}:
        raise SystemExit("RECLASSIFY_MODE must be replace or merge")
    data = _load_db(DB_PATH)
    places = data.get("places")
    if not isinstance(places, list):
        raise SystemExit("db.json missing places array")

    processed = 0
    changed = 0
    with_subtags = 0
    with_attributes = 0
    city_filtered = 0

    for place in places:
        if not isinstance(place, dict):
            continue
        city = str(place.get("city", "")).strip()
        if RECLASSIFY_CITY and city != RECLASSIFY_CITY:
            continue
        city_filtered += 1
        processed += 1
        before = deepcopy(place)
        existing_tags = [
            str(tag).strip()
            for tag in (place.get("tags") or [])
            if str(tag).strip()
        ]
        new_tags, subtags, attributes = _classify_place(place)
        if RECLASSIFY_MODE == "merge":
            merged_tags = sorted({*existing_tags, *new_tags})
        else:
            merged_tags = new_tags
        place["tags"] = merged_tags
        if subtags:
            place["subtags"] = subtags
            with_subtags += 1
        else:
            place.pop("subtags", None)
        if attributes:
            place["attributes"] = attributes
            with_attributes += 1
        else:
            place.pop("attributes", None)
        place["updatedAt"] = _utc_now_iso()
        if place != before:
            changed += 1

    _save_db(DB_PATH, data)
    scope = RECLASSIFY_CITY or "all"
    print(
        f"Reclassified {processed} places (scope={scope}, mode={RECLASSIFY_MODE}, "
        f"changed={changed}, subtags={with_subtags}, attributes={with_attributes}, "
        f"path={DB_PATH})"
    )
    if processed == 0 and RECLASSIFY_CITY:
        print(f"[warn] No places matched city filter: {RECLASSIFY_CITY}")
    elif city_filtered == 0:
        print("[warn] No places found to reclassify.")


if __name__ == "__main__":
    main()
