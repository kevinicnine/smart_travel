"""
Train a lightweight itinerary ranking profile from historical itineraries.

This script does not train a generative model. It learns preference weights
that can be loaded by backend/bin/server.dart and applied as an additive boost
inside the existing rule-based itinerary scoring pipeline.

Usage:
  python3 backend/scripts/train_itinerary_ranker.py

Optional env:
  HISTORICAL_ITINERARIES_PATH=backend/data/historical_itineraries.json
  PLACES_DB_PATH=backend/data/db.json
  OUTPUT_PATH=backend/data/itinerary_ranker_weights.json
"""
from __future__ import annotations

import json
import math
import os
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
HISTORICAL_PATH = Path(
    os.environ.get(
        "HISTORICAL_ITINERARIES_PATH",
        str(ROOT / "data" / "historical_itineraries.json"),
    )
)
PLACES_DB_PATH = Path(
    os.environ.get("PLACES_DB_PATH", str(ROOT / "data" / "db.json"))
)
OUTPUT_PATH = Path(
    os.environ.get(
        "OUTPUT_PATH",
        str(ROOT / "data" / "itinerary_ranker_weights.json"),
    )
)


def _load_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise FileNotFoundError(f"找不到檔案：{path}")
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise ValueError(f"JSON 根節點必須是 object: {path}")
    return raw


def _normalize_trip_purpose(value: Any) -> str:
    raw = str(value or "").strip().lower()
    return {
        "relax": "relax",
        "休閒放鬆": "relax",
        "explore": "explore",
        "景點探索": "explore",
        "couple": "couple",
        "情侶約會": "couple",
        "family": "family",
        "家庭旅遊": "family",
    }.get(raw, "explore")


def _normalize_travel_behavior(value: Any) -> str:
    raw = str(value or "").strip().lower()
    return {
        "family": "family",
        "家庭": "family",
        "couple": "couple",
        "情侶": "couple",
        "solo": "solo",
        "獨旅": "solo",
    }.get(raw, "general")


def _normalize_price(value: Any) -> str | None:
    raw = str(value or "").strip().lower()
    if not raw:
        return None
    if raw in {"free", "免費"}:
        return "free"
    if raw in {"low", "$", "平價"}:
        return "low"
    if raw in {"mid", "$$", "中價"}:
        return "mid"
    if raw in {"high", "$$$", "高價"}:
        return "high"
    return None


def _effective_price_category(place: dict[str, Any]) -> str | None:
    category = _normalize_price(place.get("priceCategory"))
    if category:
        return category
    level = place.get("priceLevel")
    if isinstance(level, (int, float)):
        if level <= 0:
            return "free"
        if level <= 1:
            return "low"
        if level == 2:
            return "mid"
        return "high"
    return None


def _string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [
        str(item).strip()
        for item in value
        if str(item).strip()
    ]


def _load_places() -> dict[str, dict[str, Any]]:
    data = _load_json(PLACES_DB_PATH)
    places = data.get("places")
    if not isinstance(places, list):
        raise ValueError("db.json 缺少 places 陣列")
    by_id: dict[str, dict[str, Any]] = {}
    for item in places:
        if not isinstance(item, dict):
            continue
        place_id = str(item.get("id") or "").strip()
        if not place_id:
            continue
        by_id[place_id] = item
    return by_id


def _iter_selected_place_ids(sample: dict[str, Any]) -> list[str]:
    ids: list[str] = []
    days = sample.get("days")
    if not isinstance(days, list):
        return ids
    for day in days:
        if not isinstance(day, dict):
            continue
        items = day.get("items")
        if not isinstance(items, list):
            continue
        for item in items:
            if not isinstance(item, dict):
                continue
            place_id = (
                item.get("placeId")
                or item.get("place_id")
                or item.get("id")
            )
            place_id = str(place_id or "").strip()
            if place_id:
                ids.append(place_id)
    return ids


def _context_from_sample(sample: dict[str, Any]) -> dict[str, Any]:
    context = sample.get("context")
    if not isinstance(context, dict):
        context = {}
    return {
        "interests": [item.lower() for item in _string_list(context.get("interests"))],
        "tripPurpose": _normalize_trip_purpose(context.get("tripPurpose")),
        "travelBehavior": _normalize_travel_behavior(context.get("travelBehavior")),
        "targetPrice": _normalize_price(context.get("targetPrice")),
        "weight": float(context.get("weight") or sample.get("weight") or 1.0),
    }


def _log_odds_weight(
    bucket_count: float,
    bucket_total: float,
    global_count: float,
    global_total: float,
    option_count: int,
    alpha: float = 1.0,
) -> float:
    p_bucket = (bucket_count + alpha) / (bucket_total + alpha * option_count)
    p_global = (global_count + alpha) / (global_total + alpha * option_count)
    return math.log(p_bucket / p_global)


def _normalize_counter(counter: Counter[str], scale: float = 0.4) -> dict[str, float]:
    if not counter:
        return {}
    total = sum(counter.values())
    option_count = len(counter)
    uniform = 1.0 / option_count
    output: dict[str, float] = {}
    for key, count in counter.items():
        probability = count / total
        output[key] = round(math.log(probability / uniform) * scale, 4)
    return output


def _build_affinity_map(
    buckets: dict[str, Counter[str]],
    global_counter: Counter[str],
    scale: float = 1.0,
) -> dict[str, dict[str, float]]:
    if not global_counter:
        return {}
    global_total = sum(global_counter.values())
    option_count = len(global_counter)
    output: dict[str, dict[str, float]] = {}
    for bucket_key, counter in buckets.items():
        bucket_total = sum(counter.values())
        if bucket_total <= 0:
            continue
        affinities: dict[str, float] = {}
        for option in global_counter:
            weight = _log_odds_weight(
                counter.get(option, 0.0),
                bucket_total,
                global_counter.get(option, 0.0),
                global_total,
                option_count,
            )
            if abs(weight) >= 0.08:
                affinities[option] = round(weight * scale, 4)
        if affinities:
            output[bucket_key] = affinities
    return output


def main() -> None:
    places_by_id = _load_places()
    historical = _load_json(HISTORICAL_PATH)
    samples = historical.get("samples")
    if not isinstance(samples, list):
        raise ValueError("historical_itineraries.json 缺少 samples 陣列")

    global_tag_counter: Counter[str] = Counter()
    global_price_counter: Counter[str] = Counter()
    interest_tag_buckets: dict[str, Counter[str]] = defaultdict(Counter)
    purpose_tag_buckets: dict[str, Counter[str]] = defaultdict(Counter)
    behavior_tag_buckets: dict[str, Counter[str]] = defaultdict(Counter)
    price_affinity_buckets: dict[str, Counter[str]] = defaultdict(Counter)

    used_samples = 0
    used_stops = 0
    skipped_place_refs = 0

    for sample in samples:
        if not isinstance(sample, dict):
            continue
        context = _context_from_sample(sample)
        place_ids = _iter_selected_place_ids(sample)
        if not place_ids:
            continue
        sample_used = False
        sample_weight = max(0.25, float(context["weight"]))
        for place_id in place_ids:
            place = places_by_id.get(place_id)
            if not place:
                skipped_place_refs += 1
                continue
            tags = [tag.strip().lower() for tag in _string_list(place.get("tags")) if tag.strip()]
            if not tags:
                continue
            sample_used = True
            used_stops += 1
            for tag in tags:
                global_tag_counter[tag] += sample_weight
                purpose_tag_buckets[context["tripPurpose"]][tag] += sample_weight
                behavior_tag_buckets[context["travelBehavior"]][tag] += sample_weight
                for interest in context["interests"]:
                    interest_tag_buckets[interest][tag] += sample_weight
            price_category = _effective_price_category(place)
            if price_category:
                global_price_counter[price_category] += sample_weight
                target_price = context["targetPrice"]
                if target_price:
                    price_affinity_buckets[target_price][price_category] += sample_weight
        if sample_used:
            used_samples += 1

    output = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "metadata": {
            "source": str(HISTORICAL_PATH),
            "samplesSeen": len(samples),
            "samplesUsed": used_samples,
            "stopsUsed": used_stops,
            "skippedPlaceRefs": skipped_place_refs,
        },
        "globalTagWeights": _normalize_counter(global_tag_counter, scale=0.25),
        "interestTagWeights": _build_affinity_map(
            interest_tag_buckets,
            global_tag_counter,
            scale=0.85,
        ),
        "tripPurposeTagWeights": _build_affinity_map(
            purpose_tag_buckets,
            global_tag_counter,
            scale=0.95,
        ),
        "travelBehaviorTagWeights": _build_affinity_map(
            behavior_tag_buckets,
            global_tag_counter,
            scale=0.75,
        ),
        "priceAffinity": _build_affinity_map(
            price_affinity_buckets,
            global_price_counter,
            scale=0.90,
        ),
    }

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(
        json.dumps(output, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(
        f"已輸出行程排序學習權重：{OUTPUT_PATH} "
        f"(samples_used={used_samples}, stops_used={used_stops}, skipped_place_refs={skipped_place_refs})"
    )


if __name__ == "__main__":
    main()
