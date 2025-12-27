"""
Merge tags from places_with_reviews.json into db.json places.

Usage:
  python3 backend/scripts/merge_tags_from_reviews.py
"""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "data" / "db.json"
REVIEWS_PATH = ROOT / "data" / "places_with_reviews.json"


def main() -> None:
    if not DB_PATH.exists():
        raise SystemExit(f"找不到 {DB_PATH}")
    if not REVIEWS_PATH.exists():
        raise SystemExit(f"找不到 {REVIEWS_PATH}")

    db = json.loads(DB_PATH.read_text(encoding="utf-8"))
    places = db.get("places") or []
    reviews = json.loads(REVIEWS_PATH.read_text(encoding="utf-8"))

    tag_map: dict[str, list[str]] = {}
    for item in reviews:
        name = (item.get("source_name") or item.get("name") or "").strip()
        tags = item.get("tags")
        if not name or not isinstance(tags, list) or not tags:
            continue
        tag_map[name] = [t for t in tags if isinstance(t, str) and t.strip()]

    updated = 0
    for p in places:
        name = (p.get("name") or "").strip()
        if not name or name not in tag_map:
            continue
        tags = tag_map[name]
        if not tags:
            continue
        p["tags"] = tags
        p["category"] = tags[0]
        updated += 1

    DB_PATH.write_text(json.dumps(db, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Updated tags for {updated} places -> {DB_PATH}")


if __name__ == "__main__":
    main()
