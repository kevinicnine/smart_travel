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

  Future<void> submitInterests(List<String> interestIds) async {
    await _post('/api/travel/preferences', {'interests': interestIds});
  }

  Future<Map<String, dynamic>> generateItinerary({
    required List<String> interestIds,
    DateTime? startDate,
    DateTime? endDate,
    String? location,
    int? people,
    int? budget,
  }) async {
    final payload = <String, dynamic>{'interests': interestIds};
    if (startDate != null) {
      payload['startDate'] = startDate.toIso8601String();
    }
    if (endDate != null) {
      payload['endDate'] = endDate.toIso8601String();
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

    final response = await _post('/api/travel/plans', payload);
    return _extractData(response);
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
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse('$baseUrl$path');
    http.Response response;
    try {
      response = await http
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));
    } on TimeoutException catch (error) {
      throw ApiClientException('連線逾時，請檢查網路後再試。', cause: error);
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
