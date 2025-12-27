import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'exceptions.dart';

Future<Map<String, dynamic>> parseJsonBody(Request request) async {
  final raw = await request.readAsString();
  if (raw.trim().isEmpty) {
    return <String, dynamic>{};
  }

  final decoded = jsonDecode(raw);
  if (decoded is Map<String, dynamic>) {
    return decoded;
  }

  throw ApiException(400, '請提供 JSON 物件');
}

Response jsonResponse(int statusCode, Map<String, dynamic> body) {
  return Response(
    statusCode,
    body: jsonEncode(body),
    headers: const {
      'content-type': 'application/json; charset=utf-8',
    },
  );
}

Map<String, dynamic> successBody({String? message, Map<String, dynamic>? data}) {
  return {
    'success': true,
    if (message != null) 'message': message,
    if (data != null) 'data': data,
  };
}

Map<String, dynamic> errorBody(String message, {Map<String, dynamic>? details}) {
  return {
    'success': false,
    'message': message,
    if (details != null) 'details': details,
  };
}
