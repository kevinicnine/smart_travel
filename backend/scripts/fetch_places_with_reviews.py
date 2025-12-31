"""
Fetch Google Places details (with reviews) for existing places in db.json,
to build training text for classification. Includes a simple quota guard
so it stops near your daily free quota.

Usage:
  GOOGLE_MAPS_API_KEY=your_key python3 backend/scripts/fetch_places_with_reviews.py

Outputs:
  backend/data/places_with_reviews.json  (list of dicts with name/address/geometry/reviews/category/tags)

Notes:
  - Uses Text Search to find place_id by name+city, then Place Details to fetch fields:
    name, formatted_address, geometry, editorial_summary, reviews, rating, user_ratings_total, types
  - Extracts tags from name/summary/reviews/types with keyword rules (multi-label).
  - Uses a local text classifier to filter low-signal reviews when enough data is available.
  - MAX_REQUESTS limits total HTTP calls (search + details each算一次) to avoid超額。
  - 遇到 OVER_QUERY_LIMIT/429 會立即停止。
"""
from __future__ import annotations

import json
import os
import ssl
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Dict, Any, List

ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "data" / "db.json"
OUT_PATH = ROOT / "data" / "places_with_reviews.json"
API_KEY = os.environ.get("GOOGLE_MAPS_API_KEY")

MAX_REQUESTS = 300  # 總請求數上限（search+details 都算）
SLEEP_BETWEEN = 0.1  # 秒，避免過快
REVIEWS_LIMIT = 5  # 只保留最相關的前幾則評論
MIN_REVIEW_LEN = 12  # 評論最少字數
MIN_MODEL_PROB = 0.55  # 模型判斷為「有效評論」的門檻
USE_LOCAL_MODEL = True
MERGE_TO_DB = True  # 抓完後直接合併 tags 回 db.json

NOISE_HINTS = [
    "哈哈",
    "呵呵",
    "👍",
    "讚",
    "推",
    "推推",
    "好讚",
    "超讚",
    "很棒",
    "不錯",
]
INFO_HINTS = [
    "交通",
    "停車",
    "導覽",
    "展覽",
    "門票",
    "票價",
    "環境",
    "服務",
    "親子",
    "步道",
    "景色",
    "風景",
    "餐廳",
    "咖啡",
    "人潮",
    "排隊",
    "廁所",
    "推薦",
    "地址",
    "捷運",
    "公車",
]
FIELDS = ",".join(
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
)

if not API_KEY:
    sys.exit("請先在環境變數設定 GOOGLE_MAPS_API_KEY")


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


def extract_tags(text: str, types: list[str], fallback: str) -> list[str]:
    tags = set()
    if fallback:
        tags.add(fallback)
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


def _label_review(text: str) -> int | None:
    if len(text) < MIN_REVIEW_LEN:
        return 0
    if any(term in text for term in NOISE_HINTS) and len(text) < 30:
        return 0
    if any(term in text for term in INFO_HINTS):
        return 1
    return None


def _train_review_model(texts: list[str]):
    try:
        from sklearn.feature_extraction.text import TfidfVectorizer
        from sklearn.linear_model import LogisticRegression
        from sklearn.pipeline import make_pipeline
    except Exception as exc:
        print("sklearn not available, skip model filtering:", exc)
        return None

    labels = []
    labeled_texts = []
    for t in texts:
        label = _label_review(t)
        if label is None:
            continue
        labeled_texts.append(t)
        labels.append(label)

    if len(set(labels)) < 2 or len(labels) < 80:
        print("Not enough labeled reviews for model; skip model filtering.")
        return None

    model = make_pipeline(
        TfidfVectorizer(max_features=8000),
        LogisticRegression(max_iter=1000),
    )
    model.fit(labeled_texts, labels)
    print("Trained local review filter on", len(labels), "samples.")
    return model


def clean_reviews(reviews: list[str], model=None) -> list[str]:
    seen = set()
    cleaned: list[str] = []
    for raw in reviews:
        text = (raw or "").strip()
        if len(text) < MIN_REVIEW_LEN:
            continue
        if text in seen:
            continue
        if model is not None:
            try:
                score = model.predict_proba([text])[0][1]
                if score < MIN_MODEL_PROB:
                    continue
            except Exception:
                pass
        seen.add(text)
        cleaned.append(text)
    return cleaned

def fetch_json(url: str, params: Dict[str, Any]) -> Dict[str, Any]:
    global request_count
    if request_count >= MAX_REQUESTS:
        raise RuntimeError("已達 MAX_REQUESTS，停止以避免超額")
    params["key"] = API_KEY
    qs = urllib.parse.urlencode(params, safe=",")
    full_url = f"{url}?{qs}"
    req = urllib.request.Request(full_url, headers={"User-Agent": "smart-travel/1.0"})
    with urllib.request.urlopen(req, timeout=20, context=_ssl_context()) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    request_count += 1
    if data.get("status") in {"OVER_QUERY_LIMIT", "RESOURCE_EXHAUSTED"}:
        raise RuntimeError("OVER_QUERY_LIMIT/RESOURCE_EXHAUSTED，已停止")
    return data


def _ssl_context() -> ssl.SSLContext:
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


def text_search(query: str) -> str | None:
    data = fetch_json(
        "https://maps.googleapis.com/maps/api/place/textsearch/json",
        {"query": query, "language": "zh-TW"},
    )
    results = data.get("results") or []
    if not results:
        return None
    return results[0].get("place_id")


def place_details(place_id: str) -> Dict[str, Any] | None:
    data = fetch_json(
        "https://maps.googleapis.com/maps/api/place/details/json",
        {
            "place_id": place_id,
            "language": "zh-TW",
            "reviews_sort": "most_relevant",
            "fields": FIELDS,
        },
    )
    if data.get("status") != "OK":
        return None
    return data.get("result") or {}


def main():
    global request_count
    request_count = 0

    if not DB_PATH.exists():
        sys.exit(f"找不到 {DB_PATH}")
    db = json.loads(DB_PATH.read_text(encoding="utf-8"))
    places = db.get("places") or []
    output: List[Dict[str, Any]] = []
    review_pool: List[str] = []
    staged: List[Dict[str, Any]] = []

    for idx, p in enumerate(places):
        name = p.get("name") or ""
        city = p.get("city") or ""
        category = p.get("category") or "other"
        tags = p.get("tags")
        if not isinstance(tags, list):
            tags = [category]
        if not name:
            continue

        query = f"{name} {city}".strip()
        try:
            pid = text_search(query)
        except RuntimeError as e:
            print(f"[STOP] {e}")
            break
        except Exception as e:
            print(f"[WARN] search失敗: {name} ({e})")
            continue

        if not pid:
            print(f"[SKIP] 找不到 place_id: {name}")
            continue

        time.sleep(SLEEP_BETWEEN)
        try:
            detail = place_details(pid)
        except RuntimeError as e:
            print(f"[STOP] {e}")
            break
        except Exception as e:
            print(f"[WARN] details失敗: {name} ({e})")
            continue

        if not detail:
            print(f"[SKIP] details 無資料: {name}")
            continue

        reviews = detail.get("reviews") or []
        raw_reviews = [r.get("text", "") for r in reviews]
        review_pool.extend(raw_reviews)
        staged.append(
            {
                "source_name": name,
                "category": category,
                "place_id": pid,
                "name": detail.get("name", ""),
                "address": detail.get("formatted_address", ""),
                "lat": detail.get("geometry", {}).get("location", {}).get("lat"),
                "lng": detail.get("geometry", {}).get("location", {}).get("lng"),
                "rating": detail.get("rating"),
                "user_ratings_total": detail.get("user_ratings_total"),
                "types": detail.get("types") or [],
                "editorial_summary": (detail.get("editorial_summary") or {}).get("overview", ""),
                "raw_reviews": raw_reviews,
            }
        )

        if (idx + 1) % 20 == 0:
            print(f"進度 {idx+1}/{len(places)}, 用量 {request_count}/{MAX_REQUESTS}")
        time.sleep(SLEEP_BETWEEN)

        if request_count >= MAX_REQUESTS:
            print("已達 MAX_REQUESTS，提前結束。")
            break

    model = _train_review_model(review_pool) if USE_LOCAL_MODEL else None
    for item in staged:
        reviews_texts = clean_reviews(item.pop("raw_reviews"), model)[:REVIEWS_LIMIT]
        editorial = item.get("editorial_summary") or ""
        types = item.get("types") or []
        text_blob = " ".join([item.get("source_name", ""), editorial, " ".join(reviews_texts)])
        tags = extract_tags(text_blob, types, item.get("category") or "other")
        item["tags"] = tags
        item["reviews"] = reviews_texts
        output.append(item)

    OUT_PATH.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"完成，寫入 {OUT_PATH}, 總筆數 {len(output)}, API 請求 {request_count}")
    if MERGE_TO_DB:
        merge_into_db(output)


def merge_into_db(reviews: list[Dict[str, Any]]) -> None:
    db = json.loads(DB_PATH.read_text(encoding="utf-8"))
    places = db.get("places") or []
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
    print(f"已合併 tags 回 db.json: {updated} 筆")


if __name__ == "__main__":
    main()
