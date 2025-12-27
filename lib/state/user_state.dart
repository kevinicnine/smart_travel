import 'package:shared_preferences/shared_preferences.dart';

class UserState {
  static const _kName = 'user_display_name';
  static const _kAvatar = 'user_avatar_path';

  static String? displayName;
  static String? avatarPath;
  static SharedPreferences? _prefs;

  static Future<void> load() async {
    _prefs ??= await SharedPreferences.getInstance();
    displayName = _prefs!.getString(_kName);
    avatarPath = _prefs!.getString(_kAvatar);
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

  static Future<void> _ensurePrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
  }
}
