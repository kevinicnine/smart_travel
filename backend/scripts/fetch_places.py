"""
Fetch Taiwan scenic spots open data, align to app interest categories,
optionally train a simple text classifier (if scikit-learn is installed),
then write results into backend/data/db.json (preserving existing users).

Usage:
  python backend/scripts/fetch_places.py

Notes:
- Uses交通部觀光局景點開放資料 (scenic_spot_C_f.json)。
- If scikit-learn is available, a TF-IDF + LinearSVC will be trained on
  keyword-labelled samples, otherwise only keyword rules are used.
"""
from __future__ import annotations

import json
import sys
import ssl
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

DATA_URL = "https://media.taiwan.net.tw/XMLReleaseALL_public/scenic_spot_C_f.json"
ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "data" / "db.json"
REVIEWED_PATH = ROOT / "data" / "places_reviewed.json"
MAX_ITEMS = 1200  # how many to pull from source before filtering/uniq
KEEP_COUNT = 300  # how many valid places to save


# App interest categories (id -> keywords for mapping)
INTEREST_KEYWORDS: List[tuple[str, str]] = [
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
]


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

    def to_dict(self) -> Dict:
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
        }


def fetch_raw() -> List[Dict]:
    print(f"Downloading {DATA_URL} ...")
    with urllib.request.urlopen(DATA_URL, timeout=30, context=_ssl_context()) as resp:
        text = resp.read()
    data = json.loads(text.decode("utf-8-sig"))
    items = data["XML_Head"]["Infos"]["Info"]
    print("Fetched items:", len(items))
    return items


def _ssl_context() -> ssl.SSLContext:
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


def keyword_classify(txt: str) -> str:
    # temple special-case first (avoid company)
    for kw in ["廟", "寺", "宮"]:
        if kw in txt and "公司" not in txt:
            return "temple"
    for kw, cid in INTEREST_KEYWORDS:
        if kw in txt:
            return cid
    return "other"


def build_places(raw: List[Dict]) -> List[Place]:
    seen = set()
    places: List[Place] = []
    for info in raw[:MAX_ITEMS]:
        name = info.get("Name")
        if not name or name in seen:
            continue
        lat = float(info.get("Py") or 0)
        lng = float(info.get("Px") or 0)
        if lat == 0 and lng == 0:
            continue
        seen.add(name)
        desc = (info.get("Toldescribe") or "").strip()
        class1 = info.get("Class1") or ""
        class2 = info.get("Class2") or ""
        txt = " ".join(filter(None, [name, desc, class1, class2]))
        cat = keyword_classify(txt)
        places.append(
            Place(
                id=info.get("Id") or name,
                name=name,
                category=cat,
                tags=[cat],
                city=info.get("Region") or info.get("City") or "",
                address=info.get("Add") or "",
                lat=lat,
                lng=lng,
                description=desc,
                imageUrl=info.get("Picture1") or "",
            )
        )
        if len(places) >= KEEP_COUNT:
            break
    print("Kept places:", len(places))
    return places


def train_and_refine(places: List[Place]) -> None:
    """Optional: if scikit-learn is installed, train a simple text classifier to refine 'other'."""
    try:
        from sklearn.feature_extraction.text import TfidfVectorizer
        from sklearn.pipeline import make_pipeline
        from sklearn.svm import LinearSVC
    except Exception as exc:
        print("sklearn not available, skip model refinement:", exc)
        return

    texts = []
    labels = []
    for p in places:
        if p.category != "other":
            texts.append(f"{p.name} {p.description}")
            labels.append(p.category)
    if len(set(labels)) < 2:
        print("Not enough labelled data for training; skipping model.")
        return

    model = make_pipeline(TfidfVectorizer(max_features=8000), LinearSVC())
    model.fit(texts, labels)
    print("Trained classifier on", len(texts), "samples.")

    # predict for 'other'
    updated = 0
    for p in places:
        if p.category == "other":
            pred = model.predict([f"{p.name} {p.description}"])[0]
            p.category = pred
            updated += 1
        if not p.tags:
            p.tags = [p.category]
        elif p.category not in p.tags:
            p.tags.append(p.category)
    print("Refined 'other' categories via model:", updated)


def write_db(places: List[Place]) -> None:
    db = {}
    if DB_PATH.exists():
        db = json.loads(DB_PATH.read_text(encoding="utf-8"))
    # merge reviewed overrides
    overrides = {}
    if REVIEWED_PATH.exists():
        try:
            overrides = json.loads(REVIEWED_PATH.read_text(encoding="utf-8"))
        except Exception:
            overrides = {}
    if overrides:
        for p in places:
            if p.name in overrides:
                override = overrides[p.name]
                if isinstance(override, list):
                    p.tags = [t for t in override if isinstance(t, str) and t.strip()]
                    p.category = p.tags[0] if p.tags else "other"
                elif isinstance(override, str):
                    p.category = override
                    p.tags = [override]
                else:
                    p.tags = p.tags or [p.category] if p.category else ["other"]
    # save reviewed for future runs (append new names, keep old)
    merged_overrides = overrides.copy()
    for p in places:
        merged_overrides.setdefault(p.name, p.tags or [p.category])
    REVIEWED_PATH.write_text(json.dumps(merged_overrides, ensure_ascii=False, indent=2), encoding="utf-8")
    db["places"] = [p.to_dict() for p in places]
    DB_PATH.write_text(json.dumps(db, ensure_ascii=False, indent=2), encoding="utf-8")
    print("Wrote places to", DB_PATH)
    print("Reviewed overrides saved to", REVIEWED_PATH)


def main():
    raw = fetch_raw()
    places = build_places(raw)
    train_and_refine(places)
    write_db(places)


if __name__ == "__main__":
    main()
