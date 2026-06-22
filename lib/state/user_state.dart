import 'package:shared_preferences/shared_preferences.dart';

class UserState {
  static const _kName = 'user_display_name';
  static const _kAvatar = 'user_avatar_path';
  static const _kUserId = 'user_id';
  static const _kLineLinked = 'user_line_linked';
  static const _kLinePushEnabled = 'user_line_push_enabled';
  static const _kInterestPrefix = 'user_interest_ids_';

  static String? displayName;
  static String? avatarPath;
  static String? userId;
  static bool lineLinked = false;
  static bool linePushEnabled = false;
  static List<String> selectedInterestIds = const [];
  static SharedPreferences? _prefs;

  static Future<void> load() async {
    _prefs ??= await SharedPreferences.getInstance();
    displayName = _prefs!.getString(_kName);
    avatarPath = _prefs!.getString(_kAvatar);
    userId = _prefs!.getString(_kUserId);
    lineLinked = _prefs!.getBool(_kLineLinked) ?? false;
    linePushEnabled = _prefs!.getBool(_kLinePushEnabled) ?? false;
    selectedInterestIds = _loadInterestsForUser(userId);
  }

  static Future<void> updateName(String? name) async {
    final trimmed = name?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      displayName = trimmed;
      await _ensurePrefs();
      await _prefs!.setString(_kName, trimmed);
    }
  }

  static Future<void> updateAvatar(String path) async {
    avatarPath = path;
    await _ensurePrefs();
    await _prefs!.setString(_kAvatar, path);
  }

  static Future<void> updateUser({
    String? id,
    String? name,
    bool? linked,
    bool? pushEnabled,
  }) async {
    await _ensurePrefs();
    var shouldReloadInterests = false;
    if (id != null && id.trim().isNotEmpty) {
      userId = id.trim();
      await _prefs!.setString(_kUserId, userId!);
      shouldReloadInterests = true;
    }
    if (name != null && name.trim().isNotEmpty) {
      displayName = name.trim();
      await _prefs!.setString(_kName, displayName!);
    }
    if (linked != null) {
      lineLinked = linked;
      await _prefs!.setBool(_kLineLinked, linked);
    }
    if (pushEnabled != null) {
      linePushEnabled = pushEnabled;
      await _prefs!.setBool(_kLinePushEnabled, pushEnabled);
    }
    if (shouldReloadInterests) {
      selectedInterestIds = _loadInterestsForUser(userId);
    }
  }

  static Future<void> saveSelectedInterests(List<String> interestIds) async {
    await _ensurePrefs();
    final cleaned = interestIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    selectedInterestIds = cleaned;
    final currentUserId = userId;
    if (currentUserId == null || currentUserId.isEmpty) {
      return;
    }
    await _prefs!.setStringList(_interestKey(currentUserId), cleaned);
  }

  static bool get hasSavedInterests => selectedInterestIds.isNotEmpty;

  static List<String> _loadInterestsForUser(String? id) {
    if (_prefs == null || id == null || id.isEmpty) {
      return const [];
    }
    return List<String>.from(_prefs!.getStringList(_interestKey(id)) ?? const []);
  }

  static String _interestKey(String id) => '$_kInterestPrefix$id';

  static Future<void> clearCurrentUserInterests() async {
    await _ensurePrefs();
    final currentUserId = userId;
    selectedInterestIds = const [];
    if (currentUserId == null || currentUserId.isEmpty) {
      return;
    }
    await _prefs!.remove(_interestKey(currentUserId));
  }

  static Future<void> clearSession() async {
    await _ensurePrefs();
    userId = null;
    lineLinked = false;
    linePushEnabled = false;
    selectedInterestIds = const [];
    await _prefs!.remove(_kUserId);
    await _prefs!.remove(_kLineLinked);
    await _prefs!.remove(_kLinePushEnabled);
  }

  static Future<void> _ensurePrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
  }
}
