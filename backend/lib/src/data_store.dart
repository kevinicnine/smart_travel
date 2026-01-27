import 'dart:convert';
import 'dart:io';

import 'package:mysql_client/mysql_client.dart';
import 'package:path/path.dart' as p;

import 'models.dart';

class MySqlConfig {
  MySqlConfig({
    required this.host,
    required this.port,
    required this.user,
    required this.password,
    required this.database,
  });

  final String host;
  final int port;
  final String user;
  final String password;
  final String database;

  static MySqlConfig? fromEnv() {
    final host = Platform.environment['MYSQL_HOST'];
    if (host == null || host.isEmpty) {
      return null;
    }
    final port = int.tryParse(Platform.environment['MYSQL_PORT'] ?? '3306') ?? 3306;
    final user = Platform.environment['MYSQL_USER'] ?? 'root';
    final password = Platform.environment['MYSQL_PASSWORD'] ?? '';
    final database = Platform.environment['MYSQL_DATABASE'] ?? '';
    if (database.isEmpty) {
      return null;
    }
    return MySqlConfig(
      host: host ?? 'localhost',
      port: port,
      user: user,
      password: password,
      database: database,
    );
  }
}

abstract class DataStore {
  factory DataStore.create({required String dataDirectory, MySqlConfig? mysql}) {
    if (mysql != null) {
      return MySqlDataStore(mysql);
    }
    return FileDataStore(dataDirectory: dataDirectory);
  }

  Future<BackendData> read();
  Future<void> save(BackendData data);
  Future<void> saveWithProgress(
    BackendData data, {
    void Function(String message)? onProgress,
  });
  Future<void> addUser(User user);
  Future<void> updateUser(User updated);
  Future<void> deleteUser(String id);
  Future<List<Place>> listPlaces();
  Future<void> savePlaces(List<Place> places);
  Future<void> upsertPlace(Place place);
  Future<void> deletePlace(String id);
  Future<User?> findByEmail(String email);
  Future<User?> findByPhone(String phone);
  Future<User?> findByUsername(String username);
  Future<User?> findByAccount(String account);
}

class FileDataStore implements DataStore {
  FileDataStore({required String dataDirectory})
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

  @override
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

  @override
  Future<void> save(BackendData data) async {
    await _ensureInitialized();
    await _file.writeAsString(_encoder.convert(data.toJson()));
  }

  @override
  Future<void> saveWithProgress(
    BackendData data, {
    void Function(String message)? onProgress,
  }) async {
    await save(data);
    onProgress?.call(
      '已寫入 JSON（users=${data.users.length}, places=${data.places.length}）',
    );
  }

  @override
  Future<void> addUser(User user) async {
    final data = await read();
    data.users.add(user);
    await save(data);
  }

  @override
  Future<void> updateUser(User updated) async {
    final data = await read();
    final index = data.users.indexWhere((u) => u.id == updated.id);
    if (index == -1) {
      throw StateError('User ${updated.id} not found');
    }
    data.users[index] = updated;
    await save(data);
  }

  @override
  Future<void> deleteUser(String id) async {
    final data = await read();
    data.users.removeWhere((u) => u.id == id);
    await save(data);
  }

  @override
  Future<List<Place>> listPlaces() async {
    final data = await read();
    return data.places;
  }

  @override
  Future<void> savePlaces(List<Place> places) async {
    final data = await read();
    data.places
      ..clear()
      ..addAll(places);
    await save(data);
  }

  @override
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

  @override
  Future<void> deletePlace(String id) async {
    final data = await read();
    data.places.removeWhere((p) => p.id == id);
    await save(data);
  }

  @override
  Future<User?> findByEmail(String email) async {
    final data = await read();
    return _find(data.users, (u) => u.email == email);
  }

  @override
  Future<User?> findByPhone(String phone) async {
    final data = await read();
    return _find(data.users, (u) => u.phone == phone);
  }

  @override
  Future<User?> findByUsername(String username) async {
    final lower = username.toLowerCase();
    final data = await read();
    return _find(data.users, (u) => u.username.toLowerCase() == lower);
  }

  @override
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

class MySqlDataStore implements DataStore {
  MySqlDataStore(this._config);

  final MySqlConfig _config;
  MySQLConnection? _connection;
  bool _initialized = false;

  Future<MySQLConnection> _ensureConnection() async {
    if (_connection != null) {
      return _connection!;
    }
    _connection = await MySQLConnection.createConnection(
      host: _config.host,
      port: _config.port,
      userName: _config.user,
      password: _config.password,
      databaseName: _config.database,
      secure: false,
    );
    await _connection!.connect();
    return _connection!;
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) {
      return;
    }
    final conn = await _ensureConnection();
    await conn.execute(
      '''
      CREATE TABLE IF NOT EXISTS users (
        id VARCHAR(64) PRIMARY KEY,
        username VARCHAR(64) NOT NULL,
        email VARCHAR(255) NOT NULL,
        phone VARCHAR(32) NOT NULL,
        password_hash VARCHAR(255) NOT NULL,
        created_at DATETIME NOT NULL
      )
      ''',
    );
    await _ensureIndex(conn, 'users', 'idx_users_username', 'username');
    await _ensureIndex(conn, 'users', 'idx_users_email', 'email');
    await _ensureIndex(conn, 'users', 'idx_users_phone', 'phone');
    await conn.execute(
      '''
      CREATE TABLE IF NOT EXISTS places (
        id VARCHAR(128) PRIMARY KEY,
        name VARCHAR(255) NOT NULL,
        tags JSON NOT NULL,
        city VARCHAR(64),
        address VARCHAR(255),
        lat DOUBLE,
        lng DOUBLE,
        description TEXT,
        image_url TEXT,
        rating DOUBLE,
        user_ratings_total INT
      )
      ''',
    );
    await _ensureColumn(conn, 'places', 'rating', 'DOUBLE');
    await _ensureColumn(conn, 'places', 'user_ratings_total', 'INT');
    _initialized = true;
  }

  @override
  Future<BackendData> read() async {
    await _ensureInitialized();
    final conn = await _ensureConnection();
    final userRows = await conn.execute(
      'SELECT id, username, email, phone, password_hash, created_at FROM users',
    );
    final users = userRows.rows.map<User>(_rowToUser).toList();
    final placeRows = await conn.execute(
      'SELECT id, name, tags, city, address, lat, lng, description, image_url, rating, user_ratings_total FROM places',
    );
    final places = placeRows.rows.map<Place>(_rowToPlace).toList();
    return BackendData(users: users, places: places);
  }

  @override
  Future<void> save(BackendData data) async {
    await _ensureInitialized();
    final conn = await _ensureConnection();
    await conn.execute('START TRANSACTION');
    try {
      await conn.execute('DELETE FROM users');
      await conn.execute('DELETE FROM places');
      for (final user in data.users) {
        await _insertUser(conn, user);
      }
      for (final place in data.places) {
        await _upsertPlace(conn, place);
      }
      await conn.execute('COMMIT');
    } catch (_) {
      await conn.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> saveWithProgress(
    BackendData data, {
    void Function(String message)? onProgress,
  }) async {
    await _ensureInitialized();
    final conn = await _ensureConnection();
    await conn.execute('START TRANSACTION');
    try {
      await conn.execute('DELETE FROM users');
      await conn.execute('DELETE FROM places');
      var count = 0;
      for (final user in data.users) {
        await _insertUser(conn, user);
        count += 1;
        if (count % 50 == 0) {
          onProgress?.call('已寫入 users：$count / ${data.users.length}');
        }
      }
      var placeCount = 0;
      for (final place in data.places) {
        await _upsertPlace(conn, place);
        placeCount += 1;
        if (placeCount % 100 == 0) {
          onProgress?.call('已寫入 places：$placeCount / ${data.places.length}');
        }
      }
      await conn.execute('COMMIT');
    } catch (_) {
      await conn.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> addUser(User user) async {
    await _ensureInitialized();
    final conn = await _ensureConnection();
    await _insertUser(conn, user);
  }

  @override
  Future<void> updateUser(User updated) async {
    await _ensureInitialized();
    final conn = await _ensureConnection();
    await conn.execute(
      '''
      UPDATE users
      SET username = :username, email = :email, phone = :phone, password_hash = :password_hash
      WHERE id = :id
      ''',
      {
        'username': updated.username,
        'email': updated.email,
        'phone': updated.phone,
        'password_hash': updated.passwordHash,
        'id': updated.id,
      },
    );
  }

  @override
  Future<void> deleteUser(String id) async {
    await _ensureInitialized();
    final conn = await _ensureConnection();
    await conn.execute(
      'DELETE FROM users WHERE id = :id',
      {'id': id},
    );
  }

  @override
  Future<List<Place>> listPlaces() async {
    await _ensureInitialized();
    final conn = await _ensureConnection();
    final rows = await conn.execute(
      'SELECT id, name, tags, city, address, lat, lng, description, image_url FROM places',
    );
    return rows.rows.map<Place>(_rowToPlace).toList();
  }

  @override
  Future<void> savePlaces(List<Place> places) async {
    await _ensureInitialized();
    final conn = await _ensureConnection();
    await conn.execute('START TRANSACTION');
    try {
      await conn.execute('DELETE FROM places');
      for (final place in places) {
        await _upsertPlace(conn, place);
      }
      await conn.execute('COMMIT');
    } catch (_) {
      await conn.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> upsertPlace(Place place) async {
    await _ensureInitialized();
    final conn = await _ensureConnection();
    await _upsertPlace(conn, place);
  }

  @override
  Future<void> deletePlace(String id) async {
    await _ensureInitialized();
    final conn = await _ensureConnection();
    await conn.execute(
      'DELETE FROM places WHERE id = :id',
      {'id': id},
    );
  }

  @override
  Future<User?> findByEmail(String email) async {
    await _ensureInitialized();
    final conn = await _ensureConnection();
    final rows = await conn.execute(
      'SELECT id, username, email, phone, password_hash, created_at FROM users WHERE LOWER(email) = :email LIMIT 1',
      {'email': email.toLowerCase()},
    );
    if (rows.rows.isEmpty) {
      return null;
    }
    return _rowToUser(rows.rows.first);
  }

  @override
  Future<User?> findByPhone(String phone) async {
    await _ensureInitialized();
    final conn = await _ensureConnection();
    final rows = await conn.execute(
      'SELECT id, username, email, phone, password_hash, created_at FROM users WHERE phone = :phone LIMIT 1',
      {'phone': phone},
    );
    if (rows.rows.isEmpty) {
      return null;
    }
    return _rowToUser(rows.rows.first);
  }

  @override
  Future<User?> findByUsername(String username) async {
    await _ensureInitialized();
    final conn = await _ensureConnection();
    final rows = await conn.execute(
      'SELECT id, username, email, phone, password_hash, created_at FROM users WHERE LOWER(username) = :username LIMIT 1',
      {'username': username.toLowerCase()},
    );
    if (rows.rows.isEmpty) {
      return null;
    }
    return _rowToUser(rows.rows.first);
  }

  @override
  Future<User?> findByAccount(String account) async {
    final trimmed = account.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final lower = trimmed.toLowerCase();
    await _ensureInitialized();
    final conn = await _ensureConnection();
    final rows = await conn.execute(
      '''
      SELECT id, username, email, phone, password_hash, created_at
      FROM users
      WHERE LOWER(username) = :account OR LOWER(email) = :account
      LIMIT 1
      ''',
      {'account': lower},
    );
    if (rows.rows.isEmpty) {
      return null;
    }
    return _rowToUser(rows.rows.first);
  }

  Future<void> _insertUser(
    MySQLConnection conn,
    User user,
  ) async {
    await conn.execute(
      '''
      INSERT INTO users (id, username, email, phone, password_hash, created_at)
      VALUES (:id, :username, :email, :phone, :password_hash, :created_at)
      ''',
      {
        'id': user.id,
        'username': user.username,
        'email': user.email,
        'phone': user.phone,
        'password_hash': user.passwordHash,
        'created_at': _formatDateTime(user.createdAt),
      },
    );
  }

  Future<void> _upsertPlace(
    MySQLConnection conn,
    Place place,
  ) async {
    await conn.execute(
      '''
      INSERT INTO places (id, name, tags, city, address, lat, lng, description, image_url, rating, user_ratings_total)
      VALUES (:id, :name, :tags, :city, :address, :lat, :lng, :description, :image_url, :rating, :user_ratings_total)
      ON DUPLICATE KEY UPDATE
        name = VALUES(name),
        tags = VALUES(tags),
        city = VALUES(city),
        address = VALUES(address),
        lat = VALUES(lat),
        lng = VALUES(lng),
        description = VALUES(description),
        image_url = VALUES(image_url),
        rating = VALUES(rating),
        user_ratings_total = VALUES(user_ratings_total)
      ''',
      {
        'id': place.id,
        'name': place.name,
        'tags': jsonEncode(place.tags),
        'city': place.city,
        'address': place.address,
        'lat': place.lat,
        'lng': place.lng,
        'description': place.description,
        'image_url': place.imageUrl,
        'rating': place.rating,
        'user_ratings_total': place.userRatingsTotal,
      },
    );
  }

  User _rowToUser(ResultSetRow row) {
    final createdAt = row.colByName('created_at');
    return User(
      id: row.colByName('id') ?? '',
      username: row.colByName('username') ?? '',
      email: (row.colByName('email') ?? '').toLowerCase(),
      phone: row.colByName('phone') ?? '',
      passwordHash: row.colByName('password_hash') ?? '',
      createdAt: _parseDateTime(createdAt),
    );
  }

  Place _rowToPlace(ResultSetRow row) {
    final rawTags = row.colByName('tags');
    final tags = _decodeTags(rawTags);
    final ratingValue = row.colByName('rating');
    final rating = ratingValue is num ? ratingValue.toDouble() : null;
    final totalValue = row.colByName('user_ratings_total');
    final total = totalValue is num ? totalValue.toInt() : null;
    return Place(
      id: row.colByName('id') ?? '',
      name: row.colByName('name') ?? '',
      tags: tags,
      city: row.colByName('city') ?? '',
      address: row.colByName('address') ?? '',
      lat: double.tryParse(row.colByName('lat') ?? '') ?? 0,
      lng: double.tryParse(row.colByName('lng') ?? '') ?? 0,
      description: row.colByName('description') ?? '',
      imageUrl: row.colByName('image_url') ?? '',
      rating: rating,
      userRatingsTotal: total,
    );
  }

  List<String> _decodeTags(dynamic raw) {
    if (raw == null) {
      return [];
    }
    if (raw is List) {
      return raw.whereType<String>().toList();
    }
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded.whereType<String>().toList();
        }
      } catch (_) {}
    }
    return [];
  }

  DateTime _parseDateTime(String? value) {
    if (value == null || value.isEmpty) {
      return DateTime.now().toUtc();
    }
    final normalized = value.contains('T') ? value : value.replaceFirst(' ', 'T');
    return DateTime.tryParse(normalized)?.toUtc() ?? DateTime.now().toUtc();
  }

  String _formatDateTime(DateTime value) {
    final dt = value.toUtc();
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min:$s';
  }

  Future<void> _ensureIndex(
    MySQLConnection conn,
    String table,
    String indexName,
    String column,
  ) async {
    final rows = await conn.execute(
      '''
      SELECT 1
      FROM INFORMATION_SCHEMA.STATISTICS
      WHERE TABLE_SCHEMA = :schema
        AND TABLE_NAME = :table
        AND INDEX_NAME = :index
      LIMIT 1
      ''',
      {
        'schema': _config.database,
        'table': table,
        'index': indexName,
      },
    );
    if (rows.rows.isNotEmpty) {
      return;
    }
    await conn.execute(
      'CREATE UNIQUE INDEX $indexName ON $table ($column)',
    );
  }

  Future<void> _ensureColumn(
    MySQLConnection conn,
    String table,
    String column,
    String type,
  ) async {
    final rows = await conn.execute(
      '''
      SELECT COLUMN_NAME
      FROM INFORMATION_SCHEMA.COLUMNS
      WHERE TABLE_SCHEMA = :schema
        AND TABLE_NAME = :table
        AND COLUMN_NAME = :column
      ''',
      {
        'schema': _config.database,
        'table': table,
        'column': column,
      },
    );
    if (rows.rows.isNotEmpty) {
      return;
    }
    await conn.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }
}
