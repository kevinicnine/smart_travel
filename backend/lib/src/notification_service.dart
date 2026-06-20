import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'exceptions.dart';

/// Handles real email / SMS delivery for verification codes.
///
/// Uses SendGrid (email) and Twilio (SMS) when the related environment
/// variables are provided. If the env vars are missing, calls are treated as
/// no-ops but still logged so local development continues to work without
/// external services.
class NotificationService {
  NotificationService({http.Client? httpClient})
    : _client = httpClient ?? http.Client();

  final http.Client _client;
  final _log = Logger('NotificationService');

  String? get _sendgridKey => Platform.environment['SENDGRID_API_KEY'];
  String? get _sendgridFromEmail => Platform.environment['SENDGRID_FROM_EMAIL'];
  String get _sendgridFromName =>
      Platform.environment['SENDGRID_FROM_NAME'] ?? 'Smart Travel';

  String? get _twilioSid => Platform.environment['TWILIO_ACCOUNT_SID'];
  String? get _twilioToken => Platform.environment['TWILIO_AUTH_TOKEN'];
  String? get _twilioFrom => Platform.environment['TWILIO_FROM_NUMBER'];
  String? get _lineChannelToken =>
      Platform.environment['LINE_CHANNEL_ACCESS_TOKEN'];

  bool get _emailEnabled =>
      _sendgridKey != null &&
      _sendgridFromEmail != null &&
      _sendgridFromEmail!.isNotEmpty;
  bool get _smsEnabled =>
      _twilioSid != null &&
      _twilioToken != null &&
      _twilioFrom != null &&
      _twilioFrom!.isNotEmpty;
  bool get _lineEnabled =>
      _lineChannelToken != null && _lineChannelToken!.trim().isNotEmpty;

  Future<void> sendEmailVerification({
    required String to,
    required String code,
  }) async {
    if (!_emailEnabled) {
      _log.info(
        'Skipping email verification send because SendGrid env vars are missing (to=$to, code=$code)',
      );
      return;
    }
    await _sendGridMail(
      to: to,
      subject: 'Smart Travel 確認你的電子郵件',
      content: '您的驗證碼為：$code\n五分鐘內有效，請勿外洩給他人。',
      errorMessage: '寄送 Email 驗證碼失敗，請稍後再試。',
    );
  }

  Future<void> sendPasswordResetEmail({
    required String to,
    required String code,
  }) async {
    if (!_emailEnabled) {
      _log.info(
        'Skipping password reset email because SendGrid env vars are missing (to=$to, code=$code)',
      );
      return;
    }
    await _sendGridMail(
      to: to,
      subject: 'Smart Travel 密碼重設驗證碼',
      content: '您正在重設密碼，驗證碼：$code\n若非本人操作請忽略此信。',
      errorMessage: '寄送密碼重置信件失敗，請稍後再試。',
    );
  }

  Future<void> sendSmsVerification({
    required String to,
    required String code,
  }) async {
    if (!_smsEnabled) {
      _log.info(
        'Skipping SMS verification send because Twilio env vars are missing (to=$to, code=$code)',
      );
      return;
    }
    final uri = Uri.https(
      'api.twilio.com',
      '/2010-04-01/Accounts/${_twilioSid!}/Messages.json',
    );
    final response = await _client.post(
      uri,
      headers: {
        'Authorization':
            'Basic ${base64Encode(utf8.encode('${_twilioSid!}:${_twilioToken!}'))}',
      },
      body: {
        'To': to,
        'From': _twilioFrom!,
        'Body': 'Smart Travel 驗證碼：$code (5 分鐘內有效)',
      },
    );
    if (response.statusCode >= 400) {
      _log.severe(
        'Twilio SMS send failed (${response.statusCode}): ${response.body}',
      );
      throw ApiException(500, '寄送簡訊驗證碼失敗，請稍後再試。');
    }
  }

  Future<void> sendLinePush({
    required String to,
    required String text,
    String? imageUrl,
  }) async {
    if (!_lineEnabled) {
      _log.info(
        'Skipping LINE push because LINE channel token is missing (to=$to)',
      );
      return;
    }
    final normalizedImageUrl = imageUrl?.trim() ?? '';
    final messages = <Map<String, dynamic>>[];
    final parsedImageUrl = Uri.tryParse(normalizedImageUrl);
    if (parsedImageUrl != null &&
        parsedImageUrl.scheme == 'https' &&
        parsedImageUrl.host.isNotEmpty) {
      messages.add({
        'type': 'image',
        'originalContentUrl': normalizedImageUrl,
        'previewImageUrl': normalizedImageUrl,
      });
    }
    messages.add({'type': 'text', 'text': text});

    final uri = Uri.https('api.line.me', '/v2/bot/message/push');
    final headers = {
      'Authorization': 'Bearer ${_lineChannelToken!}',
      'Content-Type': 'application/json',
    };
    var response = await _postLineWithRetry(
      uri: uri,
      headers: headers,
      payload: {'to': to, 'messages': messages},
    );
    if (response.statusCode >= 400 && messages.length > 1) {
      _log.warning(
        'LINE image push failed (${response.statusCode}); retrying text only.',
      );
      response = await _postLineWithRetry(
        uri: uri,
        headers: headers,
        payload: {
          'to': to,
          'messages': [
            {'type': 'text', 'text': text},
          ],
        },
      );
    }
    if (response.statusCode >= 400) {
      _log.severe(
        'LINE push failed (${response.statusCode}): ${response.body}',
      );
      throw ApiException(500, 'LINE 推播失敗，請稍後再試。');
    }
  }

  Future<http.Response> _postLineWithRetry({
    required Uri uri,
    required Map<String, String> headers,
    required Map<String, dynamic> payload,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final response = await _client
            .post(uri, headers: headers, body: jsonEncode(payload))
            .timeout(const Duration(seconds: 15));
        final retryable =
            response.statusCode == 429 || response.statusCode >= 500;
        if (!retryable || attempt == 2) {
          return response;
        }
        _log.warning(
          'LINE push temporarily failed (${response.statusCode}); '
          'retrying attempt ${attempt + 2}/3.',
        );
      } catch (error) {
        lastError = error;
        if (attempt == 2) rethrow;
        _log.warning(
          'LINE push transport error; retrying attempt ${attempt + 2}/3: '
          '$error',
        );
      }
      await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
    }
    throw ApiException(500, 'LINE 推播失敗：$lastError');
  }

  Future<void> replyLineText({
    required String replyToken,
    required String text,
  }) async {
    if (!_lineEnabled) {
      _log.info('Skipping LINE reply because LINE channel token is missing');
      return;
    }
    final response = await _client.post(
      Uri.https('api.line.me', '/v2/bot/message/reply'),
      headers: {
        'Authorization': 'Bearer ${_lineChannelToken!}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'replyToken': replyToken,
        'messages': [
          {'type': 'text', 'text': text},
        ],
      }),
    );
    if (response.statusCode >= 400) {
      _log.severe(
        'LINE reply failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<void> _sendGridMail({
    required String to,
    required String subject,
    required String content,
    required String errorMessage,
  }) async {
    final payload = {
      'personalizations': [
        {
          'to': [
            {'email': to},
          ],
          'subject': subject,
        },
      ],
      'from': {'email': _sendgridFromEmail, 'name': _sendgridFromName},
      'content': [
        {'type': 'text/plain', 'value': content},
      ],
    };

    final response = await _client.post(
      Uri.https('api.sendgrid.com', '/v3/mail/send'),
      headers: {
        'Authorization': 'Bearer ${_sendgridKey!}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      _log.severe(
        'SendGrid mail failed (${response.statusCode}): ${response.body}',
      );
      throw ApiException(500, errorMessage);
    }
  }
}
