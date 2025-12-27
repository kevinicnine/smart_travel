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

  bool get _emailEnabled =>
      _sendgridKey != null && _sendgridFromEmail != null && _sendgridFromEmail!.isNotEmpty;
  bool get _smsEnabled =>
      _twilioSid != null &&
      _twilioToken != null &&
      _twilioFrom != null &&
      _twilioFrom!.isNotEmpty;

  Future<void> sendEmailVerification({
    required String to,
    required String code,
  }) async {
    if (!_emailEnabled) {
      _log.info(
          'Skipping email verification send because SendGrid env vars are missing (to=$to, code=$code)');
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
          'Skipping password reset email because SendGrid env vars are missing (to=$to, code=$code)');
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
          'Skipping SMS verification send because Twilio env vars are missing (to=$to, code=$code)');
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
        }
      ],
      'from': {
        'email': _sendgridFromEmail,
        'name': _sendgridFromName,
      },
      'content': [
        {
          'type': 'text/plain',
          'value': content,
        }
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
          'SendGrid mail failed (${response.statusCode}): ${response.body}');
      throw ApiException(500, errorMessage);
    }
  }
}
