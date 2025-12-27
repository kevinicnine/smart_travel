import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'data_store.dart';
import 'exceptions.dart';
import 'models.dart';
import 'notification_service.dart';

class AuthService {
  AuthService(
    this._store, {
    Duration codeValidity = const Duration(minutes: 5),
    NotificationService? notificationService,
  })  : _codeValidity = codeValidity,
        _notificationService = notificationService;

  final DataStore _store;
  final Duration _codeValidity;
  final NotificationService? _notificationService;
  final _random = Random.secure();
  final _uuid = const Uuid();

  final Map<String, _VerificationRecord> _emailCodes = {};
  final Map<String, _VerificationRecord> _smsCodes = {};
  final Map<String, _VerificationRecord> _resetCodes = {};

  static final _emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+');

  Future<VerificationResult> sendEmailCode(String email) async {
    final normalized = _normalizeEmail(email);
    if (normalized.isEmpty) {
      throw ApiException(400, '請輸入電子郵件');
    }
    if (!_emailRegex.hasMatch(normalized)) {
      throw ApiException(400, '電子郵件格式不正確');
    }
    final existing = await _store.findByEmail(normalized);
    if (existing != null) {
      throw ApiException(409, '電子郵件已被使用');
    }
    final record = _createRecord();
    _emailCodes[normalized] = record;
    await _notificationService?.sendEmailVerification(
      to: normalized,
      code: record.code,
    );
    return VerificationResult(
      channel: 'email',
      target: normalized,
      code: record.code,
      expiresIn: _codeValidity,
    );
  }

  Future<void> verifyEmailCode(String email, String code) async {
    final normalized = _normalizeEmail(email);
    if (normalized.isEmpty) {
      throw ApiException(400, '請輸入電子郵件');
    }
    _verifyCode(
      store: _emailCodes,
      key: normalized,
      code: code,
      missingMsg: '請先寄出電子郵件驗證碼',
    );
  }

  Future<VerificationResult> sendSmsCode(String phone) async {
    final normalized = _normalizePhone(phone);
    if (normalized.isEmpty) {
      throw ApiException(400, '請輸入手機號碼');
    }
    if (normalized.length < 8) {
      throw ApiException(400, '手機號碼格式不正確');
    }
    final existing = await _store.findByPhone(normalized);
    if (existing != null) {
      throw ApiException(409, '手機號碼已被使用');
    }
    final record = _createRecord();
    _smsCodes[normalized] = record;
    await _notificationService?.sendSmsVerification(
      to: normalized,
      code: record.code,
    );
    return VerificationResult(
      channel: 'sms',
      target: normalized,
      code: record.code,
      expiresIn: _codeValidity,
    );
  }

  Future<void> verifySmsCode(String phone, String code) async {
    final normalized = _normalizePhone(phone);
    if (normalized.isEmpty) {
      throw ApiException(400, '請輸入手機號碼');
    }
    _verifyCode(
      store: _smsCodes,
      key: normalized,
      code: code,
      missingMsg: '請先寄出手機驗證碼',
    );
  }

  Future<User> register({
    required String username,
    required String email,
    String? phone,
    required String password,
  }) async {
    final normalizedUsername = _normalizeUsername(username);
    final normalizedEmail = _normalizeEmail(email);
    final normalizedPhone = _normalizePhone(phone ?? '');
    final trimmedPassword = password.trim();

    if (normalizedUsername.length < 2) {
      throw ApiException(400, '用戶名稱至少需要 2 個字');
    }
    if (!_emailRegex.hasMatch(normalizedEmail)) {
      throw ApiException(400, '電子郵件格式不正確');
    }
    if (normalizedPhone.isNotEmpty && normalizedPhone.length < 8) {
      throw ApiException(400, '手機號碼格式不正確');
    }
    if (trimmedPassword.length < 6) {
      throw ApiException(400, '密碼至少需要 6 碼');
    }

    final duplicatedName = await _store.findByUsername(normalizedUsername);
    if (duplicatedName != null) {
      throw ApiException(409, '用戶名稱已有人使用');
    }
    final duplicatedEmail = await _store.findByEmail(normalizedEmail);
    if (duplicatedEmail != null) {
      throw ApiException(409, '電子郵件已有人使用');
    }
    if (normalizedPhone.isNotEmpty) {
      final duplicatedPhone = await _store.findByPhone(normalizedPhone);
      if (duplicatedPhone != null) {
        throw ApiException(409, '手機號碼已有人使用');
      }
    }

    _ensureVerified(
      store: _emailCodes,
      key: normalizedEmail,
      message: '請先通過電子郵件驗證',
    );
    if (normalizedPhone.isNotEmpty) {
      _ensureVerified(
        store: _smsCodes,
        key: normalizedPhone,
        message: '請先通過手機驗證',
      );
    }

    final user = User(
      id: _uuid.v4(),
      username: normalizedUsername,
      email: normalizedEmail,
      phone: normalizedPhone,
      passwordHash: _hashPassword(trimmedPassword),
      createdAt: DateTime.now().toUtc(),
    );

    await _store.addUser(user);
    _emailCodes.remove(normalizedEmail);
    _smsCodes.remove(normalizedPhone);
    return user;
  }

  Future<User> login({required String account, required String password}) async {
    final trimmedAccount = account.trim();
    if (trimmedAccount.isEmpty) {
      throw ApiException(400, '請輸入帳號或電子郵件');
    }
    final user = await _store.findByAccount(trimmedAccount);
    if (user == null) {
      throw ApiException(404, '查無此帳號');
    }
    if (!_verifyPassword(password, user.passwordHash)) {
      throw ApiException(401, '密碼錯誤');
    }
    return user;
  }

  Future<VerificationResult> sendPasswordResetCode({
    required String account,
    required String email,
  }) async {
    final user = await _locateUserWithEmail(account: account, email: email);
    final key = user.id;
    final record = _createRecord();
    _resetCodes[key] = record;
    await _notificationService?.sendPasswordResetEmail(
      to: user.email,
      code: record.code,
    );
    return VerificationResult(
      channel: 'password_reset',
      target: user.email,
      code: record.code,
      expiresIn: _codeValidity,
    );
  }

  Future<void> verifyPasswordResetCode({
    required String account,
    required String email,
    required String code,
  }) async {
    final user = await _locateUserWithEmail(account: account, email: email);
    _verifyCode(
      store: _resetCodes,
      key: user.id,
      code: code,
      missingMsg: '請先寄送驗證碼',
    );
  }

  Future<User> completePasswordReset({
    required String account,
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final trimmedPassword = newPassword.trim();
    if (trimmedPassword.length < 6) {
      throw ApiException(400, '新密碼至少需要 6 碼');
    }
    final trimmedCode = code.trim();
    if (trimmedCode.isEmpty) {
      throw ApiException(400, '請輸入驗證碼');
    }
    final user = await _locateUserWithEmail(account: account, email: email);
    final record = _resetCodes[user.id];
    if (record == null) {
      throw ApiException(400, '請先寄送並驗證重設密碼驗證碼');
    }
    if (record.isExpired) {
      _resetCodes.remove(user.id);
      throw ApiException(410, '驗證碼已過期，請重新寄送');
    }
    if (record.code != trimmedCode) {
      throw ApiException(400, '驗證碼不正確');
    }
    if (!record.verified) {
      throw ApiException(403, '請先完成驗證碼驗證步驟');
    }

    final updated = user.copyWith(passwordHash: _hashPassword(trimmedPassword));
    await _store.updateUser(updated);
    _resetCodes.remove(user.id);
    return updated;
  }

  Future<User> _locateUserWithEmail({required String account, required String email}) async {
    final trimmedAccount = account.trim();
    if (trimmedAccount.isEmpty) {
      throw ApiException(400, '請輸入帳號');
    }
    final normalizedEmail = _normalizeEmail(email);
    if (normalizedEmail.isEmpty) {
      throw ApiException(400, '請輸入電子郵件');
    }
    final user = await _store.findByAccount(trimmedAccount);
    if (user == null || user.email != normalizedEmail) {
      throw ApiException(404, '帳號與電子郵件不相符');
    }
    return user;
  }

  void _ensureVerified({
    required Map<String, _VerificationRecord> store,
    required String key,
    required String message,
  }) {
    final record = store[key];
    if (record == null) {
      throw ApiException(403, message);
    }
    if (record.isExpired) {
      store.remove(key);
      throw ApiException(410, '驗證碼已過期，請重新寄送');
    }
    if (!record.verified) {
      throw ApiException(403, message);
    }
  }

  void _verifyCode({
    required Map<String, _VerificationRecord> store,
    required String key,
    required String code,
    required String missingMsg,
  }) {
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      throw ApiException(400, '請輸入驗證碼');
    }
    final record = store[key];
    if (record == null) {
      throw ApiException(400, missingMsg);
    }
    if (record.isExpired) {
      store.remove(key);
      throw ApiException(410, '驗證碼已過期，請重新寄送');
    }
    if (record.code != trimmed) {
      throw ApiException(400, '驗證碼不正確');
    }
    record.verified = true;
  }

  _VerificationRecord _createRecord() {
    final code = (_random.nextInt(900000) + 100000).toString();
    return _VerificationRecord(
      code: code,
      expiresAt: DateTime.now().toUtc().add(_codeValidity),
    );
  }

  String _hashPassword(String password) {
    final salt = List<int>.generate(16, (_) => _random.nextInt(256));
    return hashPasswordWithSalt(password, salt);
  }

  bool _verifyPassword(String password, String stored) {
    final parts = stored.split(':');
    if (parts.length != 2) {
      return false;
    }
    final salt = base64Url.decode(parts[0]);
    final expected = parts[1];
    final bytes = <int>[]
      ..addAll(salt)
      ..addAll(utf8.encode(password));
    final digest = sha256.convert(bytes);
    return base64UrlEncode(digest.bytes) == expected;
  }

  String _normalizeEmail(String email) => email.trim().toLowerCase();

  String _normalizePhone(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    return digits;
  }

  String _normalizeUsername(String username) => username.trim();

  /// For seeding users (test accounts) outside of the AuthService lifecycle.
  static String hashPasswordWithSalt(String password, List<int> salt) {
    final bytes = <int>[]
      ..addAll(salt)
      ..addAll(utf8.encode(password));
    final digest = sha256.convert(bytes);
    return '${base64UrlEncode(salt)}:${base64UrlEncode(digest.bytes)}';
  }
}

class _VerificationRecord {
  _VerificationRecord({required this.code, required this.expiresAt});

  final String code;
  final DateTime expiresAt;
  bool verified = false;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);
}

class VerificationResult {
  VerificationResult({
    required this.channel,
    required this.target,
    required this.code,
    required this.expiresIn,
  });

  final String channel;
  final String target;
  final String code;
  final Duration expiresIn;

  Map<String, dynamic> toJson({bool includeDebugCode = false}) {
    return {
      'channel': channel,
      'target': target,
      'expiresInSeconds': expiresIn.inSeconds,
      if (includeDebugCode) 'debugCode': code,
    };
  }
}
