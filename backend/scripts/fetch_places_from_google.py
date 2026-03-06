"""
Seed places from Google Places Text Search, then fetch details (reviews + ratings)
and merge into db.json + places_with_reviews.json.

Usage:
  GOOGLE_MAPS_API_KEY=your_key python3 backend/scripts/fetch_places_from_google.py

Optional env:
  GOOGLE_PLACE_QUERIES="台北 景點,台中 景點"
  GOOGLE_PLACE_CITY="宜蘭縣"  # 只抓單一縣市（優先於 GOOGLE_PLACE_QUERIES）
  MAX_REQUESTS=100
  TEXTSEARCH_MAX_PAGES=2
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
from typing import Dict, Any, List, Iterable, Tuple

ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "data" / "db.json"
REVIEWS_PATH = ROOT / "data" / "places_with_reviews.json"
API_KEY = os.environ.get("GOOGLE_MAPS_API_KEY")

MAX_REQUESTS = int(os.environ.get("MAX_REQUESTS", "100"))
TEXTSEARCH_MAX_PAGES = int(os.environ.get("TEXTSEARCH_MAX_PAGES", "2"))
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
CITY_QUERY_SUFFIXES = [
    "景點",
    "旅遊景點",
    "觀光景點",
    "必去景點",
]

CITY_QUERY_ALIASES = {
    "臺北市": "台北",
    "台北市": "台北",
    "新北市": "新北",
    "基隆市": "基隆",
    "桃園市": "桃園",
    "新竹市": "新竹",
    "新竹縣": "新竹",
    "苗栗縣": "苗栗",
    "臺中市": "台中",
    "台中市": "台中",
    "彰化縣": "彰化",
    "南投縣": "南投",
    "雲林縣": "雲林",
    "嘉義市": "嘉義",
    "嘉義縣": "嘉義",
    "臺南市": "台南",
    "台南市": "台南",
    "高雄市": "高雄",
    "屏東縣": "屏東",
    "宜蘭縣": "宜蘭",
    "花蓮縣": "花蓮",
    "台東縣": "台東",
    "臺東縣": "台東",
    "澎湖縣": "澎湖",
    "金門縣": "金門",
    "連江縣": "馬祖",
}

CITY_HINTS = [
    "臺北市",
    "台北市",
    "新北市",
    "新北市",
    "基隆市",
    "桃園市",
    "新竹市",
    "新竹市",
    "新竹縣",
    "苗栗縣",
    "臺中市",
    "台中市",
    "彰化縣",
    "南投縣",
    "雲林縣",
    "嘉義市",
    "嘉義縣",
    "臺南市",
    "台南市",
    "高雄市",
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
    priceLevel: int | None
    priceCategory: str | None
    openingHours: Dict[str, Any] | None

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
            "priceLevel": self.priceLevel,
            "priceCategory": self.priceCategory,
            "openingHours": self.openingHours,
        }


def _ssl_context() -> ssl.SSLContext:
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


def _extract_city(address: str) -> str:
    if not address:
        return ""
    address = address.replace("臺", "台")
    for hint in CITY_HINTS:
        if hint in address.replace("臺", "台"):
            return hint
    return ""


def _extract_city_from_components(components: list[dict]) -> str:
    # Prefer admin_area_level_1 (city/county), then locality.
    for level in ("administrative_area_level_1", "locality"):
        for comp in components:
            types = comp.get("types") or []
            if level in types:
                name = (comp.get("long_name") or "").replace("臺", "台")
                return name
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
    last_err = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=20, context=_ssl_context()) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            break
        except Exception as err:
            last_err = err
            if attempt == 2:
                raise
            time.sleep(0.8 * (attempt + 1))
    else:
        raise RuntimeError(f"抓取失敗: {last_err}")
    if data.get("status") in {"OVER_QUERY_LIMIT", "RESOURCE_EXHAUSTED"}:
        raise RuntimeError("OVER_QUERY_LIMIT/RESOURCE_EXHAUSTED，已停止")
    return data


def _load_queries() -> List[str]:
    def _unique(items: List[str]) -> List[str]:
        seen = set()
        out: List[str] = []
        for item in items:
            value = item.strip()
            if not value or value in seen:
                continue
            seen.add(value)
            out.append(value)
        return out

    city = (os.environ.get("GOOGLE_PLACE_CITY") or "").strip()
    if city:
        normalized = city.replace("臺", "台")
        keyword = CITY_QUERY_ALIASES.get(city) or CITY_QUERY_ALIASES.get(normalized) or normalized
        return _unique([f"{keyword} {suffix}" for suffix in CITY_QUERY_SUFFIXES])
    raw = os.environ.get("GOOGLE_PLACE_QUERIES")
    if raw:
        return _unique([q.strip() for q in raw.split(",") if q.strip()])
    return _unique(DEFAULT_QUERIES)


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
                    "price_level",
                    "types",
                    "address_components",
                    "photos",
                    "opening_hours",
                ]
            ),
        },
    )
    if data.get("status") != "OK":
        return None
    return data.get("result") or {}


def _photo_url(photo_ref: str) -> str:
    if not photo_ref:
        return ""
    params = urllib.parse.urlencode(
        {"maxwidth": "800", "photo_reference": photo_ref, "key": API_KEY}
    )
    return f"https://maps.googleapis.com/maps/api/place/photo?{params}"


def _price_category(price_level: int | None) -> str | None:
    if price_level is None:
        return None
    if price_level <= 1:
        return "low"
    if price_level == 2:
        return "mid"
    return "high"


def _normalize_opening_hours(raw: Any) -> Dict[str, Any] | None:
    if not isinstance(raw, dict):
        return None
    out: Dict[str, Any] = {}
    if isinstance(raw.get("open_now"), bool):
        out["open_now"] = raw.get("open_now")
    weekday_text = raw.get("weekday_text")
    if isinstance(weekday_text, list):
        out["weekday_text"] = [str(x) for x in weekday_text if str(x).strip()]
    periods = raw.get("periods")
    if isinstance(periods, list):
        cleaned_periods: list[dict[str, Any]] = []
        for p in periods:
            if not isinstance(p, dict):
                continue
            item: dict[str, Any] = {}
            for side in ("open", "close"):
                side_value = p.get(side)
                if not isinstance(side_value, dict):
                    continue
                day = side_value.get("day")
                time_value = side_value.get("time")
                if day is None and time_value is None:
                    continue
                side_out: dict[str, Any] = {}
                if isinstance(day, int):
                    side_out["day"] = day
                elif isinstance(day, str) and day.isdigit():
                    side_out["day"] = int(day)
                if time_value is not None:
                    side_out["time"] = str(time_value)
                if side_out:
                    item[side] = side_out
            if item:
                cleaned_periods.append(item)
        if cleaned_periods:
            out["periods"] = cleaned_periods
    return out or None

def _normalize_tag_list(tags: Any) -> list[str]:
    if not tags:
        return []
    if isinstance(tags, list):
        return [str(t).strip() for t in tags if str(t).strip()]
    if isinstance(tags, str):
        return [t.strip() for t in tags.split(",") if t.strip()]
    return []


def _merge_tags(existing: Iterable[str], fresh: Iterable[str]) -> list[str]:
    merged: list[str] = []
    seen: set[str] = set()
    for tag in list(existing) + list(fresh):
        tag = (tag or "").strip()
        if not tag or tag in seen:
            continue
        seen.add(tag)
        merged.append(tag)
    return merged


def _needs_enrich(place: Dict[str, Any]) -> bool:
    if not place:
        return True
    if not place.get("imageUrl"):
        return True
    if place.get("rating") is None or place.get("userRatingsTotal") is None:
        return True
    if place.get("priceLevel") is None or not place.get("priceCategory"):
        return True
    if not place.get("address") or len(str(place.get("address")).strip()) < 6:
        return True
    if not place.get("city"):
        return True
    if not place.get("openingHours"):
        return True
    lat = place.get("lat")
    lng = place.get("lng")
    if not lat or not lng:
        return True
    return False


def _find_place_id(query: str) -> str | None:
    data = _fetch_json(
        "https://maps.googleapis.com/maps/api/place/findplacefromtext/json",
        {
            "input": query,
            "inputtype": "textquery",
            "language": "zh-TW",
            "fields": "place_id",
        },
    )
    if data.get("status") != "OK":
        return None
    candidates = data.get("candidates") or []
    if not candidates:
        return None
    return candidates[0].get("place_id")


def _merge_places(
    existing: List[Dict[str, Any]], fresh: List[Place]
) -> Tuple[List[Dict[str, Any]], Dict[str, int]]:
    stats = {"added": 0, "updated": 0, "unchanged": 0}
    if MERGE_MODE == "replace":
        stats["added"] = len(fresh)
        return [p.to_dict() for p in fresh], stats
    by_id: Dict[str, Dict[str, Any]] = {p.get("id"): p for p in existing if p.get("id")}
    by_name = {p.get("name"): p for p in existing if p.get("name")}
    for place in fresh:
        fresh_dict = place.to_dict()
        target = None
        if place.id in by_id:
            target = by_id[place.id]
        elif place.name in by_name:
            target = by_name[place.name]

        if target is not None:
            before = json.dumps(target, ensure_ascii=False, sort_keys=True)
            target.update(fresh_dict)
            after = json.dumps(target, ensure_ascii=False, sort_keys=True)
            if after == before:
                stats["unchanged"] += 1
            else:
                stats["updated"] += 1
        else:
            existing.append(fresh_dict)
            if place.id:
                by_id[place.id] = fresh_dict
            if place.name:
                by_name[place.name] = fresh_dict
            stats["added"] += 1
    return existing, stats


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
    reviews_by_id = {
        (item.get("place_id") or "").strip(): item
        for item in reviews_db
        if isinstance(item, dict) and item.get("place_id")
    }

    queries = _load_queries()
    output: List[Place] = []
    reviews_out: List[Dict[str, Any]] = []
    seen = set()
    request_count = 0
    selected_city = (os.environ.get("GOOGLE_PLACE_CITY") or "").strip()
    single_city_mode = bool(selected_city)

    if queries:
        print(f"本次查詢目標: {', '.join(queries)}")
    if single_city_mode:
        print(f"單縣市模式啟用: {selected_city}（優先抓取該縣市，暫跳過全庫補資料）")

    def _build_query_from_place(place: Dict[str, Any]) -> str:
        name = (place.get("name") or "").strip()
        city = (place.get("city") or "").strip()
        address = (place.get("address") or "").strip()
        parts = [name]
        if city and city not in address:
            parts.append(city)
        if address:
            parts.append(address)
        return " ".join([p for p in parts if p]).strip()

    if not single_city_mode:
        # Enrich existing places missing image/rating/price/city/address.
        # Reserve some quota for search queries so crawl doesn't end before query loop starts.
        reserve_for_search = min(MAX_REQUESTS, max(20, len(queries) * 8))
        for place in existing_places:
            if request_count >= max(0, MAX_REQUESTS - reserve_for_search):
                break
            if not _needs_enrich(place):
                continue
            query = _build_query_from_place(place)
            if not query:
                continue
            place_id = _find_place_id(query)
            request_count += 1
            if not place_id:
                continue
            details = _place_details(place_id) or {}
            if details:
                request_count += 1
            geometry = (details.get("geometry") or {}).get("location", {})
            lat = float(geometry.get("lat") or 0)
            lng = float(geometry.get("lng") or 0)
            types = details.get("types") or []
            rating = details.get("rating")
            rating_total = details.get("user_ratings_total")
            price_level = details.get("price_level")
            editorial = (details.get("editorial_summary") or {}).get("overview") if details else None
            full_address = details.get("formatted_address") or place.get("address") or ""
            components = details.get("address_components") or []
            city = _extract_city_from_components(components) or _extract_city(full_address)
            photos = details.get("photos") or []
            photo_ref = ""
            if isinstance(photos, list) and photos:
                photo_ref = photos[0].get("photo_reference", "") if isinstance(photos[0], dict) else ""
            image_url = _photo_url(photo_ref)
            opening_hours = _normalize_opening_hours(details.get("opening_hours"))
            raw_reviews = [r.get("text", "") for r in (details.get("reviews") or []) if isinstance(r, dict)]
            reviews = _clean_reviews(raw_reviews)
            text = f"{place.get('name','')} {full_address} {editorial or ''} {' '.join(reviews)}"
            tags = _extract_tags(text, types)
            merged_tags = _merge_tags(_normalize_tag_list(place.get("tags")), tags)
            price_level_value = int(price_level) if price_level is not None else None
            price_category = _price_category(price_level_value)

            # Fill only missing fields
            if not place.get("city") and city:
                place["city"] = city
            if not place.get("address") or len(str(place.get("address")).strip()) < 6:
                if full_address:
                    place["address"] = full_address
            if (not place.get("lat") or not place.get("lng")) and lat and lng:
                place["lat"] = lat
                place["lng"] = lng
            if not place.get("imageUrl") and image_url:
                place["imageUrl"] = image_url
            if place.get("rating") is None and rating is not None:
                place["rating"] = float(rating)
            if place.get("userRatingsTotal") is None and rating_total is not None:
                place["userRatingsTotal"] = int(rating_total)
            if place.get("priceLevel") is None and price_level_value is not None:
                place["priceLevel"] = price_level_value
            if not place.get("priceCategory") and price_category:
                place["priceCategory"] = price_category
            if not place.get("description") and editorial:
                place["description"] = editorial
            if merged_tags:
                place["tags"] = merged_tags
                place["category"] = place.get("category") or merged_tags[0]
            if not place.get("openingHours") and opening_hours:
                place["openingHours"] = opening_hours

            if details:
                review_item = {
                    "place_id": place_id,
                    "source_name": place.get("name"),
                    "name": place.get("name"),
                    "formatted_address": full_address,
                    "rating": rating,
                    "user_ratings_total": rating_total,
                    "price_level": price_level,
                    "types": types,
                    "editorial_summary": editorial or "",
                    "reviews": reviews,
                    "image_url": image_url,
                    "opening_hours": opening_hours,
                }
                reviews_out.append(review_item)
                if place_id:
                    reviews_by_id[place_id] = review_item

    for query in queries:
        if request_count >= MAX_REQUESTS:
            break
        page_no = 0
        page_token: str | None = None
        while request_count < MAX_REQUESTS and page_no < max(1, TEXTSEARCH_MAX_PAGES):
            params: Dict[str, Any]
            if page_token:
                # next_page_token needs a short delay before becoming valid
                time.sleep(2.1)
                params = {"pagetoken": page_token, "language": "zh-TW"}
            else:
                params = {"query": query, "language": "zh-TW"}

            data = _fetch_json(
                "https://maps.googleapis.com/maps/api/place/textsearch/json",
                params,
            )
            request_count += 1
            status = data.get("status") or "UNKNOWN"
            if status not in {"OK", "ZERO_RESULTS"}:
                print(f"查詢狀態: {query} page={page_no+1} -> {status}")
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
                details = {}
                if request_count < MAX_REQUESTS:
                    details = _place_details(place_id) or {}
                    if details:
                        request_count += 1
                geometry = (details.get("geometry") or item.get("geometry") or {}).get("location", {})
                lat = float(geometry.get("lat") or 0)
                lng = float(geometry.get("lng") or 0)
                types = details.get("types") or item.get("types") or []
                rating = details.get("rating") or item.get("rating")
                rating_total = details.get("user_ratings_total") or item.get("user_ratings_total")
                price_level = details.get("price_level") or item.get("price_level")
                editorial = (details.get("editorial_summary") or {}).get("overview") if details else None
                full_address = details.get("formatted_address") or address
                components = details.get("address_components") or []
                city = _extract_city_from_components(components) or _extract_city(full_address)
                photos = details.get("photos") or item.get("photos") or []
                photo_ref = ""
                if isinstance(photos, list) and photos:
                    photo_ref = photos[0].get("photo_reference", "") if isinstance(photos[0], dict) else ""
                image_url = _photo_url(photo_ref)
                opening_hours = _normalize_opening_hours(details.get("opening_hours"))
                raw_reviews = [r.get("text", "") for r in (details.get("reviews") or []) if isinstance(r, dict)]
                reviews = _clean_reviews(raw_reviews)
                text = f"{name} {full_address} {editorial or ''} {' '.join(reviews)}"
                tags = _extract_tags(text, types)
                category = tags[0] if tags else "other"
                price_level_value = int(price_level) if price_level is not None else None
                price_category = _price_category(price_level_value)
                output.append(
                    Place(
                        id=place_id,
                        name=name,
                        category=category,
                        tags=tags,
                        city=city,
                        address=full_address,
                        lat=lat,
                        lng=lng,
                        description=editorial or "",
                        imageUrl=image_url,
                        rating=float(rating) if rating is not None else None,
                        userRatingsTotal=int(rating_total) if rating_total is not None else None,
                        priceLevel=price_level_value,
                        priceCategory=price_category,
                        openingHours=opening_hours,
                    )
                )
                reviews_out.append(
                    {
                        "place_id": place_id,
                        "source_name": name,
                        "name": name,
                        "formatted_address": address,
                        "rating": rating,
                        "user_ratings_total": rating_total,
                        "price_level": price_level,
                        "types": types,
                        "editorial_summary": editorial or "",
                        "reviews": reviews,
                        "image_url": image_url,
                        "opening_hours": opening_hours,
                    }
                )
                if request_count >= MAX_REQUESTS:
                    break

            page_token = data.get("next_page_token")
            page_no += 1
            if not page_token:
                break
        print(
            f"完成查詢: {query}, 分頁 {page_no}/{max(1, TEXTSEARCH_MAX_PAGES)}, "
            f"累積 {len(output)} 筆, 用量 {request_count}/{MAX_REQUESTS}"
        )
        time.sleep(SLEEP_BETWEEN)

    merged_places, merge_stats = _merge_places(existing_places, output)
    db["places"] = merged_places
    DB_PATH.write_text(json.dumps(db, ensure_ascii=False, indent=2), encoding="utf-8")
    if reviews_out:
        for item in reviews_out:
            key = (item.get("source_name") or item.get("name") or "").strip()
            if key:
                reviews_by_name[key] = item
            place_id = (item.get("place_id") or "").strip()
            if place_id:
                reviews_by_id[place_id] = item
        merged_reviews = {**reviews_by_name, **reviews_by_id}
        REVIEWS_PATH.write_text(
            json.dumps(list(merged_reviews.values()), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    print(
        f"完成，寫入 {DB_PATH}，來源 {len(output)} 筆，"
        f"新增 {merge_stats['added']}／更新 {merge_stats['updated']}／未變更 {merge_stats['unchanged']}"
    )


if __name__ == "__main__":
    main()
