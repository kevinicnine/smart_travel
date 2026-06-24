import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class BackendApi {
  BackendApi._internal()
    : baseUrl = const String.fromEnvironment(
        'SMART_TRAVEL_API_BASE',
        defaultValue: 'https://smart-travel-backend-6ant.onrender.com',
      );

  static final BackendApi instance = BackendApi._internal();

  final String baseUrl;

  String resolveImageUrl(String imageUrl, {String? placeId}) {
    final normalizedPlaceId = placeId?.trim() ?? '';
    String buildPhotoProxyUrl({
      String? photoReference,
      String maxWidth = '800',
    }) {
      return Uri.parse(baseUrl)
          .replace(
            path: '/api/place-photo',
            queryParameters: {
              if (normalizedPlaceId.isNotEmpty) 'place_id': normalizedPlaceId,
              if (photoReference != null && photoReference.isNotEmpty)
                'photo_reference': photoReference,
              'maxwidth': maxWidth,
            },
          )
          .toString();
    }

    final trimmed = imageUrl.trim();
    if (trimmed.isEmpty) {
      return normalizedPlaceId.isEmpty ? '' : buildPhotoProxyUrl();
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null) {
      return normalizedPlaceId.isEmpty
          ? trimmed
          : buildPhotoProxyUrl(photoReference: trimmed);
    }
    if (!uri.hasScheme && uri.path == '/api/place-photo') {
      return Uri.parse(baseUrl)
          .replace(path: uri.path, queryParameters: uri.queryParameters)
          .toString();
    }
    if (!uri.hasScheme) {
      return normalizedPlaceId.isEmpty
          ? trimmed
          : buildPhotoProxyUrl(photoReference: trimmed);
    }

    final isGooglePhoto =
        uri.host == 'maps.googleapis.com' &&
        uri.path == '/maps/api/place/photo';
    final photoReference = uri.queryParameters['photo_reference'];
    if (!isGooglePhoto || photoReference == null || photoReference.isEmpty) {
      return trimmed;
    }

    final maxWidth = uri.queryParameters['maxwidth'] ?? '800';
    return buildPhotoProxyUrl(
      photoReference: photoReference,
      maxWidth: maxWidth,
    );
  }

  Future<Map<String, dynamic>> sendEmailCode(String email) async {
    final response = await _post('/api/auth/send-email-code', {'email': email});
    return _extractData(response);
  }

  Future<void> verifyEmailCode({
    required String email,
    required String code,
  }) async {
    await _post('/api/auth/verify-email-code', {'email': email, 'code': code});
  }

  Future<Map<String, dynamic>> sendSmsCode(String phone) async {
    final response = await _post('/api/auth/send-sms-code', {'phone': phone});
    return _extractData(response);
  }

  Future<void> verifySmsCode({
    required String phone,
    required String code,
  }) async {
    await _post('/api/auth/verify-sms-code', {'phone': phone, 'code': code});
  }

  Future<Map<String, dynamic>> register({
    required String username,
    required String email,
    String? phone,
    required String password,
  }) async {
    final response = await _post('/api/auth/register', {
      'username': username,
      'email': email,
      'phone': phone ?? '',
      'password': password,
    });
    return _extractUser(response);
  }

  Future<Map<String, dynamic>> login({
    required String account,
    required String password,
  }) async {
    final response = await _post('/api/auth/login', {
      'account': account,
      'password': password,
    });
    return _extractUser(response);
  }

  Future<Map<String, dynamic>> createLineLinkCode({
    required String userId,
  }) async {
    final response = await _post('/api/line/link-code', {'userId': userId});
    return _extractData(response);
  }

  Future<Map<String, dynamic>> fetchLineLinkStatus({
    required String userId,
  }) async {
    final response = await _post('/api/line/link-status', {'userId': userId});
    return _extractData(response);
  }

  Future<void> sendLinePushTest({required String userId}) async {
    await _post('/api/line/push-test', {'userId': userId});
  }

  Future<void> submitInterests(
    List<String> interestIds, {
    String? userId,
  }) async {
    final payload = <String, dynamic>{'interests': interestIds};
    if (userId != null && userId.trim().isNotEmpty) {
      payload['userId'] = userId.trim();
    }
    await _post('/api/travel/preferences', payload);
  }

  Future<Map<String, dynamic>> generateItinerary({
    required List<String> interestIds,
    String? userId,
    DateTime? startDate,
    DateTime? endDate,
    String? originCity,
    List<String>? destinationCities,
    String? requirementsText,
    String? tripPurpose,
    String? travelBehavior,
    String? location,
    int? people,
    int? budget,
    Map<String, dynamic>? backpackerAnswers,
    String? dayStartTime,
    String? dayEndTime,
    int? extraSpots,
    List<String>? wishlistPlaces,
    List<String>? favoritePlaces,
    DateTime? currentTime,
  }) async {
    final payload = <String, dynamic>{'interests': interestIds};
    final effectiveCurrentTime = currentTime ?? DateTime.now();
    if (userId != null && userId.trim().isNotEmpty) {
      payload['userId'] = userId.trim();
    }
    if (startDate != null) {
      payload['startDate'] = startDate.toIso8601String();
    }
    if (endDate != null) {
      payload['endDate'] = endDate.toIso8601String();
    }
    if (originCity != null && originCity.trim().isNotEmpty) {
      payload['originCity'] = originCity.trim();
    }
    if (destinationCities != null && destinationCities.isNotEmpty) {
      payload['destinationCities'] = destinationCities
          .where((e) => e.trim().isNotEmpty)
          .map((e) => e.trim())
          .toList();
    }
    if (requirementsText != null && requirementsText.trim().isNotEmpty) {
      payload['requirementsText'] = requirementsText.trim();
    }
    if (tripPurpose != null && tripPurpose.trim().isNotEmpty) {
      payload['tripPurpose'] = tripPurpose.trim();
    }
    if (travelBehavior != null && travelBehavior.trim().isNotEmpty) {
      payload['travelBehavior'] = travelBehavior.trim();
    }
    if (location != null && location.trim().isNotEmpty) {
      payload['location'] = location.trim();
    }
    if (people != null) {
      payload['people'] = people;
    }
    if (budget != null) {
      payload['budget'] = budget;
    }
    if (backpackerAnswers != null && backpackerAnswers.isNotEmpty) {
      payload['backpackerAnswers'] = backpackerAnswers;
    }
    if (dayStartTime != null && dayStartTime.trim().isNotEmpty) {
      payload['dayStartTime'] = dayStartTime.trim();
    }
    if (dayEndTime != null && dayEndTime.trim().isNotEmpty) {
      payload['dayEndTime'] = dayEndTime.trim();
    }
    if (extraSpots != null && extraSpots > 0) {
      payload['extraSpots'] = extraSpots;
    }
    if (wishlistPlaces != null && wishlistPlaces.isNotEmpty) {
      payload['wishlistPlaces'] = wishlistPlaces
          .where((e) => e.trim().isNotEmpty)
          .map((e) => e.trim())
          .toList();
    }
    if (favoritePlaces != null && favoritePlaces.isNotEmpty) {
      payload['favoritePlaces'] = favoritePlaces
          .where((e) => e.trim().isNotEmpty)
          .map((e) => e.trim())
          .toList();
    }
    payload['currentDate'] = effectiveCurrentTime
        .toIso8601String()
        .split('T')
        .first;
    payload['currentMinuteOfDay'] =
        effectiveCurrentTime.hour * 60 + effectiveCurrentTime.minute;

    final response = await _post(
      '/api/travel/plans',
      payload,
      timeout: const Duration(seconds: 120),
      timeoutMessage: '行程生成較久，請稍候再試（可能正在查景點、交通、天氣或 AI 建議）。',
    );
    return _extractData(response);
  }

  Future<Map<String, dynamic>> plannerChat({
    String? conversationId,
    String? userId,
    required DateTime startDate,
    required DateTime endDate,
    required String originCity,
    required List<String> destinationCities,
    required String userMessage,
    String? requirementsText,
  }) async {
    final response = await _post(
      '/api/travel/planner-chat',
      {
        if (conversationId != null && conversationId.trim().isNotEmpty)
          'conversationId': conversationId.trim(),
        if (userId != null && userId.trim().isNotEmpty) 'userId': userId.trim(),
        'startDate': startDate.toIso8601String(),
        'endDate': endDate.toIso8601String(),
        'originCity': originCity.trim(),
        'destinationCities': destinationCities
            .where((e) => e.trim().isNotEmpty)
            .map((e) => e.trim())
            .toList(),
        'userMessage': userMessage.trim(),
        if (requirementsText != null && requirementsText.trim().isNotEmpty)
          'requirementsText': requirementsText.trim(),
      },
      timeout: const Duration(seconds: 75),
      timeoutMessage: '對話回應較久，請稍候再試。',
    );
    return _extractData(response);
  }

  Future<Map<String, dynamic>> explainItineraryStop({
    required Map<String, dynamic> payload,
  }) async {
    final response = await _post(
      '/api/travel/stop-explanation',
      payload,
      timeout: const Duration(seconds: 45),
      timeoutMessage: '景點說明生成較久，請稍候再試。',
    );
    return _extractData(response);
  }

  Future<Map<String, dynamic>> fetchContextAwareness({
    required Map<String, dynamic> day,
    String? userId,
    bool triggerLinePush = false,
    DateTime? currentTime,
  }) async {
    final payload = <String, dynamic>{
      'day': day,
      'triggerLinePush': triggerLinePush,
      'currentTime': (currentTime ?? DateTime.now()).toIso8601String(),
    };
    if (userId != null && userId.trim().isNotEmpty) {
      payload['userId'] = userId.trim();
    }
    final response = await _post(
      '/api/travel/context-awareness',
      payload,
      timeout: const Duration(seconds: 20),
      timeoutMessage: '情境感知分析較久，請稍候再試。',
    );
    return _extractData(response);
  }

  Future<void> syncActivePlan({
    required String userId,
    required Map<String, dynamic> plan,
  }) async {
    await _post(
      '/api/travel/active-plan',
      {'userId': userId, 'plan': plan},
      timeout: const Duration(seconds: 20),
      timeoutMessage: '行程同步較久，請稍候再試。',
    );
  }

  Future<Map<String, dynamic>> fetchActivePlan({required String userId}) async {
    final response = await _post(
      '/api/travel/active-plan/read',
      {'userId': userId},
      timeout: const Duration(seconds: 20),
      timeoutMessage: '抓取最新行程較久，請稍候再試。',
    );
    return _extractData(response);
  }

  Future<void> confirmItinerary({
    required String userId,
    required Map<String, dynamic> plan,
  }) async {
    await _post(
      '/api/travel/confirm-plan',
      {'userId': userId, 'plan': plan, 'source': 'formal_itinerary_page'},
      timeout: const Duration(seconds: 30),
      timeoutMessage: '正式行程確認較久，請稍候再試。',
    );
  }

  Future<void> reportAppEvent({
    required String event,
    String? page,
    String? userId,
    String? sessionId,
    Map<String, dynamic>? payload,
  }) async {
    await _post(
      '/api/analytics/events',
      {
        'event': event,
        if (page != null && page.trim().isNotEmpty) 'page': page.trim(),
        if (userId != null && userId.trim().isNotEmpty) 'userId': userId.trim(),
        if (sessionId != null && sessionId.trim().isNotEmpty)
          'sessionId': sessionId.trim(),
        if (payload != null && payload.isNotEmpty) 'payload': payload,
      },
      timeout: const Duration(seconds: 8),
      timeoutMessage: '事件上報逾時',
    );
  }

  Future<Map<String, dynamic>> updateLocation({
    required String userId,
    required double lat,
    required double lng,
    DateTime? timestamp,
    double? accuracy,
    double? speed,
    double? heading,
    bool background = false,
    bool triggerLinePush = true,
    String? source,
  }) async {
    final response = await _post(
      '/api/location/update',
      {
        'userId': userId,
        'lat': lat,
        'lng': lng,
        'timestamp': (timestamp ?? DateTime.now()).toIso8601String(),
        if (accuracy != null) 'accuracy': accuracy,
        if (speed != null) 'speed': speed,
        if (heading != null) 'heading': heading,
        'background': background,
        'triggerLinePush': triggerLinePush,
        if (source != null && source.trim().isNotEmpty) 'source': source.trim(),
      },
      timeout: const Duration(seconds: 20),
      timeoutMessage: '定位同步較久，請稍候再試。',
    );
    return _extractData(response);
  }

  Future<List<Map<String, dynamic>>> fetchPlaces({
    List<String>? tags,
    String? query,
    String? city,
    String? sort,
    int? limit,
  }) async {
    final params = <String, String>{};
    if (tags != null && tags.isNotEmpty) {
      params['tags'] = tags.join(',');
    }
    if (query != null && query.trim().isNotEmpty) {
      params['q'] = query.trim();
    }
    if (city != null && city.trim().isNotEmpty) {
      params['city'] = city.trim();
    }
    if (sort != null && sort.trim().isNotEmpty) {
      params['sort'] = sort.trim();
    }
    if (limit != null && limit > 0) {
      params['limit'] = '$limit';
    }
    final uri = Uri.parse(
      '$baseUrl/api/places',
    ).replace(queryParameters: params);
    http.Response response;
    try {
      response = await http.get(uri).timeout(const Duration(seconds: 20));
    } on TimeoutException catch (error) {
      throw ApiClientException('伺服器回應較慢，請稍候再試。', cause: error);
    } on Exception catch (error) {
      throw ApiClientException('無法連線到伺服器，請稍後再試。', cause: error);
    }

    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } on Exception {
      throw ApiClientException('伺服器回應格式不正確 (HTTP ${response.statusCode}).');
    }
    final success = decoded['success'] == true && response.statusCode < 400;
    if (!success) {
      final message =
          decoded['message']?.toString() ??
          '伺服器發生錯誤 (HTTP ${response.statusCode})';
      throw ApiClientException(
        message,
        statusCode: response.statusCode,
        details: decoded['details'] as Map<String, dynamic>?,
      );
    }
    final data = decoded['data'];
    if (data is Map<String, dynamic>) {
      final places = data['places'];
      if (places is List) {
        return places.whereType<Map<String, dynamic>>().toList();
      }
    }
    return <Map<String, dynamic>>[];
  }

  Future<List<Map<String, dynamic>>> searchPlaces({
    required String query,
    int? limit,
  }) async {
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) {
      return <Map<String, dynamic>>[];
    }

    final params = <String, String>{'q': trimmedQuery};
    if (limit != null && limit > 0) {
      params['limit'] = '$limit';
    }

    final uri = Uri.parse(
      '$baseUrl/api/place-search',
    ).replace(queryParameters: params);
    http.Response response;
    try {
      response = await http.get(uri).timeout(const Duration(seconds: 20));
    } on TimeoutException catch (error) {
      throw ApiClientException('景點搜尋逾時，請稍候再試。', cause: error);
    } on Exception catch (error) {
      throw ApiClientException('無法連線到伺服器，請稍後再試。', cause: error);
    }

    if (response.statusCode == 404) {
      throw ApiClientException(
        '後端尚未更新或尚未重啟，找不到 /api/place-search。請重啟目前使用中的後端服務。',
        statusCode: 404,
      );
    }

    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } on Exception {
      throw ApiClientException(
        '景點搜尋失敗：伺服器回應格式不正確 (HTTP ${response.statusCode})。',
        statusCode: response.statusCode,
      );
    }

    final success = decoded['success'] == true && response.statusCode < 400;
    if (!success) {
      final message =
          decoded['message']?.toString() ??
          '景點搜尋失敗 (HTTP ${response.statusCode})';
      throw ApiClientException(
        message,
        statusCode: response.statusCode,
        details: decoded['details'] as Map<String, dynamic>?,
      );
    }

    final data = decoded['data'];
    if (data is Map<String, dynamic>) {
      final places = data['places'];
      if (places is List) {
        return places.whereType<Map<String, dynamic>>().toList();
      }
    }
    return <Map<String, dynamic>>[];
  }

  Future<List<Map<String, dynamic>>> fetchMealSuggestions({
    Map<String, dynamic>? previous,
    Map<String, dynamic>? next,
    String? query,
    String? mealType,
    String? city,
    int? limit,
  }) async {
    final uri = Uri.parse('$baseUrl/api/meal-suggestions');
    http.Response response;
    try {
      response = await http
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              if (previous != null) 'previous': previous,
              if (next != null) 'next': next,
              if (query != null && query.trim().isNotEmpty)
                'query': query.trim(),
              if (mealType != null && mealType.trim().isNotEmpty)
                'mealType': mealType.trim(),
              if (city != null && city.trim().isNotEmpty) 'city': city.trim(),
              if (limit != null && limit > 0) 'limit': limit,
            }),
          )
          .timeout(const Duration(seconds: 20));
    } on TimeoutException catch (error) {
      throw ApiClientException('餐廳即時搜尋逾時，請稍候再試。', cause: error);
    } on Exception catch (error) {
      throw ApiClientException('無法連線到伺服器，請稍後再試。', cause: error);
    }

    if (response.statusCode == 404) {
      throw ApiClientException(
        '後端尚未更新或尚未重啟，找不到 /api/meal-suggestions。請重啟目前使用中的後端服務。',
        statusCode: 404,
      );
    }

    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } on Exception {
      throw ApiClientException(
        '餐廳即時搜尋失敗：伺服器回應格式不正確 (HTTP ${response.statusCode})。',
        statusCode: response.statusCode,
      );
    }

    final success = decoded['success'] == true && response.statusCode < 400;
    if (!success) {
      final message =
          decoded['message']?.toString() ??
          '餐廳即時搜尋失敗 (HTTP ${response.statusCode})';
      throw ApiClientException(
        message,
        statusCode: response.statusCode,
        details: decoded['details'] as Map<String, dynamic>?,
      );
    }

    final data = decoded['data'];
    if (data is Map<String, dynamic>) {
      final places = data['places'];
      if (places is List) {
        return places.whereType<Map<String, dynamic>>().toList();
      }
    }
    return <Map<String, dynamic>>[];
  }

  Future<Map<String, dynamic>> sendPasswordResetCode({
    required String account,
    required String email,
  }) async {
    final response = await _post('/api/auth/reset-password/code', {
      'account': account,
      'email': email,
    });
    return _extractData(response);
  }

  Future<void> verifyPasswordResetCode({
    required String account,
    required String email,
    required String code,
  }) async {
    await _post('/api/auth/reset-password/verify', {
      'account': account,
      'email': email,
      'code': code,
    });
  }

  Future<void> completePasswordReset({
    required String account,
    required String email,
    required String code,
    required String newPassword,
  }) async {
    await _post('/api/auth/reset-password/complete', {
      'account': account,
      'email': email,
      'code': code,
      'newPassword': newPassword,
    });
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 20),
    String timeoutMessage = '伺服器回應較慢，請稍候再試。',
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    http.Response response;
    try {
      response = await http
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException catch (error) {
      throw ApiClientException(timeoutMessage, cause: error);
    } on Exception catch (error) {
      throw ApiClientException('無法連線到伺服器，請稍後再試。', cause: error);
    }

    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } on Exception {
      throw ApiClientException('伺服器回應格式不正確 (HTTP ${response.statusCode}).');
    }

    final success = decoded['success'] == true && response.statusCode < 400;
    if (!success) {
      final message =
          decoded['message']?.toString() ??
          '伺服器發生錯誤 (HTTP ${response.statusCode})';
      throw ApiClientException(
        message,
        statusCode: response.statusCode,
        details: decoded['details'] as Map<String, dynamic>?,
      );
    }
    return decoded;
  }

  Map<String, dynamic> _extractData(Map<String, dynamic> response) {
    final data = response['data'];
    if (data is Map<String, dynamic>) {
      return data;
    }
    return <String, dynamic>{};
  }

  Map<String, dynamic> _extractUser(Map<String, dynamic> response) {
    final data = _extractData(response);
    final user = data['user'];
    if (user is Map<String, dynamic>) {
      return user;
    }
    return <String, dynamic>{};
  }
}

class ApiClientException implements Exception {
  ApiClientException(this.message, {this.statusCode, this.details, this.cause});

  final String message;
  final int? statusCode;
  final Map<String, dynamic>? details;
  final Object? cause;

  @override
  String toString() => 'ApiClientException($statusCode): $message';
}
