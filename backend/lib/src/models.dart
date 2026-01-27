import 'dart:convert';

class User {
  User({
    required this.id,
    required this.username,
    required this.email,
    required this.phone,
    required this.passwordHash,
    required this.createdAt,
  });

  final String id;
  final String username;
  final String email;
  final String phone;
  final String passwordHash;
  final DateTime createdAt;

  User copyWith({
    String? username,
    String? email,
    String? phone,
    String? passwordHash,
  }) {
    return User(
      id: id,
      username: username ?? this.username,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      passwordHash: passwordHash ?? this.passwordHash,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'email': email,
      'phone': phone,
      'passwordHash': passwordHash,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  Map<String, dynamic> toPublicJson() {
    return {
      'id': id,
      'username': username,
      'email': email,
      'phone': phone,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String,
      username: json['username'] as String,
      email: (json['email'] as String).toLowerCase(),
      phone: json['phone'] as String,
      passwordHash: json['passwordHash'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}

class BackendData {
  BackendData({List<User>? users, List<Place>? places})
    : users = users ?? <User>[],
      places = places ?? <Place>[];

  final List<User> users;
  final List<Place> places;

  Map<String, dynamic> toJson() {
    return {
      'users': users.map((u) => u.toJson()).toList(),
      'places': places.map((p) => p.toJson()).toList(),
    };
  }

  factory BackendData.fromJson(Map<String, dynamic> json) {
    final rawUsers = json['users'];
    final rawPlaces = json['places'];
    final places = rawPlaces is List
        ? rawPlaces
              .whereType<Map<String, dynamic>>()
              .map(Place.fromJson)
              .toList()
        : <Place>[];
    if (rawUsers is List) {
      return BackendData(
        users: rawUsers
            .whereType<Map<String, dynamic>>()
            .map(User.fromJson)
            .toList(),
        places: places,
      );
    }
    return BackendData(places: places);
  }
}

class Place {
  Place({
    required this.id,
    required this.name,
    required this.tags,
    required this.city,
    required this.address,
    required this.lat,
    required this.lng,
    required this.description,
    required this.imageUrl,
    this.rating,
    this.userRatingsTotal,
  });

  final String id;
  final String name;
  final List<String> tags;
  final String city;
  final String address;
  final double lat;
  final double lng;
  final String description;
  final String imageUrl;
  final double? rating;
  final int? userRatingsTotal;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'tags': tags,
      'city': city,
      'address': address,
      'lat': lat,
      'lng': lng,
      'description': description,
      'imageUrl': imageUrl,
      'rating': rating,
      'userRatingsTotal': userRatingsTotal,
    };
  }

  factory Place.fromJson(Map<String, dynamic> json) {
    final rawTags = json['tags'];
    final tags = rawTags is List
        ? rawTags.whereType<String>().toList()
        : <String>[];
    final fallbackCategory = json['category'] as String?;
    if (tags.isEmpty && fallbackCategory != null && fallbackCategory.isNotEmpty) {
      tags.add(fallbackCategory);
    }
    return Place(
      id: json['id'] as String,
      name: json['name'] as String,
      tags: tags,
      city: json['city'] as String? ?? '',
      address: json['address'] as String? ?? '',
      lat: (json['lat'] as num?)?.toDouble() ?? 0,
      lng: (json['lng'] as num?)?.toDouble() ?? 0,
      description: json['description'] as String? ?? '',
      imageUrl: json['imageUrl'] as String? ?? '',
      rating: (json['rating'] as num?)?.toDouble(),
      userRatingsTotal: (json['userRatingsTotal'] as num?)?.toInt(),
    );
  }
}

String prettyJson(Object value) {
  const encoder = JsonEncoder.withIndent('  ');
  return encoder.convert(value);
}
