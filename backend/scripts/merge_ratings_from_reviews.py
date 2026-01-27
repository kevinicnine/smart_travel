"""
Merge Google rating/user_ratings_total from places_with_reviews.json into db.json.

Usage:
  python3 backend/scripts/merge_ratings_from_reviews.py
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
        raise SystemExit("尚未產生評論資料 places_with_reviews.json")

    db = json.loads(DB_PATH.read_text(encoding="utf-8"))
    places = db.get("places") or []
    reviews = json.loads(REVIEWS_PATH.read_text(encoding="utf-8"))

    by_name = {}
    for item in reviews:
        if not isinstance(item, dict):
            continue
        name = (item.get("source_name") or item.get("name") or "").strip()
        if name:
            by_name[name] = item

    updated = 0
    for place in places:
        name = (place.get("name") or "").strip()
        match = by_name.get(name)
        if not match:
            continue
        rating = match.get("rating")
        total = match.get("user_ratings_total")
        if rating is None and total is None:
            continue
        place["rating"] = rating
        place["userRatingsTotal"] = total
        updated += 1

    DB_PATH.write_text(json.dumps(db, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"已回填評分：{updated} / {len(places)}")


if __name__ == "__main__":
    main()
