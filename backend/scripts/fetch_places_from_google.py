"""
Seed places from Google Places Text Search, then fetch details (reviews + ratings)
and merge into db.json + places_with_reviews.json.

Usage:
  GOOGLE_MAPS_API_KEY=your_key python3 backend/scripts/fetch_places_from_google.py

Optional env:
  GOOGLE_PLACE_QUERIES="台北 景點,台中 景點"
  MAX_REQUESTS=100
  MERGE_MODE=merge|replace
"""
from __future__ import annotations

import json
import os
import ssl
import sys
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Any, List

ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "data" / "db.json"
REVIEWS_PATH = ROOT / "data" / "places_with_reviews.json"
API_KEY = os.environ.get("GOOGLE_MAPS_API_KEY")

MAX_REQUESTS = int(os.environ.get("MAX_REQUESTS", "100"))
SLEEP_BETWEEN = 0.2
MERGE_MODE = os.environ.get("MERGE_MODE", "merge").strip().lower()
REVIEWS_LIMIT = 5
MIN_REVIEW_LEN = 12

DEFAULT_QUERIES = [
    "台北 景點",
    "台中 景點",
    "台南 景點",
    "高雄 景點",
    "花蓮 景點",
    "台東 景點",
]

CITY_HINTS = [
    "台北市",
    "新北市",
    "基隆市",
    "桃園市",
    "新竹市",
    "新竹縣",
    "苗栗縣",
    "台中市",
    "彰化縣",
    "南投縣",
    "雲林縣",
    "嘉義市",
    "嘉義縣",
    "台南市",
    "高雄市",
    "屏東縣",
    "宜蘭縣",
    "花蓮縣",
    "台東縣",
    "澎湖縣",
    "金門縣",
    "連江縣",
]

# tag keywords (kw -> tag)
INTEREST_KEYWORDS = [
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

PLACE_TYPE_TAGS = {
    "museum": "museum",
    "art_gallery": "museum",
    "amusement_park": "amusement",
    "aquarium": "aquarium",
    "zoo": "zoo",
    "park": "national_park",
    "campground": "camping",
    "shopping_mall": "department_store",
    "restaurant": "restaurant",
    "cafe": "cafe",
    "tourist_attraction": "heritage",
    "place_of_worship": "temple",
}

try:
    import certifi

    ssl._create_default_https_context = lambda: ssl.create_default_context(  # noqa: E731
        cafile=certifi.where()
    )
except Exception:
    pass


@dataclass
class Place:
    id: str
    name: str
    category: str
    tags: List[str]
    city: str
    address: str
    lat: float
    lng: float
    description: str
    imageUrl: str
    rating: float | None
    userRatingsTotal: int | None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "category": self.category,
            "tags": self.tags,
            "city": self.city,
            "address": self.address,
            "lat": self.lat,
            "lng": self.lng,
            "description": self.description,
            "imageUrl": self.imageUrl,
            "rating": self.rating,
            "userRatingsTotal": self.userRatingsTotal,
        }


def _ssl_context() -> ssl.SSLContext:
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


def _extract_city(address: str) -> str:
    for hint in CITY_HINTS:
        if hint in address:
            return hint
    return ""


def _extract_tags(text: str, types: list[str]) -> list[str]:
    tags = set()
    for kw, tag in INTEREST_KEYWORDS:
        if kw in text:
            tags.add(tag)
    for t in types:
        mapped = PLACE_TYPE_TAGS.get(t)
        if mapped:
            tags.add(mapped)
    if not tags:
        tags.add("other")
    return sorted(tags)


def _clean_reviews(raw_reviews: list[str]) -> list[str]:
    seen = set()
    cleaned: list[str] = []
    for text in raw_reviews:
        text = (text or "").strip()
        if len(text) < MIN_REVIEW_LEN:
            continue
        if text in seen:
            continue
        seen.add(text)
        cleaned.append(text)
        if len(cleaned) >= REVIEWS_LIMIT:
            break
    return cleaned


def _fetch_json(url: str, params: Dict[str, Any]) -> Dict[str, Any]:
    params["key"] = API_KEY
    qs = urllib.parse.urlencode(params, safe=",")
    full_url = f"{url}?{qs}"
    req = urllib.request.Request(full_url, headers={"User-Agent": "smart-travel/1.0"})
    with urllib.request.urlopen(req, timeout=20, context=_ssl_context()) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    if data.get("status") in {"OVER_QUERY_LIMIT", "RESOURCE_EXHAUSTED"}:
        raise RuntimeError("OVER_QUERY_LIMIT/RESOURCE_EXHAUSTED，已停止")
    return data


def _load_queries() -> List[str]:
    raw = os.environ.get("GOOGLE_PLACE_QUERIES")
    if raw:
        return [q.strip() for q in raw.split(",") if q.strip()]
    return DEFAULT_QUERIES


def _place_details(place_id: str) -> Dict[str, Any] | None:
    data = _fetch_json(
        "https://maps.googleapis.com/maps/api/place/details/json",
        {
            "place_id": place_id,
            "language": "zh-TW",
            "reviews_sort": "most_relevant",
            "fields": ",".join(
                [
                    "place_id",
                    "name",
                    "formatted_address",
                    "geometry",
                    "editorial_summary",
                    "reviews",
                    "rating",
                    "user_ratings_total",
                    "types",
                ]
            ),
        },
    )
    if data.get("status") != "OK":
        return None
    return data.get("result") or {}


def _merge_places(existing: List[Dict[str, Any]], fresh: List[Place]) -> List[Dict[str, Any]]:
    if MERGE_MODE == "replace":
        return [p.to_dict() for p in fresh]
    by_id: Dict[str, Dict[str, Any]] = {p.get("id"): p for p in existing if p.get("id")}
    by_name = {p.get("name"): p for p in existing if p.get("name")}
    for place in fresh:
        if place.id in by_id:
            by_id[place.id].update(place.to_dict())
        elif place.name in by_name:
            by_name[place.name].update(place.to_dict())
        else:
            existing.append(place.to_dict())
    return existing


def main() -> None:
    if not API_KEY:
        sys.exit("請先在環境變數設定 GOOGLE_MAPS_API_KEY")
    if not DB_PATH.exists():
        sys.exit(f"找不到 {DB_PATH}")

    db = json.loads(DB_PATH.read_text(encoding="utf-8"))
    existing_places = db.get("places") or []
    if REVIEWS_PATH.exists():
        reviews_db = json.loads(REVIEWS_PATH.read_text(encoding="utf-8"))
        if not isinstance(reviews_db, list):
            reviews_db = []
    else:
        reviews_db = []
    reviews_by_name = {
        (item.get("source_name") or item.get("name") or "").strip(): item
        for item in reviews_db
        if isinstance(item, dict)
    }

    queries = _load_queries()
    output: List[Place] = []
    reviews_out: List[Dict[str, Any]] = []
    seen = set()
    request_count = 0

    for query in queries:
        if request_count >= MAX_REQUESTS:
            break
        data = _fetch_json(
            "https://maps.googleapis.com/maps/api/place/textsearch/json",
            {"query": query, "language": "zh-TW"},
        )
        request_count += 1
        results = data.get("results") or []
        for item in results:
            place_id = item.get("place_id")
            name = item.get("name") or ""
            address = item.get("formatted_address") or ""
            if not place_id or not name:
                continue
            if place_id in seen or name in seen:
                continue
            seen.add(place_id)
            seen.add(name)
            details = _place_details(place_id) or {}
            if details:
                request_count += 1
            geometry = (details.get("geometry") or item.get("geometry") or {}).get("location", {})
            lat = float(geometry.get("lat") or 0)
            lng = float(geometry.get("lng") or 0)
            types = details.get("types") or item.get("types") or []
            rating = details.get("rating") or item.get("rating")
            rating_total = details.get("user_ratings_total") or item.get("user_ratings_total")
            editorial = (details.get("editorial_summary") or {}).get("overview") if details else None
            raw_reviews = [r.get("text", "") for r in (details.get("reviews") or []) if isinstance(r, dict)]
            reviews = _clean_reviews(raw_reviews)
            text = f"{name} {address} {editorial or ''} {' '.join(reviews)}"
            tags = _extract_tags(text, types)
            category = tags[0] if tags else "other"
            output.append(
                Place(
                    id=place_id,
                    name=name,
                    category=category,
                    tags=tags,
                    city=_extract_city(address),
                    address=address,
                    lat=lat,
                    lng=lng,
                    description=editorial or "",
                    imageUrl="",
                    rating=float(rating) if rating is not None else None,
                    userRatingsTotal=int(rating_total) if rating_total is not None else None,
                )
            )
            reviews_out.append(
                {
                    "source_name": name,
                    "name": name,
                    "formatted_address": address,
                    "rating": rating,
                    "user_ratings_total": rating_total,
                    "types": types,
                    "editorial_summary": editorial or "",
                    "reviews": reviews,
                }
            )
        print(f"完成查詢: {query}, 累積 {len(output)} 筆, 用量 {request_count}/{MAX_REQUESTS}")
        time.sleep(SLEEP_BETWEEN)

    db["places"] = _merge_places(existing_places, output)
    DB_PATH.write_text(json.dumps(db, ensure_ascii=False, indent=2), encoding="utf-8")
    if reviews_out:
        for item in reviews_out:
            key = (item.get("source_name") or item.get("name") or "").strip()
            if not key:
                continue
            reviews_by_name[key] = item
        REVIEWS_PATH.write_text(
            json.dumps(list(reviews_by_name.values()), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    print(f"完成，寫入 {DB_PATH}，新增/更新 {len(output)} 筆")


if __name__ == "__main__":
    main()
