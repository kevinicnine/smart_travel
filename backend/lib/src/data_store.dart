import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';

class DataStore {
  DataStore({required String dataDirectory})
    : _directory = Directory(dataDirectory),
      _file = File(p.join(dataDirectory, 'db.json'));

  final Directory _directory;
  final File _file;
  static const JsonEncoder _encoder = JsonEncoder.withIndent('  ');

  Future<void> _ensureInitialized() async {
    if (!await _directory.exists()) {
      await _directory.create(recursive: true);
    }
    if (!await _file.exists()) {
      await _file.writeAsString(_encoder.convert({'users': [], 'places': []}));
    }
  }

  Future<BackendData> read() async {
    await _ensureInitialized();
    final contents = await _file.readAsString();
    if (contents.trim().isEmpty) {
      return BackendData();
    }
    final Map<String, dynamic> json =
        jsonDecode(contents) as Map<String, dynamic>;
    return BackendData.fromJson(json);
  }

  Future<void> save(BackendData data) async {
    await _ensureInitialized();
    await _file.writeAsString(_encoder.convert(data.toJson()));
  }

  Future<void> addUser(User user) async {
    final data = await read();
    data.users.add(user);
    await save(data);
  }

  Future<void> updateUser(User updated) async {
    final data = await read();
    final index = data.users.indexWhere((u) => u.id == updated.id);
    if (index == -1) {
      throw StateError('User ${updated.id} not found');
    }
    data.users[index] = updated;
    await save(data);
  }

  Future<void> deleteUser(String id) async {
    final data = await read();
    data.users.removeWhere((u) => u.id == id);
    await save(data);
  }

  Future<List<Place>> listPlaces() async {
    final data = await read();
    return data.places;
  }

  Future<void> savePlaces(List<Place> places) async {
    final data = await read();
    data.places
      ..clear()
      ..addAll(places);
    await save(data);
  }

  Future<void> upsertPlace(Place place) async {
    final data = await read();
    final index = data.places.indexWhere((p) => p.id == place.id);
    if (index == -1) {
      data.places.add(place);
    } else {
      data.places[index] = place;
    }
    await save(data);
  }

  Future<void> deletePlace(String id) async {
    final data = await read();
    data.places.removeWhere((p) => p.id == id);
    await save(data);
  }

  Future<User?> findByEmail(String email) async {
    final data = await read();
    return _find(data.users, (u) => u.email == email);
  }

  Future<User?> findByPhone(String phone) async {
    final data = await read();
    return _find(data.users, (u) => u.phone == phone);
  }

  Future<User?> findByUsername(String username) async {
    final lower = username.toLowerCase();
    final data = await read();
    return _find(data.users, (u) => u.username.toLowerCase() == lower);
  }

  Future<User?> findByAccount(String account) async {
    final trimmed = account.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final data = await read();
    final lower = trimmed.toLowerCase();
    return _find(
      data.users,
      (u) => u.username.toLowerCase() == lower || u.email == lower,
    );
  }

  User? _find(List<User> users, bool Function(User user) predicate) {
    for (final user in users) {
      if (predicate(user)) {
        return user;
      }
    }
    return null;
  }
}
