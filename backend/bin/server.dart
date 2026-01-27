import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import 'package:smart_travel_backend/src/auth_service.dart';
import 'package:smart_travel_backend/src/data_store.dart';
import 'package:smart_travel_backend/src/exceptions.dart';
import 'package:smart_travel_backend/src/http_utils.dart';
import 'package:smart_travel_backend/src/models.dart';
import 'package:smart_travel_backend/src/notification_service.dart';

final _log = Logger('SmartTravelBackend');
late final bool _exposeDebugCodes;
late final String? _adminToken;
late final String? _adminUser;
late final String? _adminPass;
_CrawlJob? _crawlJob;

class _CrawlJob {
  _CrawlJob({
    required this.id,
    required this.mode,
    required this.process,
    required this.startedAt,
  });

  final String id;
  final String mode;
  final Process process;
  final DateTime startedAt;
  final List<String> logs = [];
  DateTime? finishedAt;
  int? exitCode;

  bool get running => exitCode == null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'mode': mode,
        'started_at': startedAt.toIso8601String(),
        'finished_at': finishedAt?.toIso8601String(),
        'exit_code': exitCode,
        'running': running,
        'logs': logs,
      };
}

Future<void> main(List<String> args) async {
  _configureLogging();

  final port = _resolvePort();
  final dataDir = _resolveDataDir();
  _exposeDebugCodes = _shouldExposeDebugCodes();
  _adminToken = Platform.environment['ADMIN_TOKEN'];
  _adminUser = Platform.environment['ADMIN_USERNAME'];
  _adminPass = Platform.environment['ADMIN_PASSWORD'];

  _log.info('Using data directory: $dataDir');
  _log.info(
    'Admin login enabled: ${_adminUser != null && _adminPass != null && _adminToken != null}',
  );

  final mysqlConfig = MySqlConfig.fromEnv();
  final store = DataStore.create(dataDirectory: dataDir, mysql: mysqlConfig);
  final notificationService = NotificationService();
  final authService = AuthService(
    store,
    notificationService: notificationService,
  );

  await _seedTestUser(store);

  final router = Router()
    ..get('/admin', _adminPageHandler)
    ..get('/admin/', _adminPageHandler)
    ..post('/api/admin/login', (req) => _json(req, (body) async {
          final username = _asString(body, 'username');
          final password = _asString(body, 'password');
          if (_adminUser == null || _adminPass == null) {
            throw ApiException(403, '未設定管理員帳密');
          }
          if (username != _adminUser || password != _adminPass) {
            throw ApiException(401, '帳號或密碼錯誤');
          }
          if (_adminToken == null || _adminToken!.isEmpty) {
            throw ApiException(500, '後台未設定 ADMIN_TOKEN');
          }
          return successBody(
            message: '登入成功',
            data: {'token': _adminToken},
          );
        }))
    ..get(
      '/api/admin/places',
      (req) => _withAdmin(req, () async {
        final data = await store.read();
        final query = req.url.queryParameters['q']?.trim().toLowerCase();
        final category = req.url.queryParameters['category']?.trim();
        final sort = req.url.queryParameters['sort']?.trim();
        var places = data.places;
        if (query != null && query.isNotEmpty) {
          places = places
              .where(
                (p) =>
                    p.name.toLowerCase().contains(query) ||
                    p.address.toLowerCase().contains(query) ||
                    p.city.toLowerCase().contains(query),
              )
              .toList();
        }
        if (category != null && category.isNotEmpty) {
          places = places.where((p) => p.tags.contains(category)).toList();
        }
        if (sort == 'latest') {
          places = List<Place>.from(places.reversed);
        } else if (sort == 'oldest') {
          places = List<Place>.from(places);
        } else if (sort == 'name') {
          places = List<Place>.from(places)
            ..sort((a, b) => a.name.compareTo(b.name));
        } else if (sort == 'city') {
          places = List<Place>.from(places)
            ..sort((a, b) {
              final cityCmp = a.city.compareTo(b.city);
              if (cityCmp != 0) return cityCmp;
              return a.name.compareTo(b.name);
            });
        }
        return jsonResponse(
          200,
          successBody(data: {'places': places.map((p) => p.toJson()).toList()}),
        );
      }),
    )
    ..post(
      '/api/admin/places',
      (req) => _withAdmin(req, () async {
        final body = await parseJsonBody(req);
          final place = _placeFromBody(body, fallbackId: const Uuid().v4());
        await store.upsertPlace(place);
        return jsonResponse(
          200,
          successBody(message: '已新增景點', data: place.toJson()),
        );
      }),
    )
    ..put(
      '/api/admin/places/<id>',
      (req, String id) => _withAdmin(req, () async {
        final body = await parseJsonBody(req);
          final place = _placeFromBody(body, fallbackId: id);
        await store.upsertPlace(place);
        return jsonResponse(
          200,
          successBody(message: '已更新景點', data: place.toJson()),
        );
      }),
    )
    ..delete(
      '/api/admin/places/<id>',
      (req, String id) => _withAdmin(req, () async {
        await store.deletePlace(id);
        return jsonResponse(200, successBody(message: '已刪除景點'));
      }),
    )
    ..post(
      '/api/admin/places/import',
      (req) => _withAdmin(req, () async {
        final body = await parseJsonBody(req);
        final raw = body['places'];
        if (raw is! List) {
          throw ApiException(400, 'places 格式錯誤');
        }
        final places = raw
            .whereType<Map<String, dynamic>>()
            .map(Place.fromJson)
            .toList();
        await store.savePlaces(places);
        return jsonResponse(
          200,
          successBody(message: '已匯入景點', data: {'count': places.length}),
        );
      }),
    )
    ..get(
      '/api/admin/export',
      (req) => _withAdmin(req, () async {
        final data = await store.read();
        return jsonResponse(200, data.toJson());
      }),
    )
    ..get(
      '/api/admin/users',
      (req) => _withAdmin(req, () async {
        final data = await store.read();
        return jsonResponse(
          200,
          successBody(
            data: {'users': data.users.map((u) => u.toPublicJson()).toList()},
          ),
        );
      }),
    )
    ..get(
      '/api/admin/place-reviews',
      (req) => _withAdmin(req, () async {
        final name = req.url.queryParameters['name']?.trim();
        if (name == null || name.isEmpty) {
          throw ApiException(400, '請提供景點名稱');
        }
        final file = File(p.join(_resolveDataDir(), 'places_with_reviews.json'));
        if (!file.existsSync()) {
          throw ApiException(404, '尚未產生評論資料');
        }
        final raw = jsonDecode(await file.readAsString());
        if (raw is! List) {
          throw ApiException(500, '評論資料格式錯誤');
        }
        Map<String, dynamic>? match;
        for (final item in raw.whereType<Map<String, dynamic>>()) {
          final sourceName = (item['source_name'] as String?)?.trim();
          final itemName = (item['name'] as String?)?.trim();
          if (sourceName == name || itemName == name) {
            match = item;
            break;
          }
        }
        if (match == null) {
          throw ApiException(404, '找不到評論');
        }
        return jsonResponse(
          200,
          successBody(
            data: {
              'reviews': match['reviews'] ?? [],
              'editorial_summary': match['editorial_summary'] ?? '',
              'types': match['types'] ?? [],
              'rating': match['rating'],
              'user_ratings_total': match['user_ratings_total'],
            },
          ),
        );
      }),
    )
    ..post(
      '/api/admin/crawl/start',
      (req) => _withAdmin(req, () async {
        final body = await parseJsonBody(req);
        final mode = _asString(body, 'mode');
        if (_crawlJob != null && _crawlJob!.running) {
          throw ApiException(409, '已有爬取進行中');
        }
        final script = switch (mode) {
          'places' => 'fetch_places.py',
          'reviews' => 'fetch_places_with_reviews.py',
          'merge_tags' => 'merge_tags_from_reviews.py',
          'google_places' => 'fetch_places_from_google.py',
          _ => throw ApiException(400, '未知的爬取模式'),
        };
        final scriptPath = p.join(
          _resolveDataDir(),
          '..',
          'scripts',
          script,
        );
        if (!File(scriptPath).existsSync()) {
          throw ApiException(404, '找不到爬取腳本');
        }
        final process = await Process.start(
          'python3',
          [scriptPath],
          workingDirectory: p.dirname(scriptPath),
          environment: {
            ...Platform.environment,
            'PYTHONUNBUFFERED': '1',
            'PYTHONIOENCODING': 'utf-8',
          },
        );
        final job = _CrawlJob(
          id: const Uuid().v4(),
          mode: mode,
          process: process,
          startedAt: DateTime.now(),
        );
        _crawlJob = job;
        _captureProcessLogs(job, process);
        return jsonResponse(200, successBody(message: '已開始爬取', data: job.toJson()));
      }),
    )
    ..post(
      '/api/admin/crawl/stop',
      (req) => _withAdmin(req, () async {
        final job = _crawlJob;
        if (job == null || !job.running) {
          return jsonResponse(200, successBody(message: '目前沒有爬取進行中'));
        }
        job.process.kill(ProcessSignal.sigterm);
        return jsonResponse(200, successBody(message: '已送出停止指令'));
      }),
    )
    ..get(
      '/api/admin/crawl/status',
      (req) => _withAdmin(req, () async {
        final job = _crawlJob;
        if (job == null) {
          return jsonResponse(200, successBody(data: {'running': false}));
        }
        return jsonResponse(200, successBody(data: job.toJson()));
      }),
    )
    ..delete(
      '/api/admin/users/<id>',
      (req, String id) => _withAdmin(req, () async {
        await store.deleteUser(id);
        return jsonResponse(200, successBody(message: '已刪除使用者'));
      }),
    )
    ..get('/health', _healthHandler)
    ..post(
      '/api/auth/send-email-code',
      (req) => _json(req, (body) async {
        final result = await authService.sendEmailCode(
          _asString(body, 'email'),
        );
        return successBody(
          message: '驗證碼已寄出',
          data: result.toJson(includeDebugCode: _exposeDebugCodes),
        );
      }),
    )
    ..post(
      '/api/auth/verify-email-code',
      (req) => _json(req, (body) async {
        await authService.verifyEmailCode(
          _asString(body, 'email'),
          _asString(body, 'code'),
        );
        return successBody(message: 'Email 驗證成功');
      }),
    )
    ..post(
      '/api/auth/send-sms-code',
      (req) => _json(req, (body) async {
        final result = await authService.sendSmsCode(_asString(body, 'phone'));
        return successBody(
          message: '簡訊驗證碼已寄出',
          data: result.toJson(includeDebugCode: _exposeDebugCodes),
        );
      }),
    )
    ..post(
      '/api/auth/verify-sms-code',
      (req) => _json(req, (body) async {
        await authService.verifySmsCode(
          _asString(body, 'phone'),
          _asString(body, 'code'),
        );
        return successBody(message: '手機驗證成功');
      }),
    )
    ..post(
      '/api/auth/register',
      (req) => _json(req, (body) async {
        final user = await authService.register(
          username: _asString(body, 'username'),
          email: _asString(body, 'email'),
          phone: _asString(body, 'phone'),
          password: _asString(body, 'password'),
        );
        return successBody(
          message: '註冊成功',
          data: {'user': user.toPublicJson()},
        );
      }),
    )
    ..post(
      '/api/auth/login',
      (req) => _json(req, (body) async {
        final user = await authService.login(
          account: _asString(body, 'account'),
          password: _asString(body, 'password'),
        );
        return successBody(
          message: '登入成功',
          data: {'user': user.toPublicJson()},
        );
      }),
    )
    ..post(
      '/api/auth/reset-password/code',
      (req) => _json(req, (body) async {
        final result = await authService.sendPasswordResetCode(
          account: _asString(body, 'account'),
          email: _asString(body, 'email'),
        );
        return successBody(
          message: '重設密碼驗證碼已寄出',
          data: result.toJson(includeDebugCode: _exposeDebugCodes),
        );
      }),
    )
    ..post(
      '/api/auth/reset-password/verify',
      (req) => _json(req, (body) async {
        await authService.verifyPasswordResetCode(
          account: _asString(body, 'account'),
          email: _asString(body, 'email'),
          code: _asString(body, 'code'),
        );
        return successBody(message: '驗證成功');
      }),
    )
    ..post(
      '/api/auth/reset-password/complete',
      (req) => _json(req, (body) async {
        final user = await authService.completePasswordReset(
          account: _asString(body, 'account'),
          email: _asString(body, 'email'),
          code: _asString(body, 'code'),
          newPassword: _asString(body, 'newPassword'),
        );
        return successBody(
          message: '密碼已更新，請使用新密碼登入',
          data: {'user': user.toPublicJson()},
        );
      }),
    )
    ..post(
      '/api/travel/preferences',
      (req) => _json(req, (body) async {
        final interests =
            (body['interests'] as List?)?.whereType<String>().toList() ??
            const [];
        return successBody(message: '已接收興趣偏好', data: {'saved': interests});
      }),
    )
    ..post(
      '/api/travel/plans',
      (req) => _json(req, (body) async {
        final interests =
            (body['interests'] as List?)?.whereType<String>().toList() ??
            const [];
        final plan = [
          {
            'title': 'Day 1',
            'items': interests
                .map((id) => {'spot': id, 'time': '10:00'})
                .toList(),
          },
        ];
        return successBody(message: '行程已生成（測試資料）', data: {'plan': plan});
      }),
    );

  final pipeline = const Pipeline()
      .addMiddleware(
        logRequests(
          logger: (message, isError) {
            if (isError) {
              _log.severe(message);
            } else {
              _log.info(message);
            }
          },
        ),
      )
      .addMiddleware(_corsMiddleware())
      .addHandler(router);

  final server = await shelf_io.serve(pipeline, InternetAddress.anyIPv4, port);
  server.autoCompress = true;
  _log.info('Backend API 已啟動，正在監聽 http://localhost:${server.port}');
}

void _captureProcessLogs(_CrawlJob job, Process process) {
  const maxLines = 200;
  void addLine(String line) {
    if (line.trim().isEmpty) return;
    job.logs.add(line);
    if (job.logs.length > maxLines) {
      job.logs.removeAt(0);
    }
  }

  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(addLine);
  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) => addLine('[ERR] $line'));

  process.exitCode.then((code) {
    job.exitCode = code;
    job.finishedAt = DateTime.now();
    _log.info('Crawl job ${job.id} finished with exit code $code');
  });
}

Future<Response> _healthHandler(Request request) async {
  return jsonResponse(
    200,
    successBody(
      data: {
        'status': 'ok',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      },
    ),
  );
}

Future<Response> _json(
  Request request,
  Future<Map<String, dynamic>> Function(Map<String, dynamic> body) handler,
) async {
  return _handle(() async {
    final body = await parseJsonBody(request);
    return jsonResponse(200, await handler(body));
  });
}

Future<Response> _handle(Future<Response> Function() action) async {
  try {
    return await action();
  } on ApiException catch (error) {
    return jsonResponse(
      error.statusCode,
      errorBody(error.message, details: error.details),
    );
  } catch (error, stack) {
    _log.severe('未預期錯誤: $error', error, stack);
    return jsonResponse(500, errorBody('伺服器發生錯誤，請稍後再試'));
  }
}

Future<Response> _withAdmin(
  Request request,
  Future<Response> Function() action,
) async {
  if (_adminToken == null || _adminToken!.isEmpty) {
    return jsonResponse(403, errorBody('後台未設定 ADMIN_TOKEN'));
  }
  final token = request.headers['x-admin-token'];
  if (token != _adminToken) {
    return jsonResponse(401, errorBody('未授權'));
  }
  return _handle(action);
}

Future<Response> _adminPageHandler(Request request) async {
  final file = File(p.join(_resolveDataDir(), '..', 'web', 'admin.html'));
  if (!await file.exists()) {
    return Response.notFound('admin.html not found');
  }
  final html = await file.readAsString();
  return Response.ok(
    html,
    headers: {'Content-Type': 'text/html; charset=utf-8'},
  );
}

Place _placeFromBody(Map<String, dynamic> body, {required String fallbackId}) {
  final rawTags = body['tags'];
  final tags = rawTags is List ? rawTags.whereType<String>().toList() : <String>[];
  final fallbackCategory = body['category'] as String?;
  if (tags.isEmpty && fallbackCategory != null && fallbackCategory.isNotEmpty) {
    tags.add(fallbackCategory);
  }
  return Place(
    id: body['id'] as String? ?? fallbackId,
    name: body['name'] as String? ?? '',
    tags: tags,
    city: body['city'] as String? ?? '',
    address: body['address'] as String? ?? '',
    lat: (body['lat'] as num?)?.toDouble() ?? 0,
    lng: (body['lng'] as num?)?.toDouble() ?? 0,
    description: body['description'] as String? ?? '',
    imageUrl: body['imageUrl'] as String? ?? '',
  );
}

String _asString(Map<String, dynamic> body, String key) {
  final value = body[key];
  if (value == null) {
    return '';
  }
  return value.toString();
}

int _resolvePort() {
  final env = Platform.environment['PORT'];
  if (env == null) {
    return 8080;
  }
  return int.tryParse(env) ?? 8080;
}

String _resolveDataDir() {
  final override = Platform.environment['SMART_TRAVEL_DATA_DIR'];
  if (override != null && override.trim().isNotEmpty) {
    return override;
  }
  final scriptDir = Directory.fromUri(Platform.script).parent;
  final dataPath = p.normalize(p.join(scriptDir.path, '..', 'data'));
  return dataPath;
}

bool _shouldExposeDebugCodes() {
  final flag = Platform.environment['SMART_TRAVEL_EXPOSE_CODES'];
  if (flag == null) {
    return true;
  }
  return flag.toLowerCase() == 'true' || flag == '1';
}

void _configureLogging() {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print(
      '[${record.level.name}] ${record.time.toIso8601String()} ${record.loggerName}: ${record.message}',
    );
    if (record.error != null) {
      // ignore: avoid_print
      print('  error: ${record.error}');
    }
    if (record.stackTrace != null) {
      // ignore: avoid_print
      print('  stack: ${record.stackTrace}');
    }
  });
}

Future<void> _seedTestUser(DataStore store) async {
  const username = 'testuser';
  const email = 'test@example.com';
  const password = 'test1234';

  final existingByName = await store.findByUsername(username);
  final existingByEmail = await store.findByEmail(email);
  if (existingByName != null || existingByEmail != null) {
    _log.info('Seed user already exists, skipping.');
    return;
  }

  final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  final hashed = AuthService.hashPasswordWithSalt(password, salt);
  final user = User(
    id: const Uuid().v4(),
    username: username,
    email: email,
    phone: '',
    passwordHash: hashed,
    createdAt: DateTime.now().toUtc(),
  );
  await store.addUser(user);
  _log.info(
    'Seed user created: account="$username" / email="$email" / password="$password"',
  );
}

Middleware _corsMiddleware() {
  const corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Origin, Content-Type, Accept',
    'Access-Control-Allow-Methods': 'GET,POST,PUT,PATCH,DELETE,OPTIONS',
  };
  return (innerHandler) {
    return (request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: corsHeaders);
      }
      final response = await innerHandler(request);
      return response.change(headers: corsHeaders);
    };
  };
}
