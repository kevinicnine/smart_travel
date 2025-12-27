class InterestItem {
  final String id;
  final String label;
  final String imagePath;
  const InterestItem({
    required this.id,
    required this.label,
    required this.imagePath,
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
        id: 'national_park',
        label: '國家公園',
        imagePath: 'assets/images/national_park.jpg',
      ),
      InterestItem(
        id: 'lake_river',
        label: '湖泊/河川',
        imagePath: 'assets/images/lake_river.jpg',
      ),
      InterestItem(
        id: 'beach',
        label: '海灘',
        imagePath: 'assets/images/beach.jpg',
      ),
      InterestItem(
        id: 'hot_spring',
        label: '溫泉',
        imagePath: 'assets/images/hot_spring.jpg',
      ),
      InterestItem(
        id: 'waterfall',
        label: '瀑布',
        imagePath: 'assets/images/waterfall.jpg',
      ),
    ],
  ),
  InterestCategory(
    title: '文化歷史',
    items: [
      InterestItem(
        id: 'heritage',
        label: '古蹟',
        imagePath: 'assets/images/heritage.jpg',
      ),
      InterestItem(
        id: 'temple',
        label: '廟宇',
        imagePath: 'assets/images/temple.jpg',
      ),
      InterestItem(
        id: 'church',
        label: '教堂',
        imagePath: 'assets/images/church.jpg',
      ),
      InterestItem(
        id: 'creative_park',
        label: '文創園區',
        imagePath: 'assets/images/creative_park.jpg',
      ),
      InterestItem(
        id: 'museum',
        label: '博物館',
        imagePath: 'assets/images/museum.jpg',
      ),
    ],
  ),
  InterestCategory(
    title: '娛樂活動',
    items: [
      InterestItem(
        id: 'aquarium',
        label: '水族館',
        imagePath: 'assets/images/aquarium.jpg',
      ),
      InterestItem(
        id: 'concert_hall',
        label: '音樂廳',
        imagePath: 'assets/images/concert_hall.jpg',
      ),
      InterestItem(
        id: 'cinema',
        label: '電影院',
        imagePath: 'assets/images/cinema.jpg',
      ),
      InterestItem(
        id: 'amusement',
        label: '遊樂園',
        imagePath: 'assets/images/amusement.jpg',
      ),
      InterestItem(
        id: 'night_market',
        label: '夜市',
        imagePath: 'assets/images/night_market.jpg',
      ),
      InterestItem(
        id: 'zoo',
        label: '動物園',
        imagePath: 'assets/images/zoo.jpg',
      ),
    ],
  ),
  InterestCategory(
    title: '美食購物',
    items: [
      InterestItem(
        id: 'street_food',
        label: '路邊攤',
        imagePath: 'assets/images/street_food.jpg',
      ),
      InterestItem(
        id: 'department_store',
        label: '百貨公司',
        imagePath: 'assets/images/department_store.jpg',
      ),
      InterestItem(
        id: 'handcraft_shop',
        label: '手工藝品店',
        imagePath: 'assets/images/handcraft_shop.jpg',
      ),
      InterestItem(
        id: 'restaurant',
        label: '餐廳',
        imagePath: 'assets/images/restaurant.jpg',
      ),
      InterestItem(
        id: 'cafe',
        label: '咖啡廳',
        imagePath: 'assets/images/cafe.jpg',
      ),
    ],
  ),
  InterestCategory(
    title: '戶外運動',
    items: [
      InterestItem(
        id: 'farm',
        label: '農場',
        imagePath: 'assets/images/farm.jpg',
      ),
      InterestItem(
        id: 'camping',
        label: '露營',
        imagePath: 'assets/images/camping.jpg',
      ),
      InterestItem(
        id: 'bike',
        label: '自行車',
        imagePath: 'assets/images/bike.jpg',
      ),
      InterestItem(
        id: 'water_sport',
        label: '水上運動',
        imagePath: 'assets/images/water_sport.jpg',
      ),
      InterestItem(
        id: 'ball_sport',
        label: '球類運動',
        imagePath: 'assets/images/ball_sport.jpg',
      ),
    ],
  ),
];

final Map<String, InterestItem> interestItemsById = {
  for (final category in interestCategories)
    for (final item in category.items) item.id: item,
};
