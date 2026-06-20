class InterestItem {
  final String id;
  final String label;
  final String imagePath;
  final List<String> matchTags;

  const InterestItem({
    required this.id,
    required this.label,
    required this.imagePath,
    required this.matchTags,
  });
}

class InterestCategory {
  final String title;
  final List<InterestItem> items;

  const InterestCategory({
    required this.title,
    required this.items,
  });
}

const List<InterestCategory> interestCategories = [
  InterestCategory(
    title: '自然景觀',
    items: [
      InterestItem(
        id: 'viewpoint',
        label: '觀景平台',
        imagePath: 'assets/images/national_park.jpg',
        matchTags: ['national_park'],
      ),
      InterestItem(
        id: 'trail',
        label: '森林步道',
        imagePath: 'assets/images/national_park.jpg',
        matchTags: ['national_park'],
      ),
      InterestItem(
        id: 'wetland',
        label: '濕地',
        imagePath: 'assets/images/lake_river.jpg',
        matchTags: ['national_park', 'lake_river'],
      ),
      InterestItem(
        id: 'lake_river',
        label: '湖泊/河岸',
        imagePath: 'assets/images/lake_river.jpg',
        matchTags: ['lake_river'],
      ),
      InterestItem(
        id: 'beach',
        label: '海灘',
        imagePath: 'assets/images/beach.jpg',
        matchTags: ['beach'],
      ),
      InterestItem(
        id: 'hot_spring',
        label: '溫泉',
        imagePath: 'assets/images/hot_spring.jpg',
        matchTags: ['hot_spring'],
      ),
      InterestItem(
        id: 'waterfall',
        label: '瀑布',
        imagePath: 'assets/images/waterfall.jpg',
        matchTags: ['waterfall'],
      ),
      InterestItem(
        id: 'bike_trail',
        label: '單車綠道',
        imagePath: 'assets/images/bike.jpg',
        matchTags: ['bike', 'national_park'],
      ),
    ],
  ),
  InterestCategory(
    title: '文化歷史',
    items: [
      InterestItem(
        id: 'historic_building',
        label: '歷史建築',
        imagePath: 'assets/images/heritage.jpg',
        matchTags: ['heritage'],
      ),
      InterestItem(
        id: 'old_street',
        label: '老街聚落',
        imagePath: 'assets/images/heritage.jpg',
        matchTags: ['heritage', 'street_food'],
      ),
      InterestItem(
        id: 'church_landmark',
        label: '教堂',
        imagePath: 'assets/images/church.jpg',
        matchTags: ['heritage'],
      ),
      InterestItem(
        id: 'temple',
        label: '廟宇',
        imagePath: 'assets/images/temple.jpg',
        matchTags: ['temple', 'heritage'],
      ),
      InterestItem(
        id: 'cultural_district',
        label: '文創街區',
        imagePath: 'assets/images/creative_park.jpg',
        matchTags: ['creative_park', 'heritage'],
      ),
      InterestItem(
        id: 'history_museum',
        label: '歷史博物館',
        imagePath: 'assets/images/museum.jpg',
        matchTags: ['museum', 'heritage'],
      ),
      InterestItem(
        id: 'art_museum',
        label: '藝術展館',
        imagePath: 'assets/images/museum.jpg',
        matchTags: ['museum'],
      ),
      InterestItem(
        id: 'science_museum',
        label: '科學展館',
        imagePath: 'assets/images/museum.jpg',
        matchTags: ['museum'],
      ),
    ],
  ),
  InterestCategory(
    title: '娛樂親子',
    items: [
      InterestItem(
        id: 'aquarium',
        label: '水族館',
        imagePath: 'assets/images/aquarium.jpg',
        matchTags: ['aquarium'],
      ),
      InterestItem(
        id: 'zoo',
        label: '動物園',
        imagePath: 'assets/images/zoo.jpg',
        matchTags: ['zoo'],
      ),
      InterestItem(
        id: 'amusement',
        label: '遊樂設施',
        imagePath: 'assets/images/amusement.jpg',
        matchTags: ['amusement'],
      ),
      InterestItem(
        id: 'concert_hall',
        label: '表演場館',
        imagePath: 'assets/images/concert_hall.jpg',
        matchTags: ['concert_hall'],
      ),
      InterestItem(
        id: 'cinema',
        label: '電影院',
        imagePath: 'assets/images/cinema.jpg',
        matchTags: ['cinema'],
      ),
      InterestItem(
        id: 'night_market',
        label: '夜市',
        imagePath: 'assets/images/night_market.jpg',
        matchTags: ['night_market', 'street_food'],
      ),
    ],
  ),
  InterestCategory(
    title: '美食購物',
    items: [
      InterestItem(
        id: 'local_food',
        label: '在地小吃',
        imagePath: 'assets/images/street_food.jpg',
        matchTags: ['street_food', 'restaurant'],
      ),
      InterestItem(
        id: 'dessert_shop',
        label: '甜點咖啡',
        imagePath: 'assets/images/cafe.jpg',
        matchTags: ['cafe', 'restaurant'],
      ),
      InterestItem(
        id: 'shopping_mall',
        label: '百貨商場',
        imagePath: 'assets/images/department_store.jpg',
        matchTags: ['department_store'],
      ),
      InterestItem(
        id: 'outlet',
        label: 'Outlet',
        imagePath: 'assets/images/department_store.jpg',
        matchTags: ['department_store'],
      ),
      InterestItem(
        id: 'business_district',
        label: '商圈散策',
        imagePath: 'assets/images/department_store.jpg',
        matchTags: ['department_store', 'cafe', 'restaurant'],
      ),
      InterestItem(
        id: 'handcraft_shop',
        label: '手作選物',
        imagePath: 'assets/images/handcraft_shop.jpg',
        matchTags: ['handcraft_shop', 'creative_park'],
      ),
    ],
  ),
  InterestCategory(
    title: '戶外活動',
    items: [
      InterestItem(
        id: 'farm',
        label: '農場體驗',
        imagePath: 'assets/images/farm.jpg',
        matchTags: ['farm'],
      ),
      InterestItem(
        id: 'camping',
        label: '露營',
        imagePath: 'assets/images/camping.jpg',
        matchTags: ['camping'],
      ),
      InterestItem(
        id: 'water_sport',
        label: '水上活動',
        imagePath: 'assets/images/water_sport.jpg',
        matchTags: ['water_sport'],
      ),
      InterestItem(
        id: 'ball_sport',
        label: '球類運動',
        imagePath: 'assets/images/ball_sport.jpg',
        matchTags: ['ball_sport'],
      ),
    ],
  ),
];

final Map<String, InterestItem> interestItemsById = {
  for (final category in interestCategories)
    for (final item in category.items) item.id: item,
};

const Map<String, String> _legacyInterestFallbacks = {
  'national_park': 'viewpoint',
  'heritage': 'historic_building',
  'museum': 'history_museum',
  'creative_park': 'cultural_district',
  'street_food': 'local_food',
  'department_store': 'shopping_mall',
  'restaurant': 'local_food',
  'cafe': 'dessert_shop',
  'bike': 'bike_trail',
  'church': 'church_landmark',
};

List<String> normalizeInterestSelectionIds(Iterable<String> rawIds) {
  final normalized = <String>{};
  for (final rawId in rawIds) {
    final id = rawId.trim();
    if (id.isEmpty) continue;
    if (interestItemsById.containsKey(id)) {
      normalized.add(id);
      continue;
    }
    final mapped = _legacyInterestFallbacks[id];
    if (mapped != null && interestItemsById.containsKey(mapped)) {
      normalized.add(mapped);
    }
  }
  return normalized.toList()..sort();
}

List<String> expandInterestIdsToMatchTags(Iterable<String> rawIds) {
  final expanded = <String>{};
  for (final rawId in rawIds) {
    final id = rawId.trim();
    if (id.isEmpty) continue;
    final item = interestItemsById[id];
    if (item != null) {
      expanded.addAll(item.matchTags.map((tag) => tag.toLowerCase().trim()));
      continue;
    }
    expanded.add(id.toLowerCase());
  }
  return expanded.toList()..sort();
}
