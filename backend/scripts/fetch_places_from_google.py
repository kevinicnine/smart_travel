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
  GOOGLE_QUERY_SCOPE=standard|expanded
  MERGE_MODE=merge|replace
"""
from __future__ import annotations

import json
import os
import re
import ssl
import sys
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Any, List, Iterable, Tuple

ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "data" / "db.json"
REVIEWS_PATH = ROOT / "data" / "places_with_reviews.json"
API_KEY = os.environ.get("GOOGLE_MAPS_API_KEY")

MAX_REQUESTS = int(os.environ.get("MAX_REQUESTS", "100"))
TEXTSEARCH_MAX_PAGES = int(os.environ.get("TEXTSEARCH_MAX_PAGES", "2"))
QUERY_SCOPE = os.environ.get("GOOGLE_QUERY_SCOPE", "standard").strip().lower()
SLEEP_BETWEEN = 0.2
MERGE_MODE = os.environ.get("MERGE_MODE", "merge").strip().lower()
REVIEWS_LIMIT = 5
MIN_REVIEW_LEN = 12

TAIWAN_CITIES = [
    "臺北市",
    "新北市",
    "基隆市",
    "桃園市",
    "新竹市",
    "新竹縣",
    "苗栗縣",
    "臺中市",
    "彰化縣",
    "南投縣",
    "雲林縣",
    "嘉義市",
    "嘉義縣",
    "臺南市",
    "高雄市",
    "屏東縣",
    "宜蘭縣",
    "花蓮縣",
    "臺東縣",
    "澎湖縣",
    "金門縣",
    "連江縣",
]

STANDARD_CITY_QUERY_SUFFIXES = ["景點", "旅遊景點", "觀光景點", "必去景點"]

EXPANDED_CITY_QUERY_SUFFIXES = [
    *STANDARD_CITY_QUERY_SUFFIXES,
    "親子景點",
    "自然景點",
    "秘境",
    "博物館",
    "老街",
    "步道",
    "公園",
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

CITY_CANONICAL_MAP = {
    "台北市": "臺北市",
    "臺北市": "臺北市",
    "新北市": "新北市",
    "基隆市": "基隆市",
    "桃園市": "桃園市",
    "新竹市": "新竹市",
    "新竹縣": "新竹縣",
    "苗栗縣": "苗栗縣",
    "台中市": "臺中市",
    "臺中市": "臺中市",
    "彰化縣": "彰化縣",
    "南投縣": "南投縣",
    "雲林縣": "雲林縣",
    "嘉義市": "嘉義市",
    "嘉義縣": "嘉義縣",
    "台南市": "臺南市",
    "臺南市": "臺南市",
    "高雄市": "高雄市",
    "屏東縣": "屏東縣",
    "宜蘭縣": "宜蘭縣",
    "花蓮縣": "花蓮縣",
    "台東縣": "臺東縣",
    "臺東縣": "臺東縣",
    "澎湖縣": "澎湖縣",
    "金門縣": "金門縣",
    "連江縣": "連江縣",
    "馬祖": "連江縣",
}

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
    source: str | None = None
    updatedAt: str | None = None

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
            "source": self.source,
            "updatedAt": self.updatedAt,
        }


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _stamp_metadata(place: Dict[str, Any], *, source: str = "google_places") -> None:
    place["source"] = source
    place["updatedAt"] = _utc_now_iso()


def _ssl_context() -> ssl.SSLContext:
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


TW_TEXT_VARIANT_MAP = str.maketrans({
    "臺": "台",
    "云": "雲",
    "县": "縣",
    "市": "市",
    "区": "區",
    "镇": "鎮",
    "乡": "鄉",
    "村": "村",
    "里": "里",
    "东": "東",
    "西": "西",
    "南": "南",
    "北": "北",
    "兰": "蘭",
    "门": "門",
    "连": "連",
    "江": "江",
    "台": "台",
    "号": "號",
    "段": "段",
    "路": "路",
    "街": "街",
    "巷": "巷",
    "弄": "弄",
})


def _normalize_tw_text(value: str) -> str:
    if not value:
        return ""
    text = str(value).strip().translate(TW_TEXT_VARIANT_MAP)
    text = text.replace("邮政编码", "郵政編碼").replace("郵遞區號", "郵政編碼")
    return text


def _extract_city(address: str) -> str:
    if not address:
        return ""
    address = _normalize_tw_text(address)
    for hint in CITY_HINTS:
        if hint in address:
            return hint
    return ""


def _extract_city_from_components(components: list[dict]) -> str:
    # Prefer admin_area_level_1 (city/county), then locality.
    for level in ("administrative_area_level_1", "locality"):
        for comp in components:
            types = comp.get("types") or []
            if level in types:
                name = _normalize_tw_text(comp.get("long_name") or "")
                return name
    return ""


def _normalize_city_name(value: str) -> str:
    if not value:
        return ""
    normalized = _normalize_tw_text(value)
    return CITY_CANONICAL_MAP.get(normalized, value.strip())


def _normalize_name(value: str) -> str:
    return " ".join((value or "").strip().split()).lower()


def _normalize_address(value: str) -> str:
    return "".join(_normalize_tw_text(value).split()).lower()


def _clean_display_address(value: str) -> str:
    if not value:
        return ""
    text = _normalize_tw_text(value)
    text = re.sub(r"[，,、]?\s*郵政編碼[:：]?\s*\d{3,6}", "", text)
    text = re.sub(r"\s+", "", text)
    text = re.sub(
        r"^(?P<postal>\d{3,6})(?=(台北市|臺北市|新北市|基隆市|桃園市|新竹市|新竹縣|苗栗縣|台中市|臺中市|彰化縣|南投縣|雲林縣|嘉義市|嘉義縣|台南市|臺南市|高雄市|屏東縣|宜蘭縣|花蓮縣|台東縣|臺東縣|澎湖縣|金門縣|連江縣))",
        "",
        text,
    )
    return text.strip(" ,，、")


def _address_quality_score(value: str) -> int:
    text = _clean_display_address(value)
    if not text:
        return -100
    score = len(text)
    if _extract_city(text):
        score += 30
    if re.search(r"[鄉鎮市區村里]", text):
        score += 20
    if re.search(r"[路街道段巷弄號]", text):
        score += 20
    if re.fullmatch(r"\d{3,6}", text):
        score -= 120
    if "郵政編碼" in text:
        score -= 80
    return score


def _build_address_from_components(components: list[dict], fallback: str = "") -> str:
    cleaned_fallback = _clean_display_address(fallback)
    if not components:
        return cleaned_fallback

    ordered_types = [
        "administrative_area_level_1",
        "administrative_area_level_2",
        "administrative_area_level_3",
        "administrative_area_level_4",
        "locality",
        "sublocality_level_1",
        "sublocality_level_2",
        "sublocality_level_3",
        "route",
        "street_number",
        "premise",
        "subpremise",
    ]

    parts: list[str] = []
    seen: set[str] = set()
    for type_name in ordered_types:
        for comp in components:
            types = comp.get("types") or []
            if type_name not in types:
                continue
            name = _clean_display_address(comp.get("long_name") or "")
            if type_name == "street_number" and name.isdigit():
                name = f"{name}號"
            if not name or name in seen:
                continue
            seen.add(name)
            parts.append(name)

    rebuilt = _clean_display_address("".join(parts))
    if _address_quality_score(cleaned_fallback) > _address_quality_score(rebuilt):
        return cleaned_fallback
    return rebuilt or cleaned_fallback


def _pick_best_address(*candidates: str) -> str:
    best = ""
    best_score = -10**9
    best_len = -1
    for candidate in candidates:
        cleaned = _clean_display_address(candidate)
        if not cleaned:
            continue
        score = _address_quality_score(cleaned)
        if score > best_score or (score == best_score and len(cleaned) > best_len):
            best = cleaned
            best_score = score
            best_len = len(cleaned)
    return best


def _ensure_address_with_city(address: str, city: str) -> str:
    cleaned = _clean_display_address(address)
    normalized_city = _normalize_city_name(city)
    if not cleaned or not normalized_city:
        return cleaned
    if normalized_city in cleaned:
        return cleaned
    candidate = _clean_display_address(f"{normalized_city}{cleaned}")
    if _address_quality_score(candidate) >= _address_quality_score(cleaned):
        return candidate
    return cleaned


def _place_merge_key(name: str, city: str, address: str) -> tuple[str, str]:
    normalized_name = _normalize_name(name)
    normalized_city = _normalize_city_name(city)
    if normalized_city:
        return normalized_name, normalized_city
    extracted_city = _normalize_city_name(_extract_city(address))
    if extracted_city:
        return normalized_name, extracted_city
    normalized_address = _normalize_address(address)
    return normalized_name, normalized_address


def _city_variants(value: str) -> set[str]:
    canonical = _normalize_city_name(value)
    if not canonical:
        return set()
    variants = {
        canonical,
        canonical.replace("臺", "台"),
    }
    alias = CITY_QUERY_ALIASES.get(canonical) or CITY_QUERY_ALIASES.get(canonical.replace("臺", "台"))
    if alias:
        variants.add(alias)
    if canonical.endswith(("市", "縣")):
        variants.add(canonical[:-1])
        variants.add(canonical.replace("臺", "台")[:-1])
    return {item for item in variants if item}


def _matches_selected_city(selected_city: str, city: str, address: str) -> bool:
    normalized_selected = _normalize_city_name(selected_city)
    if not normalized_selected:
        return True
    if city and _normalize_city_name(city) == normalized_selected:
        return True
    normalized_address = _normalize_tw_text(address or "")
    return any(_normalize_tw_text(variant) in normalized_address for variant in _city_variants(normalized_selected))


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

    suffixes = (
        EXPANDED_CITY_QUERY_SUFFIXES
        if QUERY_SCOPE == "expanded"
        else STANDARD_CITY_QUERY_SUFFIXES
    )
    city = (os.environ.get("GOOGLE_PLACE_CITY") or "").strip()
    if city:
        normalized = city.replace("臺", "台")
        keyword = CITY_QUERY_ALIASES.get(city) or CITY_QUERY_ALIASES.get(normalized) or normalized
        return _unique([f"{keyword} {suffix}" for suffix in suffixes])
    raw = os.environ.get("GOOGLE_PLACE_QUERIES")
    if raw:
        return _unique([q.strip() for q in raw.split(",") if q.strip()])

    # 全縣市模式：先掃一輪每個縣市「景點」，再擴展後綴，確保覆蓋面。
    queries: List[str] = []
    for suffix in suffixes:
        for city_name in TAIWAN_CITIES:
            queries.append(f"{city_name.replace('臺', '台')} {suffix}")
    return _unique(queries)


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
    status = data.get("status")
    if status != "OK":
        if status not in {"ZERO_RESULTS", "NOT_FOUND"}:
            print(f"details 狀態: {place_id} -> {status}")
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
    if price_level <= 0:
        return "free"
    if price_level <= 1:
        return "low"
    return "high"


FREE_TICKET_KEYWORDS = (
    "免門票",
    "免收門票",
    "免費入場",
    "免費參觀",
    "自由入場",
    "入場免費",
    "門票免費",
    "票價免費",
    "參觀免費",
    "free admission",
    "free entry",
)

PAID_TICKET_KEYWORDS = (
    "門票",
    "票價",
    "全票",
    "優待票",
    "成人票",
    "兒童票",
    "入園費",
    "入館費",
    "入場費",
    "購票",
    "售票",
    "售價",
    "收費",
)

HIGH_PRICE_VENUE_KEYWORDS = (
    "遊樂園",
    "主題樂園",
    "樂園",
    "水族館",
    "動物園",
    "海洋公園",
    "纜車",
    "渡假村",
    "觀景台",
    "摩天輪",
    "台北101",
    "臺北101",
)

HIGH_PRICE_TAGS = {
    "amusement_park",
    "aquarium",
    "zoo",
    "rv_park",
    "campground",
    "spa",
}

FREE_DEFAULT_TAGS = {
    "lake_river",
    "beach",
    "national_park",
    "waterfall",
    "temple",
    "night_market",
}

FREE_DEFAULT_TYPES = {
    "park",
    "beach",
    "hiking_area",
}

FREE_DEFAULT_KEYWORDS = (
    "公園",
    "老街",
    "步道",
    "古道",
    "海灘",
    "沙灘",
    "海岸",
    "湖",
    "溪",
    "瀑布",
    "河濱",
    "濕地",
    "夜市",
    "廟",
    "寺",
)

LOW_PRICE_TAGS = {
    "museum",
    "heritage",
    "creative_park",
    "handcraft_shop",
}

LOW_PRICE_TYPES = {
    "museum",
    "art_gallery",
    "tourist_attraction",
}

LOW_PRICE_KEYWORDS = (
    "博物館",
    "美術館",
    "文學館",
    "文化館",
    "故事館",
    "紀念館",
    "教育園區",
    "園區",
    "展覽館",
    "古蹟",
    "觀光工廠",
    "文創",
)

OPEN_ALL_DAY_KEYWORDS = (
    "公園",
    "老街",
    "步道",
    "古道",
    "海灘",
    "沙灘",
    "海岸",
    "湖",
    "溪",
    "河濱",
    "濕地",
    "紀念公園",
    "紀念林",
    "風景區",
    "自然公園",
)

DAYTIME_OPEN_KEYWORDS = (
    "博物館",
    "美術館",
    "文化館",
    "展覽館",
    "紀念館",
    "教育園區",
    "文創園區",
    "觀光工廠",
    "科學館",
)


def _infer_price_level(
    name: str,
    types: Iterable[str],
    city: str,
    address: str,
    description: str,
    review_text: str = "",
) -> int | None:
    haystack = " ".join(
        part
        for part in [name, city, address, description, review_text]
        if (part or "").strip()
    ).lower()
    type_set = set(types or [])

    def extract_explicit_ticket_amount() -> int | None:
        patterns = [
            r"(?:nt\$|twd|\$)\s*(\d{2,5})",
            r"(\d{2,5})\s*元",
            r"(?:門票|票價|全票|入園|入館|成人票|優待票|售價|收費)[^\d]{0,8}(\d{2,5})",
            r"(\d{2,5})[^\d]{0,6}(?:門票|票價|全票|入園|入館|成人票|優待票|售價|收費)",
        ]
        for pattern in patterns:
            match = re.search(pattern, haystack, re.IGNORECASE)
            if not match:
                continue
            amount = int(match.group(1))
            if amount > 0:
                return amount
        return None

    def has_explicit_free_ticket_signal() -> bool:
        return any(keyword in haystack for keyword in FREE_TICKET_KEYWORDS)

    explicit_amount = extract_explicit_ticket_amount()
    if explicit_amount is not None:
        if explicit_amount >= 300:
            return 3
        return 1

    if has_explicit_free_ticket_signal():
        return 0

    has_explicit_paid_signal = any(keyword in haystack for keyword in PAID_TICKET_KEYWORDS)
    if has_explicit_paid_signal:
        if type_set.intersection(HIGH_PRICE_TAGS) or any(
            keyword in haystack for keyword in HIGH_PRICE_VENUE_KEYWORDS
        ):
            return 3
        return 1

    if type_set.intersection(HIGH_PRICE_TAGS) or any(
        keyword in haystack for keyword in HIGH_PRICE_VENUE_KEYWORDS
    ):
        return 3

    if type_set.intersection(FREE_DEFAULT_TYPES) or type_set.intersection(FREE_DEFAULT_TAGS):
        return 0
    if any(keyword in haystack for keyword in FREE_DEFAULT_KEYWORDS):
        return 0

    if type_set.intersection(LOW_PRICE_TYPES) or type_set.intersection(LOW_PRICE_TAGS):
        return 1
    if any(keyword in haystack for keyword in LOW_PRICE_KEYWORDS):
        return 1

    return None


def _build_inferred_opening_hours(
    *,
    open_now: bool | None,
    weekday_line: str,
    note: str,
) -> Dict[str, Any]:
    weekdays = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日']
    lines = [f'{day} {weekday_line}' for day in weekdays]
    result: Dict[str, Any] = {
        "weekday_text": lines,
        "inferred": True,
        "note": note,
    }
    if open_now is not None:
        result["open_now"] = open_now
    return result


def _infer_opening_hours(
    name: str,
    types: Iterable[str],
    tags: Iterable[str],
    description: str,
) -> Dict[str, Any] | None:
    haystack = " ".join(
        part for part in [name, description] if (part or "").strip()
    ).lower()
    type_set = set(types or [])
    tag_set = set(tags or [])

    if any(keyword in haystack for keyword in OPEN_ALL_DAY_KEYWORDS) or type_set.intersection(
        {"park", "beach", "hiking_area"}
    ) or tag_set.intersection({"lake_river", "beach", "national_park", "waterfall"}):
        return _build_inferred_opening_hours(
            open_now=True,
            weekday_line="24 小時開放",
            note="依景點型態推估為開放式場域，實際仍以現場公告為準",
        )

    if "夜市" in haystack or "night_market" in tag_set:
        return _build_inferred_opening_hours(
            open_now=False,
            weekday_line="17:00–23:00",
            note="依夜市型景點推估，實際仍以現場公告為準",
        )

    if any(keyword in haystack for keyword in DAYTIME_OPEN_KEYWORDS) or type_set.intersection(
        {"museum", "art_gallery", "library"}
    ) or tag_set.intersection({"museum", "creative_park", "heritage"}):
        return _build_inferred_opening_hours(
            open_now=False,
            weekday_line="09:00–17:00",
            note="依景點型態推估為日間開放，實際仍以現場公告為準",
        )

    if type_set.intersection({"tourist_attraction"}) or tag_set:
        return _build_inferred_opening_hours(
            open_now=None,
            weekday_line="依現場公告",
            note="Google 未提供營業時間，先以景點頁面顯示為準",
        )

    return None


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
    if isinstance(raw.get("inferred"), bool):
        out["inferred"] = raw["inferred"]
    note = raw.get("note")
    if isinstance(note, str) and note.strip():
        out["note"] = note.strip()
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
    if _address_quality_score(str(place.get("address") or "")) < 40:
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


def _has_metadata(place: Dict[str, Any]) -> bool:
    return bool((place.get("source") or "").strip()) and bool(
        (place.get("updatedAt") or "").strip()
    )


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
    by_merge_key: Dict[tuple[str, str], Dict[str, Any]] = {}
    for place in existing:
        if not isinstance(place, dict):
            continue
        key = _place_merge_key(
            str(place.get("name") or ""),
            str(place.get("city") or ""),
            str(place.get("address") or ""),
        )
        if key[0]:
            by_merge_key[key] = place
    for place in fresh:
        fresh_dict = place.to_dict()
        target = None
        if place.id in by_id:
            target = by_id[place.id]
        else:
            key = _place_merge_key(place.name, place.city, place.address)
            target = by_merge_key.get(key)

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
            key = _place_merge_key(place.name, place.city, place.address)
            if key[0]:
                by_merge_key[key] = fresh_dict
            stats["added"] += 1
    return existing, stats


def _enrich_place_from_details(place: Dict[str, Any], details: Dict[str, Any]) -> tuple[bool, Dict[str, Any] | None]:
    if not details:
        return False, None

    geometry = (details.get("geometry") or {}).get("location", {})
    lat = float(geometry.get("lat") or 0)
    lng = float(geometry.get("lng") or 0)
    types = details.get("types") or []
    rating = details.get("rating")
    rating_total = details.get("user_ratings_total")
    price_level = details.get("price_level")
    editorial = (details.get("editorial_summary") or {}).get("overview") if details else None
    details_address = details.get("formatted_address") or ""
    existing_address = place.get("address") or ""
    components = details.get("address_components") or []
    base_address = _pick_best_address(details_address, existing_address)
    rebuilt_address = _build_address_from_components(components, base_address)
    city = _normalize_city_name(
        _extract_city_from_components(components)
        or _extract_city(base_address)
        or _extract_city(rebuilt_address)
    )
    full_address = _pick_best_address(base_address, rebuilt_address)
    full_address = _ensure_address_with_city(full_address, city)
    photos = details.get("photos") or []
    photo_ref = ""
    if isinstance(photos, list) and photos:
        photo_ref = photos[0].get("photo_reference", "") if isinstance(photos[0], dict) else ""
    image_url = _photo_url(photo_ref)
    raw_reviews = [r.get("text", "") for r in (details.get("reviews") or []) if isinstance(r, dict)]
    reviews = _clean_reviews(raw_reviews)
    text = f"{place.get('name','')} {full_address} {editorial or ''} {' '.join(reviews)}"
    tags = _extract_tags(text, types)
    merged_tags = _merge_tags(_normalize_tag_list(place.get("tags")), tags)
    opening_hours = _normalize_opening_hours(details.get("opening_hours")) or _infer_opening_hours(
        str(place.get("name") or ""),
        types,
        merged_tags,
        editorial or "",
    )
    price_level_value = int(price_level) if price_level is not None else None
    if price_level_value is None:
        price_level_value = _infer_price_level(
            str(place.get("name") or ""),
            types,
            city,
            full_address,
            editorial or "",
            " ".join(reviews),
        )
    price_category = _price_category(price_level_value)
    changed = False

    if city and _normalize_city_name(str(place.get("city") or "")) != city:
        place["city"] = city
        changed = True
    existing_address = str(place.get("address") or "")
    if full_address and _address_quality_score(full_address) > _address_quality_score(existing_address):
        place["address"] = full_address
        changed = True
    if (not place.get("lat") or not place.get("lng")) and lat and lng:
        place["lat"] = lat
        place["lng"] = lng
        changed = True
    if not place.get("imageUrl") and image_url:
        place["imageUrl"] = image_url
        changed = True
    if place.get("rating") is None and rating is not None:
        place["rating"] = float(rating)
        changed = True
    if place.get("userRatingsTotal") is None and rating_total is not None:
        place["userRatingsTotal"] = int(rating_total)
        changed = True
    if price_level_value is not None and place.get("priceLevel") != price_level_value:
        place["priceLevel"] = price_level_value
        changed = True
    if price_category and place.get("priceCategory") != price_category:
        place["priceCategory"] = price_category
        changed = True
    if not place.get("description") and editorial:
        place["description"] = editorial
        changed = True
    if merged_tags:
        if _normalize_tag_list(place.get("tags")) != merged_tags:
            place["tags"] = merged_tags
            changed = True
        if not place.get("category") and merged_tags[0]:
            place["category"] = merged_tags[0]
            changed = True
    if opening_hours and (
        not place.get("openingHours") or
        len(str(place.get("openingHours"))) < len(str(opening_hours))
    ):
        place["openingHours"] = opening_hours
        changed = True
    if changed or not _has_metadata(place):
        _stamp_metadata(place)

    review_item = {
        "place_id": place.get("id") or details.get("place_id"),
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
    return changed, review_item


def main() -> None:
    if not API_KEY:
        sys.exit("請先在環境變數設定 GOOGLE_MAPS_API_KEY")
    if not DB_PATH.exists():
        sys.exit(f"找不到 {DB_PATH}")

    db = json.loads(DB_PATH.read_text(encoding="utf-8"))
    existing_places = db.get("places") or []
    existing_by_id = {p.get("id"): p for p in existing_places if isinstance(p, dict) and p.get("id")}
    existing_by_merge_key = {}
    for place in existing_places:
        if not isinstance(place, dict):
            continue
        key = _place_merge_key(
            str(place.get("name") or ""),
            str(place.get("city") or ""),
            str(place.get("address") or ""),
        )
        if key[0]:
            existing_by_merge_key[key] = place
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
    skipped_complete = 0
    skipped_outside_city = 0
    selected_city = (os.environ.get("GOOGLE_PLACE_CITY") or "").strip()
    single_city_mode = bool(selected_city)

    print(
        f"抓取設定: scope={QUERY_SCOPE}, max_requests={MAX_REQUESTS}, "
        f"textsearch_pages={TEXTSEARCH_MAX_PAGES}"
    )
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
            details_address = details.get("formatted_address") or ""
            existing_address = place.get("address") or ""
            components = details.get("address_components") or []
            base_address = _pick_best_address(details_address, existing_address)
            rebuilt_address = _build_address_from_components(components, base_address)
            city = _normalize_city_name(
                _extract_city_from_components(components)
                or _extract_city(base_address)
                or _extract_city(rebuilt_address)
            )
            full_address = _pick_best_address(base_address, rebuilt_address)
            full_address = _ensure_address_with_city(full_address, city)
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
            opening_hours = opening_hours or _infer_opening_hours(
                str(place.get("name") or ""),
                types,
                merged_tags,
                editorial or "",
            )
            price_level_value = int(price_level) if price_level is not None else None
            if price_level_value is None:
                price_level_value = _infer_price_level(
                    str(place.get("name") or ""),
                    types,
                    city,
                    full_address,
                    editorial or "",
                    " ".join(reviews),
                )
            price_category = _price_category(price_level_value)
            changed = False

            # Fill only missing fields
            if city and _normalize_city_name(str(place.get("city") or "")) != city:
                place["city"] = city
                changed = True
            existing_address = str(place.get("address") or "")
            if full_address and _address_quality_score(full_address) > _address_quality_score(existing_address):
                place["address"] = full_address
                changed = True
            if (not place.get("lat") or not place.get("lng")) and lat and lng:
                place["lat"] = lat
                place["lng"] = lng
                changed = True
            if not place.get("imageUrl") and image_url:
                place["imageUrl"] = image_url
                changed = True
            if place.get("rating") is None and rating is not None:
                place["rating"] = float(rating)
                changed = True
            if place.get("userRatingsTotal") is None and rating_total is not None:
                place["userRatingsTotal"] = int(rating_total)
                changed = True
            if price_level_value is not None and place.get("priceLevel") != price_level_value:
                place["priceLevel"] = price_level_value
                changed = True
            if price_category and place.get("priceCategory") != price_category:
                place["priceCategory"] = price_category
                changed = True
            if not place.get("description") and editorial:
                place["description"] = editorial
                changed = True
            if merged_tags:
                if _normalize_tag_list(place.get("tags")) != merged_tags:
                    place["tags"] = merged_tags
                    changed = True
                if not place.get("category") and merged_tags[0]:
                    place["category"] = merged_tags[0]
                    changed = True
            if opening_hours and (
                not place.get("openingHours") or
                len(str(place.get("openingHours"))) < len(str(opening_hours))
            ):
                place["openingHours"] = opening_hours
                changed = True
            if changed or not _has_metadata(place):
                _stamp_metadata(place)

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

    for query_idx, query in enumerate(queries):
        if request_count >= MAX_REQUESTS:
            break
        page_no = 0
        page_token: str | None = None
        while request_count < MAX_REQUESTS and page_no < max(1, TEXTSEARCH_MAX_PAGES):
            params: Dict[str, Any]
            token_attempts = 1
            if page_token:
                params = {"pagetoken": page_token, "language": "zh-TW"}
                token_attempts = 4
            else:
                params = {"query": query, "language": "zh-TW"}

            data: Dict[str, Any] = {}
            status = "UNKNOWN"
            for attempt in range(token_attempts):
                if page_token:
                    # next_page_token requires a short propagation delay.
                    time.sleep(2.0 if attempt == 0 else 1.2)
                data = _fetch_json(
                    "https://maps.googleapis.com/maps/api/place/textsearch/json",
                    params,
                )
                request_count += 1
                status = data.get("status") or "UNKNOWN"
                if status == "INVALID_REQUEST" and page_token and attempt < token_attempts - 1:
                    continue
                break

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

                preview_address = item.get("formatted_address") or ""
                preview_city = _normalize_city_name(_extract_city(preview_address))
                merge_key = _place_merge_key(name, preview_city, preview_address)
                existing_hit = existing_by_id.get(place_id) or existing_by_merge_key.get(merge_key)
                if existing_hit and not _needs_enrich(existing_hit):
                    skipped_complete += 1
                    continue

                details = {}
                # Reserve quota for the remaining queries (at least 1 call each query).
                remaining_queries = max(0, len(queries) - query_idx - 1)
                reserve_quota = remaining_queries
                if request_count < MAX_REQUESTS - reserve_quota:
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
                details_address = details.get("formatted_address") or ""
                components = details.get("address_components") or []
                base_address = _pick_best_address(details_address, address)
                rebuilt_address = _build_address_from_components(components, base_address)
                city = _normalize_city_name(
                    _extract_city_from_components(components)
                    or _extract_city(base_address)
                    or _extract_city(rebuilt_address)
                )
                if single_city_mode and not city:
                    city = _normalize_city_name(selected_city)
                full_address = _pick_best_address(base_address, rebuilt_address)
                full_address = _ensure_address_with_city(full_address, city)
                if single_city_mode and not _matches_selected_city(selected_city, city, full_address):
                    skipped_outside_city += 1
                    continue
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
                opening_hours = opening_hours or _infer_opening_hours(
                    name,
                    types,
                    tags,
                    editorial or "",
                )
                price_level_value = int(price_level) if price_level is not None else None
                if price_level_value is None:
                    price_level_value = _infer_price_level(
                        name,
                        types,
                        city,
                        full_address,
                        editorial or "",
                        " ".join(reviews),
                    )
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
                        source="google_places",
                        updatedAt=_utc_now_iso(),
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
            if not page_token or status not in {"OK", "ZERO_RESULTS"}:
                break

        print(
            f"完成查詢: {query}, 分頁 {page_no}/{max(1, TEXTSEARCH_MAX_PAGES)}, "
            f"累積 {len(output)} 筆, 用量 {request_count}/{MAX_REQUESTS}, "
            f"跳過完整資料 {skipped_complete} 筆, 跳過非目標縣市 {skipped_outside_city} 筆"
        )
        time.sleep(SLEEP_BETWEEN)

    # Backfill only the source marker for legacy records.
    # Do not stamp updatedAt here, otherwise "只看剛更新" 會把沒有被這次爬蟲碰到的舊資料
    # 也誤判成剛更新，讓單縣市結果看起來像混進其他縣市。
    for place in existing_places:
        if isinstance(place, dict) and not place.get("source"):
            place["source"] = "google_places"

    merged_places, merge_stats = _merge_places(existing_places, output)

    if single_city_mode and request_count < MAX_REQUESTS:
        enriched_selected_city = 0
        for place in merged_places:
            if request_count >= MAX_REQUESTS:
                break
            if not isinstance(place, dict):
                continue
            if not _matches_selected_city(selected_city, str(place.get("city") or ""), str(place.get("address") or "")):
                continue
            if not _needs_enrich(place):
                continue

            place_id = (place.get("id") or "").strip()
            if not place_id:
                query = _build_query_from_place(place)
                if not query:
                    continue
                place_id = _find_place_id(query) or ""
                request_count += 1
                if not place_id:
                    continue
                place["id"] = place_id

            details = _place_details(place_id) or {}
            if details:
                request_count += 1
            changed, review_item = _enrich_place_from_details(place, details)
            if changed:
                enriched_selected_city += 1
            if review_item:
                reviews_out.append(review_item)
                review_place_id = (review_item.get("place_id") or "").strip()
                if review_place_id:
                    reviews_by_id[review_place_id] = review_item

        if enriched_selected_city:
            print(f"單縣市補完整資料：{selected_city} 額外補齊 {enriched_selected_city} 筆")

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
        f"新增 {merge_stats['added']}／更新 {merge_stats['updated']}／未變更 {merge_stats['unchanged']}，"
        f"查詢中跳過完整資料 {skipped_complete} 筆，"
        f"跳過非目標縣市 {skipped_outside_city} 筆"
    )


if __name__ == "__main__":
    main()
