import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class BackendApi {
  BackendApi._internal()
    : baseUrl = const String.fromEnvironment(
        'SMART_TRAVEL_API_BASE',
        defaultValue: 'http://localhost:8080',
      );

  static final BackendApi instance = BackendApi._internal();

  final String baseUrl;

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

  Future<void> sendLinePushTest({
    required String userId,
  }) async {
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
  }) async {
    final payload = <String, dynamic>{'interests': interestIds};
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

    final response = await _post(
      '/api/travel/plans',
      payload,
      timeout: const Duration(seconds: 60),
      timeoutMessage: '行程生成較久，請稍候再試（可能正在查交通/天氣/GPT）。',
    );
    return _extractData(response);
  }

  Future<Map<String, dynamic>> explainItineraryStop({
    required Map<String, dynamic> payload,
  }) async {
    final response = await _post(
      '/api/travel/stop-explanation',
      payload,
      timeout: const Duration(seconds: 20),
      timeoutMessage: '景點說明生成較久，請稍候再試。',
    );
    return _extractData(response);
  }

  Future<Map<String, dynamic>> fetchContextAwareness({
    required Map<String, dynamic> day,
    String? userId,
    bool triggerLinePush = true,
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
              if (query != null && query.trim().isNotEmpty) 'query': query.trim(),
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
