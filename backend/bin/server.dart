import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
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
String? _syncSourceUrl;
String? _syncSourceToken;
String? _localSyncUrl;
String? _localSyncToken;
String? _openAiApiKey;
String? _openAiBaseUrl;
String? _openAiModel;
String? _lineChannelSecret;
String? _lineAddFriendUrl;
String? _reminderCronToken;
late final String _dataStoreLabel;
late final String? _adminToken;
late final String? _adminUser;
late final String? _adminPass;
late final String _dataDir;
late final _ItineraryLearningProfile _itineraryLearningProfile;
late final DataStore _store;
late final NotificationService _notificationService;
_CrawlJob? _crawlJob;
final Map<String, _LineLinkCode> _lineLinkCodes = {};
final Map<String, DateTime> _lineContextPushCooldown = {};
final Map<String, int> _requestPathCounts = {};
final List<Map<String, dynamic>> _recentRequestLogs = [];
final List<Map<String, dynamic>> _linePushHistory = [];
final List<Map<String, dynamic>> _reminderRunHistory = [];
final List<Map<String, dynamic>> _appEventHistory = [];
int _totalRequestCount = 0;
int _totalErrorCount = 0;

class _ItineraryLearningProfile {
  const _ItineraryLearningProfile({
    required this.globalTagWeights,
    required this.interestTagWeights,
    required this.tripPurposeTagWeights,
    required this.travelBehaviorTagWeights,
    required this.priceAffinity,
    required this.metadata,
    required this.sourcePath,
  });

  final Map<String, double> globalTagWeights;
  final Map<String, Map<String, double>> interestTagWeights;
  final Map<String, Map<String, double>> tripPurposeTagWeights;
  final Map<String, Map<String, double>> travelBehaviorTagWeights;
  final Map<String, Map<String, double>> priceAffinity;
  final Map<String, dynamic> metadata;
  final String? sourcePath;

  static const empty = _ItineraryLearningProfile(
    globalTagWeights: <String, double>{},
    interestTagWeights: <String, Map<String, double>>{},
    tripPurposeTagWeights: <String, Map<String, double>>{},
    travelBehaviorTagWeights: <String, Map<String, double>>{},
    priceAffinity: <String, Map<String, double>>{},
    metadata: <String, dynamic>{},
    sourcePath: null,
  );

  bool get enabled =>
      globalTagWeights.isNotEmpty ||
      interestTagWeights.isNotEmpty ||
      tripPurposeTagWeights.isNotEmpty ||
      travelBehaviorTagWeights.isNotEmpty ||
      priceAffinity.isNotEmpty;

  factory _ItineraryLearningProfile.load(String dataDir) {
    final file = File(p.join(dataDir, 'itinerary_ranker_weights.json'));
    if (!file.existsSync()) {
      return _ItineraryLearningProfile.empty;
    }
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) {
        return _ItineraryLearningProfile.empty;
      }
      final json = Map<String, dynamic>.from(raw);
      return _ItineraryLearningProfile(
        globalTagWeights: _doubleMapFromJson(json['globalTagWeights']),
        interestTagWeights: _nestedDoubleMapFromJson(json['interestTagWeights']),
        tripPurposeTagWeights: _nestedDoubleMapFromJson(
          json['tripPurposeTagWeights'],
        ),
        travelBehaviorTagWeights: _nestedDoubleMapFromJson(
          json['travelBehaviorTagWeights'],
        ),
        priceAffinity: _nestedDoubleMapFromJson(json['priceAffinity']),
        metadata: json['metadata'] is Map
            ? Map<String, dynamic>.from(json['metadata'] as Map)
            : const <String, dynamic>{},
        sourcePath: file.path,
      );
    } catch (error, stack) {
      _log.warning('Failed to load itinerary learning profile: $error');
      _log.fine('$stack');
      return _ItineraryLearningProfile.empty;
    }
  }

  double scoreBoost(
    Place place, {
    required Set<String> preferredTags,
    required String? targetPrice,
    required _PlannerWeights weights,
  }) {
    if (!enabled) return 0;
    final tags = place.tags.map((tag) => tag.trim().toLowerCase()).toSet()
      ..removeWhere((tag) => tag.isEmpty);
    if (tags.isEmpty && (targetPrice == null || targetPrice.trim().isEmpty)) {
      return 0;
    }

    var score = 0.0;
    for (final tag in tags) {
      score += (globalTagWeights[tag] ?? 0) * 0.10;
      score +=
          (tripPurposeTagWeights[weights.tripPurpose]?[tag] ?? 0) * 0.45;
      score +=
          (travelBehaviorTagWeights[weights.travelBehavior]?[tag] ?? 0) * 0.30;
    }
    for (final interest in preferredTags) {
      final affinity = interestTagWeights[interest.toLowerCase()];
      if (affinity == null) continue;
      for (final tag in tags) {
        score += (affinity[tag] ?? 0) * 0.50;
      }
    }
    final normalizedTargetPrice = targetPrice?.trim().toLowerCase();
    final category = _effectivePriceCategory(place)?.trim().toLowerCase();
    if (normalizedTargetPrice != null &&
        normalizedTargetPrice.isNotEmpty &&
        category != null &&
        category.isNotEmpty) {
      score +=
          (priceAffinity[normalizedTargetPrice]?[category] ?? 0) * 0.65;
    }
    return score.clamp(-2.5, 2.5);
  }
}

class _CrawlJob {
  _CrawlJob({
    required this.id,
    required this.mode,
    required this.startedAt,
    this.profile,
    this.city,
    List<String>? cities,
  }) : cities = List<String>.unmodifiable(cities ?? const []);

  final String id;
  final String mode;
  final String? profile;
  final DateTime startedAt;
  final String? city;
  final List<String> cities;
  final List<String> logs = [];
  final List<Map<String, dynamic>> cityRuns = [];
  Process? process;
  String? currentCity;
  bool stopRequested = false;
  int completedCities = 0;
  int succeededCities = 0;
  int failedCities = 0;
  DateTime? finishedAt;
  int? exitCode;
  DateTime? syncStartedAt;
  DateTime? syncFinishedAt;
  bool? syncOk;
  String? syncMessage;
  int? syncedPlaces;

  bool get running => finishedAt == null;
  bool get batchMode => cities.length > 1;
  int get totalCities => cities.length;

  Map<String, dynamic> toJson() => {
    'id': id,
    'mode': mode,
    'profile': profile,
    'city': city,
    'cities': cities,
    'batch_mode': batchMode,
    'current_city': currentCity,
    'completed_cities': completedCities,
    'succeeded_cities': succeededCities,
    'failed_cities': failedCities,
    'stop_requested': stopRequested,
    'started_at': startedAt.toIso8601String(),
    'finished_at': finishedAt?.toIso8601String(),
    'exit_code': exitCode,
    'running': running,
    'sync_started_at': syncStartedAt?.toIso8601String(),
    'sync_finished_at': syncFinishedAt?.toIso8601String(),
    'sync_ok': syncOk,
    'sync_message': syncMessage,
    'synced_places': syncedPlaces,
    'city_runs': cityRuns,
    'logs': logs,
  };
}

class _LineLinkCode {
  _LineLinkCode({
    required this.code,
    required this.userId,
    required this.createdAt,
    required this.expiresAt,
  });

  final String code;
  final String userId;
  final DateTime createdAt;
  final DateTime expiresAt;

  bool get expired => DateTime.now().isAfter(expiresAt);

  Map<String, dynamic> toJson({String? addFriendUrl}) => {
    'code': code,
    'createdAt': createdAt.toIso8601String(),
    'expiresAt': expiresAt.toIso8601String(),
    if (addFriendUrl != null && addFriendUrl.isNotEmpty)
      'addFriendUrl': addFriendUrl,
  };
}

class _RouteFeasibilityDecision {
  const _RouteFeasibilityDecision({
    required this.shouldBlock,
    required this.message,
    this.reasons = const [],
    this.suggestions = const [],
    this.metrics,
  });

  final bool shouldBlock;
  final String message;
  final List<String> reasons;
  final List<String> suggestions;
  final Map<String, dynamic>? metrics;

  Map<String, dynamic> toJson() => {
    'code': 'route_not_feasible',
    'shouldBlock': shouldBlock,
    'reasons': reasons,
    'suggestions': suggestions,
    if (metrics != null) 'metrics': metrics,
  };
}

class _ContextFocus {
  const _ContextFocus({
    required this.targetIndex,
    required this.targetItem,
    required this.phase,
    this.currentMinute,
  });

  final int targetIndex;
  final Map<String, dynamic> targetItem;
  final String phase;
  final int? currentMinute;
}

Future<void> main(List<String> args) async {
  _configureLogging();

  final port = _resolvePort();
  _dataDir = _resolveDataDir();
  _exposeDebugCodes = _shouldExposeDebugCodes();
  _adminToken = Platform.environment['ADMIN_TOKEN'];
  _adminUser = Platform.environment['ADMIN_USERNAME'];
  _adminPass = Platform.environment['ADMIN_PASSWORD'];
  _syncSourceUrl = Platform.environment['SYNC_SOURCE_URL'];
  _syncSourceToken = Platform.environment['SYNC_SOURCE_TOKEN'];
  _localSyncUrl = Platform.environment['LOCAL_SYNC_URL'];
  _localSyncToken = Platform.environment['LOCAL_SYNC_TOKEN'];
  _openAiApiKey = Platform.environment['OPENAI_API_KEY'];
  _openAiBaseUrl = Platform.environment['OPENAI_BASE_URL'];
  _openAiModel = Platform.environment['OPENAI_MODEL'] ?? 'gpt-4o-mini';
  _lineChannelSecret = Platform.environment['LINE_CHANNEL_SECRET'];
  _lineAddFriendUrl = Platform.environment['LINE_ADD_FRIEND_URL'];
  _reminderCronToken = Platform.environment['REMINDER_CRON_TOKEN'];
  _itineraryLearningProfile = _ItineraryLearningProfile.load(_dataDir);

  _log.info('Using data directory: $_dataDir');
  _log.info(
    'Admin login enabled: ${_adminUser != null && _adminPass != null && _adminToken != null}',
  );
  _log.info(
    'GPT itinerary explanation enabled: ${_openAiApiKey != null && _openAiApiKey!.isNotEmpty}',
  );
  _log.info(
    'Itinerary learning profile enabled: ${_itineraryLearningProfile.enabled}'
    '${_itineraryLearningProfile.sourcePath != null ? ' (${_itineraryLearningProfile.sourcePath})' : ''}',
  );

  final postgresConfig = PostgresConfig.fromEnv();
  final mysqlConfig = MySqlConfig.fromEnv();
  if (postgresConfig != null) {
    _dataStoreLabel = 'postgres';
    _log.info(
      'Data store: Postgres host=${postgresConfig.host} db=${postgresConfig.database} ssl=${postgresConfig.useSsl}',
    );
  } else if (mysqlConfig != null) {
    _dataStoreLabel = 'mysql';
    _log.info(
      'Data store: MySQL host=${mysqlConfig.host}:${mysqlConfig.port} db=${mysqlConfig.database}',
    );
  } else {
    _dataStoreLabel = 'json';
    _log.info('Data store: Local JSON (db.json)');
  }
  final store = DataStore.create(
    dataDirectory: _dataDir,
    mysql: mysqlConfig,
    postgres: postgresConfig,
  );
  _store = store;
  final notificationService = NotificationService();
  _notificationService = notificationService;
  final authService = AuthService(
    store,
    notificationService: notificationService,
  );

  await _seedTestUser(store);

  final router = Router()
    ..get('/admin', _adminPageHandler)
    ..get('/admin/', _adminPageHandler)
    ..get(
      '/api/places',
      (req) => _json(req, (_) async {
        final data = await store.read();
        final query = req.url.queryParameters['q']?.trim().toLowerCase();
        final tagsParam = req.url.queryParameters['tags']?.trim();
        final city = req.url.queryParameters['city']?.trim();
        final sort = req.url.queryParameters['sort']?.trim();
        final limit = int.tryParse(req.url.queryParameters['limit'] ?? '');
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
        if (city != null && city.isNotEmpty) {
          places = places.where((p) => p.city.contains(city)).toList();
        }
        if (tagsParam != null && tagsParam.isNotEmpty) {
          final tagsRaw = tagsParam.toString();
          final tags = tagsRaw
              .split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toSet();
          if (tags.isNotEmpty) {
            places = places
                .where((p) => p.tags.any((tag) => tags.contains(tag)))
                .toList();
          }
        }
        if (sort == 'latest') {
          places = _sortPlacesByLatest(places);
        } else if (sort == 'oldest') {
          places = _sortPlacesByOldest(places);
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
        } else if (sort == 'rating') {
          places = List<Place>.from(places)
            ..sort((a, b) {
              final ar = a.rating ?? 0;
              final br = b.rating ?? 0;
              return br.compareTo(ar);
            });
        }
        if (limit != null && limit > 0 && places.length > limit) {
          places = places.take(limit).toList();
        }
        places = await _backfillVisiblePlaces(store, places);
        return successBody(
          data: {'places': places.map(_placeToApiJson).toList()},
        );
      }),
    )
    ..post(
      '/api/meal-suggestions',
      (req) => _json(req, (body) async {
        final previous = body['previous'];
        final next = body['next'];
        final query = _asString(body, 'query').trim();
        final mealType = _asString(body, 'mealType').trim().toLowerCase();
        final city = _asString(body, 'city').trim();
        final limit = (_asInt(body, 'limit') ?? 12).clamp(1, 20);

        final previousMap = previous is Map
            ? Map<String, dynamic>.from(previous)
            : const <String, dynamic>{};
        final nextMap = next is Map
            ? Map<String, dynamic>.from(next)
            : const <String, dynamic>{};

        final suggestions = await _fetchLiveMealSuggestions(
          previous: previousMap,
          next: nextMap,
          query: query,
          mealType: mealType,
          city: city,
          limit: limit,
        );
        return successBody(
          message: '已取得餐廳候選',
          data: {'places': suggestions},
        );
      }),
    )
    ..post(
      '/api/analytics/events',
      (req) => _json(req, (body) async {
        final event = _asString(body, 'event').trim();
        final page = _asString(body, 'page').trim();
        final userId = _asString(body, 'userId').trim();
        final sessionId = _asString(body, 'sessionId').trim();
        final payload = body['payload'] is Map
            ? Map<String, dynamic>.from(body['payload'] as Map)
            : <String, dynamic>{};
        if (event.isEmpty) {
          throw ApiException(400, '缺少事件名稱');
        }
        _recordAppEvent(
          request: req,
          event: event,
          page: page.isEmpty ? null : page,
          userId: userId.isEmpty ? null : userId,
          sessionId: sessionId.isEmpty ? null : sessionId,
          payload: payload,
        );
        return successBody(message: '事件已記錄');
      }),
    )
    ..post(
      '/api/admin/login',
      (req) => _json(req, (body) async {
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
        return successBody(message: '登入成功', data: {'token': _adminToken});
      }),
    )
    ..get(
      '/api/admin/places',
      (req) => _withAdmin(req, () async {
        final data = await store.read();
        final query = req.url.queryParameters['q']?.trim().toLowerCase();
        final category = req.url.queryParameters['category']?.trim();
        final tagsParam = req.url.queryParameters['tags']?.trim();
        final sort = req.url.queryParameters['sort']?.trim();
        final onlyRecent =
            req.url.queryParameters['recent'] == '1' ||
            req.url.queryParameters['recent'] == 'true';
        final onlyIncomplete =
            req.url.queryParameters['incomplete'] == '1' ||
            req.url.queryParameters['incomplete'] == 'true';
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
        final combinedTags =
            [if (category != null) category, if (tagsParam != null) tagsParam]
                .join(',')
                .split(',')
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toSet();
        if (combinedTags.isNotEmpty) {
          places = places
                .where((p) => p.tags.any((tag) => combinedTags.contains(tag)))
              .toList();
        }
        if (onlyRecent) {
          places = places.where(_isRecentPlaceUpdate).toList();
        }
        if (onlyIncomplete) {
          places = places.where(_isPlaceIncomplete).toList();
        }
        if (sort == 'latest') {
          places = _sortPlacesByLatest(places);
        } else if (sort == 'oldest') {
          places = _sortPlacesByOldest(places);
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
        } else if (sort == 'rating') {
          places = List<Place>.from(places)
            ..sort((a, b) {
              final ar = a.rating ?? 0;
              final br = b.rating ?? 0;
              return br.compareTo(ar);
            });
        }
        places = await _backfillVisiblePlaces(store, places);
        return jsonResponse(
          200,
          successBody(data: {'places': places.map(_placeToApiJson).toList()}),
        );
      }),
    )
    ..post(
      '/api/admin/places',
      (req) => _withAdmin(req, () async {
        final body = await parseJsonBody(req);
        final place = _normalizePlaceForStorage(
          _placeFromBody(body, fallbackId: const Uuid().v4()),
        );
        await store.upsertPlace(place);
        return jsonResponse(
          200,
          successBody(message: '已新增景點', data: _placeToApiJson(place)),
        );
      }),
    )
    ..put(
      '/api/admin/places/<id>',
      (req, String id) => _withAdmin(req, () async {
        final body = await parseJsonBody(req);
        final place = _normalizePlaceForStorage(
          _placeFromBody(body, fallbackId: id),
        );
        await store.upsertPlace(place);
        return jsonResponse(
          200,
          successBody(message: '已更新景點', data: _placeToApiJson(place)),
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
        final count = await _mergePlacesToStore(store, places);
        return jsonResponse(
          200,
          successBody(message: '已合併匯入景點', data: {'count': count}),
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
    ..post(
      '/api/admin/sync-from-remote',
      (req) => _withAdmin(req, () async {
        if (_syncSourceUrl == null || _syncSourceUrl!.trim().isEmpty) {
          throw ApiException(400, '尚未設定 SYNC_SOURCE_URL');
        }
        if (_syncSourceToken == null || _syncSourceToken!.trim().isEmpty) {
          throw ApiException(400, '尚未設定 SYNC_SOURCE_TOKEN');
        }
        final exportUri = Uri.parse(
          _syncSourceUrl!,
        ).resolve('/api/admin/export');
        final client = HttpClient();
        try {
          final request = await client.getUrl(exportUri);
          request.headers.set('x-admin-token', _syncSourceToken!);
          final response = await request.close();
          final body = await response.transform(utf8.decoder).join();
          if (response.statusCode >= 400) {
            throw ApiException(
              response.statusCode,
              '雲端匯出失敗 (${response.statusCode})',
            );
          }
          final decoded = jsonDecode(body);
          if (decoded is! Map<String, dynamic>) {
            throw ApiException(500, '雲端回傳格式錯誤');
          }
          final data = decoded['data'] is Map<String, dynamic>
              ? decoded['data'] as Map<String, dynamic>
              : decoded;
          final rawPlaces = data['places'];
          if (rawPlaces is! List) {
            throw ApiException(500, '雲端資料缺少 places');
          }
          final places = rawPlaces
              .whereType<Map<String, dynamic>>()
              .map(Place.fromJson)
              .toList();
          final count = await _mergePlacesToStore(store, places);
          return jsonResponse(
            200,
            successBody(message: '同步完成（合併模式）', data: {'count': count}),
          );
        } finally {
          client.close(force: true);
        }
      }),
    )
    ..post(
      '/api/admin/import-from-file',
      (req) => _withAdmin(req, () async {
        final file = File(p.join(_dataDir, 'db.json'));
        if (!file.existsSync()) {
          throw ApiException(404, '找不到 db.json，請先執行爬取');
        }
        final raw = jsonDecode(await file.readAsString());
        if (raw is! Map<String, dynamic>) {
          throw ApiException(500, 'db.json 格式錯誤');
        }
        final rawPlaces = raw['places'];
        if (rawPlaces is! List) {
          throw ApiException(500, 'db.json 缺少 places');
        }
        final places = rawPlaces
            .whereType<Map<String, dynamic>>()
            .map(Place.fromJson)
            .toList();
        final count = await _mergePlacesToStore(store, places);
        return jsonResponse(
          200,
          successBody(
            message: '已合併匯入 db.json 到資料庫',
            data: {'count': count},
          ),
        );
      }),
    )
    ..post(
      '/api/admin/sync-to-local',
      (req) => _withAdmin(req, () async {
        if (_localSyncUrl == null || _localSyncUrl!.trim().isEmpty) {
          throw ApiException(400, '尚未設定 LOCAL_SYNC_URL');
        }
        if (_localSyncToken == null || _localSyncToken!.trim().isEmpty) {
          throw ApiException(400, '尚未設定 LOCAL_SYNC_TOKEN');
        }
        final exportUri = Uri.parse(
          _localSyncUrl!,
        ).resolve('/api/admin/places/import');
        final data = await store.read();
        final payload = jsonEncode({
          'places': data.places.map(_placeToApiJson).toList(),
        });
        final client = HttpClient();
        try {
          final request = await client.postUrl(exportUri);
          request.headers.set('Content-Type', 'application/json');
          request.headers.set('x-admin-token', _localSyncToken!);
          request.add(utf8.encode(payload));
          final response = await request.close();
          final body = await response.transform(utf8.decoder).join();
          if (response.statusCode >= 400) {
            throw ApiException(
              response.statusCode,
              '同步到本機失敗 (${response.statusCode})',
            );
          }
          Map<String, dynamic>? decoded;
          try {
            decoded = jsonDecode(body) as Map<String, dynamic>?;
          } catch (_) {}
          final count = decoded?['data']?['count'];
          return jsonResponse(
            200,
            successBody(
              message: '同步到本機完成',
              data: {'count': count ?? data.places.length},
            ),
          );
        } finally {
          client.close(force: true);
        }
      }),
    )
    ..get(
      '/api/admin/metrics',
      (req) => _withAdmin(req, () async {
        final snapshot = await _buildAdminMetricsSnapshot();
        return jsonResponse(
          200,
          successBody(message: '已取得即時監控資料', data: snapshot),
        );
      }),
    )
    ..post(
      '/api/admin/analytics/events',
      (req) => _withAdmin(req, () async {
        final snapshot = _buildAppEventSnapshot();
        return jsonResponse(
          200,
          successBody(message: '已取得 App 事件監控資料', data: snapshot),
        );
      }),
    )
    ..post(
      '/api/admin/reminders/run-now',
      (req) => _withAdmin(req, () async {
        final result = await _runUpcomingReminderScan(triggerSource: 'admin');
        return jsonResponse(
          200,
          successBody(message: '已手動執行提醒掃描', data: result),
        );
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
      '/api/admin/users/<id>/active-plan',
      (req, String id) => _withAdmin(req, () async {
        final user = await _store.findUserById(id);
        if (user == null) {
          throw ApiException(404, '找不到使用者');
        }
        return jsonResponse(
          200,
          successBody(
            message: '已取得使用者有效行程',
            data: {
              'user': user.toPublicJson(),
              'activePlan': user.activePlan,
              'activePlanUpdatedAt': user.activePlanUpdatedAt?.toIso8601String(),
            },
          ),
        );
      }),
    )
    ..post(
      '/api/admin/users/<id>/line-push-test',
      (req, String id) => _withAdmin(req, () async {
        final user = await _store.findUserById(id);
        if (user == null) {
          throw ApiException(404, '找不到使用者');
        }
        final lineUserId = user.lineUserId?.trim();
        if (lineUserId == null || lineUserId.isEmpty) {
          throw ApiException(400, '該使用者尚未綁定 LINE');
        }
        await _sendTrackedLinePush(
          to: lineUserId,
          text: 'Smart Travel 後台測試推播成功。你之後會在這裡收到下一站提醒與情境感知通知。',
          category: 'admin_test',
          userId: user.id,
          username: user.username,
        );
        return jsonResponse(200, successBody(message: '已送出 LINE 測試推播'));
      }),
    )
    ..get(
      '/api/admin/place-reviews',
      (req) => _withAdmin(req, () async {
        final name = req.url.queryParameters['name']?.trim();
        final id = req.url.queryParameters['id']?.trim();
        if ((name == null || name.isEmpty) && (id == null || id.isEmpty)) {
          throw ApiException(400, '請提供景點名稱或 id');
        }
        final file = File(p.join(_dataDir, 'places_with_reviews.json'));
        if (!file.existsSync()) {
          throw ApiException(404, '尚未產生評論資料');
        }
        final raw = jsonDecode(await file.readAsString());
        if (raw is! List) {
          throw ApiException(500, '評論資料格式錯誤');
        }
        final normalizedName = _normalizeText(name ?? '');
        final normalizedId = (id ?? '').trim();
        Map<String, dynamic>? match;
        for (final item in raw.whereType<Map<String, dynamic>>()) {
          final sourceName = (item['source_name'] as String?)?.trim() ?? '';
          final itemName = (item['name'] as String?)?.trim() ?? '';
          final itemId = (item['place_id'] as String?)?.trim() ?? '';
          final fallbackId = (item['id'] as String?)?.trim() ?? '';
          if (normalizedId.isNotEmpty &&
              (itemId == normalizedId || fallbackId == normalizedId)) {
            match = item;
            break;
          }
          if (name != null && name.isNotEmpty) {
            if (sourceName == name || itemName == name) {
              match = item;
              break;
            }
            final normSource = _normalizeText(sourceName);
            final normItem = _normalizeText(itemName);
            if (normalizedName.isNotEmpty &&
                (normSource == normalizedName ||
                    normItem == normalizedName ||
                    normSource.contains(normalizedName) ||
                    normalizedName.contains(normSource) ||
                    normItem.contains(normalizedName) ||
                    normalizedName.contains(normItem))) {
              match = item;
              break;
            }
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
        final crawlCity = _asString(body, 'city').trim();
        final batchCities = _crawlCitiesFromBody(body);
        final maxRequests = _asInt(body, 'maxRequests');
        final maxPages = _asInt(body, 'maxPages');
        final queryScope = _asString(body, 'queryScope').trim().toLowerCase();
        final crawlProfile = _asString(body, 'crawlProfile').trim().toLowerCase();
        if (_crawlJob != null && _crawlJob!.running) {
          throw ApiException(409, '已有爬取進行中');
        }
        final script = _crawlScriptForMode(mode);
        if (_crawlModeNeedsGoogleKey(mode)) {
          final googleKey = Platform.environment['GOOGLE_MAPS_API_KEY'] ?? '';
          if (googleKey.isEmpty) {
            throw ApiException(400, '需要設定 GOOGLE_MAPS_API_KEY');
          }
        }
        if (mode != 'google_places' && batchCities.length > 1) {
          throw ApiException(400, '目前只有 Google 抓景點支援批次多縣市');
        }
        final scriptPath = p.join(_dataDir, '..', 'scripts', script);
        if (!File(scriptPath).existsSync()) {
          throw ApiException(404, '找不到爬取腳本');
        }
        final cities = batchCities.length > 1
            ? batchCities
            : crawlCity.isEmpty
            ? const <String>[]
            : <String>[crawlCity];
        final job = _CrawlJob(
          id: const Uuid().v4(),
          mode: mode,
          startedAt: DateTime.now(),
          profile: mode == 'google_places' && crawlProfile.isNotEmpty
              ? crawlProfile
              : null,
          city: crawlCity.isEmpty ? null : crawlCity,
          cities: cities,
        );
        _crawlJob = job;
        if (cities.length > 1) {
          unawaited(
            _runBatchCrawlJob(
              job: job,
              scriptPath: scriptPath,
              maxRequests: maxRequests,
              maxPages: maxPages,
              queryScope: queryScope,
              crawlProfile: crawlProfile,
            ),
          );
          return jsonResponse(
            200,
            successBody(
              message: '已開始批次爬取，共 ${cities.length} 個縣市',
              data: job.toJson(),
            ),
          );
        }
        final process = await _startCrawlProcess(
          scriptPath: scriptPath,
          mode: mode,
          city: crawlCity.isEmpty ? null : crawlCity,
          maxRequests: maxRequests,
          maxPages: maxPages,
          queryScope: queryScope,
          crawlProfile: crawlProfile,
        );
        unawaited(_runSingleCrawlJob(job, process));
        return jsonResponse(
          200,
          successBody(message: '已開始爬取', data: job.toJson()),
        );
      }),
    )
    ..post(
      '/api/admin/crawl/stop',
      (req) => _withAdmin(req, () async {
        final job = _crawlJob;
        if (job == null || !job.running) {
          return jsonResponse(200, successBody(message: '目前沒有爬取進行中'));
        }
        job.stopRequested = true;
        job.process?.kill(ProcessSignal.sigterm);
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
      '/api/line/link-code',
      (req) => _json(req, (body) async {
        final userId = _asString(body, 'userId').trim();
        if (userId.isEmpty) {
          throw ApiException(400, '缺少使用者 id');
        }
        final user = await _findUserById(userId);
        if (user == null) {
          throw ApiException(404, '找不到使用者');
        }
        _cleanupExpiredLineCodes();
        final existing = _lineLinkCodes.values
            .where((entry) => entry.userId == user.id && !entry.expired)
            .toList();
        final code = existing.isNotEmpty ? existing.first : _issueLineLinkCode(user.id);
        return successBody(
          message: 'LINE 綁定碼已建立',
          data: {
            'userId': user.id,
            'linked': user.lineUserId != null && user.lineUserId!.isNotEmpty,
            'binding': code.toJson(addFriendUrl: _lineAddFriendUrl),
          },
        );
      }),
    )
    ..post(
      '/api/line/link-status',
      (req) => _json(req, (body) async {
        final userId = _asString(body, 'userId').trim();
        if (userId.isEmpty) {
          throw ApiException(400, '缺少使用者 id');
        }
        final user = await _findUserById(userId);
        if (user == null) {
          throw ApiException(404, '找不到使用者');
        }
        return successBody(
          data: {
            'userId': user.id,
            'linked': user.lineUserId != null && user.lineUserId!.isNotEmpty,
            'linePushEnabled': user.linePushEnabled,
            'lineLinkedAt': user.lineLinkedAt?.toIso8601String(),
          },
        );
      }),
    )
    ..post(
      '/api/line/push-test',
      (req) => _json(req, (body) async {
        final userId = _asString(body, 'userId').trim();
        if (userId.isEmpty) {
          throw ApiException(400, '缺少使用者 id');
        }
        final user = await _findUserById(userId);
        if (user == null) {
          throw ApiException(404, '找不到使用者');
        }
        final lineUserId = user.lineUserId;
        if (lineUserId == null || lineUserId.isEmpty) {
          throw ApiException(400, '尚未綁定 LINE');
        }
        await _sendTrackedLinePush(
          to: lineUserId,
          text: 'Smart Travel 測試推播成功。之後你會在這裡收到行程提醒。',
          category: 'app_test',
          userId: user.id,
          username: user.username,
        );
        return successBody(message: '已送出 LINE 測試推播');
      }),
    )
    ..post('/api/line/webhook', _lineWebhookHandler)
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
        final userId = _asString(body, 'userId').trim();
        final interests =
            (body['interests'] as List?)?.whereType<String>().toList() ??
            const [];
        User? updatedUser;
        if (userId.isNotEmpty) {
          final user = await _store.findUserById(userId);
          if (user == null) {
            throw ApiException(404, '查無此使用者');
          }
          updatedUser = user.copyWith(interests: interests);
          await _store.updateUser(updatedUser);
        }
        return successBody(
          message: '已接收興趣偏好',
          data: {
            'saved': interests,
            if (updatedUser != null) 'user': updatedUser.toPublicJson(),
          },
        );
      }),
    )
    ..post(
      '/api/travel/plans',
      (req) => _json(req, (body) async {
        final userId = _asString(body, 'userId').trim();
        final interests =
            (body['interests'] as List?)?.whereType<String>().toList() ??
            const [];
        final startDate = _parseDate(body['startDate']?.toString());
        final endDate = _parseDate(body['endDate']?.toString());
        final originCity = body['originCity']?.toString().trim();
        final destinationCities =
            (body['destinationCities'] as List?)
                ?.map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
                .toList() ??
            const <String>[];
        final tripPurpose = body['tripPurpose']?.toString().trim();
        final travelBehavior = body['travelBehavior']?.toString().trim();
        final location = body['location']?.toString().trim();
        final people = _asInt(body, 'people');
        final budget = _asInt(body, 'budget');
        final rawBackpackerAnswers = body['backpackerAnswers'];
        final backpackerAnswers = rawBackpackerAnswers is Map
            ? rawBackpackerAnswers.map(
                (key, value) => MapEntry(key.toString(), value),
              )
            : null;
        final dayStartTime = body['dayStartTime']?.toString().trim();
        final dayEndTime = body['dayEndTime']?.toString().trim();
        final extraSpots = _asInt(body, 'extraSpots');
        final wishlistPlaces =
            (body['wishlistPlaces'] as List?)
                ?.map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
                .toList() ??
            const <String>[];

        final plan = await _buildItineraryPlan(
          interests: interests,
          startDate: startDate,
          endDate: endDate,
          originCity: (originCity == null || originCity.isEmpty)
              ? null
              : originCity,
          destinationCities: destinationCities,
          tripPurpose: (tripPurpose == null || tripPurpose.isEmpty)
              ? null
              : tripPurpose,
          travelBehavior: (travelBehavior == null || travelBehavior.isEmpty)
              ? null
              : travelBehavior,
          location: (location == null || location.isEmpty) ? null : location,
          people: people,
          budget: budget,
          backpackerAnswers: backpackerAnswers,
          dayStartTime: (dayStartTime == null || dayStartTime.isEmpty)
              ? null
              : dayStartTime,
          dayEndTime: (dayEndTime == null || dayEndTime.isEmpty)
              ? null
              : dayEndTime,
          extraSpots: extraSpots,
          wishlistPlaces: wishlistPlaces,
        );
        if (userId.isNotEmpty) {
          unawaited(_syncUserActivePlan(userId: userId, plan: plan));
          unawaited(_sendLineItineraryGeneratedNotification(userId: userId, plan: plan));
        }
        return successBody(message: '行程已生成', data: plan);
      }),
    )
    ..post(
      '/api/travel/active-plan',
      (req) => _json(req, (body) async {
        final userId = _asString(body, 'userId').trim();
        final rawPlan = body['plan'];
        if (userId.isEmpty) {
          throw ApiException(400, '缺少使用者 id');
        }
        if (rawPlan is! Map) {
          throw ApiException(400, '缺少行程資料');
        }
        final plan = Map<String, dynamic>.from(rawPlan);
        await _syncUserActivePlan(userId: userId, plan: plan);
        final updatedUser = await _store.findUserById(userId);
        return successBody(
          message: '已同步目前行程到雲端提醒',
          data: {
            'activePlanSynced': true,
            'activePlanUpdatedAt': updatedUser?.activePlanUpdatedAt?.toIso8601String(),
          },
        );
      }),
    )
    ..post(
      '/api/travel/stop-explanation',
      (req) => _json(req, (body) async {
        final result = await _buildStopExplanation(body);
        return successBody(message: '景點說明已生成', data: result);
      }),
    )
    ..post(
      '/api/travel/context-awareness',
      (req) => _json(req, (body) async {
        final result = await _buildContextAwareness(body);
        return successBody(message: '情境感知分析完成', data: result);
      }),
    )
    ..post(
      '/api/line/run-upcoming-reminders',
      (req) => _withReminderCron(req, () async {
        final result = await _runUpcomingReminderScan(triggerSource: 'cron');
        return jsonResponse(
          200,
          successBody(message: '已完成即時提醒掃描', data: result),
        );
      }),
    );

  final pipeline = const Pipeline()
      .addMiddleware(_metricsMiddleware())
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

  final server = await shelf_io.serve(pipeline, '0.0.0.0', port);
  server.autoCompress = true;
  _log.info(
    'Backend API 已啟動，正在監聽 http://${server.address.address}:${server.port}',
  );
}

String _normalizeText(String input) {
  return input.toLowerCase().replaceAll(RegExp(r'[\s\W_]+', unicode: true), '');
}

Future<int> _mergePlacesToStore(DataStore store, List<Place> places) async {
  for (final place in places) {
    await store.upsertPlace(_normalizePlaceForStorage(place));
  }
  return places.length;
}

Future<int> _importDbJsonToStore() async {
  final file = File(p.join(_dataDir, 'db.json'));
  if (!await file.exists()) {
    _log.warning('Sync skipped: db.json not found at ${file.path}');
    return 0;
  }
  final raw = jsonDecode(await file.readAsString());
  if (raw is! Map || raw['places'] is! List) {
    _log.warning('Sync skipped: db.json missing places array');
    return 0;
  }
  final places = (raw['places'] as List)
      .whereType<Map>()
      .map((item) => Place.fromJson(Map<String, dynamic>.from(item)))
      .toList();
  return _mergePlacesToStore(_store, places);
}

const _crawlModesToSync = {
  'places',
  'reviews',
  'merge_tags',
  'google_places',
  'merge_ratings',
};

void _appendCrawlLog(_CrawlJob job, String line) {
  const maxLines = 400;
  if (line.trim().isEmpty) return;
  job.logs.add(line);
  if (job.logs.length > maxLines) {
    job.logs.removeAt(0);
  }
}

String _crawlScriptForMode(String mode) => switch (mode) {
  'places' => 'fetch_places.py',
  'reviews' => 'fetch_places_with_reviews.py',
  'merge_tags' => 'merge_tags_from_reviews.py',
  'google_places' => 'fetch_places_from_google.py',
  'merge_ratings' => 'merge_ratings_from_reviews.py',
  _ => throw ApiException(400, '未知的爬取模式'),
};

bool _crawlModeNeedsGoogleKey(String mode) =>
    mode == 'reviews' || mode == 'google_places';

List<String> _crawlCitiesFromBody(Map<String, dynamic> body) {
  final raw = body['cities'];
  if (raw is! List) {
    return const [];
  }
  return raw
      .map((item) => item?.toString().trim() ?? '')
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList();
}

Future<Process> _startCrawlProcess({
  required String scriptPath,
  required String mode,
  String? city,
  int? maxRequests,
  int? maxPages,
  String? queryScope,
  String? crawlProfile,
}) {
  return Process.start(
    'python3',
    [scriptPath],
    workingDirectory: p.dirname(scriptPath),
    environment: {
      ...Platform.environment,
      'PYTHONUNBUFFERED': '1',
      'PYTHONIOENCODING': 'utf-8',
      if (mode == 'google_places' && city != null && city.trim().isNotEmpty)
        'GOOGLE_PLACE_CITY': city.trim(),
      if (mode == 'google_places' && maxRequests != null && maxRequests > 0)
        'MAX_REQUESTS': maxRequests.clamp(50, 1000).toString(),
      if (mode == 'google_places' && maxPages != null && maxPages > 0)
        'TEXTSEARCH_MAX_PAGES': maxPages.clamp(1, 5).toString(),
      if (mode == 'google_places' &&
          (queryScope == 'standard' || queryScope == 'expanded'))
        'GOOGLE_QUERY_SCOPE': queryScope!,
      if (mode == 'google_places' &&
          (crawlProfile == 'balanced' ||
              crawlProfile == 'fast_bulk' ||
              crawlProfile == 'backfill'))
        'GOOGLE_CRAWL_PROFILE': crawlProfile!,
    },
  );
}

Future<int> _watchCrawlProcess(
  _CrawlJob job,
  Process process, {
  String? linePrefix,
}) async {
  String decorate(String line) {
    if (linePrefix == null || linePrefix.isEmpty) {
      return line;
    }
    return '[$linePrefix] $line';
  }

  final stdoutDone = Completer<void>();
  final stderrDone = Completer<void>();
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) => _appendCrawlLog(job, decorate(line)),
        onDone: stdoutDone.complete,
      );
  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) => _appendCrawlLog(job, decorate('[ERR] $line')),
        onDone: stderrDone.complete,
      );

  final code = await process.exitCode;
  await Future.wait([stdoutDone.future, stderrDone.future]);
  _log.info('Crawl job ${job.id} process finished with exit code $code');
  return code;
}

Future<void> _syncCrawlJobResults(_CrawlJob job) async {
  if (!_crawlModesToSync.contains(job.mode)) {
    return;
  }
  try {
    job.syncStartedAt = DateTime.now();
    final beforeCount = (await _store.read()).places.length;
    final count = await _importDbJsonToStore();
    final afterCount = (await _store.read()).places.length;
    final netDelta = afterCount - beforeCount;
    final message =
        '已同步到資料庫（處理 $count 筆，景點總數 $beforeCount -> $afterCount，淨增 $netDelta）';
    job.syncOk = true;
    job.syncedPlaces = count;
    job.syncFinishedAt = DateTime.now();
    job.syncMessage = message;
    _appendCrawlLog(job, message);
    _log.info('Crawl sync: $message');
  } catch (error, stack) {
    final message = '同步到資料庫失敗：$error';
    job.syncOk = false;
    job.syncFinishedAt = DateTime.now();
    job.syncMessage = message;
    _appendCrawlLog(job, message);
    _log.severe(message, error, stack);
  }
}

Future<void> _runSingleCrawlJob(_CrawlJob job, Process process) async {
  job.process = process;
  job.currentCity = job.city;
  final code = await _watchCrawlProcess(
    job,
    process,
    linePrefix: job.city?.trim().isNotEmpty == true ? job.city : null,
  );
  job.exitCode = code;
  job.finishedAt = DateTime.now();
  job.process = null;
  job.currentCity = null;
  if (code == 0) {
    await _syncCrawlJobResults(job);
  }
}

Future<void> _runBatchCrawlJob({
  required _CrawlJob job,
  required String scriptPath,
  int? maxRequests,
  int? maxPages,
  String? queryScope,
  String? crawlProfile,
}) async {
  _appendCrawlLog(job, '開始批次爬取，共 ${job.totalCities} 個縣市');
  for (final city in job.cities) {
    if (job.stopRequested) {
      _appendCrawlLog(job, '收到停止指令，批次作業提前結束');
      break;
    }
    final run = <String, dynamic>{
      'city': city,
      'started_at': DateTime.now().toIso8601String(),
      'status': 'running',
    };
    job.cityRuns.add(run);
    job.currentCity = city;
    _appendCrawlLog(job, '開始處理 $city');
    try {
      final process = await _startCrawlProcess(
        scriptPath: scriptPath,
        mode: job.mode,
        city: city,
        maxRequests: maxRequests,
        maxPages: maxPages,
        queryScope: queryScope,
        crawlProfile: crawlProfile,
      );
      job.process = process;
      final code = await _watchCrawlProcess(job, process, linePrefix: city);
      run['finished_at'] = DateTime.now().toIso8601String();
      run['exit_code'] = code;
      if (code == 0) {
        run['status'] = 'success';
        job.succeededCities += 1;
      } else {
        run['status'] = job.stopRequested ? 'stopped' : 'failed';
        job.failedCities += 1;
      }
    } catch (error) {
      run['finished_at'] = DateTime.now().toIso8601String();
      run['exit_code'] = -1;
      run['status'] = 'failed';
      run['error'] = error.toString();
      job.failedCities += 1;
      _appendCrawlLog(job, '[$city] 啟動失敗：$error');
    } finally {
      job.completedCities += 1;
      job.process = null;
      job.currentCity = null;
      _appendCrawlLog(
        job,
        '$city 完成，累積 ${job.completedCities}/${job.totalCities}，成功 ${job.succeededCities}，失敗 ${job.failedCities}',
      );
    }
  }

  if (job.succeededCities > 0) {
    await _syncCrawlJobResults(job);
  }
  job.finishedAt = DateTime.now();
  if (job.stopRequested) {
    job.exitCode = job.failedCities > 0 ? 1 : 130;
  } else {
    job.exitCode = job.failedCities > 0 ? 1 : 0;
  }
  final summary =
      '批次爬取結束：完成 ${job.completedCities}/${job.totalCities}，成功 ${job.succeededCities}，失敗 ${job.failedCities}';
  _appendCrawlLog(job, summary);
  _log.info('Crawl job ${job.id} finished: $summary');
}

Middleware _metricsMiddleware() {
  return (Handler innerHandler) {
    return (Request request) async {
      final startedAt = DateTime.now();
      Response response;
      try {
        response = await innerHandler(request);
      } catch (error) {
        _recordRequestMetric(
          request: request,
          startedAt: startedAt,
          statusCode: 500,
          error: error.toString(),
        );
        rethrow;
      }
      _recordRequestMetric(
        request: request,
        startedAt: startedAt,
        statusCode: response.statusCode,
      );
      return response;
    };
  };
}

void _recordRequestMetric({
  required Request request,
  required DateTime startedAt,
  required int statusCode,
  String? error,
}) {
  final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
  final routeKey = '${request.method} /${request.url.path}';
  _totalRequestCount += 1;
  if (statusCode >= 400) {
    _totalErrorCount += 1;
  }
  _requestPathCounts.update(routeKey, (value) => value + 1, ifAbsent: () => 1);
  _appendBounded(
    _recentRequestLogs,
    {
      'timestamp': startedAt.toUtc().toIso8601String(),
      'method': request.method,
      'path': '/${request.url.path}',
      'status': statusCode,
      'durationMs': durationMs,
      'query': request.url.queryParameters.isEmpty
          ? null
          : request.url.queryParameters,
      if (error != null && error.isNotEmpty) 'error': error,
    },
    limit: 120,
  );
}

void _recordAppEvent({
  required Request request,
  required String event,
  String? page,
  String? userId,
  String? sessionId,
  Map<String, dynamic>? payload,
}) {
  _appendBounded(
    _appEventHistory,
    {
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'event': event,
      'page': page,
      'userId': userId,
      'sessionId': sessionId,
      'userAgent': request.headers['user-agent'],
      'ip':
          request.headers['x-forwarded-for'] ??
          request.context['shelf.io.connection_info']?.toString(),
      'payload': payload ?? <String, dynamic>{},
    },
    limit: 600,
  );
}

Future<void> _sendTrackedLinePush({
  required String to,
  required String text,
  required String category,
  String? userId,
  String? username,
}) async {
  final entry = <String, dynamic>{
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'category': category,
    'userId': userId,
    'username': username,
    'lineUserId': to,
    'preview': text.length > 120 ? '${text.substring(0, 120)}…' : text,
  };
  try {
    await _notificationService.sendLinePush(to: to, text: text);
    entry['status'] = 'success';
    _appendBounded(_linePushHistory, entry, limit: 80);
  } catch (error) {
    entry['status'] = 'failed';
    entry['error'] = error.toString();
    _appendBounded(_linePushHistory, entry, limit: 80);
    rethrow;
  }
}

void _recordReminderRun({
  required String source,
  required Map<String, dynamic> result,
}) {
  _appendBounded(
    _reminderRunHistory,
    {
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'source': source,
      ...result,
    },
    limit: 60,
  );
}

void _appendBounded(
  List<Map<String, dynamic>> target,
  Map<String, dynamic> item, {
  required int limit,
}) {
  target.add(item);
  if (target.length > limit) {
    target.removeRange(0, target.length - limit);
  }
}

Future<Map<String, dynamic>> _buildAdminMetricsSnapshot() async {
  final data = await _store.read();
  final now = DateTime.now();
  final recentFiveMinutes = now.subtract(const Duration(minutes: 5));
  final recentWindow = _recentRequestLogs.where((entry) {
    final timestamp = DateTime.tryParse(entry['timestamp']?.toString() ?? '');
    return timestamp != null && timestamp.isAfter(recentFiveMinutes);
  }).toList();
  final recentErrors = recentWindow
      .where((entry) => (entry['status'] as int? ?? 200) >= 400)
      .length;
  final avgLatency = recentWindow.isEmpty
      ? 0
      : recentWindow
                .map((entry) => (entry['durationMs'] as int?) ?? 0)
                .reduce((a, b) => a + b) ~/
            recentWindow.length;
  final users = data.users;
  final places = data.places;
  final lineLinkedUsers = users
      .where((user) => (user.lineUserId?.trim().isNotEmpty ?? false))
      .length;
  final activePlanUsers = users.where((user) => user.activePlan != null).length;
  final pushEnabledUsers = users.where((user) => user.linePushEnabled).length;
  final topRoutes = _requestPathCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  return {
    'stats': {
      'totalRequests': _totalRequestCount,
      'totalErrors': _totalErrorCount,
      'requestsLast5Min': recentWindow.length,
      'errorsLast5Min': recentErrors,
      'avgLatencyMsLast5Min': avgLatency,
      'userCount': users.length,
      'placeCount': places.length,
      'lineLinkedUsers': lineLinkedUsers,
      'linePushEnabledUsers': pushEnabledUsers,
      'activePlanUsers': activePlanUsers,
    },
    'health': {
      'dataStore': _dataStoreLabel,
      'openAiConfigured': _openAiApiKey != null && _openAiApiKey!.isNotEmpty,
      'lineConfigured':
          (_lineChannelSecret?.isNotEmpty ?? false) &&
          ((Platform.environment['LINE_CHANNEL_ACCESS_TOKEN'] ?? '').isNotEmpty),
      'googleMapsConfigured':
          (Platform.environment['GOOGLE_MAPS_API_KEY'] ?? '').isNotEmpty,
      'itineraryLearningConfigured': _itineraryLearningProfile.enabled,
      'cronConfigured': _reminderCronToken != null && _reminderCronToken!.isNotEmpty,
      'crawlRunning': _crawlJob?.running == true,
      'timestamp': now.toUtc().toIso8601String(),
    },
    'topRoutes': topRoutes
        .take(12)
        .map((entry) => {'route': entry.key, 'count': entry.value})
        .toList(),
    'recentRequests': _recentRequestLogs.reversed.take(30).toList(),
    'linePushHistory': _linePushHistory.reversed.take(30).toList(),
    'reminderRuns': _reminderRunHistory.reversed.take(20).toList(),
    'appEvents': _buildAppEventSnapshot(),
    'crawlJob': _crawlJob?.toJson(),
  };
}

Map<String, dynamic> _buildAppEventSnapshot() {
  final now = DateTime.now();
  final recentFiveMinutes = now.subtract(const Duration(minutes: 5));
  final recentEvents = _appEventHistory.where((entry) {
    final timestamp = DateTime.tryParse(entry['timestamp']?.toString() ?? '');
    return timestamp != null && timestamp.isAfter(recentFiveMinutes);
  }).toList();
  final eventCounts = <String, int>{};
  final pageCounts = <String, int>{};
  for (final entry in _appEventHistory) {
    final event = entry['event']?.toString().trim();
    if (event != null && event.isNotEmpty) {
      eventCounts.update(event, (value) => value + 1, ifAbsent: () => 1);
    }
    final page = entry['page']?.toString().trim();
    if (page != null && page.isNotEmpty) {
      pageCounts.update(page, (value) => value + 1, ifAbsent: () => 1);
    }
  }
  final topEvents = eventCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final topPages = pageCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return {
    'totalEvents': _appEventHistory.length,
    'eventsLast5Min': recentEvents.length,
    'topEvents': topEvents
        .take(12)
        .map((entry) => {'event': entry.key, 'count': entry.value})
        .toList(),
    'topPages': topPages
        .take(12)
        .map((entry) => {'page': entry.key, 'count': entry.value})
        .toList(),
    'recentEvents': _appEventHistory.reversed.take(40).toList(),
  };
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

Future<Response> _withReminderCron(
  Request request,
  Future<Response> Function() action,
) async {
  if (_reminderCronToken == null || _reminderCronToken!.isEmpty) {
    return jsonResponse(403, errorBody('尚未設定 REMINDER_CRON_TOKEN'));
  }
  final token = request.headers['x-reminder-token']?.trim();
  if (token == null || token != _reminderCronToken) {
    return jsonResponse(401, errorBody('未授權'));
  }
  return _handle(action);
}

Future<Response> _adminPageHandler(Request request) async {
  final file = File(p.join(_dataDir, '..', 'web', 'admin.html'));
  if (!await file.exists()) {
    return Response.notFound('admin.html not found');
  }
  final html = await file.readAsString();
  return Response.ok(
    html,
    headers: {'Content-Type': 'text/html; charset=utf-8'},
  );
}

Future<User?> _findUserById(String userId) async {
  return _store.findUserById(userId);
}

Future<void> _syncUserActivePlan({
  required String userId,
  required Map<String, dynamic> plan,
}) async {
  final user = await _store.findUserById(userId);
  if (user == null) {
    throw ApiException(404, '找不到使用者');
  }
  final normalizedPlan = Map<String, dynamic>.from(
    jsonDecode(jsonEncode(plan)) as Map,
  );
  await _store.updateUser(
    user.copyWith(
      activePlan: normalizedPlan,
      activePlanUpdatedAt: DateTime.now(),
    ),
  );
}

Future<Map<String, dynamic>> _runUpcomingReminderScan({
  required String triggerSource,
}) async {
  final users = (await _store.read()).users;
  final now = DateTime.now();
  final todayText = now.toIso8601String().substring(0, 10);
  var scanned = 0;
  var syncedPlans = 0;
  var pushed = 0;
  final pushedUsers = <String>[];

  for (final user in users) {
    if (user.lineUserId == null ||
        user.lineUserId!.trim().isEmpty ||
        user.linePushEnabled != true) {
      continue;
    }
    final plan = user.activePlan;
    if (plan == null) {
      continue;
    }
    syncedPlans += 1;
    final rawDays = plan['days'];
    if (rawDays is! List) {
      continue;
    }
    final todayDay = rawDays
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .firstWhere(
          (item) => item['date']?.toString().startsWith(todayText) == true,
          orElse: () => const <String, dynamic>{},
        );
    if (todayDay.isEmpty) {
      continue;
    }
    scanned += 1;
    final result = await _buildContextAwareness({
      'day': todayDay,
      'userId': user.id,
      'triggerLinePush': true,
      'currentTime': now.toIso8601String(),
    });
    if (result['linePushed'] == true) {
      pushed += 1;
      pushedUsers.add(user.username);
    }
  }

  final result = {
    'scannedUsers': scanned,
    'syncedPlans': syncedPlans,
    'linePushed': pushed,
    'pushedUsers': pushedUsers,
    'checkedAt': now.toIso8601String(),
  };
  _recordReminderRun(source: triggerSource, result: result);
  return result;
}

Future<void> _sendLineItineraryGeneratedNotification({
  required String userId,
  required Map<String, dynamic> plan,
}) async {
  try {
    final user = await _store.findUserById(userId);
    if (user == null) {
      return;
    }
    final lineUserId = user.lineUserId?.trim();
    if (lineUserId == null || lineUserId.isEmpty) {
      return;
    }
    final message = _buildLineItinerarySummary(plan);
    await _sendTrackedLinePush(
      to: lineUserId,
      text: message,
      category: 'itinerary_generated',
      userId: user.id,
      username: user.username,
    );
    _log.info('LINE 行程推播已送出：user=$userId lineUserId=$lineUserId');
  } catch (error, stack) {
    _log.warning('LINE 行程推播失敗：user=$userId error=$error');
    _log.fine(stack.toString());
  }
}

String _buildLineItinerarySummary(Map<String, dynamic> plan) {
  final meta = plan['meta'];
  final days = plan['days'];
  final insight = plan['insight'];

  final metaMap = meta is Map ? Map<String, dynamic>.from(meta) : const <String, dynamic>{};
  final dayList = days is List
      ? days.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : const <Map<String, dynamic>>[];
  final insightMap = insight is Map
      ? Map<String, dynamic>.from(insight)
      : const <String, dynamic>{};

  final location = metaMap['location']?.toString().trim();
  final startDate = metaMap['startDate']?.toString();
  final dayCount = dayList.length;
  final stopCount = dayList.fold<int>(0, (sum, day) {
    final items = day['items'];
    if (items is List) return sum + items.length;
    return sum;
  });

  String? firstStop;
  String? firstTime;
  if (dayList.isNotEmpty) {
    final firstDayItems = dayList.first['items'];
    if (firstDayItems is List && firstDayItems.isNotEmpty) {
      final firstItem = firstDayItems.first;
      if (firstItem is Map) {
        firstTime = firstItem['time']?.toString();
        final place = firstItem['place'];
        if (place is Map) {
          firstStop = place['name']?.toString();
        }
      }
    }
  }

  final summary = insightMap['summary']?.toString().trim();
  final lines = <String>[
    'Smart Travel 已為你安排新行程${location != null && location.isNotEmpty ? '：$location' : ''}',
    if (startDate != null && startDate.isNotEmpty)
      '日期：${startDate.substring(0, 10)} 起，共 $dayCount 天',
    '景點數：$stopCount',
    if (firstStop != null && firstStop.isNotEmpty)
      '第一站：${firstTime != null && firstTime.isNotEmpty ? '$firstTime ' : ''}$firstStop',
    if (summary != null && summary.isNotEmpty) summary,
    '打開 App 可查看完整行程與地圖路線。',
  ];
  return lines.join('\n');
}

Future<Map<String, dynamic>> _buildContextAwareness(
  Map<String, dynamic> body,
) async {
  final rawDay = body['day'];
  if (rawDay is! Map) {
    throw ApiException(400, '缺少行程日資料');
  }

  final day = Map<String, dynamic>.from(rawDay);
  final userId = _asString(body, 'userId').trim();
  final triggerLinePush = body['triggerLinePush'] != false;
  final referenceTime =
      DateTime.tryParse(body['currentTime']?.toString() ?? '')?.toLocal() ??
      DateTime.now();
  final dayDate = _parseDate(day['date']?.toString());
  final dayDateText = dayDate?.toIso8601String().substring(0, 10);
  if (dayDate == null || dayDateText == null) {
    throw ApiException(400, '行程日期格式不正確');
  }

  var weather = day['weather'] is Map
      ? Map<String, dynamic>.from(day['weather'] as Map)
      : null;
  if (weather == null) {
    var coordinate = _resolveDayWeatherCoordinate(day);
    if (coordinate == null) {
      final catalog = await _store.listPlaces();
      coordinate = _resolveDayWeatherCoordinate(day, catalog: catalog);
    }
    if (coordinate != null) {
      final byDate = await _fetchDailyWeatherForecast(
        lat: coordinate.$1,
        lng: coordinate.$2,
        startDate: dayDateText,
        endDate: dayDateText,
      );
      weather = byDate[dayDateText];
    }
  }

  final alerts = <Map<String, dynamic>>[];
  final suggestions = <String>{};
  final backupPlans = <Map<String, dynamic>>[];
  final itemMaps = (day['items'] as List?)
          ?.whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList() ??
      const <Map<String, dynamic>>[];
  final visitItems = itemMaps
      .where((item) {
        final place = item['place'];
        if (place is! Map) return false;
        final kind = place['kind']?.toString() ?? 'place';
        return kind != 'meal_break';
      })
      .toList();
  final focus = _resolveContextFocus(
    dayDate: dayDate,
    visitItems: visitItems,
    referenceTime: referenceTime,
  );

  final visitPlaces = visitItems
      .map((item) => _planPlaceToPlace(Map<String, dynamic>.from(item['place'] as Map)))
      .toList();
  final outdoorCount = visitPlaces.where(_isOutdoorPlace).length;
  final severeRain = (weather != null &&
      ((_asIntValue(weather['code']) ?? 0) >= 95 ||
          (_asIntValue(weather['precipitationProbability']) ?? 0) >= 60));
  final hotOutdoorDay = (weather != null &&
      (_asDoubleValue(weather['temperatureMax']) ?? 0) >= 33 &&
      outdoorCount >= 2);

  if (weather != null) {
    final rainProb = _asIntValue(weather['precipitationProbability']) ?? 0;
    final weatherCode = _asIntValue(weather['code']);
    final tempMax = _asDoubleValue(weather['temperatureMax']);
    final summary = weather['summary']?.toString() ?? _weatherCodeToText(weatherCode);

    if (weatherCode != null && weatherCode >= 95 && outdoorCount > 0) {
      alerts.add(_contextAlert(
        type: 'weather_thunder',
        severity: 'high',
        title: '雷雨風險偏高',
        message: '今天預報為 $summary，戶外景點建議提前或改成室內點。',
      ));
      suggestions.add('優先把戶外景點移到上午，午後改排室內景點或餐食休息。');
    } else if (rainProb >= 70 && outdoorCount > 0) {
      alerts.add(_contextAlert(
        type: 'weather_rain',
        severity: 'high',
        title: '午後降雨機率高',
        message: '降雨機率約 $rainProb%，戶外行程可能受影響。',
      ));
      suggestions.add('保留雨備方案，將步道、海邊、公園等戶外點前移。');
    } else if (rainProb >= 40 && outdoorCount >= 2) {
      alerts.add(_contextAlert(
        type: 'weather_rain',
        severity: 'medium',
        title: '有降雨風險',
        message: '降雨機率約 $rainProb%，今天的戶外景點較多，建議預留彈性。',
      ));
      suggestions.add('下午時段可預留咖啡館、博物館等室內替代點。');
    }

    if (tempMax != null && tempMax >= 34 && outdoorCount >= 2) {
      alerts.add(_contextAlert(
        type: 'weather_heat',
        severity: 'high',
        title: '高溫曝曬風險',
        message: '今日高溫約 ${tempMax.toStringAsFixed(0)}°C，連續戶外停留可能偏累。',
      ));
      suggestions.add('中午前後優先安排冷氣室內點或午餐休息，避免長時間曝曬。');
    } else if (tempMax != null && tempMax >= 31 && outdoorCount >= 3) {
      alerts.add(_contextAlert(
        type: 'weather_heat',
        severity: 'medium',
        title: '中午體感偏熱',
        message: '今日高溫約 ${tempMax.toStringAsFixed(0)}°C，戶外景點密度偏高。',
      ));
      suggestions.add('最曬的 12:00-14:00 盡量安排午餐或室內景點。');
    }
  } else {
    alerts.add(_contextAlert(
      type: 'weather_pending',
      severity: 'low',
      title: '天氣資料尚未同步',
      message: '目前無法取得今日天氣，建議出發前再確認一次。',
    ));
  }

  final catalog = (severeRain || hotOutdoorDay)
      ? await _store.listPlaces()
      : const <Place>[];
  final usedPlaceIds = visitPlaces.map((place) => place.id).toSet();
  if (catalog.isNotEmpty) {
    for (var visitIndex = 0; visitIndex < visitItems.length; visitIndex++) {
      final item = visitItems[visitIndex];
      final placeMap = Map<String, dynamic>.from(item['place'] as Map);
      final place = _planPlaceToPlace(placeMap);
      if (!_isOutdoorPlace(place)) {
        continue;
      }
      final scheduleStart = _parseHmToMinute(item['time']?.toString());
      final rainCandidates = severeRain
          ? _findContextAlternativeCandidates(
              targetPlace: place,
              dayPlaces: visitPlaces,
              catalog: catalog,
              dayDate: dayDate,
              targetStartMinute: scheduleStart,
              usedPlaceIds: usedPlaceIds,
              preferIndoor: true,
            )
          : const <Place>[];
      final heatCandidates = (!severeRain && hotOutdoorDay)
          ? _findContextAlternativeCandidates(
              targetPlace: place,
              dayPlaces: visitPlaces,
              catalog: catalog,
              dayDate: dayDate,
              targetStartMinute: scheduleStart,
              usedPlaceIds: usedPlaceIds,
              preferIndoor: true,
            )
          : const <Place>[];

      final candidates = severeRain ? rainCandidates : heatCandidates;
      if (candidates.isEmpty) {
        continue;
      }

      final reason = severeRain
          ? '若 ${place.name} 受雨勢影響，可改排同城市室內備案。'
          : '若中午曝曬過強，可改排冷氣室內景點降低體力消耗。';
      backupPlans.add({
        'trigger': severeRain ? 'weather_rain' : 'weather_heat',
        'targetPlaceId': place.id,
        'targetPlaceName': place.name,
        'reason': reason,
        'replacements': candidates
            .take(3)
            .map(_contextReplacementToJson)
            .toList(),
      });
      if (focus != null && focus.targetIndex == visitIndex) {
        final topNames = candidates.take(2).map((e) => e.name).join(' / ');
        _setContextNextAction(
          day,
          {
            'type': severeRain ? 'swap_for_weather' : 'swap_for_heat',
            'severity': severeRain ? 'high' : 'medium',
            'phase': focus.phase,
            'targetPlaceId': place.id,
            'targetPlaceName': place.name,
            'scheduledTime': item['time']?.toString(),
            'title': focus.phase == 'current'
                ? '建議立即調整目前景點'
                : '建議調整接下來的景點',
            'message': severeRain
                ? '${place.name} 目前受降雨風險影響，建議不要硬走原本戶外安排。'
                : '${place.name} 遇到高溫曝曬風險，建議改成室內點再回來。',
            'recommendedAction': topNames.isEmpty
                ? '先改排同城市室內備案。'
                : '先改去 $topNames，等天氣穩定後再回來。',
            'alternatives': candidates.take(3).map(_contextReplacementToJson).toList(),
          },
        );
      }
    }
    if (backupPlans.isNotEmpty) {
      final sample = backupPlans.first;
      final replacements =
          (sample['replacements'] as List).take(2).map((e) => e['name']).join(' / ');
      suggestions.add(
        '已為 ${sample['targetPlaceName']} 準備雨備/室內替代點：$replacements。',
      );
    }
  }

  for (var visitIndex = 0; visitIndex < visitItems.length; visitIndex++) {
    final item = visitItems[visitIndex];
    final placeMap = Map<String, dynamic>.from(item['place'] as Map);
    final place = _planPlaceToPlace(placeMap);
    final scheduleStart = _parseHmToMinute(item['time']?.toString());
    final scheduleEnd = _parseHmToMinute(item['endTime']?.toString());
    final window = _openingWindowForDate(place, dayDate);
    if (place.openingHours != null && window == null) {
      final weekdayText = _openingWeekdayText(place, dayDate);
      final closureText = weekdayText == null ? '今天的營業資訊無法判讀。' : '今日營業資訊顯示：$weekdayText';
      alerts.add(_contextAlert(
        type: 'opening_closed_or_unknown',
        severity: 'high',
        title: '${place.name} 今日可能未開放',
        message: closureText,
      ));
      suggestions.add('建議先電話確認 ${place.name} 是否營業，或改用同城市備案景點。');
      if (focus != null && focus.targetIndex == visitIndex) {
        _setContextNextAction(
          day,
          {
            'type': 'opening_unknown',
            'severity': 'high',
            'phase': focus.phase,
            'targetPlaceId': place.id,
            'targetPlaceName': place.name,
            'scheduledTime': item['time']?.toString(),
            'title': '下一站營業狀態不明',
            'message': '${place.name} 今天的營業資訊無法可靠判讀，不建議直接前往。',
            'recommendedAction': '先電話確認，若無法確認就改用同城市備案景點。',
          },
        );
      }
      continue;
    }
    if (place.openingHours == null) {
      alerts.add(_contextAlert(
        type: 'opening_missing',
        severity: 'low',
        title: '${place.name} 缺少營業時間',
        message: '目前沒有 ${place.name} 的營業時段資料，建議出發前再確認。',
      ));
      continue;
    }
    if (scheduleStart == null || window == null) {
      continue;
    }

    final openMinute = window.$1;
    final closeMinute = window.$2;
    if (scheduleStart < openMinute) {
      alerts.add(_contextAlert(
        type: 'opening_before_open',
        severity: 'high',
        title: '${place.name} 可能尚未開門',
        message: '行程安排 ${item['time']} 到訪，但今日約 ${_minutesToHm(openMinute)} 才開放。',
      ));
      suggestions.add('將 ${place.name} 延後到 ${_minutesToHm(openMinute)} 後，或先安排附近早開景點。');
      if (focus != null && focus.targetIndex == visitIndex) {
        _setContextNextAction(
          day,
          {
            'type': 'delay_until_open',
            'severity': 'high',
            'phase': focus.phase,
            'targetPlaceId': place.id,
            'targetPlaceName': place.name,
            'scheduledTime': item['time']?.toString(),
            'title': '建議延後前往下一站',
            'message': '${place.name} 約 ${_minutesToHm(openMinute)} 才開放，照原時間過去會撲空。',
            'recommendedAction': '把 ${place.name} 延後到 ${_minutesToHm(openMinute)} 後，或先換去附近早開景點。',
          },
        );
      }
      continue;
    }
    if (scheduleStart >= closeMinute) {
      alerts.add(_contextAlert(
        type: 'opening_after_close',
        severity: 'high',
        title: '${place.name} 抵達時可能已打烊',
        message: '行程安排 ${item['time']} 到訪，但今日約 ${_minutesToHm(closeMinute)} 前結束營業。',
      ));
      suggestions.add('把 ${place.name} 提前，或改成當天較早時段的景點。');
      if (focus != null && focus.targetIndex == visitIndex) {
        _setContextNextAction(
          day,
          {
            'type': 'skip_closed',
            'severity': 'high',
            'phase': focus.phase,
            'targetPlaceId': place.id,
            'targetPlaceName': place.name,
            'scheduledTime': item['time']?.toString(),
            'title': '下一站可能已打烊',
            'message': '${place.name} 抵達時段可能已結束營業，不建議照原順序前往。',
            'recommendedAction': '改成當天較早時段景點，或直接換成備案景點。',
          },
        );
      }
      continue;
    }
    if (scheduleEnd != null && scheduleEnd > closeMinute) {
      alerts.add(_contextAlert(
        type: 'opening_short_window',
        severity: 'medium',
        title: '${place.name} 停留時間可能不足',
        message: '預計待到 ${item['endTime']}，但今日約 ${_minutesToHm(closeMinute)} 前結束營業。',
      ));
      suggestions.add('縮短前一站停留或提早出發，避免 ${place.name} 只逛到一半。');
      if (focus != null && focus.targetIndex == visitIndex) {
        _setContextNextAction(
          day,
          {
            'type': 'shorten_before_stop',
            'severity': 'medium',
            'phase': focus.phase,
            'targetPlaceId': place.id,
            'targetPlaceName': place.name,
            'scheduledTime': item['time']?.toString(),
            'title': '下一站停留時間會被壓縮',
            'message': '${place.name} 的可用營業時段偏短，照原節奏過去可能來不及完整停留。',
            'recommendedAction': '提早出發，或先縮短前一站停留時間。',
          },
        );
      }
      continue;
    }
    if (closeMinute - scheduleStart <= 30) {
      alerts.add(_contextAlert(
        type: 'opening_near_close',
        severity: 'medium',
        title: '${place.name} 接近打烊時段',
        message: '預計 ${item['time']} 到訪，距離今日打烊只剩 ${closeMinute - scheduleStart} 分鐘。',
      ));
      suggestions.add('若想完整停留，可將 ${place.name} 提前到更早時段。');
    }
  }

  final rawOriginTransit = day['originTransit'];
  if (rawOriginTransit is Map) {
    final originTransit = Map<String, dynamic>.from(rawOriginTransit);
    final minutes = _asIntValue(originTransit['minutes']) ?? 0;
    final label = originTransit['label']?.toString() ?? '交通';
    final fromLabel = originTransit['fromLabel']?.toString() ?? '出發地';
    final toLabel = originTransit['toLabel']?.toString() ?? '第一站';
    if (minutes >= 180) {
      alerts.add(_contextAlert(
        type: 'origin_transit_long',
        severity: 'high',
        title: '第一段移動時間很長',
        message: '$fromLabel 到 $toLabel 預估需 $minutes 分鐘（$label），第一天節奏可能偏趕。',
      ));
      suggestions.add('若可行，建議前一晚先接近旅遊城市，或第一天減少景點數。');
      if (focus != null && focus.targetIndex == 0) {
        _setContextNextAction(
          day,
          {
            'type': 'origin_transit_too_long',
            'severity': 'high',
            'phase': focus.phase,
            'targetPlaceName': toLabel,
            'title': '出發段過長，建議立即縮減第一天安排',
            'message': '$fromLabel 到 $toLabel 預估需 $minutes 分鐘，第一天前段移動成本過高。',
            'recommendedAction': '優先保留第一站與核心景點，其餘景點往後移或刪減 1 站。',
          },
        );
      }
    } else if (minutes >= 120) {
      alerts.add(_contextAlert(
        type: 'origin_transit_long',
        severity: 'medium',
        title: '出發段交通偏長',
        message: '$fromLabel 到 $toLabel 預估需 $minutes 分鐘（$label）。',
      ));
      suggestions.add('第一站後可預留午餐或休息時間，避免一路趕行程。');
      if (focus != null && focus.targetIndex == 0) {
        _setContextNextAction(
          day,
          {
            'type': 'origin_transit_long',
            'severity': 'medium',
            'phase': focus.phase,
            'targetPlaceName': toLabel,
            'title': '第一站前交通偏長',
            'message': '$fromLabel 到 $toLabel 需要約 $minutes 分鐘，照原節奏會偏趕。',
            'recommendedAction': '第一站後先預留休息或午餐，後段景點數不要再加。',
          },
        );
      }
    }
    _appendTransitContextAlerts(
      alerts: alerts,
      suggestions: suggestions,
      transit: originTransit,
      rainRisk: severeRain,
      heatRisk: hotOutdoorDay,
    );
  }

  for (final item in visitItems) {
    final rawTransit = item['transitToNext'];
    if (rawTransit is! Map) {
      continue;
    }
    _appendTransitContextAlerts(
      alerts: alerts,
      suggestions: suggestions,
      transit: Map<String, dynamic>.from(rawTransit),
      rainRisk: severeRain,
      heatRisk: hotOutdoorDay,
    );
  }

  final overallSeverity = _contextOverallSeverity(alerts);
  final nextAction = _contextNextAction(day);
  final upcomingReminder = _buildContextUpcomingReminder(
    day: day,
    visitItems: visitItems,
    focus: focus,
    referenceTime: referenceTime,
    weather: weather,
    alerts: alerts,
  );
  final summary = alerts.isEmpty
      ? upcomingReminder == null
            ? '今日行程狀況穩定，目前沒有需要即時調整的重點。'
            : '接下來建議準備前往「${upcomingReminder['targetPlaceName']}」，已整理出發與注意事項。'
      : nextAction == null
      ? '今日行程有 ${alerts.length} 項需留意的情境提醒${backupPlans.isNotEmpty ? '，並已幫你準備室內備案。' : '。'}'
      : '系統判斷接下來較需要先調整「${nextAction['targetPlaceName']?.toString().trim().isNotEmpty == true ? nextAction['targetPlaceName'] : nextAction['title']}」，已同步整理立即應變建議。';

  final result = <String, dynamic>{
    'summary': summary,
    'severity': overallSeverity,
    'alerts': alerts,
    'suggestions': suggestions.toList(),
    'backupPlans': backupPlans,
    if (nextAction != null) 'nextAction': nextAction,
    if (upcomingReminder != null) 'upcomingReminder': upcomingReminder,
    'checkedAt': DateTime.now().toUtc().toIso8601String(),
    'linePushed': false,
  };

  if (triggerLinePush && userId.isNotEmpty) {
    result['linePushed'] = await _sendLineContextAwarenessNotification(
      userId: userId,
      dayDate: dayDate,
      result: result,
    );
  }

  return result;
}

Map<String, dynamic>? _buildContextUpcomingReminder({
  required Map<String, dynamic> day,
  required List<Map<String, dynamic>> visitItems,
  required _ContextFocus? focus,
  required DateTime referenceTime,
  required Map<String, dynamic>? weather,
  required List<Map<String, dynamic>> alerts,
}) {
  if (focus == null || visitItems.isEmpty || focus.phase == 'completed') {
    return null;
  }

  Map<String, dynamic>? targetItem;
  Map<String, dynamic>? transit;
  var targetIndex = focus.targetIndex;

  if (focus.phase == 'current') {
    final nextIndex = focus.targetIndex + 1;
    if (nextIndex >= visitItems.length) {
      return null;
    }
    targetIndex = nextIndex;
    targetItem = visitItems[nextIndex];
    final currentTransit = focus.targetItem['transitToNext'];
    if (currentTransit is Map) {
      transit = Map<String, dynamic>.from(currentTransit);
    }
  } else {
    targetItem = focus.targetItem;
    if (targetIndex == 0) {
      final rawOriginTransit = day['originTransit'];
      if (rawOriginTransit is Map) {
        transit = Map<String, dynamic>.from(rawOriginTransit);
      }
    } else {
      final previousItem = visitItems[targetIndex - 1];
      final rawTransit = previousItem['transitToNext'];
      if (rawTransit is Map) {
        transit = Map<String, dynamic>.from(rawTransit);
      }
    }
  }

  final place = targetItem['place'];
  if (place is! Map) {
    return null;
  }

  final scheduledTime = targetItem['time']?.toString() ?? '';
  final startMinute = _parseHmToMinute(scheduledTime);
  if (startMinute == null) {
    return null;
  }

  final nowMinute = referenceTime.hour * 60 + referenceTime.minute;
  final minutesUntil = startMinute - nowMinute;
  final dateText = day['date']?.toString() ?? '';
  final dayDate = _parseDate(dateText);
  final isToday = dayDate != null &&
      dayDate.year == referenceTime.year &&
      dayDate.month == referenceTime.month &&
      dayDate.day == referenceTime.day;

  final transitLabel = transit?['label']?.toString().trim() ?? '';
  final fromLabel = transit?['fromLabel']?.toString().trim() ?? '';
  final toLabel =
      transit?['toLabel']?.toString().trim().isNotEmpty == true
          ? transit!['toLabel']!.toString().trim()
          : place['name']?.toString().trim() ?? '下一站';
  final transitMinutes = _asIntValue(transit?['minutes']);
  final cautionNotes = <String>[];
  for (final alert in alerts) {
    final title = alert['title']?.toString() ?? '';
    final message = alert['message']?.toString() ?? '';
    final placeName = place['name']?.toString() ?? '';
    if ((title.contains(placeName) || message.contains(placeName)) &&
        message.trim().isNotEmpty) {
      cautionNotes.add(message.trim());
    } else if (fromLabel.isNotEmpty &&
        toLabel.isNotEmpty &&
        title.contains(fromLabel) &&
        title.contains(toLabel) &&
        message.trim().isNotEmpty) {
      cautionNotes.add(message.trim());
    }
  }
  if (cautionNotes.isEmpty && weather != null) {
    final rainProb = _asIntValue(weather['precipitationProbability']) ?? 0;
    final summary = weather['summary']?.toString().trim() ?? '';
    if (rainProb >= 50 && summary.isNotEmpty) {
      cautionNotes.add('目前天氣為 $summary，降雨機率約 $rainProb%，建議預留雨具。');
    }
  }
  if (cautionNotes.isEmpty && transitMinutes != null && transitMinutes >= 60) {
    cautionNotes.add('本段交通約 $transitMinutes 分鐘，建議提早整理並準備出發。');
  }

  final shouldPush = isToday && minutesUntil >= 0 && minutesUntil <= 20;
  return {
    'phase': focus.phase == 'current' ? 'after_current' : 'upcoming',
    'targetIndex': targetIndex,
    'targetPlaceName': place['name']?.toString() ?? '下一站',
    'scheduledTime': scheduledTime,
    'minutesUntil': minutesUntil,
    'fromLabel': fromLabel,
    'toLabel': toLabel,
    'transitLabel': transitLabel,
    'transitMinutes': transitMinutes,
    'weatherSummary': weather?['summary']?.toString(),
    'notes': cautionNotes.take(3).toList(),
    'shouldPush': shouldPush,
  };
}

Map<String, dynamic> _contextAlert({
  required String type,
  required String severity,
  required String title,
  required String message,
}) {
  return {
    'type': type,
    'severity': severity,
    'title': title,
    'message': message,
  };
}

Map<String, dynamic> _contextReplacementToJson(Place place) {
  return {
    'id': place.id,
    'name': place.name,
    'city': place.city,
    'address': place.address,
    'rating': place.rating,
    'tags': place.tags,
  };
}

_ContextFocus? _resolveContextFocus({
  required DateTime dayDate,
  required List<Map<String, dynamic>> visitItems,
  required DateTime referenceTime,
}) {
  if (visitItems.isEmpty) {
    return null;
  }
  final dayOnly = DateTime(dayDate.year, dayDate.month, dayDate.day);
  final refOnly = DateTime(
    referenceTime.year,
    referenceTime.month,
    referenceTime.day,
  );
  if (refOnly.isBefore(dayOnly)) {
    return _ContextFocus(
      targetIndex: 0,
      targetItem: visitItems.first,
      phase: 'upcoming',
    );
  }
  if (refOnly.isAfter(dayOnly)) {
    return _ContextFocus(
      targetIndex: visitItems.length - 1,
      targetItem: visitItems.last,
      phase: 'completed',
    );
  }

  final currentMinute = referenceTime.hour * 60 + referenceTime.minute;
  for (var i = 0; i < visitItems.length; i++) {
    final item = visitItems[i];
    final startMinute = _parseHmToMinute(item['time']?.toString());
    final endMinute = _parseHmToMinute(item['endTime']?.toString());
    if (startMinute == null) {
      continue;
    }
    if (currentMinute < startMinute) {
      return _ContextFocus(
        targetIndex: i,
        targetItem: item,
        phase: 'upcoming',
        currentMinute: currentMinute,
      );
    }
    if (endMinute != null && currentMinute <= endMinute) {
      return _ContextFocus(
        targetIndex: i,
        targetItem: item,
        phase: 'current',
        currentMinute: currentMinute,
      );
    }
  }
  return _ContextFocus(
    targetIndex: visitItems.length - 1,
    targetItem: visitItems.last,
    phase: 'completed',
    currentMinute: currentMinute,
  );
}

void _setContextNextAction(
  Map<String, dynamic> day,
  Map<String, dynamic> candidate,
) {
  final existing = day['_contextNextAction'];
  if (existing is! Map<String, dynamic>) {
    day['_contextNextAction'] = candidate;
    return;
  }
  final existingRank = _contextSeverityRank(existing['severity']?.toString());
  final candidateRank = _contextSeverityRank(candidate['severity']?.toString());
  if (candidateRank > existingRank) {
    day['_contextNextAction'] = candidate;
    return;
  }
  if (candidateRank == existingRank) {
    final existingPhase = existing['phase']?.toString() ?? '';
    final candidatePhase = candidate['phase']?.toString() ?? '';
    if (existingPhase != 'current' && candidatePhase == 'current') {
      day['_contextNextAction'] = candidate;
    }
  }
}

Map<String, dynamic>? _contextNextAction(Map<String, dynamic> day) {
  final raw = day.remove('_contextNextAction');
  if (raw is Map<String, dynamic>) {
    return raw;
  }
  return null;
}

List<Place> _findContextAlternativeCandidates({
  required Place targetPlace,
  required List<Place> dayPlaces,
  required List<Place> catalog,
  required DateTime dayDate,
  required int? targetStartMinute,
  required Set<String> usedPlaceIds,
  required bool preferIndoor,
}) {
  final targetCity = _normalizeLocationText(targetPlace.city);
  final targetAddress = _normalizeLocationText(targetPlace.address);

  final filtered = catalog.where((candidate) {
    if (candidate.id == targetPlace.id || usedPlaceIds.contains(candidate.id)) {
      return false;
    }
    if (candidate.lat == 0 && candidate.lng == 0) {
      return false;
    }
    if (_isPlaceIncomplete(candidate)) {
      return false;
    }
    if (preferIndoor && !_isIndoorPlace(candidate)) {
      return false;
    }
    if (targetCity.isNotEmpty &&
        _normalizeLocationText(candidate.city) != targetCity) {
      return false;
    }
    if (targetCity.isEmpty &&
        targetAddress.isNotEmpty &&
        !_normalizeLocationText(candidate.address).contains(targetAddress)) {
      return false;
    }
    final opening = _openingWindowForDate(candidate, dayDate);
    if (opening == null) {
      return false;
    }
    if (targetStartMinute != null) {
      if (targetStartMinute < opening.$1 || targetStartMinute >= opening.$2) {
        return false;
      }
      if (opening.$2 - targetStartMinute < 45) {
        return false;
      }
    }
    return true;
  }).toList();

  filtered.sort((a, b) {
    final aScore = (a.rating ?? 0) * 10 - _distanceKm(
      a.lat,
      a.lng,
      targetPlace.lat,
      targetPlace.lng,
    );
    final bScore = (b.rating ?? 0) * 10 - _distanceKm(
      b.lat,
      b.lng,
      targetPlace.lat,
      targetPlace.lng,
    );
    return bScore.compareTo(aScore);
  });
  return filtered;
}

void _appendTransitContextAlerts({
  required List<Map<String, dynamic>> alerts,
  required Set<String> suggestions,
  required Map<String, dynamic> transit,
  required bool rainRisk,
  required bool heatRisk,
}) {
  final mode = transit['mode']?.toString() ?? '';
  final label = transit['label']?.toString() ?? '交通';
  final minutes = _asIntValue(transit['minutes']) ?? 0;
  final fromLabel = transit['fromLabel']?.toString() ?? '上一站';
  final toLabel = transit['toLabel']?.toString() ?? '下一站';
  final lines =
      (transit['lines'] as List?)?.map((e) => e.toString()).toList() ??
      const <String>[];
  final isWalk = mode == 'walk' || label.contains('步行');
  final isTransit = mode == 'transit' || mode == 'bus' || mode == 'rail';

  if (rainRisk && isWalk && minutes >= 12) {
    alerts.add(_contextAlert(
      type: 'transit_rain_walk',
      severity: minutes >= 25 ? 'high' : 'medium',
      title: '$fromLabel 到 $toLabel 可能遇雨',
      message: '$label 約 $minutes 分鐘，若下雨可能明顯影響移動體驗。',
    ));
    suggestions.add('下雨時可改搭車或把步行較長的景點順序往後調整。');
  }
  if (rainRisk && isTransit && (minutes >= 45 || lines.length >= 2)) {
    alerts.add(_contextAlert(
      type: 'transit_rain_transfer',
      severity: minutes >= 80 ? 'high' : 'medium',
      title: '$fromLabel 到 $toLabel 轉乘風險提高',
      message: '$label 約 $minutes 分鐘${lines.isNotEmpty ? '，含 ${lines.join(' / ')}' : ''}，遇雨時轉乘與等車可能更花時間。',
    ));
    suggestions.add('雨勢較大時，保留多 15-20 分鐘轉乘緩衝較穩妥。');
  }
  if (heatRisk && isWalk && minutes >= 15) {
    alerts.add(_contextAlert(
      type: 'transit_heat_walk',
      severity: minutes >= 30 ? 'high' : 'medium',
      title: '$fromLabel 到 $toLabel 步行曝曬偏高',
      message: '$label 約 $minutes 分鐘，若正午高溫可能較耗體力。',
    ));
    suggestions.add('高溫時段可優先改搭車，或先插入室內休息點。');
  }
}

Place _planPlaceToPlace(Map<String, dynamic> json) {
  return Place(
    id: json['id']?.toString() ?? json['name']?.toString() ?? '_place_',
    name: json['name']?.toString() ?? '未命名景點',
    tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ?? const [],
    city: json['city']?.toString() ?? '',
    address: json['address']?.toString() ?? '',
    lat: _asDoubleValue(json['lat']) ?? 0,
    lng: _asDoubleValue(json['lng']) ?? 0,
    description: json['description']?.toString() ?? '',
    imageUrl: json['imageUrl']?.toString() ?? '',
    rating: _asDoubleValue(json['rating']),
    userRatingsTotal: _asIntValue(json['userRatingsTotal']),
    priceLevel: _asIntValue(json['priceLevel']),
    priceCategory: json['priceCategory']?.toString(),
    openingHours: json['openingHours'] is Map
        ? Map<String, dynamic>.from(json['openingHours'] as Map)
        : null,
    source: json['source']?.toString(),
  );
}

bool _isOutdoorPlace(Place place) {
  const outdoorTags = {
    'beach',
    'lake_river',
    'trail',
    'hiking',
    'forest',
    'mountain',
    'national_park',
    'water_sport',
    'waterfall',
    'zoo',
    'park',
    'bike',
  };
  final text = '${place.name} ${place.description} ${place.tags.join(' ')}';
  if (place.tags.any(outdoorTags.contains)) {
    return true;
  }
  return text.contains('步道') ||
      text.contains('海灘') ||
      text.contains('公園') ||
      text.contains('濕地') ||
      text.contains('登山') ||
      text.contains('森林') ||
      text.contains('農場');
}

bool _isIndoorPlace(Place place) {
  const indoorTags = {
    'museum',
    'aquarium',
    'cafe',
    'restaurant',
    'department_store',
    'concert_hall',
    'cinema',
    'creative_park',
    'handcraft_shop',
    'hot_spring',
  };
  final text = '${place.name} ${place.description} ${place.tags.join(' ')}';
  if (place.tags.any(indoorTags.contains)) {
    return true;
  }
  return text.contains('博物館') ||
      text.contains('美術館') ||
      text.contains('展覽') ||
      text.contains('文化館') ||
      text.contains('百貨') ||
      text.contains('商場') ||
      text.contains('影城') ||
      text.contains('咖啡') ||
      text.contains('餐廳');
}

String? _openingWeekdayText(Place place, DateTime date) {
  final raw = place.openingHours;
  if (raw == null) {
    return null;
  }
  final weekdayText = raw['weekday_text'];
  if (weekdayText is! List || weekdayText.isEmpty) {
    return null;
  }
  final weekdayMap = {
    1: '星期一',
    2: '星期二',
    3: '星期三',
    4: '星期四',
    5: '星期五',
    6: '星期六',
    7: '星期日',
  };
  final key = weekdayMap[date.weekday];
  if (key == null) {
    return null;
  }
  for (final item in weekdayText) {
    final text = item.toString().trim();
    if (text.startsWith(key)) {
      return text;
    }
  }
  return null;
}

String _contextOverallSeverity(List<Map<String, dynamic>> alerts) {
  var rank = 0;
  for (final alert in alerts) {
    rank = max(rank, _contextSeverityRank(alert['severity']?.toString()));
  }
  return switch (rank) {
    >= 3 => 'high',
    2 => 'medium',
    1 => 'low',
    _ => 'ok',
  };
}

int _contextSeverityRank(String? severity) {
  return switch (severity) {
    'high' => 3,
    'medium' => 2,
    'low' => 1,
    _ => 0,
  };
}

void _cleanupContextPushCooldown() {
  final cutoff = DateTime.now().toUtc().subtract(const Duration(hours: 6));
  final expired = _lineContextPushCooldown.entries
      .where((entry) => entry.value.isBefore(cutoff))
      .map((entry) => entry.key)
      .toList();
  for (final key in expired) {
    _lineContextPushCooldown.remove(key);
  }
}

Future<bool> _sendLineContextAwarenessNotification({
  required String userId,
  required DateTime dayDate,
  required Map<String, dynamic> result,
}) async {
  try {
    final alerts = (result['alerts'] as List?)
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList() ??
        const <Map<String, dynamic>>[];
    final upcomingReminder = result['upcomingReminder'] is Map
        ? Map<String, dynamic>.from(result['upcomingReminder'] as Map)
        : null;
    final shouldPushReminder = upcomingReminder?['shouldPush'] == true;
    if (alerts.isEmpty && !shouldPushReminder) {
      return false;
    }

    final user = await _store.findUserById(userId);
    if (user == null) {
      return false;
    }
    final lineUserId = user.lineUserId?.trim();
    if (lineUserId == null ||
        lineUserId.isEmpty ||
        user.linePushEnabled != true) {
      return false;
    }

    final overallSeverity = result['severity']?.toString() ?? 'ok';
    if (!shouldPushReminder && _contextSeverityRank(overallSeverity) < 2) {
      return false;
    }

    _cleanupContextPushCooldown();
    final signatureParts = <String>[];
    if (shouldPushReminder) {
      signatureParts.add(
        'reminder:${upcomingReminder?['targetPlaceName']}:${upcomingReminder?['scheduledTime']}',
      );
    }
    if (alerts.isNotEmpty) {
      signatureParts.add(
        alerts.map((alert) => '${alert['type']}:${alert['title']}').join('|'),
      );
    }
    final signature = signatureParts.join('||');
    final cooldownKey =
        '$userId|${dayDate.toIso8601String().substring(0, 10)}|$signature';
    final lastSentAt = _lineContextPushCooldown[cooldownKey];
    final now = DateTime.now().toUtc();
    final cooldownWindow = shouldPushReminder && alerts.isEmpty
        ? const Duration(minutes: 20)
        : const Duration(minutes: 45);
    if (lastSentAt != null &&
        now.difference(lastSentAt) < cooldownWindow) {
      return false;
    }

    final suggestions =
        (result['suggestions'] as List?)?.map((e) => e.toString()).toList() ??
            const <String>[];
    final backupPlans = (result['backupPlans'] as List?)
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList() ??
        const <Map<String, dynamic>>[];
    final message = _buildLineContextAwarenessSummary(
      dayDate: dayDate,
      alerts: alerts,
      suggestions: suggestions,
      backupPlans: backupPlans,
      upcomingReminder: shouldPushReminder ? upcomingReminder : null,
    );
    await _sendTrackedLinePush(
      to: lineUserId,
      text: message,
      category: shouldPushReminder ? 'upcoming_reminder' : 'context_awareness',
      userId: user.id,
      username: user.username,
    );
    _lineContextPushCooldown[cooldownKey] = now;
    _log.info('LINE 情境感知提醒已送出：user=$userId lineUserId=$lineUserId');
    return true;
  } catch (error, stack) {
    _log.warning('LINE 情境感知提醒失敗：user=$userId error=$error');
    _log.fine(stack.toString());
    return false;
  }
}

String _buildLineContextAwarenessSummary({
  required DateTime dayDate,
  required List<Map<String, dynamic>> alerts,
  required List<String> suggestions,
  required List<Map<String, dynamic>> backupPlans,
  Map<String, dynamic>? upcomingReminder,
}) {
  final dateLabel = '${dayDate.month}/${dayDate.day}';
  final lines = <String>['Smart Travel 即時提醒'];
  if (upcomingReminder != null) {
    final target = upcomingReminder['targetPlaceName']?.toString() ?? '下一站';
    final scheduled = upcomingReminder['scheduledTime']?.toString() ?? '';
    final transitLabel = upcomingReminder['transitLabel']?.toString() ?? '';
    final transitMinutes = _asIntValue(upcomingReminder['transitMinutes']);
    final notes =
        (upcomingReminder['notes'] as List?)?.map((e) => e.toString()).toList() ??
            const <String>[];
    lines.add(
      '$dateLabel 即將前往：$target${scheduled.isNotEmpty ? '（預計 $scheduled）' : ''}',
    );
    if (transitLabel.isNotEmpty || transitMinutes != null) {
      lines.add(
        '建議交通：${transitLabel.isNotEmpty ? transitLabel : '依目前路況出發'}'
        '${transitMinutes != null ? '，約 $transitMinutes 分鐘' : ''}',
      );
    }
    for (final note in notes.take(2)) {
      if (note.trim().isNotEmpty) {
        lines.add('• 注意：$note');
      }
    }
  }
  if (alerts.isNotEmpty) {
    lines.add('$dateLabel 行程需留意以下狀況：');
    for (final alert in alerts.take(3)) {
      lines.add('• ${alert['title']}: ${alert['message']}');
    }
  }
  if (suggestions.isNotEmpty) {
    lines.add('建議：${suggestions.take(2).join(' / ')}');
  }
  if (backupPlans.isNotEmpty) {
    for (final plan in backupPlans.take(1)) {
      final replacements =
          (plan['replacements'] as List?)
                  ?.whereType<Map>()
                  .map((e) => e['name']?.toString() ?? '')
                  .where((e) => e.isNotEmpty)
                  .take(2)
                  .join(' / ') ??
              '';
      if (replacements.isNotEmpty) {
        lines.add('雨備建議：${plan['targetPlaceName']} 可改為 $replacements');
      }
    }
  }
  lines.add('打開 App 可查看今日最新調整建議。');
  return lines.join('\n');
}

void _cleanupExpiredLineCodes() {
  final expiredKeys = _lineLinkCodes.entries
      .where((entry) => entry.value.expired)
      .map((entry) => entry.key)
      .toList();
  for (final key in expiredKeys) {
    _lineLinkCodes.remove(key);
  }
}

_LineLinkCode _issueLineLinkCode(String userId) {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final random = Random.secure();
  String nextCode() =>
      List.generate(6, (_) => chars[random.nextInt(chars.length)]).join();
  var code = nextCode();
  while (_lineLinkCodes.containsKey(code)) {
    code = nextCode();
  }
  final entry = _LineLinkCode(
    code: code,
    userId: userId,
    createdAt: DateTime.now(),
    expiresAt: DateTime.now().add(const Duration(minutes: 10)),
  );
  _lineLinkCodes[code] = entry;
  return entry;
}

bool _verifyLineSignature(String body, String signature) {
  final secret = _lineChannelSecret;
  if (secret == null || secret.isEmpty) {
    return false;
  }
  final mac = Hmac(sha256, utf8.encode(secret));
  final digest = mac.convert(utf8.encode(body));
  final expected = base64Encode(digest.bytes);
  return expected == signature;
}

Future<Response> _lineWebhookHandler(Request request) async {
  return _handle(() async {
    final rawBody = await request.readAsString();
    final signature = request.headers['x-line-signature'] ?? '';
    if (!_verifyLineSignature(rawBody, signature)) {
      _log.warning('LINE webhook 驗證失敗');
      return jsonResponse(401, errorBody('LINE webhook 驗證失敗'));
    }
    final decoded = jsonDecode(rawBody);
    if (decoded is! Map<String, dynamic>) {
      _log.warning('LINE webhook 格式錯誤: $decoded');
      return jsonResponse(400, errorBody('LINE webhook 格式錯誤'));
    }
    final events = (decoded['events'] as List?) ?? const [];
    _log.info('LINE webhook 收到 ${events.length} 筆事件');
    for (final rawEvent in events) {
      if (rawEvent is! Map) continue;
      final event = Map<String, dynamic>.from(rawEvent);
      await _handleLineEvent(event);
    }
    return jsonResponse(200, successBody(message: 'ok'));
  });
}

Future<void> _handleLineEvent(Map<String, dynamic> event) async {
  final eventType = event['type']?.toString();
  final replyToken = event['replyToken']?.toString();
  final source = event['source'];
  final lineUserId = source is Map ? source['userId']?.toString() : null;
  _log.info('LINE event type=$eventType user=$lineUserId');
  if (lineUserId == null || lineUserId.isEmpty) {
    _log.warning('LINE event 缺少 userId: $event');
    return;
  }
  if (eventType == 'follow') {
    if (replyToken != null && replyToken.isNotEmpty) {
      await _notificationService.replyLineText(
        replyToken: replyToken,
        text: '歡迎加入 Smart Travel。請回到 App 帳戶頁，點選「LINE 通知綁定」取得綁定碼，再把綁定碼傳給我。',
      );
    }
    return;
  }
  if (eventType != 'message') {
    return;
  }
  final message = event['message'];
  if (message is! Map) {
    return;
  }
  if (message['type']?.toString() != 'text') {
    if (replyToken != null && replyToken.isNotEmpty) {
      await _notificationService.replyLineText(
        replyToken: replyToken,
        text: '目前只支援文字綁定碼，請把 App 內顯示的綁定碼直接傳給我。',
      );
    }
    return;
  }
  final text = message['text']?.toString().trim().toUpperCase() ?? '';
  _log.info('LINE 文字訊息: "$text" from $lineUserId');
  _cleanupExpiredLineCodes();
  final binding = _lineLinkCodes[text];
  if (binding == null) {
    _log.info('LINE 綁定碼不存在: code=$text');
    if (replyToken != null && replyToken.isNotEmpty) {
      await _notificationService.replyLineText(
        replyToken: replyToken,
        text: '找不到這組綁定碼。請回到 App 重新產生新的 LINE 綁定碼後再試。',
      );
    }
    return;
  }
  if (binding.expired) {
    _lineLinkCodes.remove(text);
    _log.info('LINE 綁定碼已過期: code=$text user=${binding.userId}');
    if (replyToken != null && replyToken.isNotEmpty) {
      await _notificationService.replyLineText(
        replyToken: replyToken,
        text: '這組綁定碼已過期，請回到 App 重新產生新的綁定碼。',
      );
    }
    return;
  }
  final target = await _store.findUserById(binding.userId);
  if (target == null) {
    _lineLinkCodes.remove(text);
    _log.warning('LINE 綁定失敗：找不到使用者 id=${binding.userId} code=$text');
    if (replyToken != null && replyToken.isNotEmpty) {
      await _notificationService.replyLineText(
        replyToken: replyToken,
        text: '綁定失敗：找不到對應使用者，請回到 App 重新登入再試。',
      );
    }
    return;
  }
  if (replyToken != null && replyToken.isNotEmpty) {
    await _notificationService.replyLineText(
      replyToken: replyToken,
      text: '已收到綁定碼，正在為你完成 LINE 綁定，請稍候。',
    );
  }
  try {
    final existingLinkedUser = await _store.findByLineUserId(lineUserId);
    if (existingLinkedUser != null && existingLinkedUser.id != target.id) {
      await _store.updateUser(
        existingLinkedUser.copyWith(
          lineUserId: null,
          lineLinkedAt: null,
          linePushEnabled: false,
        ),
      );
    }
    await _store.updateUser(
      target.copyWith(
        lineUserId: lineUserId,
        lineLinkedAt: DateTime.now(),
        linePushEnabled: true,
      ),
    );
    _lineLinkCodes.remove(text);
    _log.info('LINE 綁定成功：user=${target.id} username=${target.username} lineUserId=$lineUserId code=$text');
    await _sendTrackedLinePush(
      to: lineUserId,
      text: 'LINE 綁定成功。之後你會在這裡收到 Smart Travel 的行程提醒與通知。回到 App 按「重新整理」即可看到最新狀態。',
      category: 'line_linked',
      userId: target.id,
      username: target.username,
    );
  } catch (error, stack) {
    _log.severe('LINE 綁定處理失敗：code=$text user=${target.id} lineUserId=$lineUserId', error, stack);
    await _sendTrackedLinePush(
      to: lineUserId,
      text: 'LINE 綁定處理失敗，請回到 App 重新產生綁定碼後再試一次。',
      category: 'line_link_failed',
      userId: target.id,
      username: target.username,
    );
  }
}

Place _placeFromBody(Map<String, dynamic> body, {required String fallbackId}) {
  final rawTags = body['tags'];
  final tags = rawTags is List
      ? rawTags.whereType<String>().toList()
      : <String>[];
  final fallbackCategory = body['category'] as String?;
  if (tags.isEmpty && fallbackCategory != null && fallbackCategory.isNotEmpty) {
    tags.add(fallbackCategory);
  }
  final parsedUpdatedAt = _parseDateTimeValue(body['updatedAt']);
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
    rating: (body['rating'] as num?)?.toDouble(),
    userRatingsTotal: (body['userRatingsTotal'] as num?)?.toInt(),
    priceLevel: (body['priceLevel'] as num?)?.toInt(),
    priceCategory: body['priceCategory'] as String?,
    openingHours: body['openingHours'] is Map
        ? Map<String, dynamic>.from(body['openingHours'] as Map)
        : null,
    source: body['source'] as String? ?? 'admin',
    updatedAt: parsedUpdatedAt ?? DateTime.now().toUtc(),
  );
}

List<Place> _sortPlacesByLatest(List<Place> places) {
  return List<Place>.from(places)
    ..sort((a, b) {
      final aTime = a.updatedAt;
      final bTime = b.updatedAt;
      if (aTime != null && bTime != null) {
        final cmp = bTime.compareTo(aTime);
        if (cmp != 0) return cmp;
      } else if (bTime != null) {
        return 1;
      } else if (aTime != null) {
        return -1;
      }
      return a.name.compareTo(b.name);
    });
}

List<Place> _sortPlacesByOldest(List<Place> places) {
  return List<Place>.from(places)
    ..sort((a, b) {
      final aTime = a.updatedAt;
      final bTime = b.updatedAt;
      if (aTime != null && bTime != null) {
        final cmp = aTime.compareTo(bTime);
        if (cmp != 0) return cmp;
      } else if (aTime != null) {
        return -1;
      } else if (bTime != null) {
        return 1;
      }
      return a.name.compareTo(b.name);
    });
}

bool _isRecentPlaceUpdate(Place place) {
  final updatedAt = place.updatedAt;
  if (updatedAt == null) return false;
  return DateTime.now().toUtc().difference(updatedAt.toUtc()) <=
      const Duration(hours: 24);
}

bool _isPlaceIncomplete(Place place) {
  final hasPrice = _effectivePriceLevel(place) != null ||
      (_effectivePriceCategory(place)?.trim().isNotEmpty ?? false);
  final hasOpeningHours = place.openingHours != null &&
      place.openingHours!.isNotEmpty;
  final hasLatLng = place.lat != 0 && place.lng != 0;
  return place.imageUrl.trim().isEmpty ||
      place.rating == null ||
      place.userRatingsTotal == null ||
      !hasPrice ||
      !hasOpeningHours ||
      place.city.trim().isEmpty ||
      place.address.trim().isEmpty ||
      !hasLatLng;
}

DateTime? _parseDateTimeValue(dynamic raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw.toUtc();
  final text = raw.toString().trim();
  if (text.isEmpty) return null;
  return DateTime.tryParse(text)?.toUtc();
}

DateTime? _parseDate(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return null;
  }
  try {
    return DateTime.parse(raw);
  } catch (_) {
    return null;
  }
}

Future<Map<String, dynamic>> _buildItineraryPlan({
  required List<String> interests,
  DateTime? startDate,
  DateTime? endDate,
  String? originCity,
  List<String> destinationCities = const [],
  String? tripPurpose,
  String? travelBehavior,
  String? location,
  int? people,
  int? budget,
  Map<String, dynamic>? backpackerAnswers,
  String? dayStartTime,
  String? dayEndTime,
  int? extraSpots,
  List<String> wishlistPlaces = const [],
}) async {
  final places = await _store.listPlaces();
  final normalizedOriginCity = originCity == null
      ? null
      : _normalizeLocationText(originCity);
  final normalizedDestinationCities = destinationCities
      .map(_normalizeLocationText)
      .where((city) => city.isNotEmpty)
      .toList();
  final normalizedTripPurpose = _normalizeTripPurpose(tripPurpose);
  final normalizedTravelBehavior = _normalizeTravelBehavior(travelBehavior);
  final normalizedLocation = location == null
      ? null
      : _normalizeLocationText(location);
  final locationParts = _parseLocationParts(location);
  final preferredTags = interests.map((tag) => tag.toLowerCase()).toSet();
  final totalDays = _calculateDays(startDate, endDate);

  bool containsLoc(String source, String target) {
    if (target.trim().isEmpty) return true;
    return _normalizeLocationText(
      source,
    ).contains(_normalizeLocationText(target));
  }

  bool matchesCityScope(Place place) {
    if (normalizedDestinationCities.isNotEmpty) {
      return normalizedDestinationCities.any(
        (city) => containsLoc(place.city, city) || containsLoc(place.address, city),
      );
    }
    final city = locationParts.$1;
    if (city == null || city.isEmpty) {
      return true;
    }
    return containsLoc(place.city, city) || containsLoc(place.address, city);
  }

  bool matchesTownshipScope(Place place) {
    if (normalizedDestinationCities.isNotEmpty) {
      return true;
    }
    final township = locationParts.$2;
    if (township == null || township.isEmpty) {
      return true;
    }
    return containsLoc(place.address, township);
  }

  bool matchesLocation(Place place) {
    if (normalizedLocation == null || normalizedLocation.isEmpty) {
      return true;
    }
    final haystack = _normalizeText(
      '${place.name} ${place.city} ${place.address}',
    );
    return haystack.contains(normalizedLocation);
  }

  bool matchesTags(Place place) {
    if (preferredTags.isEmpty) {
      return true;
    }
    return place.tags.any((tag) => preferredTags.contains(tag.toLowerCase()));
  }

  var candidates = places.where((place) {
    return matchesCityScope(place) &&
        matchesTownshipScope(place) &&
        matchesTags(place);
  }).toList();

  if (candidates.isEmpty) {
    candidates = places.where((place) {
      return matchesCityScope(place) && matchesTags(place);
    }).toList();
  }
  if (candidates.isEmpty) {
    candidates = places.where(matchesCityScope).toList();
  }
  if (candidates.isEmpty) {
    candidates = places.where((place) {
      return matchesLocation(place) && matchesTags(place);
    }).toList();
  }
  if (candidates.isEmpty) {
    candidates = places.where(matchesLocation).toList();
  }
  candidates = _filterCandidatesByTripPurpose(
    candidates,
    normalizedTripPurpose,
  );

  final plannerAssist = await _buildAiPlannerAssist(
    allPlaces: places,
    candidates: candidates,
    interests: interests,
    startDate: startDate,
    endDate: endDate,
    totalDays: totalDays,
    originCity: originCity,
    destinationCities: destinationCities,
    tripPurpose: normalizedTripPurpose,
    travelBehavior: normalizedTravelBehavior,
    location: location,
    budget: budget,
    people: people,
    dayStartTime: dayStartTime,
    dayEndTime: dayEndTime,
    extraSpots: extraSpots,
    wishlistPlaces: wishlistPlaces,
  );
  final prioritizedCities = _stringListFromJson(
    plannerAssist['prioritizedCities'],
    maxItems: 6,
  )
      .map(_normalizeLocationText)
      .where((e) => e.isNotEmpty)
      .toSet();
  final feasibilityDecision = _evaluateRouteFeasibilityDecision(
    allPlaces: places,
    totalDays: totalDays,
    originCity: originCity,
    destinationCities: destinationCities,
    tripPurpose: normalizedTripPurpose,
    travelBehavior: normalizedTravelBehavior,
    plannerAssist: plannerAssist,
  );
  if (feasibilityDecision.shouldBlock) {
    throw ApiException(
      422,
      feasibilityDecision.message,
      details: feasibilityDecision.toJson(),
    );
  }

  final targetPrice = _budgetToPriceCategory(budget);
  final weights = _PlannerWeights.fromInputs(
    targetPrice: targetPrice,
    people: people,
    tripPurpose: normalizedTripPurpose,
    travelBehavior: normalizedTravelBehavior,
    backpackerAnswers: backpackerAnswers,
  );
  final wishKeywords = wishlistPlaces
      .map(_normalizeLocationText)
      .where((e) => e.isNotEmpty)
      .toList();
  final baseScores = <String, double>{
    for (final place in candidates)
      place.id:
          _scorePlace(
            place,
            preferredTags: preferredTags,
            targetPrice: targetPrice,
            weights: weights,
          ) +
          _plannerPriorityBoost(place, prioritizedCities) +
          _wishlistBoost(place, wishKeywords),
  };
  candidates.sort(
    (a, b) => (baseScores[b.id] ?? 0).compareTo(baseScores[a.id] ?? 0),
  );
  final originAnchor = _resolveOriginAnchor(
    places: places,
    originCity: normalizedOriginCity,
  );

  final basePerDay = switch (normalizedTripPurpose) {
    'relax' => totalDays <= 2 ? 3 : 2,
    'explore' => totalDays <= 2 ? 5 : 4,
    'couple' => totalDays <= 2 ? 4 : 3,
    'family' => totalDays <= 2 ? 3 : 2,
    _ => totalDays <= 2 ? 4 : 3,
  };
  final extraSpotsClamped = (extraSpots ?? 0).clamp(0, 3);
  final aiDailyStopCap = (plannerAssist['dailyStopCap'] as num?)?.toInt();
  final aiRecommendedStartMinute = _parseHmToMinute(
    plannerAssist['recommendedStartTime']?.toString(),
  );
  final perDay = min(
    (basePerDay + extraSpotsClamped).clamp(2, 8),
    (aiDailyStopCap ?? 8).clamp(2, 8),
  );
  final lunchStartMinute =
      _parseHmToMinute(plannerAssist['lunchStartTime']?.toString()) ??
      (12 * 60);
  final dinnerStartMinute =
      _parseHmToMinute(plannerAssist['dinnerStartTime']?.toString()) ??
      (18 * 60);
  final preferredStartMinute =
      _parseHmToMinute(dayStartTime) ??
      aiRecommendedStartMinute ??
      (9 * 60 + 30);
  var preferredEndMinute = _parseHmToMinute(dayEndTime) ?? (18 * 60 + 30);
  if (preferredEndMinute <= preferredStartMinute) {
    preferredEndMinute = preferredStartMinute + 8 * 60;
  }

  final days = <Map<String, dynamic>>[];
  final globallyPicked = <Place>[];
  var remaining = List<Place>.from(candidates);
  for (var dayIndex = 0; dayIndex < totalDays; dayIndex++) {
    final dayDate = (startDate ?? DateTime.now()).add(Duration(days: dayIndex));
    var dayPreferredStartMinute = preferredStartMinute;
    var dayPreferredEndMinute = preferredEndMinute;
    if ((dayStartTime == null || dayStartTime.trim().isEmpty) && dayIndex == 0) {
      dayPreferredStartMinute = _effectiveStartMinuteForToday(
        dayDate: dayDate,
        fallbackStartMinute: preferredStartMinute,
        dayEndMinute: dayPreferredEndMinute,
      );
      if (dayPreferredEndMinute <= dayPreferredStartMinute) {
        dayPreferredEndMinute = dayPreferredStartMinute + 3 * 60;
      }
    }
    final dayTimeWindowMinutes = max(
      180,
      dayPreferredEndMinute - dayPreferredStartMinute,
    );
    final dayDailyMinutesBudget = min(weights.dayMinutesBudget, dayTimeWindowMinutes);
    final dayStayMinutesBudget = max(
      180,
      (dayDailyMinutesBudget * weights.stayBudgetRatio).round(),
    );
    final items = <Map<String, dynamic>>[];
    Map<String, dynamic>? dayOriginTransit;
    if (remaining.isNotEmpty) {
      final adjustedScores = <String, double>{};
      for (final place in remaining) {
        var score = baseScores[place.id] ?? 0;
        if (globallyPicked.isNotEmpty) {
          final history = globallyPicked.length <= 8
              ? globallyPicked
              : globallyPicked.sublist(globallyPicked.length - 8);
          score -=
              _diversityPenalty(place, history) *
              weights.diversityPenaltyWeight;
        }
        if (locationParts.$1 != null && locationParts.$1!.isNotEmpty) {
          if (_normalizeLocationText(
            place.city,
          ).contains(_normalizeLocationText(locationParts.$1!))) {
            score += 0.45;
          }
        }
        if (locationParts.$2 != null && locationParts.$2!.isNotEmpty) {
          if (_normalizeLocationText(
            place.address,
          ).contains(_normalizeLocationText(locationParts.$2!))) {
            score += 0.35;
          }
        }
        adjustedScores[place.id] = score;
      }

      var dayPicked = _selectDayPlacesByBackpacker(
        candidates: remaining,
        scores: adjustedScores,
        maxStops: perDay,
        stayBudgetMinutes: dayStayMinutesBudget,
        weights: weights,
        plannerAssist: plannerAssist,
      );
      if (dayPicked.isEmpty) {
        dayPicked = [remaining.first];
      }

      final dayStartAnchor = dayIndex == 0 ? originAnchor : null;
      var ordered = _orderPlacesByRoute(
        dayPicked,
        scores: adjustedScores,
        startAnchor: dayStartAnchor,
      );
      var routeBudget = dayDailyMinutesBudget;
      if (dayStartAnchor != null && ordered.isNotEmpty) {
        routeBudget = max(
          120,
          dayDailyMinutesBudget -
              _estimateTransitMinutesFromAnchor(
                dayStartAnchor,
                ordered.first,
                weights,
              ),
        );
      }
      ordered = _trimRouteToBudget(
        ordered,
        scores: adjustedScores,
        dailyMinutesBudget: routeBudget,
        weights: weights,
        startAnchor: dayStartAnchor,
        plannerAssist: plannerAssist,
      );
      ordered = _orderPlacesByTimeAwareRoute(
        ordered,
        scores: adjustedScores,
        weights: weights,
        dayStartMinute: dayPreferredStartMinute,
        dayEndMinute: dayPreferredEndMinute,
        dayDate: dayDate,
        startAnchor: dayStartAnchor,
        plannerAssist: plannerAssist,
      );

      var currentMinute = dayPreferredStartMinute;
      Map<String, dynamic>? originTransit;
      if (dayIndex == 0 && dayStartAnchor != null && ordered.isNotEmpty) {
        originTransit = await _buildOriginTransitSegment(
          originAnchor: dayStartAnchor,
          originLabel: originCity ?? '出發地',
          to: ordered.first,
          dayDate: dayDate,
          departureMinute: dayPreferredStartMinute,
          weights: weights,
        );
        final originMinutes = originTransit['minutes'] as int? ?? 0;
        currentMinute = dayPreferredStartMinute + originMinutes;
        dayOriginTransit = originTransit;
      }
      var hadLunchBreak = false;
      var hadDinnerBreak = false;
      for (var i = 0; i < ordered.length; i++) {
        final place = ordered[i];
        final nextPlace = i < ordered.length - 1 ? ordered[i + 1] : null;

        if (!hadLunchBreak &&
            _shouldInsertMealBreak(
              currentMinute,
              'lunch',
              suggestedStartMinute: lunchStartMinute,
            )) {
          items.add(
            _buildMealBreakItem(
              dayIndex: dayIndex,
              mealType: 'lunch',
              startMinute: currentMinute,
              city: place.city,
              plannerAssist: plannerAssist,
            ),
          );
          currentMinute += _mealBreakDurationMinutes(
            'lunch',
            plannerAssist: plannerAssist,
          );
          hadLunchBreak = true;
        }
        if (!hadDinnerBreak &&
            _shouldInsertMealBreak(
              currentMinute,
              'dinner',
              suggestedStartMinute: dinnerStartMinute,
            )) {
          items.add(
            _buildMealBreakItem(
              dayIndex: dayIndex,
              mealType: 'dinner',
              startMinute: currentMinute,
              city: place.city,
              plannerAssist: plannerAssist,
            ),
          );
          currentMinute += _mealBreakDurationMinutes(
            'dinner',
            plannerAssist: plannerAssist,
          );
          hadDinnerBreak = true;
        }

        final stayMinutes = _estimateStayMinutes(
          place,
          plannerAssist: plannerAssist,
        );
        final departureMinute = currentMinute + stayMinutes;
        items.add({
          'time': _minutesToHm(currentMinute),
          'endTime': _minutesToHm(departureMinute),
          'durationMinutes': stayMinutes,
          'place': _placeToPlanJson(place),
        });
        globallyPicked.add(place);

        var nextMinute = departureMinute;
        if (!hadLunchBreak &&
            _shouldInsertMealBreak(
              departureMinute,
              'lunch',
              suggestedStartMinute: lunchStartMinute,
            )) {
          items.add(
            _buildMealBreakItem(
              dayIndex: dayIndex,
              mealType: 'lunch',
              startMinute: departureMinute,
              city: place.city,
              plannerAssist: plannerAssist,
            ),
          );
          nextMinute += _mealBreakDurationMinutes(
            'lunch',
            plannerAssist: plannerAssist,
          );
          hadLunchBreak = true;
        }
        if (!hadDinnerBreak &&
            _shouldInsertMealBreak(
              nextMinute,
              'dinner',
              suggestedStartMinute: dinnerStartMinute,
            )) {
          items.add(
            _buildMealBreakItem(
              dayIndex: dayIndex,
              mealType: 'dinner',
              startMinute: nextMinute,
              city: place.city,
              plannerAssist: plannerAssist,
            ),
          );
          nextMinute += _mealBreakDurationMinutes(
            'dinner',
            plannerAssist: plannerAssist,
          );
          hadDinnerBreak = true;
        }

        if (nextPlace != null) {
          final transit = await _buildTransitSegment(
            from: ordered[i],
            to: nextPlace,
            dayDate: dayDate,
            departureMinute: nextMinute,
            weights: weights,
          );
          items.last['transitToNext'] = transit;
          currentMinute = nextMinute + (transit['minutes'] as int? ?? 0);
          if (currentMinute > dayPreferredEndMinute) {
            currentMinute = dayPreferredEndMinute;
          }
        } else {
          currentMinute = nextMinute;
        }
      }

      final usedIds = ordered.map((place) => place.id).toSet();
      remaining = remaining
          .where((place) => !usedIds.contains(place.id))
          .toList();
    }

    days.add({
      'day': dayIndex + 1,
      'date': dayDate.toIso8601String().substring(0, 10),
      if (dayOriginTransit != null) 'originTransit': dayOriginTransit,
      'items': items,
    });
  }

  await _attachWeatherToDays(days, catalog: places);
  final insight = await _buildItineraryInsight(
    allPlaces: places,
    days: days,
    interests: interests,
    originCity: originCity,
    destinationCities: destinationCities,
    tripPurpose: normalizedTripPurpose,
    travelBehavior: normalizedTravelBehavior,
    location: location,
    budget: budget,
    people: people,
    targetPrice: targetPrice,
  );
  final mergedInsight = _mergePlannerAssistIntoInsight(
    insight: insight,
    plannerAssist: plannerAssist,
  );

  return {
    'meta': {
      'days': totalDays,
      'location': location,
      'originCity': originCity,
      'destinationCities': destinationCities,
      'tripPurpose': normalizedTripPurpose,
      'travelBehavior': normalizedTravelBehavior,
      'locationMatched': candidates.isNotEmpty,
      'locationCity': locationParts.$1,
      'locationTownship': locationParts.$2,
      'people': people,
      'budget': budget,
      'tags': interests,
      'startDate': startDate?.toIso8601String(),
      'endDate': endDate?.toIso8601String(),
      'backpackerAnswers': backpackerAnswers,
      'dayStartTime': dayStartTime,
      'dayEndTime': dayEndTime,
      'extraSpots': extraSpots,
      'wishlistPlaces': wishlistPlaces,
      'weights': weights.toJson(),
      'insightSource': mergedInsight['source'],
      'plannerAssist': plannerAssist,
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
    },
    'insight': mergedInsight,
    'days': days,
  };
}

double _distanceKm(double lat1, double lon1, double lat2, double lon2) {
  if ((lat1 == 0 && lon1 == 0) || (lat2 == 0 && lon2 == 0)) {
    return 0;
  }
  const r = 6371.0;
  final dLat = _degToRad(lat2 - lat1);
  final dLon = _degToRad(lon2 - lon1);
  final a =
      sin(dLat / 2) * sin(dLat / 2) +
      cos(_degToRad(lat1)) *
          cos(_degToRad(lat2)) *
          sin(dLon / 2) *
          sin(dLon / 2);
  final c = 2 * atan2(sqrt(a), sqrt(1 - a));
  return r * c;
}

double _degToRad(double degree) => degree * pi / 180;

String _normalizeLocationText(String input) {
  return input
      .replaceAll('台', '臺')
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'[，,。．·\-_]'), '')
      .toLowerCase();
}

(String?, String?) _parseLocationParts(String? rawLocation) {
  if (rawLocation == null || rawLocation.trim().isEmpty) {
    return (null, null);
  }
  final text = rawLocation.trim();
  String? city;
  String? township;

  final cityMatch = RegExp(
    r'[\u4e00-\u9fff]{1,8}(縣|市)',
  ).allMatches(text).map((m) => m.group(0)).whereType<String>().toList();
  if (cityMatch.isNotEmpty) {
    city = cityMatch.first;
  }

  final townshipMatch = RegExp(
    r'[\u4e00-\u9fff]{1,8}(鄉|鎮|市|區)',
  ).allMatches(text).map((m) => m.group(0)).whereType<String>().toList();
  if (townshipMatch.isNotEmpty) {
    if (city != null &&
        townshipMatch.first == city &&
        townshipMatch.length > 1) {
      township = townshipMatch[1];
    } else {
      township = townshipMatch.first;
    }
  }
  return (city, township);
}

List<Place> _selectDayPlacesByBackpacker({
  required List<Place> candidates,
  required Map<String, double> scores,
  required int maxStops,
  required int stayBudgetMinutes,
  required _PlannerWeights weights,
  Map<String, dynamic>? plannerAssist,
}) {
  if (candidates.isEmpty || maxStops <= 0) {
    return const [];
  }

  final ranked = List<Place>.from(candidates)
    ..sort((a, b) => (scores[b.id] ?? 0).compareTo(scores[a.id] ?? 0));
  final purposeMatched = ranked
      .where((place) => _placeMatchesTripPurpose(place, weights.tripPurpose))
      .toList();
  final purposeOthers = ranked
      .where((place) => !_placeMatchesTripPurpose(place, weights.tripPurpose))
      .toList();
  final pool = switch (weights.tripPurpose) {
    'explore' => ranked.take(min(40, ranked.length)).toList(),
    _ when purposeMatched.length >= 4 => [
      ...purposeMatched.take(min(28, purposeMatched.length)),
      ...purposeOthers.take(min(10, purposeOthers.length)),
    ],
    _ => ranked.take(min(36, ranked.length)).toList(),
  };
  final stays = [
    for (final place in pool)
      _estimateStayMinutes(place, plannerAssist: plannerAssist),
  ];
  final purposeMatchedFlags = [
    for (final place in pool)
      _placeMatchesTripPurpose(place, weights.tripPurpose),
  ];

  var bestScore = -999999.0;
  var bestMinutes = 1 << 30;
  List<int> bestChoice = const [];

  void evaluate(List<int> picked, int usedMinutes, double score) {
    if (picked.isEmpty) return;
    final matchedCount = picked.where((idx) => purposeMatchedFlags[idx]).length;
    final mismatchCount = picked.length - matchedCount;
    final purposeBonus = switch (weights.tripPurpose) {
      'relax' => matchedCount * 2.1 - mismatchCount * 1.5,
      'couple' => matchedCount * 2.3 - mismatchCount * 1.6,
      'family' => matchedCount * 2.5 - mismatchCount * 1.9,
      'explore' => _exploreSelectionBonus([
        for (final idx in picked) pool[idx],
      ]),
      _ => 0.0,
    };
    final scoreWithCountBonus = score + picked.length * 0.12 + purposeBonus;
    if (scoreWithCountBonus > bestScore ||
        (scoreWithCountBonus == bestScore && usedMinutes < bestMinutes)) {
      bestScore = scoreWithCountBonus;
      bestMinutes = usedMinutes;
      bestChoice = List<int>.from(picked);
    }
  }

  void search(int start, List<int> picked, int usedMinutes, double score) {
    evaluate(picked, usedMinutes, score);
    if (picked.length >= maxStops) {
      return;
    }
    for (var i = start; i < pool.length; i++) {
      final nextMinutes = usedMinutes + stays[i];
      if (nextMinutes > stayBudgetMinutes) {
        continue;
      }
      picked.add(i);
      search(i + 1, picked, nextMinutes, score + (scores[pool[i].id] ?? 0));
      picked.removeLast();
    }
  }

  search(0, <int>[], 0, 0);
  if (bestChoice.isEmpty) {
    return pool.isEmpty ? const [] : [pool.first];
  }
  return [for (final idx in bestChoice) pool[idx]];
}

double _exploreSelectionBonus(List<Place> picked) {
  if (picked.isEmpty) return 0;
  final uniqueTags = <String>{};
  for (final place in picked) {
    uniqueTags.addAll(place.tags.map((tag) => tag.toLowerCase()));
  }
  return uniqueTags.length * 0.28;
}

List<Place> _orderPlacesByRoute(
  List<Place> places, {
  required Map<String, double> scores,
  (double lat, double lng)? startAnchor,
}) {
  if (places.length <= 2) {
    return List<Place>.from(places);
  }

  final remaining = List<Place>.from(places)
    ..sort((a, b) => (scores[b.id] ?? 0).compareTo(scores[a.id] ?? 0));
  if (startAnchor != null) {
    remaining.sort((a, b) {
      final da = _distanceKm(startAnchor.$1, startAnchor.$2, a.lat, a.lng);
      final db = _distanceKm(startAnchor.$1, startAnchor.$2, b.lat, b.lng);
      final wa = da - (scores[a.id] ?? 0) * 0.16;
      final wb = db - (scores[b.id] ?? 0) * 0.16;
      return wa.compareTo(wb);
    });
  }
  final route = <Place>[remaining.removeAt(0)];

  while (remaining.isNotEmpty) {
    final current = route.last;
    remaining.sort((a, b) {
      final da = _distanceKm(current.lat, current.lng, a.lat, a.lng);
      final db = _distanceKm(current.lat, current.lng, b.lat, b.lng);
      final wa = da - (scores[a.id] ?? 0) * 0.16;
      final wb = db - (scores[b.id] ?? 0) * 0.16;
      return wa.compareTo(wb);
    });
    route.add(remaining.removeAt(0));
  }

  return _twoOptImprove(route);
}

List<Place> _trimRouteToBudget(
  List<Place> route, {
  required Map<String, double> scores,
  required int dailyMinutesBudget,
  required _PlannerWeights weights,
  (double lat, double lng)? startAnchor,
  Map<String, dynamic>? plannerAssist,
}) {
  var output = List<Place>.from(route);
  while (output.length > 1 &&
      _estimateDayMinutes(
            output,
            weights,
            plannerAssist: plannerAssist,
          ) >
          dailyMinutesBudget) {
    var removeIdx = 0;
    var removeScore = 999999.0;
    for (var i = 0; i < output.length; i++) {
      final place = output[i];
      final value = scores[place.id] ?? 0;
      final stay = _estimateStayMinutes(place, plannerAssist: plannerAssist);
      final valueDensity = value / max(30, stay);
      final travelDelta = _removalTravelDeltaKm(output, i);
      final score = valueDensity + travelDelta * 0.05;
      if (score < removeScore) {
        removeScore = score;
        removeIdx = i;
      }
    }
    output.removeAt(removeIdx);
    output = _orderPlacesByRoute(
      output,
      scores: scores,
      startAnchor: startAnchor,
    );
  }
  return output;
}

List<Place> _orderPlacesByTimeAwareRoute(
  List<Place> places, {
  required Map<String, double> scores,
  required _PlannerWeights weights,
  required int dayStartMinute,
  required int dayEndMinute,
  required DateTime dayDate,
  (double lat, double lng)? startAnchor,
  Map<String, dynamic>? plannerAssist,
}) {
  if (places.length <= 1) return List<Place>.from(places);

  final remaining = List<Place>.from(places);
  final ordered = <Place>[];
  var currentMinute = dayStartMinute;
  Place? previous;

  while (remaining.isNotEmpty) {
    remaining.sort((a, b) {
      final ca = _timeAwareSelectionCost(
        candidate: a,
        previous: previous,
        currentMinute: currentMinute,
        scores: scores,
        weights: weights,
        dayEndMinute: dayEndMinute,
        dayDate: dayDate,
        startAnchor: startAnchor,
        plannerAssist: plannerAssist,
      );
      final cb = _timeAwareSelectionCost(
        candidate: b,
        previous: previous,
        currentMinute: currentMinute,
        scores: scores,
        weights: weights,
        dayEndMinute: dayEndMinute,
        dayDate: dayDate,
        startAnchor: startAnchor,
        plannerAssist: plannerAssist,
      );
      return ca.compareTo(cb);
    });

    final next = remaining.removeAt(0);
    ordered.add(next);

    final transitMinutes = previous == null
        ? 0
        : _estimateTransitMinutes(previous, next, weights);
    final window = _suggestedVisitWindow(next, dayDate: dayDate);
    final arrivalMinute = currentMinute + transitMinutes;
    final visitStart = max(arrivalMinute, window.$1);
    currentMinute =
        visitStart + _estimateStayMinutes(next, plannerAssist: plannerAssist);
    previous = next;
  }

  return ordered;
}

double _timeAwareSelectionCost({
  required Place candidate,
  required Place? previous,
  required int currentMinute,
  required Map<String, double> scores,
  required _PlannerWeights weights,
  required int dayEndMinute,
  required DateTime dayDate,
  (double lat, double lng)? startAnchor,
  Map<String, dynamic>? plannerAssist,
}) {
  final distanceKm = previous != null
      ? _distanceKm(previous.lat, previous.lng, candidate.lat, candidate.lng)
      : startAnchor != null
      ? _distanceKm(
          startAnchor.$1,
          startAnchor.$2,
          candidate.lat,
          candidate.lng,
        )
      : 0.0;
  final travelMinutes = previous != null
      ? _estimateTransitMinutes(previous, candidate, weights)
      : startAnchor != null
      ? max(8, (distanceKm / 35.0 * 60.0).round())
      : 0;
  final arrivalMinute = currentMinute + travelMinutes;
  final stayMinutes = _estimateStayMinutes(
    candidate,
    plannerAssist: plannerAssist,
  );
  final window = _suggestedVisitWindow(candidate, dayDate: dayDate);
  final openMinute = window.$1;
  final closeMinute = window.$2;
  final idealMinute = window.$3;

  final waitMinutes = max(0, openMinute - arrivalMinute);
  final visitStart = max(arrivalMinute, openMinute);
  final visitEnd = visitStart + stayMinutes;

  final tooEarlyPenalty = waitMinutes * 1.1;
  final closePenalty = max(0, visitEnd - closeMinute) * 5.0;
  final dayEndPenalty = max(0, visitEnd - dayEndMinute) * 4.0;
  final timePreferencePenalty = ((visitStart - idealMinute).abs()) * 0.05;

  var tagPenalty = 0.0;
  final tags = candidate.tags.map((e) => e.toLowerCase()).toSet();
  if ((tags.contains('night_market') || tags.contains('street_food')) &&
      visitStart < 16 * 60) {
    tagPenalty += 220.0;
  }
  if (tags.contains('restaurant') && visitStart < 10 * 60) {
    tagPenalty += 60.0;
  }
  if ((tags.contains('museum') || tags.contains('heritage')) &&
      visitStart > 18 * 60) {
    tagPenalty += 140.0;
  }

  final popularityBonus = () {
    final rating = candidate.rating ?? 0;
    final reviews = (candidate.userRatingsTotal ?? 0).clamp(0, 20000);
    final pop = (rating * 1.2) + (reviews / 4000.0);
    return pop;
  }();

  final scoreBonus = (scores[candidate.id] ?? 0) * 7.5 + popularityBonus * 2.4;

  return distanceKm * 10.0 +
      travelMinutes * 0.35 +
      tooEarlyPenalty +
      closePenalty +
      dayEndPenalty +
      timePreferencePenalty +
      tagPenalty -
      scoreBonus;
}

(double lat, double lng)? _resolveCityAnchor({
  required List<Place> places,
  required String? city,
}) {
  if (city == null || city.isEmpty) {
    return null;
  }
  final cityPlaces = places.where((place) {
    final placeCity = _normalizeLocationText(place.city);
    final address = _normalizeLocationText(place.address);
    return placeCity.contains(city) || address.contains(city);
  }).toList();
  if (cityPlaces.isEmpty) {
    return null;
  }
  final lat = cityPlaces.map((place) => place.lat).reduce((a, b) => a + b) /
      cityPlaces.length;
  final lng = cityPlaces.map((place) => place.lng).reduce((a, b) => a + b) /
      cityPlaces.length;
  return (lat, lng);
}

(double lat, double lng)? _resolveOriginAnchor({
  required List<Place> places,
  required String? originCity,
}) {
  return _resolveCityAnchor(places: places, city: originCity);
}

(int, int, int) _suggestedVisitWindow(Place place, {DateTime? dayDate}) {
  final tags = place.tags.map((e) => e.toLowerCase()).toSet();
  final name = _normalizeLocationText(place.name);
  final address = _normalizeLocationText(place.address);
  final text = '$name $address';

  bool hasAny(List<String> keys) => keys.any(tags.contains);
  bool textHas(String keyword) =>
      text.contains(_normalizeLocationText(keyword));
  final exactWindow = dayDate == null ? null : _openingWindowForDate(place, dayDate);

  // (openMinute, closeMinute, idealMinute)
  if (hasAny(['night_market']) || textHas('夜市')) {
    final ideal = (place.userRatingsTotal ?? 0) > 3000 ? 19 * 60 : 18 * 60 + 30;
    if (exactWindow != null) {
      final adjustedIdeal = _clampInt(
        ideal,
        exactWindow.$1,
        max(exactWindow.$1, exactWindow.$2 - 1),
      );
      return (exactWindow.$1, exactWindow.$2, adjustedIdeal);
    }
    return (17 * 60, 23 * 60, ideal);
  }
  if (hasAny(['street_food']) || hasAny(['restaurant']) || textHas('美食')) {
    if (exactWindow != null) {
      final adjustedIdeal = _clampInt(
        18 * 60 + 15,
        exactWindow.$1,
        max(exactWindow.$1, exactWindow.$2 - 1),
      );
      return (exactWindow.$1, exactWindow.$2, adjustedIdeal);
    }
    return (11 * 60, 21 * 60 + 30, 18 * 60 + 15);
  }
  if (hasAny(['cafe'])) {
    if (exactWindow != null) {
      final adjustedIdeal = _clampInt(
        14 * 60,
        exactWindow.$1,
        max(exactWindow.$1, exactWindow.$2 - 1),
      );
      return (exactWindow.$1, exactWindow.$2, adjustedIdeal);
    }
    return (9 * 60, 20 * 60, 14 * 60);
  }
  if (hasAny(['museum', 'heritage', 'creative_park']) ||
      textHas('博物館') ||
      textHas('紀念館') ||
      textHas('美術館')) {
    if (exactWindow != null) {
      final adjustedIdeal = _clampInt(
        13 * 60 + 30,
        exactWindow.$1,
        max(exactWindow.$1, exactWindow.$2 - 1),
      );
      return (exactWindow.$1, exactWindow.$2, adjustedIdeal);
    }
    return (9 * 60, 17 * 60 + 30, 13 * 60 + 30);
  }
  if (hasAny(['temple', 'church']) || textHas('寺') || textHas('宮')) {
    if (exactWindow != null) {
      final adjustedIdeal = _clampInt(
        10 * 60,
        exactWindow.$1,
        max(exactWindow.$1, exactWindow.$2 - 1),
      );
      return (exactWindow.$1, exactWindow.$2, adjustedIdeal);
    }
    return (6 * 60, 19 * 60, 10 * 60);
  }
  if (hasAny(['national_park', 'lake_river', 'beach', 'waterfall', 'zoo'])) {
    if (exactWindow != null) {
      final adjustedIdeal = _clampInt(
        10 * 60 + 30,
        exactWindow.$1,
        max(exactWindow.$1, exactWindow.$2 - 1),
      );
      return (exactWindow.$1, exactWindow.$2, adjustedIdeal);
    }
    return (8 * 60, 17 * 60 + 30, 10 * 60 + 30);
  }
  if (hasAny(['department_store', 'shopping']) || textHas('百貨')) {
    if (exactWindow != null) {
      final adjustedIdeal = _clampInt(
        16 * 60,
        exactWindow.$1,
        max(exactWindow.$1, exactWindow.$2 - 1),
      );
      return (exactWindow.$1, exactWindow.$2, adjustedIdeal);
    }
    return (11 * 60, 22 * 60, 16 * 60);
  }
  if (exactWindow != null) {
    final adjustedIdeal = _clampInt(
      (exactWindow.$1 + exactWindow.$2) ~/ 2,
      exactWindow.$1,
      max(exactWindow.$1, exactWindow.$2 - 1),
    );
    return (exactWindow.$1, exactWindow.$2, adjustedIdeal);
  }
  return (9 * 60, 18 * 60, 13 * 60);
}

(int, int)? _openingWindowForDate(Place place, DateTime date) {
  final raw = place.openingHours;
  if (raw == null) return null;
  final periods = raw['periods'];
  if (periods is! List || periods.isEmpty) return null;

  final googleDow = date.weekday % 7; // Sunday=0
  const dayMinutes = 24 * 60;
  const weekMinutes = 7 * dayMinutes;
  final targetStart = googleDow * dayMinutes;
  final targetEnd = targetStart + dayMinutes;
  final windows = <(int, int)>[];

  for (final item in periods.whereType<Map>()) {
    final open = item['open'];
    if (open is! Map) continue;
    final openDay = _asOpeningDay(open['day']);
    final openMinute = _asOpeningMinute(open['time']);
    if (openDay == null || openMinute == null) continue;
    final close = item['close'];

    var startAbs = openDay * dayMinutes + openMinute;
    int endAbs;
    if (close is Map) {
      final closeDay = _asOpeningDay(close['day']);
      final closeMinute = _asOpeningMinute(close['time']);
      if (closeDay == null || closeMinute == null) continue;
      endAbs = closeDay * dayMinutes + closeMinute;
      if (endAbs <= startAbs) {
        endAbs += weekMinutes;
      }
    } else {
      endAbs = startAbs + dayMinutes; // open 24h-ish fallback
    }

    for (final shift in const [-1, 0, 1]) {
      final s = startAbs + shift * weekMinutes;
      final e = endAbs + shift * weekMinutes;
      final overlapStart = max(s, targetStart);
      final overlapEnd = min(e, targetEnd);
      if (overlapEnd > overlapStart) {
        windows.add((overlapStart - targetStart, overlapEnd - targetStart));
      }
    }
  }

  if (windows.isEmpty) {
    return null;
  }
  var openMin = windows.first.$1;
  var closeMin = windows.first.$2;
  for (final w in windows.skip(1)) {
    if (w.$1 < openMin) openMin = w.$1;
    if (w.$2 > closeMin) closeMin = w.$2;
  }
  openMin = _clampInt(openMin, 0, dayMinutes - 1);
  closeMin = _clampInt(closeMin, 1, dayMinutes);
  if (closeMin <= openMin) return null;
  return (openMin, closeMin);
}

int? _asOpeningDay(dynamic value) {
  if (value is int) return _clampInt(value, 0, 6);
  if (value is num) return _clampInt(value.toInt(), 0, 6);
  final parsed = int.tryParse(value?.toString() ?? '');
  return parsed == null ? null : _clampInt(parsed, 0, 6);
}

int? _asOpeningMinute(dynamic value) {
  final text = value?.toString() ?? '';
  if (text.length < 4) return null;
  final hh = int.tryParse(text.substring(0, 2));
  final mm = int.tryParse(text.substring(2, 4));
  if (hh == null || mm == null) return null;
  return (_clampInt(hh, 0, 23) * 60) + _clampInt(mm, 0, 59);
}

List<Place> _twoOptImprove(List<Place> route) {
  if (route.length < 4) {
    return route;
  }
  var improved = true;
  var best = List<Place>.from(route);
  var bestDistance = _routeDistanceKm(best);
  while (improved) {
    improved = false;
    for (var i = 1; i < best.length - 2; i++) {
      for (var j = i + 1; j < best.length - 1; j++) {
        final candidate = List<Place>.from(best);
        final section = candidate.sublist(i, j + 1).reversed.toList();
        candidate.setRange(i, j + 1, section);
        final candidateDistance = _routeDistanceKm(candidate);
        if (candidateDistance + 0.001 < bestDistance) {
          best = candidate;
          bestDistance = candidateDistance;
          improved = true;
        }
      }
    }
  }
  return best;
}

double _routeDistanceKm(List<Place> route) {
  var total = 0.0;
  for (var i = 0; i < route.length - 1; i++) {
    total += _distanceKm(
      route[i].lat,
      route[i].lng,
      route[i + 1].lat,
      route[i + 1].lng,
    );
  }
  return total;
}

double _removalTravelDeltaKm(List<Place> route, int index) {
  final prev = index > 0 ? route[index - 1] : null;
  final curr = route[index];
  final next = index < route.length - 1 ? route[index + 1] : null;
  var before = 0.0;
  var after = 0.0;
  if (prev != null) {
    before += _distanceKm(prev.lat, prev.lng, curr.lat, curr.lng);
  }
  if (next != null) {
    before += _distanceKm(curr.lat, curr.lng, next.lat, next.lng);
  }
  if (prev != null && next != null) {
    after += _distanceKm(prev.lat, prev.lng, next.lat, next.lng);
  }
  return after - before;
}

int _estimateStayMinutes(
  Place place, {
  Map<String, dynamic>? plannerAssist,
}) {
  var minutes = 70;
  final tags = place.tags.map((e) => e.toLowerCase()).toSet();
  final text =
      '${place.name} ${place.description} ${place.tags.join(' ')}'.toLowerCase();

  bool hasAny(Iterable<String> values) =>
      values.any((value) => tags.contains(value) || text.contains(value));

  if (hasAny(['theme_park', 'amusement', 'aquarium', 'zoo'])) {
    minutes += 70;
  }
  if (hasAny([
    'national_park',
    'lake_river',
    'beach',
    'trail',
    'hiking',
    'forest',
    'water_sport',
    'mountain',
  ])) {
    minutes += 55;
  }
  if (hasAny(['museum', 'heritage', 'creative_park', 'gallery', 'exhibition'])) {
    minutes += 35;
  }
  if (hasAny(['night_market', 'street_food', 'market', 'food'])) {
    minutes += 35;
  }
  if (hasAny(['temple', 'church', 'memorial', 'historic'])) {
    minutes += 20;
  }
  if (hasAny(['campus', 'park', 'garden'])) {
    minutes += 15;
  }

  final rating = place.rating ?? 0;
  final reviews = place.userRatingsTotal ?? 0;
  if (reviews >= 10000) {
    minutes += 25;
  } else if (reviews >= 3000) {
    minutes += 15;
  } else if (reviews <= 150) {
    minutes -= 10;
  }
  if (rating >= 4.7) {
    minutes += 10;
  } else if (rating > 0 && rating <= 3.8) {
    minutes -= 10;
  }
  if (place.description.trim().isNotEmpty) {
    minutes += 8;
  }
  final stayStyle = plannerAssist?['stayStyle']?.toString().trim().toLowerCase();
  switch (stayStyle) {
    case 'slow':
      minutes = (minutes * 1.18).round();
      break;
    case 'compact':
      minutes = (minutes * 0.88).round();
      break;
    default:
      break;
  }
  return minutes.clamp(40, 240).toInt();
}

int _mealBreakDurationMinutes(
  String mealType, {
  Map<String, dynamic>? plannerAssist,
}) {
  var minutes = switch (mealType) {
    'lunch' => 60,
    'dinner' => 75,
    _ => 45,
  };
  final stayStyle = plannerAssist?['stayStyle']?.toString().trim().toLowerCase();
  if (stayStyle == 'slow') {
    minutes += mealType == 'dinner' ? 10 : 5;
  } else if (stayStyle == 'compact') {
    minutes -= mealType == 'dinner' ? 10 : 5;
  }
  return minutes.clamp(35, 95);
}

bool _shouldInsertMealBreak(
  int currentMinute,
  String mealType, {
  int? suggestedStartMinute,
}) {
  final (windowStart, latestRecommended) = switch (mealType) {
    'lunch' => (
        max(10 * 60 + 45, (suggestedStartMinute ?? (12 * 60)) - 30),
        min(14 * 60 + 15, (suggestedStartMinute ?? (12 * 60)) + 90),
      ),
    'dinner' => (
        max(17 * 60, (suggestedStartMinute ?? (18 * 60)) - 30),
        min(20 * 60 + 30, (suggestedStartMinute ?? (18 * 60)) + 105),
      ),
    _ => (12 * 60, 19 * 60),
  };
  return currentMinute >= windowStart && currentMinute <= latestRecommended;
}

Map<String, dynamic> _buildMealBreakItem({
  required int dayIndex,
  required String mealType,
  required int startMinute,
  required String city,
  Map<String, dynamic>? plannerAssist,
}) {
  final durationMinutes = _mealBreakDurationMinutes(
    mealType,
    plannerAssist: plannerAssist,
  );
  final start = _minutesToHm(startMinute);
  final end = _minutesToHm(startMinute + durationMinutes);
  final isLunch = mealType == 'lunch';
  return {
    'time': start,
    'endTime': end,
    'durationMinutes': durationMinutes,
    'place': {
      'id': 'meal-${mealType}-${dayIndex + 1}-$start',
      'name': isLunch ? '午餐時間' : '晚餐時間',
      'city': city,
      'address': '',
      'description': isLunch
          ? '預留午餐與短暫休息時間，避免上午景點連續壓縮體力。'
          : '預留晚餐與休息時間，讓晚間行程節奏更合理。',
      'lat': null,
      'lng': null,
      'tags': ['meal_break', mealType],
      'rating': null,
      'userRatingsTotal': null,
      'priceLevel': null,
      'priceCategory': null,
      'imageUrl': '',
      'openingHours': null,
      'kind': 'meal_break',
    },
  };
}

int _estimateTransitMinutes(Place from, Place to, _PlannerWeights weights) {
  final km = _distanceKm(from.lat, from.lng, to.lat, to.lng);
  if (km <= 0.6) return 8;
  if (km <= 2) return max(10, (km / 4.5 * 60).round());
  if (km <= 20) {
    final speed = weights.preferTransitFriendly ? 22.0 : 30.0;
    final buffer = weights.preferTransitFriendly ? 10 : 6;
    return max(15, (km / speed * 60).round() + buffer);
  }
  final speed = weights.preferTransitFriendly ? 42.0 : 55.0;
  final buffer = weights.preferTransitFriendly ? 18 : 12;
  return max(30, (km / speed * 60).round() + buffer);
}

int _estimateDayMinutes(
  List<Place> route,
  _PlannerWeights weights, {
  Map<String, dynamic>? plannerAssist,
}) {
  var total = 0;
  for (final place in route) {
    total += _estimateStayMinutes(place, plannerAssist: plannerAssist);
  }
  for (var i = 0; i < route.length - 1; i++) {
    total += _estimateTransitMinutes(route[i], route[i + 1], weights);
  }
  return total;
}

String _minutesToHm(int totalMinutes) {
  final clamped = totalMinutes.clamp(0, 23 * 60 + 59);
  final h = (clamped ~/ 60).toString().padLeft(2, '0');
  final m = (clamped % 60).toString().padLeft(2, '0');
  return '$h:$m';
}

int _estimateTransitMinutesFromAnchor(
  (double lat, double lng) fromAnchor,
  Place to,
  _PlannerWeights weights,
) {
  final pseudoOrigin = Place(
    id: '_origin_anchor_',
    name: '出發地',
    tags: const [],
    city: '',
    address: '',
    lat: fromAnchor.$1,
    lng: fromAnchor.$2,
    description: '',
    imageUrl: '',
  );
  return _estimateTransitMinutes(pseudoOrigin, to, weights);
}

int _clampInt(int value, int minValue, int maxValue) {
  return value.clamp(minValue, maxValue);
}

int _effectiveStartMinuteForToday({
  required DateTime dayDate,
  required int fallbackStartMinute,
  required int dayEndMinute,
}) {
  final now = DateTime.now();
  final isSameDay =
      now.year == dayDate.year &&
      now.month == dayDate.month &&
      now.day == dayDate.day;
  if (!isSameDay) {
    return fallbackStartMinute;
  }

  final nowMinute = now.hour * 60 + now.minute;
  final bufferedNowMinute = nowMinute + 30;
  final roundedUp = ((bufferedNowMinute + 14) ~/ 15) * 15;
  final latestAllowedStart = max(fallbackStartMinute, dayEndMinute - 180);
  return _clampInt(
    max(fallbackStartMinute, roundedUp),
    fallbackStartMinute,
    latestAllowedStart,
  );
}

int? _parseHmToMinute(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final parts = raw.trim().split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  final hh = h.clamp(0, 23);
  final mm = m.clamp(0, 59);
  return hh * 60 + mm;
}

Future<Map<String, dynamic>> _buildTransitSegment({
  required Place from,
  required Place to,
  required DateTime dayDate,
  required int departureMinute,
  required _PlannerWeights weights,
}) async {
  final apiResult = await _fetchTransitSegmentFromGoogle(
    from: from,
    to: to,
    dayDate: dayDate,
    departureMinute: departureMinute,
    weights: weights,
  );
  if (apiResult != null) {
    return apiResult;
  }
  return _buildEstimatedTransitSegment(from: from, to: to, weights: weights);
}

Future<Map<String, dynamic>> _buildOriginTransitSegment({
  required (double lat, double lng) originAnchor,
  required String originLabel,
  required Place to,
  required DateTime dayDate,
  required int departureMinute,
  required _PlannerWeights weights,
}) async {
  final from = Place(
    id: '_origin_${_normalizeLocationText(originLabel)}',
    name: originLabel,
    tags: const [],
    city: originLabel,
    address: originLabel,
    lat: originAnchor.$1,
    lng: originAnchor.$2,
    description: '',
    imageUrl: '',
  );
  final transit = await _buildTransitSegment(
    from: from,
    to: to,
    dayDate: dayDate,
    departureMinute: departureMinute,
    weights: weights,
  );
  final minutes = transit['minutes'] as int? ?? 0;
  return {
    ...transit,
    'fromLabel': originLabel,
    'toLabel': to.name,
    'departureTime': _minutesToHm(departureMinute),
    'arrivalTime': _minutesToHm(departureMinute + minutes),
    'detail':
        '從$originLabel出發前往${to.name}${transit['detail']?.toString().trim().isNotEmpty == true ? '；${transit['detail']}' : ''}',
  };
}

Future<Map<String, dynamic>?> _fetchTransitSegmentFromGoogle({
  required Place from,
  required Place to,
  required DateTime dayDate,
  required int departureMinute,
  required _PlannerWeights weights,
}) async {
  final key = Platform.environment['GOOGLE_MAPS_API_KEY'] ?? '';
  if (key.isEmpty) {
    return null;
  }
  if ((from.lat == 0 && from.lng == 0) || (to.lat == 0 && to.lng == 0)) {
    return null;
  }

  final departure = DateTime(
    dayDate.year,
    dayDate.month,
    dayDate.day,
  ).add(Duration(minutes: departureMinute));
  final departureEpoch = (departure.toUtc().millisecondsSinceEpoch ~/ 1000)
      .toString();
  final uri = Uri.https('maps.googleapis.com', '/maps/api/directions/json', {
    'origin': '${from.lat},${from.lng}',
    'destination': '${to.lat},${to.lng}',
    'mode': 'transit',
    'language': 'zh-TW',
    'region': 'tw',
    'departure_time': departureEpoch,
    'key': key,
  });

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      return null;
    }
    final body = await utf8.decodeStream(response);
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      return null;
    }
    final status = decoded['status']?.toString();
    if (status != 'OK') {
      return null;
    }
    final routes = decoded['routes'];
    if (routes is! List || routes.isEmpty || routes.first is! Map) {
      return null;
    }
    final route = routes.first as Map;
    final legs = route['legs'];
    if (legs is! List || legs.isEmpty || legs.first is! Map) {
      return null;
    }
    final leg = legs.first as Map;
    final durationMap = leg['duration'];
    final durationMinutes = durationMap is Map
        ? ((durationMap['value'] as num?)?.toInt() ?? 0) ~/ 60
        : 0;
    if (durationMinutes <= 0) {
      return null;
    }
    final depTime = (leg['departure_time'] as Map?)?['text']?.toString();
    final arrTime = (leg['arrival_time'] as Map?)?['text']?.toString();
    final distanceText = (leg['distance'] as Map?)?['text']?.toString() ?? '';
    final distanceKm =
        ((leg['distance'] as Map?)?['value'] as num?)?.toDouble() == null
        ? _distanceKm(from.lat, from.lng, to.lat, to.lng)
        : (((leg['distance'] as Map?)?['value'] as num?)!.toDouble() / 1000.0);
    final estimatedMinutes = _estimateTransitMinutes(from, to, weights);

    final steps = leg['steps'];
    final lineParts = <String>[];
    final stepTexts = <String>[];
    if (steps is List) {
      for (final step in steps.whereType<Map>()) {
        final mode = step['travel_mode']?.toString();
        if (mode != 'TRANSIT') continue;
        final transit = step['transit_details'];
        if (transit is! Map) continue;
        final line = transit['line'];
        String? lineName;
        if (line is Map) {
          lineName =
              line['short_name']?.toString() ??
              line['name']?.toString() ??
              line['vehicle']?['name']?.toString();
        }
        final depStop = (transit['departure_stop'] as Map?)?['name']
            ?.toString();
        final arrStop = (transit['arrival_stop'] as Map?)?['name']?.toString();
        if (lineName != null && lineName.trim().isNotEmpty) {
          lineParts.add(lineName.trim());
        }
        final sb = StringBuffer();
        if (lineName != null && lineName.trim().isNotEmpty) {
          sb.write('搭乘 $lineName');
        } else {
          sb.write('搭乘大眾運輸');
        }
        if (depStop != null && depStop.isNotEmpty) {
          sb.write('（$depStop');
          if (arrStop != null && arrStop.isNotEmpty) {
            sb.write(' → $arrStop');
          }
          sb.write('）');
        }
        stepTexts.add(sb.toString());
      }
    }

    final uniqueLines = lineParts.toSet().take(4).toList();
    if (!_isTransitResultTourismReasonable(
      durationMinutes: durationMinutes,
      estimatedMinutes: estimatedMinutes,
      distanceKm: distanceKm,
      transferLineCount: uniqueLines.length,
    )) {
      return null;
    }
    final lineText = uniqueLines.join(' / ');
    final detailText = stepTexts.take(2).join('；');
    return {
      'provider': 'google_directions',
      'mode': uniqueLines.isNotEmpty ? 'bus' : 'transit',
      'label': uniqueLines.isNotEmpty ? '公車 $lineText' : '大眾運輸',
      'minutes': durationMinutes,
      'distanceText': distanceText,
      'departureTime': depTime,
      'arrivalTime': arrTime,
      'lines': uniqueLines,
      'detail': detailText,
    };
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

bool _isTransitResultTourismReasonable({
  required int durationMinutes,
  required int estimatedMinutes,
  required double distanceKm,
  required int transferLineCount,
}) {
  if (durationMinutes <= 0) return false;
  if (durationMinutes >= 8 * 60) {
    return false;
  }

  final ratio = estimatedMinutes <= 0 ? 99.0 : durationMinutes / estimatedMinutes;
  if (distanceKm >= 80 && durationMinutes >= 5 * 60) {
    return false;
  }
  if (distanceKm >= 40 && ratio >= 2.8 && durationMinutes - estimatedMinutes >= 120) {
    return false;
  }
  if (transferLineCount >= 3 && durationMinutes >= 4 * 60) {
    return false;
  }
  return true;
}

Map<String, dynamic> _buildEstimatedTransitSegment({
  required Place from,
  required Place to,
  required _PlannerWeights weights,
}) {
  final km = _distanceKm(from.lat, from.lng, to.lat, to.lng);
  final minutes = _estimateTransitMinutes(from, to, weights);
  String label;
  String mode;
  if (km <= 1.5) {
    label = '步行';
    mode = 'walk';
  } else if (km <= 20) {
    label = '開車/計程車';
    mode = 'car';
  } else {
    label = '大眾運輸';
    mode = 'transit';
  }
  return {
    'provider': 'estimate',
    'mode': mode,
    'label': label,
    'minutes': minutes,
    'distanceText': '${km.toStringAsFixed(1)} km',
    'lines': const <String>[],
  };
}

Future<Map<String, dynamic>> _buildItineraryInsight({
  required List<Place> allPlaces,
  required List<Map<String, dynamic>> days,
  required List<String> interests,
  required String? originCity,
  required List<String> destinationCities,
  required String? tripPurpose,
  required String? travelBehavior,
  required String? location,
  required int? budget,
  required int? people,
  required String? targetPrice,
}) async {
  final fallback = _buildRuleBasedInsight(
    allPlaces: allPlaces,
    days: days,
    interests: interests,
    originCity: originCity,
    destinationCities: destinationCities,
    tripPurpose: tripPurpose,
    travelBehavior: travelBehavior,
    location: location,
    budget: budget,
    people: people,
    targetPrice: targetPrice,
  );
  final key = _openAiApiKey;
  if (key == null || key.trim().isEmpty) {
    return fallback;
  }

  try {
    final base = (_openAiBaseUrl == null || _openAiBaseUrl!.trim().isEmpty)
        ? 'https://api.openai.com'
        : _openAiBaseUrl!.trim();
    final uri = Uri.parse(base).resolve('/v1/chat/completions');
    final model = (_openAiModel == null || _openAiModel!.trim().isEmpty)
        ? 'gpt-4o-mini'
        : _openAiModel!.trim();
    final prompt = _buildItineraryInsightPrompt(
      allPlaces: allPlaces,
      days: days,
      interests: interests,
      originCity: originCity,
      destinationCities: destinationCities,
      tripPurpose: tripPurpose,
      travelBehavior: travelBehavior,
      location: location,
      budget: budget,
      people: people,
      targetPrice: targetPrice,
    );
    final payload = {
      'model': model,
      'temperature': 0.35,
      'response_format': {'type': 'json_object'},
      'messages': [
        {
          'role': 'system',
          'content': '你是資深旅遊規劃師。請用繁體中文，清楚說明排程理由。只能回傳 JSON 物件。',
        },
        {'role': 'user', 'content': prompt},
      ],
    };

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      request.add(utf8.encode(jsonEncode(payload)));
      final response = await request.close().timeout(
        const Duration(seconds: 14),
      );
      final body = await utf8.decodeStream(response);
      if (response.statusCode >= 400) {
        _log.warning('GPT insight HTTP ${response.statusCode}: $body');
        return fallback;
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return fallback;
      }
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty || choices.first is! Map) {
        return fallback;
      }
      final message = (choices.first as Map)['message'];
      final content = message is Map ? message['content']?.toString() : null;
      if (content == null || content.trim().isEmpty) {
        return fallback;
      }
      final aiJson = _extractJsonMap(content);
      if (aiJson == null) {
        return fallback;
      }
      final tipsRaw = aiJson['tips'];
      final tips = tipsRaw is List
          ? tipsRaw
                .map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
                .take(4)
                .toList()
          : <String>[];
      final warnings = _stringListFromJson(aiJson['warnings'], maxItems: 3);
      final improvements = _stringListFromJson(
        aiJson['improvements'],
        maxItems: 3,
      );

      final summary = aiJson['summary']?.toString().trim();
      final routeReason = aiJson['route_reason']?.toString().trim();
      final userLikeReason = aiJson['user_like_reason']?.toString().trim();
      final pacing = aiJson['pacing']?.toString().trim();
      final mealPlan = aiJson['meal_plan']?.toString().trim();
      if ((summary == null || summary.isEmpty) &&
          (routeReason == null || routeReason.isEmpty) &&
          (userLikeReason == null || userLikeReason.isEmpty)) {
        return fallback;
      }
      return {
        'summary': summary ?? fallback['summary'],
        'routeReason': routeReason ?? fallback['routeReason'],
        'userLikeReason': userLikeReason ?? fallback['userLikeReason'],
        'tips': tips.isEmpty ? fallback['tips'] : tips,
        'warnings': warnings.isEmpty ? fallback['warnings'] : warnings,
        'improvements': improvements.isEmpty
            ? fallback['improvements']
            : improvements,
        'pacing': (pacing == null || pacing.isEmpty)
            ? fallback['pacing']
            : pacing,
        'mealPlan': (mealPlan == null || mealPlan.isEmpty)
            ? fallback['mealPlan']
            : mealPlan,
        'source': 'gpt',
      };
    } finally {
      client.close(force: true);
    }
  } catch (error) {
    _log.warning('GPT insight fallback to rule-based: $error');
    return fallback;
  }
}

Map<String, dynamic> _buildRuleBasedInsight({
  required List<Place> allPlaces,
  required List<Map<String, dynamic>> days,
  required List<String> interests,
  required String? originCity,
  required List<String> destinationCities,
  required String? tripPurpose,
  required String? travelBehavior,
  required String? location,
  required int? budget,
  required int? people,
  required String? targetPrice,
}) {
  final allStops = <Map<String, dynamic>>[];
  for (final day in days) {
    final items = day['items'];
    if (items is List) {
      for (final item in items.whereType<Map>()) {
        final place = item['place'];
        if (place is Map) {
          allStops.add(Map<String, dynamic>.from(place));
        }
      }
    }
  }
  final stopCount = allStops.length;
  final cities = allStops
      .map((place) => place['city']?.toString() ?? '')
      .where((city) => city.trim().isNotEmpty)
      .toSet();
  final normalizedTripPurpose = _normalizeTripPurpose(tripPurpose);
  final purposeLabel = _tripPurposeLabel(normalizedTripPurpose);
  final behaviorLabel = _travelBehaviorLabel(travelBehavior);
  final warnings = _buildRouteFeasibilityTips(
    allPlaces: allPlaces,
    days: days,
    originCity: originCity,
    destinationCities: destinationCities,
  );
  final tips = _buildRouteFeasibilityTips(
    allPlaces: allPlaces,
    days: days,
    originCity: originCity,
    destinationCities: destinationCities,
  );
  if (days.length > 1) {
    tips.add('先完成同區景點再往外擴，減少跨區折返。');
  }
  tips.add('已預留午餐與晚餐的緩衝時間，避免整天只是在趕景點。');
  if (targetPrice != null) {
    final label = switch (targetPrice) {
      'low' => '低預算',
      'mid' => '中預算',
      'high' => '高預算',
      _ => '預算',
    };
    tips.add('已按$label範圍挑選景點，降低超支風險。');
  }
  if (interests.isNotEmpty) {
    final topTags = interests.take(3).join('、');
    tips.add('優先放入你偏好的類型：$topTags。');
  }
  switch (normalizedTripPurpose) {
    case 'relax':
      tips.add('本次以休閒放鬆為主，刻意拉長停留與休息緩衝，避免整天趕點。');
      break;
    case 'explore':
      tips.add('本次以景點探索為主，會提高景點多樣性並擴大單日可安排的站點數。');
      break;
    case 'couple':
      tips.add('本次以情侶約會為主，會優先安排互動感與情境體驗較好的景點。');
      break;
    case 'family':
      tips.add('本次以家庭旅遊為主，會降低跨區移動與單日景點密度。');
      break;
  }
  if (tips.length < 2) {
    tips.add('每站預留停留與交通時間，行程更容易實際完成。');
  }

  var lunchCount = 0;
  var dinnerCount = 0;
  var totalStayMinutes = 0;
  var longestTransitMinutes = 0;
  var maxStopsInDay = 0;
  for (final day in days) {
    final rawItems = day['items'];
    if (rawItems is! List) continue;
    var stopCountInDay = 0;
    for (final item in rawItems.whereType<Map>()) {
      final mealType = item['mealType']?.toString();
      if (mealType == 'lunch') {
        lunchCount++;
        continue;
      }
      if (mealType == 'dinner') {
        dinnerCount++;
        continue;
      }
      if (item['place'] is Map) {
        stopCountInDay++;
      }
      totalStayMinutes += (item['durationMinutes'] as num?)?.toInt() ?? 0;
      final transit = item['transitToNext'];
      if (transit is Map) {
        final minutes = (transit['minutes'] as num?)?.toInt() ?? 0;
        if (minutes > longestTransitMinutes) {
          longestTransitMinutes = minutes;
        }
      }
    }
    if (stopCountInDay > maxStopsInDay) {
      maxStopsInDay = stopCountInDay;
    }
  }

  final avgStayMinutes = stopCount == 0 ? 0 : (totalStayMinutes / stopCount).round();
  final pacing = switch (maxStopsInDay) {
    >= 8 => '節奏偏滿：單日最多 $maxStopsInDay 站，建議刪減 1 到 2 站或延長旅遊天數。',
    >= 5 => '節奏中等偏充實：單日最多 $maxStopsInDay 站，若想慢遊或多拍照，可再放寬停留時間。',
    _ => '節奏較寬鬆：單日最多 $maxStopsInDay 站，保有一定彈性可臨時調整。',
  };
  final mealPlan = lunchCount > 0 || dinnerCount > 0
      ? '已安排 ${lunchCount > 0 ? '$lunchCount 段午餐' : '0 段午餐'} 與 ${dinnerCount > 0 ? '$dinnerCount 段晚餐' : '0 段晚餐'} 緩衝，避免整天只是在趕景點。'
      : '目前餐食緩衝偏少，若想更從容，建議午晚餐各保留 45 到 60 分鐘。';
  if ((normalizedTripPurpose == 'relax' || normalizedTripPurpose == 'family') &&
      cities.length >= 2) {
    warnings.add('這次以$purposeLabel為主，但目前仍有跨城安排，可能削弱放鬆或家庭旅遊節奏。');
  }
  final purposeImprovement = switch (normalizedTripPurpose) {
    'relax' => '這次以休閒放鬆為主，建議單日保留更多停留與休息彈性。',
    'explore' => '這次以景點探索為主，會提高景點多樣性與單日安排上限。',
    'couple' => '這次以情侶約會為主，會提高景觀、咖啡與互動型景點比重。',
    'family' => '這次以家庭旅遊為主，會降低單日景點數與移動強度。',
    _ => null,
  };
  final improvements = <String>[
    if (warnings.isNotEmpty) '若想更順，優先減少跨城數量或改選相鄰縣市。',
    if (longestTransitMinutes >= 90) '最長交通段約 $longestTransitMinutes 分鐘，可考慮把遠距景點拆到不同天。',
    if (avgStayMinutes > 0) '目前平均每站停留約 $avgStayMinutes 分鐘，可依你想慢遊或快閃的風格再微調。',
    if (purposeImprovement != null) purposeImprovement,
  ];

  final summary = location != null && location.trim().isNotEmpty
      ? '行程以 $location 為核心，依「$purposeLabel」目的安排 $stopCount 個景點，優先同區順路。'
      : '行程依「$purposeLabel」目的安排 $stopCount 個景點，優先同區順路與熱門度平衡。';
  final routeReason =
      '透過背包式選點先挑出高價值景點，再用最短路徑排序，並按景點類型、熱門度與停留價值估算每站時間，降低移動時間。'
      '${tips.any((tip) => tip.contains('跨城') || tip.contains('第一天')) ? ' 若跨城距離偏遠，也會主動提醒你調整城市數量、增加天數或提早出發。' : ''}';
  final userLikeReason = [
    if (interests.isNotEmpty) '符合你的興趣標籤',
    if (people != null && people > 0) '符合$people人同行的節奏',
    if (behaviorLabel != '一般旅伴') '符合$behaviorLabel出遊的移動與停留方式',
    if (budget != null) '符合預算限制',
    if (cities.length <= 1) '城市切換少、體驗更連貫',
  ].join('、');

  return {
    'summary': summary,
    'routeReason': routeReason,
    'userLikeReason': userLikeReason.isEmpty
        ? '景點品質、順路性與可玩性兼顧，並符合這次「$purposeLabel」的旅遊目的。'
        : '符合這次「$purposeLabel」的旅遊目的、$userLikeReason，所以更容易玩得順。',
    'tips': tips.take(4).toList(),
    'warnings': warnings.take(3).toList(),
    'improvements': improvements.whereType<String>().take(3).toList(),
    'pacing': pacing,
    'mealPlan': mealPlan,
    'source': 'rule',
  };
}

String _buildItineraryInsightPrompt({
  required List<Place> allPlaces,
  required List<Map<String, dynamic>> days,
  required List<String> interests,
  required String? originCity,
  required List<String> destinationCities,
  required String? tripPurpose,
  required String? travelBehavior,
  required String? location,
  required int? budget,
  required int? people,
  required String? targetPrice,
}) {
  final daySummaries = <String>[];
  for (final day in days.take(5)) {
    final dayNo = day['day']?.toString() ?? '?';
    final date = day['date']?.toString() ?? '';
    final items = day['items'];
    final names = <String>[];
    if (items is List) {
      for (final item in items.whereType<Map>()) {
        final place = item['place'];
        if (place is Map) {
          final name = place['name']?.toString();
          final city = place['city']?.toString();
          if (name != null && name.trim().isNotEmpty) {
            names.add(city != null && city.isNotEmpty ? '$name($city)' : name);
          }
        }
      }
    }
    daySummaries.add('Day$dayNo $date: ${names.join(' -> ')}');
  }
  final feasibilityTips = _buildRouteFeasibilityTips(
    allPlaces: allPlaces,
    days: days,
    originCity: originCity,
    destinationCities: destinationCities,
  );

  return '''
請根據以下行程，解釋排程邏輯與使用者偏好匹配原因。
需求：
- 用繁體中文
- 回傳 JSON 物件，欄位固定為：
  {
    "summary": "1-2句總結",
    "route_reason": "為何這樣排比較順路",
    "user_like_reason": "為何使用者會喜歡",
    "tips": ["重點提醒1","重點提醒2","重點提醒3"],
    "warnings": ["風險1","風險2"],
    "improvements": ["改善建議1","改善建議2"],
    "pacing": "整體節奏判斷",
    "meal_plan": "午餐晚餐與休息安排說明"
  }
- 若出發地到第一站距離偏遠，或複選旅遊城市彼此距離太遠、天數不足，請明確指出不合理之處並提出改善建議
- 請說明午餐/晚餐保留時段、景點停留時長估算依據，以及行程是否過趕
- 旅遊目的會影響節奏、景點取向、用餐時段與停留時間，請在說明中具體寫出
- 旅伴型態也會影響節奏與安排重點，請在說明中具體寫出
- 不要輸出任何 JSON 以外文字

使用者條件：
- 出發地：${originCity ?? '未指定'}
- 旅遊城市：${destinationCities.isEmpty ? '未提供' : destinationCities.join(', ')}
- 旅遊目的：${_tripPurposeLabel(tripPurpose)}
- 旅伴型態：${_travelBehaviorLabel(travelBehavior)}
- 位置：${location ?? '未指定'}
- 預算：${budget?.toString() ?? '未提供'}（分類：${targetPrice ?? '未提供'}）
- 人數：${people?.toString() ?? '未提供'}
- 興趣：${interests.isEmpty ? '未提供' : interests.join(', ')}
- 可行性提醒：${feasibilityTips.isEmpty ? '目前沒有明顯跨城風險' : feasibilityTips.join('；')}

行程：
${daySummaries.join('\n')}
''';
}

List<String> _buildRouteFeasibilityTips({
  required List<Place> allPlaces,
  required List<Map<String, dynamic>> days,
  required String? originCity,
  required List<String> destinationCities,
}) {
  final tips = <String>[];
  final normalizedDestinationCities = destinationCities
      .map(_normalizeLocationText)
      .where((city) => city.isNotEmpty)
      .toSet()
      .toList();
  final totalDays = max(1, days.length);
  if (normalizedDestinationCities.length >= 2) {
    if (normalizedDestinationCities.length > totalDays + 1) {
      tips.add(
        '這次勾選 ${normalizedDestinationCities.length} 個旅遊城市，但只有 $totalDays 天，跨城移動可能壓縮實際可玩時間，建議減少城市數量或增加旅遊天數。',
      );
    }
    double maxPairKm = 0;
    for (var i = 0; i < normalizedDestinationCities.length; i++) {
      final a = _resolveCityAnchor(
        places: allPlaces,
        city: normalizedDestinationCities[i],
      );
      if (a == null) continue;
      for (var j = i + 1; j < normalizedDestinationCities.length; j++) {
        final b = _resolveCityAnchor(
          places: allPlaces,
          city: normalizedDestinationCities[j],
        );
        if (b == null) continue;
        maxPairKm = max(
          maxPairKm,
          _distanceKm(a.$1, a.$2, b.$1, b.$2),
        );
      }
    }
    if (maxPairKm >= 90) {
      tips.add(
        '你選擇的旅遊城市彼此距離偏遠（最遠約 ${maxPairKm.toStringAsFixed(0)} km），單趟跨城時間可能較長，建議優先挑相鄰縣市、拆成兩趟旅程，或增加停留天數。',
      );
    }
  }

  final normalizedOriginCity = originCity == null
      ? null
      : _normalizeLocationText(originCity);
  final originAnchor = _resolveCityAnchor(
    places: allPlaces,
    city: normalizedOriginCity,
  );
  final firstPlace = () {
    if (days.isEmpty) return null;
    final items = days.first['items'];
    if (items is! List || items.isEmpty || items.first is! Map) return null;
    final place = (items.first as Map)['place'];
    return place is Map ? Map<String, dynamic>.from(place) : null;
  }();
  if (originAnchor != null && firstPlace != null) {
    final firstLat = (firstPlace['lat'] as num?)?.toDouble();
    final firstLng = (firstPlace['lng'] as num?)?.toDouble();
    final firstName = firstPlace['name']?.toString() ?? '第一站';
    if (firstLat != null && firstLng != null) {
      final originKm = _distanceKm(
        originAnchor.$1,
        originAnchor.$2,
        firstLat,
        firstLng,
      );
      if (originKm >= 40) {
        tips.add(
          '出發地到第一站 $firstName 約 ${originKm.toStringAsFixed(0)} km，第一天會先花較多時間在移動上，建議提早出門，或改成更靠近出發地／進城動線的第一站。',
        );
      }
    }
  }

  return tips.take(4).toList();
}

_RouteFeasibilityDecision _evaluateRouteFeasibilityDecision({
  required List<Place> allPlaces,
  required int totalDays,
  required String? originCity,
  required List<String> destinationCities,
  required String? tripPurpose,
  required String? travelBehavior,
  required Map<String, dynamic> plannerAssist,
}) {
  final normalizedDestinationCities = destinationCities
      .map(_normalizeLocationText)
      .where((city) => city.isNotEmpty)
      .toSet()
      .toList();
  if (normalizedDestinationCities.length <= 1) {
    return const _RouteFeasibilityDecision(
      shouldBlock: false,
      message: '',
      suggestions: [],
    );
  }

  final prioritizedCities = _stringListFromJson(
    plannerAssist['prioritizedCities'],
    maxItems: 6,
  )
      .map(_normalizeLocationText)
      .where((city) => normalizedDestinationCities.contains(city))
      .toList();
  final warnings = _stringListFromJson(plannerAssist['warnings'], maxItems: 4);
  final improvements = _stringListFromJson(
    plannerAssist['improvements'],
    maxItems: 4,
  );
  final alternativePlan =
      plannerAssist['alternativePlan']?.toString().trim() ?? '';

  double maxPairKm = 0;
  for (var i = 0; i < normalizedDestinationCities.length; i++) {
    final a = _resolveCityAnchor(
      places: allPlaces,
      city: normalizedDestinationCities[i],
    );
    if (a == null) continue;
    for (var j = i + 1; j < normalizedDestinationCities.length; j++) {
      final b = _resolveCityAnchor(
        places: allPlaces,
        city: normalizedDestinationCities[j],
      );
      if (b == null) continue;
      maxPairKm = max(maxPairKm, _distanceKm(a.$1, a.$2, b.$1, b.$2));
    }
  }

  final normalizedOriginCity = originCity == null
      ? null
      : _normalizeLocationText(originCity);
  final originAnchor = _resolveCityAnchor(
    places: allPlaces,
    city: normalizedOriginCity,
  );
  double nearestOriginKm = 0;
  if (originAnchor != null) {
    var nearest = double.infinity;
    for (final city in normalizedDestinationCities) {
      final cityAnchor = _resolveCityAnchor(places: allPlaces, city: city);
      if (cityAnchor == null) continue;
      nearest = min(
        nearest,
        _distanceKm(originAnchor.$1, originAnchor.$2, cityAnchor.$1, cityAnchor.$2),
      );
    }
    if (nearest.isFinite) {
      nearestOriginKm = nearest;
    }
  }

  var severity = 0;
  if (normalizedDestinationCities.length >= 3 && totalDays <= 2) {
    severity += 2;
  }
  if (normalizedDestinationCities.length > totalDays + 1) {
    severity += 1;
  }
  if (maxPairKm >= 220) {
    severity += 3;
  } else if (maxPairKm >= 160 && totalDays <= 3) {
    severity += 2;
  } else if (maxPairKm >= 120 && totalDays <= 2) {
    severity += 2;
  } else if (maxPairKm >= 90 && totalDays <= 1) {
    severity += 2;
  }
  if (nearestOriginKm >= 160 && totalDays <= 2) {
    severity += 1;
  }

  final normalizedTripPurpose = _normalizeTripPurpose(tripPurpose);
  final normalizedTravelBehavior = _normalizeTravelBehavior(travelBehavior);
  if ((normalizedTripPurpose == 'relax' || normalizedTripPurpose == 'family') &&
      normalizedDestinationCities.length >= 2 &&
      maxPairKm >= 80) {
    severity += 1;
  }
  if (normalizedTravelBehavior == 'family' &&
      normalizedDestinationCities.length >= 2 &&
      maxPairKm >= 80) {
    severity += 1;
  }

  final shouldBlock = severity >= 3;
  if (!shouldBlock) {
    return _RouteFeasibilityDecision(
      shouldBlock: false,
      message: '',
      suggestions: improvements,
      metrics: {
        'selectedCityCount': normalizedDestinationCities.length,
        'totalDays': totalDays,
        'maxPairKm': maxPairKm.round(),
        'nearestOriginKm': nearestOriginKm.round(),
      },
    );
  }

  final recommendedCities = prioritizedCities.isNotEmpty
      ? prioritizedCities.take(min(prioritizedCities.length, max(1, totalDays))).toList()
      : normalizedDestinationCities.take(min(normalizedDestinationCities.length, max(1, totalDays))).toList();
  final reasons = <String>[
    if (normalizedDestinationCities.length >= 3 && totalDays <= 2)
      '$totalDays 天內安排 ${normalizedDestinationCities.length} 個城市，跨城切換次數過多。',
    if (maxPairKm >= 90)
      '你選的城市最遠相隔約 ${maxPairKm.toStringAsFixed(0)} 公里，移動成本過高。',
    if (nearestOriginKm >= 160)
      '從出發地到最近旅遊城市也約 ${nearestOriginKm.toStringAsFixed(0)} 公里，第一天會先被長距離移動吃掉。',
  ];
  final suggestions = <String>[
    if (recommendedCities.isNotEmpty)
      '這次先集中在 ${recommendedCities.join('、')}，其餘城市拆到下次。',
    if (normalizedDestinationCities.length > totalDays + 1)
      '$totalDays 天建議最多先安排 ${max(1, totalDays)} 到 ${totalDays + 1} 個相鄰城市。',
    if (alternativePlan.isNotEmpty) alternativePlan,
    ...warnings,
    ...improvements,
  ].where((text) => text.trim().isNotEmpty).toSet().take(5).toList();

  return _RouteFeasibilityDecision(
    shouldBlock: true,
    message: '目前選擇的城市組合距離過遠或天數不足，不建議直接排出行程。',
    reasons: reasons,
    suggestions: suggestions,
    metrics: {
      'selectedCityCount': normalizedDestinationCities.length,
      'totalDays': totalDays,
      'maxPairKm': maxPairKm.round(),
      'nearestOriginKm': nearestOriginKm.round(),
      'recommendedCities': recommendedCities,
      'tripPurpose': normalizedTripPurpose,
      'travelBehavior': normalizedTravelBehavior,
    },
  );
}

Future<Map<String, dynamic>> _buildAiPlannerAssist({
  required List<Place> allPlaces,
  required List<Place> candidates,
  required List<String> interests,
  required DateTime? startDate,
  required DateTime? endDate,
  required int totalDays,
  required String? originCity,
  required List<String> destinationCities,
  required String? tripPurpose,
  required String? travelBehavior,
  required String? location,
  required int? budget,
  required int? people,
  required String? dayStartTime,
  required String? dayEndTime,
  required int? extraSpots,
  required List<String> wishlistPlaces,
}) async {
  final fallback = _buildRuleBasedPlannerAssist(
    allPlaces: allPlaces,
    candidates: candidates,
    interests: interests,
    startDate: startDate,
    endDate: endDate,
    totalDays: totalDays,
    originCity: originCity,
    destinationCities: destinationCities,
    tripPurpose: tripPurpose,
    travelBehavior: travelBehavior,
    location: location,
    budget: budget,
    people: people,
    dayStartTime: dayStartTime,
    dayEndTime: dayEndTime,
    extraSpots: extraSpots,
    wishlistPlaces: wishlistPlaces,
  );
  final key = _openAiApiKey;
  if (key == null || key.trim().isEmpty || candidates.isEmpty) {
    return fallback;
  }

  try {
    final base = (_openAiBaseUrl == null || _openAiBaseUrl!.trim().isEmpty)
        ? 'https://api.openai.com'
        : _openAiBaseUrl!.trim();
    final uri = Uri.parse(base).resolve('/v1/chat/completions');
    final model = (_openAiModel == null || _openAiModel!.trim().isEmpty)
        ? 'gpt-4o-mini'
        : _openAiModel!.trim();
    final payload = {
      'model': model,
      'temperature': 0.25,
      'response_format': {'type': 'json_object'},
      'messages': [
        {
          'role': 'system',
          'content':
              '你是資深旅遊行程規劃師。請只回傳 JSON，使用繁體中文，重點是改善路線合理性而不是只寫漂亮文案。',
        },
        {
          'role': 'user',
          'content': _buildAiPlannerAssistPrompt(
            allPlaces: allPlaces,
            candidates: candidates,
            interests: interests,
            startDate: startDate,
            endDate: endDate,
            totalDays: totalDays,
            originCity: originCity,
            destinationCities: destinationCities,
            tripPurpose: tripPurpose,
            travelBehavior: travelBehavior,
            location: location,
            budget: budget,
            people: people,
            dayStartTime: dayStartTime,
            dayEndTime: dayEndTime,
            extraSpots: extraSpots,
            wishlistPlaces: wishlistPlaces,
          ),
        },
      ],
    };

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      request.add(utf8.encode(jsonEncode(payload)));
      final response = await request.close().timeout(
        const Duration(seconds: 14),
      );
      final body = await utf8.decodeStream(response);
      if (response.statusCode >= 400) {
        _log.warning('GPT planner assist HTTP ${response.statusCode}: $body');
        return fallback;
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map) return fallback;
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty || choices.first is! Map) {
        return fallback;
      }
      final message = (choices.first as Map)['message'];
      final content = message is Map ? message['content']?.toString() : null;
      if (content == null || content.trim().isEmpty) {
        return fallback;
      }
      final aiJson = _extractJsonMap(content);
      if (aiJson == null) {
        return fallback;
      }

      final prioritizedCities = _stringListFromJson(
        aiJson['prioritized_cities'],
        maxItems: 6,
      );
      final warnings = _stringListFromJson(aiJson['warnings'], maxItems: 4);
      final improvements = _stringListFromJson(
        aiJson['improvements'],
        maxItems: 4,
      );
      final planningFocus = aiJson['planning_focus']?.toString().trim() ?? '';
      final dailyStopCapRaw = (aiJson['daily_stop_cap'] as num?)?.toInt();
      final recommendedStartTime =
          aiJson['recommended_start_time']?.toString().trim() ?? '';
      final parsedStart = _parseHmToMinute(recommendedStartTime);
      final stayStyleRaw = aiJson['stay_style']?.toString().trim().toLowerCase();
      final stayStyle = switch (stayStyleRaw) {
        'slow' => 'slow',
        'compact' => 'compact',
        _ => 'balanced',
      };
      final lunchStartTime =
          aiJson['lunch_start_time']?.toString().trim() ?? '';
      final dinnerStartTime =
          aiJson['dinner_start_time']?.toString().trim() ?? '';
      final parsedLunch = _parseHmToMinute(lunchStartTime);
      final parsedDinner = _parseHmToMinute(dinnerStartTime);
      final alternativePlan =
          aiJson['alternative_plan']?.toString().trim() ?? '';

      return {
        'prioritizedCities': prioritizedCities.isEmpty
            ? fallback['prioritizedCities']
            : prioritizedCities,
        'dailyStopCap': (dailyStopCapRaw == null || dailyStopCapRaw < 2)
            ? fallback['dailyStopCap']
            : dailyStopCapRaw.clamp(2, 8),
        'recommendedStartTime': parsedStart == null
            ? fallback['recommendedStartTime']
            : recommendedStartTime,
        'warnings': warnings.isEmpty ? fallback['warnings'] : warnings,
        'improvements': improvements.isEmpty
            ? fallback['improvements']
            : improvements,
        'planningFocus': planningFocus.isEmpty
            ? fallback['planningFocus']
            : planningFocus,
        'stayStyle': stayStyle,
        'lunchStartTime': parsedLunch == null
            ? fallback['lunchStartTime']
            : lunchStartTime,
        'dinnerStartTime': parsedDinner == null
            ? fallback['dinnerStartTime']
            : dinnerStartTime,
        'alternativePlan': alternativePlan.isEmpty
            ? fallback['alternativePlan']
            : alternativePlan,
        'source': 'gpt',
      };
    } finally {
      client.close(force: true);
    }
  } catch (error) {
    _log.warning('GPT planner assist fallback to rule-based: $error');
    return fallback;
  }
}

Map<String, dynamic> _buildRuleBasedPlannerAssist({
  required List<Place> allPlaces,
  required List<Place> candidates,
  required List<String> interests,
  required DateTime? startDate,
  required DateTime? endDate,
  required int totalDays,
  required String? originCity,
  required List<String> destinationCities,
  required String? tripPurpose,
  required String? travelBehavior,
  required String? location,
  required int? budget,
  required int? people,
  required String? dayStartTime,
  required String? dayEndTime,
  required int? extraSpots,
  required List<String> wishlistPlaces,
}) {
  final warnings = <String>[];
  final improvements = <String>[];
  final normalizedOriginCity = originCity == null
      ? null
      : _normalizeLocationText(originCity);
  final normalizedDestinationCities = destinationCities
      .map(_normalizeLocationText)
      .where((city) => city.isNotEmpty)
      .toList();
  final fallbackCity = () {
    final parsed = _parseLocationParts(location);
    return parsed.$1 == null ? null : _normalizeLocationText(parsed.$1!);
  }();
  final normalizedTripPurpose = _normalizeTripPurpose(tripPurpose);
  final purposeLabel = _tripPurposeLabel(normalizedTripPurpose);
  final normalizedTravelBehavior = _normalizeTravelBehavior(travelBehavior);
  final behaviorLabel = _travelBehaviorLabel(normalizedTravelBehavior);
  final selectedCities = normalizedDestinationCities.isNotEmpty
      ? normalizedDestinationCities
      : [
          if (fallbackCity != null && fallbackCity.isNotEmpty) fallbackCity,
        ];

  final cityBuckets = <String, List<Place>>{};
  for (final place in candidates) {
    final key = _normalizeLocationText(place.city);
    if (key.isEmpty) continue;
    cityBuckets.putIfAbsent(key, () => <Place>[]).add(place);
  }

  final cityRank = cityBuckets.entries.map((entry) {
    final bucket = entry.value;
    final ratingAvg = bucket.isEmpty
        ? 0.0
        : bucket
                  .map((place) => place.rating ?? 0)
                  .fold<double>(0, (sum, value) => sum + value) /
              bucket.length;
    final completenessAvg = bucket.isEmpty
        ? 0.0
        : bucket
                  .map(_infoCompletenessScore)
                  .fold<double>(0, (sum, value) => sum + value) /
              bucket.length;
    final score = bucket.length * 0.85 + ratingAvg * 0.9 + completenessAvg * 2;
    return (city: entry.key, score: score, count: bucket.length);
  }).toList()
    ..sort((a, b) => b.score.compareTo(a.score));

  final prioritizedCities = <String>[];
  if (selectedCities.isNotEmpty) {
    final originAnchor = _resolveCityAnchor(
      places: allPlaces,
      city: normalizedOriginCity,
    );
    final rankedSelected = selectedCities.map((city) {
      final bucket = cityBuckets[city] ?? const <Place>[];
      ({String city, double score, int count})? scoreEntry;
      for (final entry in cityRank) {
        if (entry.city == city) {
          scoreEntry = entry;
          break;
        }
      }
      final cityAnchor = _resolveCityAnchor(places: allPlaces, city: city);
      final distancePenalty =
          originAnchor != null && cityAnchor != null
          ? _distanceKm(
                  originAnchor.$1,
                  originAnchor.$2,
                  cityAnchor.$1,
                  cityAnchor.$2,
                ) *
                0.015
          : 0.0;
      final score = (scoreEntry?.score ?? bucket.length.toDouble()) -
          distancePenalty;
      return (city: city, score: score);
    }).toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    prioritizedCities.addAll(
      rankedSelected.take(min(max(1, totalDays + 1), rankedSelected.length)).map(
            (entry) => entry.city,
          ),
    );
  } else {
    prioritizedCities.addAll(
      cityRank.take(min(max(1, totalDays + 1), cityRank.length)).map(
            (entry) => entry.city,
          ),
    );
  }

  double maxPairKm = 0;
  for (var i = 0; i < prioritizedCities.length; i++) {
    final a = _resolveCityAnchor(places: allPlaces, city: prioritizedCities[i]);
    if (a == null) continue;
    for (var j = i + 1; j < prioritizedCities.length; j++) {
      final b = _resolveCityAnchor(
        places: allPlaces,
        city: prioritizedCities[j],
      );
      if (b == null) continue;
      maxPairKm = max(maxPairKm, _distanceKm(a.$1, a.$2, b.$1, b.$2));
    }
  }

  final firstPriority = prioritizedCities.isEmpty ? null : prioritizedCities.first;
  final originAnchor = _resolveCityAnchor(
    places: allPlaces,
    city: normalizedOriginCity,
  );
  final firstAnchor = _resolveCityAnchor(places: allPlaces, city: firstPriority);
  final originToFirstKm =
      originAnchor != null && firstAnchor != null
      ? _distanceKm(originAnchor.$1, originAnchor.$2, firstAnchor.$1, firstAnchor.$2)
      : 0.0;

  var dailyStopCap = totalDays <= 1 ? 5 : 4;
  if (maxPairKm >= 90) dailyStopCap -= 1;
  if (prioritizedCities.length > totalDays + 1) dailyStopCap -= 1;
  if ((extraSpots ?? 0) >= 2 && maxPairKm < 40) dailyStopCap += 1;
  dailyStopCap = dailyStopCap.clamp(2, 8);

  var recommendedStartTime = '09:30';
  if ((dayStartTime == null || dayStartTime.trim().isEmpty) &&
      originToFirstKm > 0) {
    if (originToFirstKm >= 120) {
      recommendedStartTime = '07:00';
    } else if (originToFirstKm >= 80) {
      recommendedStartTime = '07:30';
    } else if (originToFirstKm >= 40) {
      recommendedStartTime = '08:00';
    } else if (originToFirstKm >= 20) {
      recommendedStartTime = '08:30';
    } else {
      recommendedStartTime = '09:00';
    }
  }
  switch (normalizedTripPurpose) {
    case 'relax':
      dailyStopCap = max(2, dailyStopCap - 1);
      if (dayStartTime == null || dayStartTime.trim().isEmpty) {
        recommendedStartTime = originToFirstKm < 40 ? '09:00' : recommendedStartTime;
      }
      break;
    case 'explore':
      dailyStopCap = min(8, dailyStopCap + 1);
      recommendedStartTime = originToFirstKm < 20 ? '08:30' : recommendedStartTime;
      break;
    case 'couple':
      if (dayStartTime == null || dayStartTime.trim().isEmpty) {
        recommendedStartTime = originToFirstKm < 40 ? '09:00' : recommendedStartTime;
      }
      break;
    case 'family':
      dailyStopCap = max(2, dailyStopCap - 1);
      if (dayStartTime == null || dayStartTime.trim().isEmpty) {
        recommendedStartTime = originToFirstKm < 40 ? '09:00' : recommendedStartTime;
      }
      break;
  }
  switch (normalizedTravelBehavior) {
    case 'family':
      dailyStopCap = max(2, dailyStopCap - 1);
      break;
    case 'couple':
      dailyStopCap = max(2, dailyStopCap);
      break;
    case 'solo':
      break;
  }

  if (prioritizedCities.length >= 2 && maxPairKm >= 90) {
    warnings.add(
      '你挑選的旅遊城市最遠相隔約 ${maxPairKm.toStringAsFixed(0)} 公里，單日跨城會明顯壓縮景點停留時間。',
    );
  }
  if (prioritizedCities.length > totalDays + 1) {
    warnings.add(
      '${prioritizedCities.length} 個城市分配到 $totalDays 天會偏趕，建議先集中在 ${prioritizedCities.take(totalDays + 1).join('、')}。',
    );
  }
  if (originToFirstKm >= 40) {
    warnings.add(
      '從出發地到第一個優先城市約 ${originToFirstKm.toStringAsFixed(0)} 公里，第一天建議提早出門或減少上午景點數。',
    );
  }
  if ((normalizedTripPurpose == 'relax' || normalizedTripPurpose == 'family') &&
      prioritizedCities.length >= 2) {
    warnings.add('這次以$purposeLabel為主，但目前仍有跨城安排，可能削弱放鬆或家庭旅遊節奏。');
  }
  if (normalizedTravelBehavior == 'family' && prioritizedCities.length >= 2) {
    warnings.add('目前是$behaviorLabel出遊，但仍有跨城安排，可能增加移動疲勞。');
  }

  if (prioritizedCities.length >= 2) {
    improvements.add(
      '建議優先排 ${prioritizedCities.take(min(prioritizedCities.length, totalDays + 1)).join('、')}，其餘城市可留待下次或延長天數。',
    );
  }
  if (dailyStopCap <= 3) {
    improvements.add('這次更適合慢遊模式，單日控制在 $dailyStopCap 站左右，才能保留交通與用餐緩衝。');
  } else {
    improvements.add('若想更從容拍照或逛店，仍可把單日景點數壓到 ${max(3, dailyStopCap - 1)} 站。');
  }
  if (wishlistPlaces.isNotEmpty) {
    improvements.add('你另外指定的景點願望清單會被優先加分，但若與主要城市距離過遠，建議拆到其他天。');
  }
  final stayStyle = switch (normalizedTripPurpose) {
    'relax' || 'family' => 'slow',
    'couple' => 'balanced',
    'explore' => 'compact',
    _ => switch (dailyStopCap) {
      <= 3 => 'slow',
      >= 6 => 'compact',
      _ => 'balanced',
    },
  };
  var lunchStartTime = originToFirstKm >= 60 ? '12:15' : '12:00';
  var dinnerStartTime = prioritizedCities.length >= 2 ? '18:30' : '18:00';
  if (normalizedTripPurpose == 'explore') {
    lunchStartTime = '12:00';
    dinnerStartTime = '18:15';
  } else if (normalizedTripPurpose == 'couple') {
    lunchStartTime = '11:45';
    dinnerStartTime = '17:45';
  } else if (normalizedTripPurpose == 'family') {
    lunchStartTime = '11:30';
    dinnerStartTime = '17:30';
  }
  final alternativePlan = prioritizedCities.length >= 2 && maxPairKm >= 90
      ? '若要更合理，可改成只保留 ${prioritizedCities.take(min(prioritizedCities.length, totalDays)).join('、')}，其餘城市拆成下一趟旅程。'
      : originToFirstKm >= 60
      ? '若想避免第一天過趕，可把第一站改成更靠近出發地或主要進城動線的景點。'
      : '目前城市配置尚可，若想更悠閒可把單日景點數再減少 1 站。';
  switch (normalizedTripPurpose) {
    case 'relax':
      improvements.add('這次以休閒放鬆為主，建議單日保留更多停留與休息彈性。');
      break;
    case 'explore':
      improvements.add('這次以景點探索為主，會提高景點數量與多樣性，但仍會控制跨城成本。');
      break;
    case 'couple':
      improvements.add('這次以情侶約會為主，會提高景觀、咖啡與互動型景點比重。');
      break;
    case 'family':
      improvements.add('這次以家庭旅遊為主，會降低單日景點數與移動強度。');
      break;
  }
  switch (normalizedTravelBehavior) {
    case 'family':
      improvements.add('家庭出遊建議保留更多休息與用餐緩衝，避免連續趕點。');
      break;
    case 'couple':
      improvements.add('情侶出遊可提高單點停留時間，讓拍照與用餐安排更完整。');
      break;
    case 'solo':
      improvements.add('個人旅行可保留較高彈性，方便依現場狀況微調停留順序。');
      break;
  }

  final focus = [
    '以$purposeLabel為目的',
    '採$behaviorLabel節奏',
    if (firstPriority != null) '先以${firstPriority.replaceAll('台', '臺')}為主軸',
    if (prioritizedCities.length >= 2)
      '再視天數向${prioritizedCities.skip(1).take(2).map((city) => city.replaceAll('台', '臺')).join('、')}延伸',
    '單日建議約 $dailyStopCap 站',
    if (dayStartTime == null || dayStartTime.trim().isEmpty)
      '建議 $recommendedStartTime 出發',
  ].join('，');

  return {
    'prioritizedCities': prioritizedCities
        .map((city) => city.replaceAll('台', '臺'))
        .toList(),
    'dailyStopCap': dailyStopCap,
    'recommendedStartTime': recommendedStartTime,
    'warnings': warnings.take(4).toList(),
    'improvements': improvements.take(4).toList(),
    'planningFocus': focus,
    'stayStyle': stayStyle,
    'lunchStartTime': lunchStartTime,
    'dinnerStartTime': dinnerStartTime,
    'alternativePlan': alternativePlan,
    'source': 'rule',
  };
}

String _buildAiPlannerAssistPrompt({
  required List<Place> allPlaces,
  required List<Place> candidates,
  required List<String> interests,
  required DateTime? startDate,
  required DateTime? endDate,
  required int totalDays,
  required String? originCity,
  required List<String> destinationCities,
  required String? tripPurpose,
  required String? travelBehavior,
  required String? location,
  required int? budget,
  required int? people,
  required String? dayStartTime,
  required String? dayEndTime,
  required int? extraSpots,
  required List<String> wishlistPlaces,
}) {
  final cities = <String, int>{};
  for (final place in candidates) {
    final city = place.city.trim();
    if (city.isEmpty) continue;
    cities.update(city, (count) => count + 1, ifAbsent: () => 1);
  }
  final citySummary = cities.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final feasibilityTips = _buildRouteFeasibilityTips(
    allPlaces: allPlaces,
    days: const [],
    originCity: originCity,
    destinationCities: destinationCities,
  );
  final exampleStops = candidates
      .take(12)
      .map((place) => '${place.name}(${place.city})')
      .join('、');

  return '''
請先扮演行程規劃顧問，針對以下旅遊條件給出「排程策略建議」，只能回傳 JSON 物件。

固定欄位：
{
  "planning_focus": "1-2句規劃重點",
  "prioritized_cities": ["城市1","城市2"],
  "daily_stop_cap": 4,
  "recommended_start_time": "08:30",
  "stay_style": "slow|balanced|compact",
  "lunch_start_time": "12:00",
  "dinner_start_time": "18:00",
  "warnings": ["提醒1","提醒2"],
  "improvements": ["改善建議1","改善建議2"],
  "alternative_plan": "若目前城市組合不夠合理，請給替代安排"
}

規則：
- 使用繁體中文
- prioritized_cities 只能填使用者有選到的旅遊城市，若未指定則可從候選城市挑選
- daily_stop_cap 只能是 2 到 8 的整數
- recommended_start_time 必須是 HH:mm
- lunch_start_time / dinner_start_time 必須是 HH:mm
- stay_style 只能是 slow、balanced、compact 其中之一
- 你要考慮：出發地到第一站距離、城市間距離、旅遊天數、景點密度、用餐緩衝、交通合理性
- 你要考慮：出發地到第一站距離、城市間距離、旅遊天數、景點密度、用餐緩衝、交通合理性、旅遊目的
- 你要考慮：旅伴型態（家庭/情侶/個人）對節奏、停留時間與跨城容忍度的影響
- 如果多城市過遠或天數不夠，必須直接指出
- 不要回傳任何 JSON 以外的文字

使用者條件：
- 出發地：${originCity ?? '未指定'}
- 想去城市：${destinationCities.isEmpty ? '未指定' : destinationCities.join('、')}
- 旅遊目的：${_tripPurposeLabel(tripPurpose)}
- 旅伴型態：${_travelBehaviorLabel(travelBehavior)}
- 位置：${location ?? '未指定'}
- 開始日期：${startDate?.toIso8601String().substring(0, 10) ?? '未指定'}
- 結束日期：${endDate?.toIso8601String().substring(0, 10) ?? '未指定'}
- 共 $totalDays 天
- 預算：${budget?.toString() ?? '未提供'}
- 人數：${people?.toString() ?? '未提供'}
- 興趣：${interests.isEmpty ? '未提供' : interests.join('、')}
- 想再多排景點：${extraSpots?.toString() ?? '0'}
- 已指定想去景點：${wishlistPlaces.isEmpty ? '無' : wishlistPlaces.join('、')}
- 使用者手動指定出發時間：${dayStartTime ?? '未指定'}
- 使用者手動指定結束時間：${dayEndTime ?? '未指定'}

候選資料：
- 可用候選景點數：${candidates.length}
- 候選城市分布：${citySummary.take(8).map((e) => '${e.key}:${e.value}').join('、')}
- 候選景點範例：$exampleStops
- 可行性提醒：${feasibilityTips.isEmpty ? '暫無' : feasibilityTips.join('；')}
''';
}

Map<String, dynamic> _mergePlannerAssistIntoInsight({
  required Map<String, dynamic> insight,
  required Map<String, dynamic> plannerAssist,
}) {
  final mergedWarnings = <String>{
    ..._stringListFromJson(plannerAssist['warnings'], maxItems: 4),
    ..._stringListFromJson(insight['warnings'], maxItems: 4),
  }.toList();
  final mergedImprovements = <String>{
    ..._stringListFromJson(plannerAssist['improvements'], maxItems: 4),
    ..._stringListFromJson(insight['improvements'], maxItems: 4),
  }.toList();
  final planningFocus = plannerAssist['planningFocus']?.toString().trim() ?? '';
  final summary = insight['summary']?.toString().trim() ?? '';
  return {
    ...insight,
    'summary': planningFocus.isEmpty
        ? summary
        : summary.isEmpty
        ? planningFocus
        : '$planningFocus。$summary',
    'warnings': mergedWarnings.take(4).toList(),
    'improvements': mergedImprovements.take(4).toList(),
    'planningFocus': planningFocus,
    'alternativePlan':
        plannerAssist['alternativePlan']?.toString().trim().isNotEmpty == true
        ? plannerAssist['alternativePlan']?.toString().trim()
        : insight['alternativePlan']?.toString() ?? '',
    'plannerAssistSource': plannerAssist['source']?.toString() ?? 'rule',
  };
}

Future<Map<String, dynamic>> _buildStopExplanation(
  Map<String, dynamic> body,
) async {
  final place = body['place'] is Map
      ? Map<String, dynamic>.from(body['place'] as Map)
      : <String, dynamic>{};
  final fallback = _buildRuleBasedStopExplanation(body, place);
  final key = _openAiApiKey;
  if (key == null || key.trim().isEmpty) {
    return fallback;
  }

  try {
    final base = (_openAiBaseUrl == null || _openAiBaseUrl!.trim().isEmpty)
        ? 'https://api.openai.com'
        : _openAiBaseUrl!.trim();
    final uri = Uri.parse(base).resolve('/v1/chat/completions');
    final model = (_openAiModel == null || _openAiModel!.trim().isEmpty)
        ? 'gpt-4o-mini'
        : _openAiModel!.trim();
    final payload = {
      'model': model,
      'temperature': 0.35,
      'response_format': {'type': 'json_object'},
      'messages': [
        {'role': 'system', 'content': '你是旅遊行程規劃助理。用繁體中文，解釋單一景點安排理由。只回傳 JSON。'},
        {'role': 'user', 'content': _buildStopExplanationPrompt(body, place)},
      ],
    };

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      request.add(utf8.encode(jsonEncode(payload)));
      final response = await request.close().timeout(
        const Duration(seconds: 14),
      );
      final raw = await utf8.decodeStream(response);
      if (response.statusCode >= 400) {
        _log.warning('GPT stop explanation HTTP ${response.statusCode}: $raw');
        return fallback;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return fallback;
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty || choices.first is! Map) {
        return fallback;
      }
      final msg = (choices.first as Map)['message'];
      final content = msg is Map ? msg['content']?.toString() : null;
      if (content == null || content.trim().isEmpty) return fallback;
      final aiJson = _extractJsonMap(content);
      if (aiJson == null) return fallback;

      final tips =
          (aiJson['tips'] as List?)
              ?.map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .take(4)
              .toList() ??
          const <String>[];
      return {
        'summary': aiJson['summary']?.toString().trim().isNotEmpty == true
            ? aiJson['summary'].toString().trim()
            : fallback['summary'],
        'whyIncluded':
            aiJson['why_included']?.toString().trim().isNotEmpty == true
            ? aiJson['why_included'].toString().trim()
            : fallback['whyIncluded'],
        'whyTiming': aiJson['why_timing']?.toString().trim().isNotEmpty == true
            ? aiJson['why_timing'].toString().trim()
            : fallback['whyTiming'],
        'whyDuration':
            aiJson['why_duration']?.toString().trim().isNotEmpty == true
            ? aiJson['why_duration'].toString().trim()
            : fallback['whyDuration'],
        'tips': tips.isEmpty ? fallback['tips'] : tips,
        'source': 'gpt',
      };
    } finally {
      client.close(force: true);
    }
  } catch (error) {
    _log.warning('GPT stop explanation fallback to rule-based: $error');
    return fallback;
  }
}

Map<String, dynamic> _buildRuleBasedStopExplanation(
  Map<String, dynamic> body,
  Map<String, dynamic> place,
) {
  final explanationContext = body['explanationContext']?.toString().trim();
  final isMealSelection = explanationContext == 'meal_selection';
  final name = place['name']?.toString() ?? '此景點';
  final city = place['city']?.toString() ?? '';
  final tags =
      (place['tags'] as List?)?.map((e) => e.toString()).toList() ??
      const <String>[];
  final start = body['startTime']?.toString() ?? '';
  final end = body['endTime']?.toString() ?? '';
  final durationMin = (body['durationMinutes'] as num?)?.toInt();
  final prevName = body['prevPlaceName']?.toString() ?? '';
  final nextName = body['nextPlaceName']?.toString() ?? '';
  final weather = body['weatherSummary']?.toString() ?? '';
  final interests =
      (body['interests'] as List?)?.map((e) => e.toString()).toList() ??
      const <String>[];

  final matchTags = tags.where(
    (tag) => interests.map((e) => e.toLowerCase()).contains(tag.toLowerCase()),
  );
  final includeReason = isMealSelection
      ? [
          if (city.isNotEmpty) '位於$city',
          if (prevName.isNotEmpty && nextName.isNotEmpty) '落在「$prevName」與「$nextName」之間，順路性較高',
          if (prevName.isEmpty && nextName.isNotEmpty) '方便接續下一站「$nextName」',
          if (prevName.isNotEmpty && nextName.isEmpty) '方便從前一站「$prevName」銜接過來',
        ].join('，')
      : [
          if (city.isNotEmpty) '位於$city',
          if (matchTags.isNotEmpty) '符合偏好類型（${matchTags.take(3).join('、')}）',
          if (matchTags.isEmpty && tags.isNotEmpty)
            '景點類型多元（${tags.take(3).join('、')}）',
        ].join('，');

  final timingReason = [
    if (start.isNotEmpty && end.isNotEmpty) '安排在 $start-$end 時段',
    if (prevName.isNotEmpty) '可銜接前一站「$prevName」',
    if (nextName.isNotEmpty) '也方便接續下一站「$nextName」',
    if (weather.isNotEmpty) '並考量當日天氣（$weather）',
  ].join('，');

  final duration =
      durationMin ??
      (() {
        if (start.isNotEmpty && end.isNotEmpty) {
          final s = _parseHmToMinute(start);
          final e = _parseHmToMinute(end);
          if (s != null && e != null && e > s) return e - s;
        }
        return 90;
      })();

  String durationReason;
  if (isMealSelection) {
    if (duration >= 90) {
      durationReason = '用餐停留時間較充裕，可保留點餐、候位與休息彈性。';
    } else if (duration >= 60) {
      durationReason = '用餐停留時間設定為常見餐期長度，兼顧休息與後續移動效率。';
    } else {
      durationReason = '此餐期安排較精簡，適合快速用餐後銜接下一站。';
    }
  } else if (duration >= 160) {
    durationReason = '此站停留時間較長，代表包含較完整的參觀/休憩與移動緩衝。';
  } else if (duration >= 100) {
    durationReason = '停留時間設定為中等偏充裕，兼顧拍照、步行與休息。';
  } else {
    durationReason = '停留時間較精簡，適合快速走訪後前往下一站。';
  }

  return {
    'summary': isMealSelection
        ? '$name 可作為這段行程中的餐期節點，重點是讓前後動線與用餐時間更順。'
        : '$name 是此日動線中的重點節點，用來平衡順路性與體驗完整度。',
    'whyIncluded': includeReason.isEmpty
        ? (isMealSelection ? '這個餐廳位於路線附近，適合作為前後站之間的用餐安排。' : '此景點綜合評分高且與行程主題相符。')
        : '因為$includeReason。',
    'whyTiming': timingReason.isEmpty
        ? '此時段安排可讓整體動線更順，減少折返。'
        : '因為$timingReason。',
    'whyDuration': durationReason,
    'tips': <String>[
      if (weather.isNotEmpty) '留意天氣：$weather',
      if (isMealSelection && duration >= 60) '若現場候位較久，可優先改選同區餐廳以免壓縮後續景點',
      if (!isMealSelection && duration >= 120) '可預留拍照或用餐時間，避免太趕',
      '若臨時延誤，可優先縮短停留而非跨區折返',
    ].take(4).toList(),
    'source': 'rule',
  };
}

String _buildStopExplanationPrompt(
  Map<String, dynamic> body,
  Map<String, dynamic> place,
) {
  final explanationContext = body['explanationContext']?.toString().trim();
  final isMealSelection = explanationContext == 'meal_selection';
  final tags =
      (place['tags'] as List?)?.map((e) => e.toString()).join(', ') ?? '';
  return '''
請解釋單一${isMealSelection ? '餐廳' : '景點'}在旅遊行程中的安排理由，用繁體中文，且只回傳 JSON。

欄位固定：
{
  "summary": "1句總結",
  "why_included": "為什麼加入這個景點",
  "why_timing": "為什麼安排在這個時間點",
  "why_duration": "為什麼安排這個停留時長",
  "tips": ["提醒1","提醒2","提醒3"]
}

使用者條件：
- 城市/地點：${body['location']?.toString() ?? '未提供'}
- 預算：${body['budget']?.toString() ?? '未提供'}
- 人數：${body['people']?.toString() ?? '未提供'}

${isMealSelection ? '餐廳資訊' : '景點資訊'}：
- 名稱：${place['name']?.toString() ?? ''}
- 城市：${place['city']?.toString() ?? ''}
- 地址：${place['address']?.toString() ?? ''}
- 標籤：$tags
- 評分：${place['rating']?.toString() ?? '未提供'}

行程上下文：
- 日期：${body['date']?.toString() ?? ''}
- 第幾天：${body['day']?.toString() ?? ''}
- 時段：${body['startTime']?.toString() ?? ''} ~ ${body['endTime']?.toString() ?? ''}
- 停留分鐘：${body['durationMinutes']?.toString() ?? '未提供'}
- 前一站：${body['prevPlaceName']?.toString() ?? '無'}
- 下一站：${body['nextPlaceName']?.toString() ?? '無'}
- 前段交通：${body['transitFromPrev']?.toString() ?? '未提供'}
- 後段交通：${body['transitToNext']?.toString() ?? '未提供'}
- 天氣：${body['weatherSummary']?.toString() ?? '未提供'} ${body['weatherTempRange']?.toString() ?? ''}

${isMealSelection ? '重點：不要用「符合偏好類型」或興趣匹配當理由。餐廳說明只聚焦順路性、餐期時段、前後站銜接、交通與天氣，避免把餐廳講成景點主題的一部分。' : '重點：可考慮興趣、景點類型、時間安排與前後站銜接。'}
''';
}

List<String> _stringListFromJson(dynamic raw, {int maxItems = 4}) {
  if (raw is! List) return const <String>[];
  return raw
      .map((e) => e.toString().trim())
      .where((e) => e.isNotEmpty)
      .take(maxItems)
      .toList();
}

Map<String, dynamic>? _extractJsonMap(String raw) {
  var text = raw.trim();
  if (text.startsWith('```')) {
    text = text.replaceAll(RegExp(r'^```[a-zA-Z]*\s*'), '');
    text = text.replaceAll(RegExp(r'\s*```$'), '');
  }
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {}

  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start >= 0 && end > start) {
    final candidate = text.substring(start, end + 1);
    try {
      final decoded = jsonDecode(candidate);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
  }
  return null;
}

Future<void> _attachWeatherToDays(
  List<Map<String, dynamic>> days, {
  List<Place>? catalog,
}) async {
  if (days.isEmpty) return;
  final startDate = days.first['date']?.toString();
  final endDate = days.last['date']?.toString();
  if (startDate == null || endDate == null) return;

  final cache = <String, Map<String, Map<String, dynamic>>>{};
  for (final day in days) {
    final dayDate = day['date']?.toString();
    if (dayDate == null || dayDate.isEmpty) {
      continue;
    }
    final coordinate = _resolveDayWeatherCoordinate(day, catalog: catalog);
    if (coordinate == null) {
      continue;
    }
    final key =
        '${coordinate.$1.toStringAsFixed(4)},${coordinate.$2.toStringAsFixed(4)}';
    final byDate = cache[key] ??= await _fetchDailyWeatherForecast(
      lat: coordinate.$1,
      lng: coordinate.$2,
      startDate: startDate,
      endDate: endDate,
    );
    final weather = byDate[dayDate];
    if (weather != null) {
      day['weather'] = weather;
    }
  }
}

(double, double)? _extractDayCoordinate(Map<String, dynamic> day) {
  final items = day['items'];
  if (items is! List || items.isEmpty) {
    return null;
  }
  for (final item in items) {
    if (item is! Map) continue;
    final place = item['place'];
    if (place is! Map) continue;
    final lat = _asDoubleValue(place['lat']);
    final lng = _asDoubleValue(place['lng']);
    if (lat == null || lng == null) {
      continue;
    }
    if (lat == 0 && lng == 0) {
      continue;
    }
    return (lat, lng);
  }
  return null;
}

String? _extractDayCity(Map<String, dynamic> day) {
  final items = day['items'];
  if (items is List) {
    for (final item in items.whereType<Map>()) {
      final place = item['place'];
      if (place is! Map) continue;
      final city = place['city']?.toString().trim();
      if (city != null && city.isNotEmpty) {
        return city;
      }
      final address = place['address']?.toString().trim() ?? '';
      final inferred = _extractCityFromAddressText(address);
      if (inferred != null && inferred.isNotEmpty) {
        return inferred;
      }
    }
  }
  final location = day['location']?.toString().trim() ?? '';
  if (location.isNotEmpty) {
    final parts = _parseLocationParts(location);
    if (parts.$1 != null && parts.$1!.isNotEmpty) {
      return parts.$1!;
    }
  }
  return null;
}

(double, double)? _resolveDayWeatherCoordinate(
  Map<String, dynamic> day, {
  List<Place>? catalog,
}) {
  final direct = _extractDayCoordinate(day);
  if (direct != null) {
    return direct;
  }
  if (catalog == null || catalog.isEmpty) {
    return null;
  }
  final city = _extractDayCity(day);
  if (city == null || city.isEmpty) {
    return null;
  }
  return _resolveCityAnchor(
    places: catalog,
    city: _normalizeLocationText(city),
  );
}

String? _extractCityFromAddressText(String address) {
  final text = address.trim();
  if (text.isEmpty) return null;
  final match = RegExp(
    r'(臺北市|台北市|新北市|基隆市|桃園市|新竹市|新竹縣|苗栗縣|臺中市|台中市|彰化縣|南投縣|雲林縣|嘉義市|嘉義縣|臺南市|台南市|高雄市|屏東縣|宜蘭縣|花蓮縣|臺東縣|台東縣|澎湖縣|金門縣|連江縣)',
  ).firstMatch(text);
  return match?.group(0);
}

Future<Map<String, Map<String, dynamic>>> _fetchDailyWeatherForecast({
  required double lat,
  required double lng,
  required String startDate,
  required String endDate,
}) async {
  final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
    'latitude': lat.toString(),
    'longitude': lng.toString(),
    'daily':
        'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max',
    'timezone': 'Asia/Taipei',
    'start_date': startDate,
    'end_date': endDate,
  });

  Object? lastError;
  for (var attempt = 0; attempt < 3; attempt++) {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        _log.warning(
          'Open-Meteo request failed: HTTP ${response.statusCode} ($uri)',
        );
        lastError = 'HTTP ${response.statusCode}';
        if (attempt < 2) {
          await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
          continue;
        }
        return const {};
      }
      final body = await utf8.decodeStream(response);
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return const {};
      }
      final daily = decoded['daily'];
      if (daily is! Map) {
        return const {};
      }

      final dates = (daily['time'] as List?)?.map((e) => e.toString()).toList();
      final weatherCodes = (daily['weather_code'] as List?) ?? const [];
      final tempMax = (daily['temperature_2m_max'] as List?) ?? const [];
      final tempMin = (daily['temperature_2m_min'] as List?) ?? const [];
      final precipMax =
          (daily['precipitation_probability_max'] as List?) ?? const [];
      if (dates == null || dates.isEmpty) {
        return const {};
      }

      final result = <String, Map<String, dynamic>>{};
      for (var i = 0; i < dates.length; i++) {
        final code = _asIntValue(
          i < weatherCodes.length ? weatherCodes[i] : null,
        );
        final maxValue = _asDoubleValue(i < tempMax.length ? tempMax[i] : null);
        final minValue = _asDoubleValue(i < tempMin.length ? tempMin[i] : null);
        final rainProb = _asIntValue(i < precipMax.length ? precipMax[i] : null);
        result[dates[i]] = {
          'summary': _weatherCodeToText(code),
          'code': code,
          'temperatureMax': maxValue,
          'temperatureMin': minValue,
          'precipitationProbability': rainProb,
          'source': 'open-meteo',
        };
      }
      return result;
    } catch (error) {
      lastError = error;
      if (attempt < 2) {
        await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
        continue;
      }
    } finally {
      client.close(force: true);
    }
  }
  _log.warning('Open-Meteo request error: $lastError');
  return const {};
}

double? _asDoubleValue(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

int? _asIntValue(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

String _weatherCodeToText(int? code) {
  if (code == null) return '天氣資料整理中';
  if (code == 0) return '晴朗';
  if (code == 1) return '大致晴朗';
  if (code == 2) return '局部多雲';
  if (code == 3) return '陰天';
  if (code >= 45 && code <= 48) return '有霧';
  if (code >= 51 && code <= 57) return '毛毛雨';
  if (code >= 61 && code <= 67) return '降雨';
  if (code >= 71 && code <= 77) return '降雪';
  if (code >= 80 && code <= 82) return '陣雨';
  if (code >= 95) return '雷雨';
  return '多變天氣';
}

int _calculateDays(DateTime? start, DateTime? end) {
  if (start == null || end == null) {
    return 1;
  }
  final diff = end.difference(start).inDays;
  return diff >= 0 ? diff + 1 : 1;
}

String? _budgetToPriceCategory(int? budget) {
  if (budget == null) return null;
  if (budget <= 1000) return 'low';
  if (budget <= 3000) return 'mid';
  return 'high';
}

String _normalizeTripPurpose(String? raw) {
  final value = raw?.trim().toLowerCase() ?? '';
  return switch (value) {
    'relax' || '休閒放鬆' || '放鬆慢遊' || '放鬆' || '慢遊' => 'relax',
    'explore' || '景點探索' || '綜合推薦' || 'balanced' || '美食探索' || '美食' ||
    '人文走讀' || '人文' || '文化' || '走讀' || '自然療癒' || '自然' || '戶外' => 'explore',
    'couple' || '情侶約會' || '約會' => 'couple',
    'family' || '家庭旅遊' || '親子同遊' || '親子' || '家庭' => 'family',
    _ => 'explore',
  };
}

String _normalizeTravelBehavior(String? raw) {
  final value = raw?.trim().toLowerCase() ?? '';
  return switch (value) {
    'family' || '家庭' || '親子' => 'family',
    'couple' || '情侶' => 'couple',
    'solo' || '個人' || '單人' || '獨旅' => 'solo',
    _ => 'general',
  };
}

String _tripPurposeLabel(String? purpose) {
  return switch (_normalizeTripPurpose(purpose)) {
    'relax' => '休閒放鬆',
    'explore' => '景點探索',
    'couple' => '情侶約會',
    'family' => '家庭旅遊',
    _ => '景點探索',
  };
}

String _travelBehaviorLabel(String? behavior) {
  return switch (_normalizeTravelBehavior(behavior)) {
    'family' => '家庭出遊',
    'couple' => '情侶出遊',
    'solo' => '個人旅行',
    _ => '一般旅伴',
  };
}

bool _placeMatchesTripPurpose(
  Place place,
  String purpose,
) {
  final score = _tripPurposeScore(
    place,
    _PlannerWeights.tripPurposeProbe(
      tripPurpose: purpose,
      travelBehavior: 'general',
    ),
  );
  return score >= 0.85;
}

double _tripPurposePenalty(Place place, _PlannerWeights weights) {
  final tags = place.tags.map((e) => e.toLowerCase()).toSet();
  final text = _normalizeText(
    '${place.name} ${place.description} ${place.address}',
  );

  bool textHas(List<String> needles) =>
      needles.any((needle) => text.contains(_normalizeText(needle)));

  var penalty = 0.0;
  switch (weights.tripPurpose) {
    case 'relax':
      if ([
        'amusement_park',
        'arcade',
        'night_market',
        'street_food',
      ].any(tags.contains)) {
        penalty += 0.9;
      }
      if (textHas(['排隊', '夜市', '遊樂園', '人潮'])) {
        penalty += 0.5;
      }
      break;
    case 'explore':
      break;
    case 'couple':
      if (['zoo', 'aquarium'].any(tags.contains)) {
        penalty += 0.35;
      }
      if (textHas(['工業區', '行政', '批發'])) {
        penalty += 0.75;
      }
      break;
    case 'family':
      if (['bar', 'pub', 'night_club'].any(tags.contains)) {
        penalty += 1.2;
      }
      if (textHas(['酒吧', '夜店', '深夜'])) {
        penalty += 0.9;
      }
      if (textHas(['登山口', '陡坡', '長距離步道'])) {
        penalty += 0.6;
      }
      break;
  }
  return penalty;
}

List<Place> _filterCandidatesByTripPurpose(
  List<Place> candidates,
  String purpose,
) {
  if (candidates.length <= 6 || purpose == 'explore') {
    return candidates;
  }

  final matched = candidates
      .where((place) => _placeMatchesTripPurpose(place, purpose))
      .toList();
  if (matched.length >= max(4, (candidates.length * 0.28).round())) {
    return matched;
  }
  if (matched.length >= 3) {
    final extras = candidates
        .where((place) => !matched.any((picked) => picked.id == place.id))
        .take(max(2, candidates.length ~/ 7))
        .toList();
    return [...matched, ...extras];
  }
  return candidates;
}

double _tripPurposeScore(Place place, _PlannerWeights weights) {
  final tags = place.tags.map((e) => e.toLowerCase()).toSet();
  final text = _normalizeText(
    '${place.name} ${place.description} ${place.address}',
  );

  bool textHas(List<String> needles) =>
      needles.any((needle) => text.contains(_normalizeText(needle)));

  var score = 0.0;
  switch (weights.tripPurpose) {
    case 'relax':
      if ([
        'lake_river',
        'beach',
        'waterfall',
        'national_park',
        'cafe',
        'bike',
      ].any(tags.contains)) {
        score += 0.95;
      }
      if (textHas(['老街', '溫泉', '步道', '景觀', '湖', '海景'])) {
        score += 0.45;
      }
      if (['amusement_park', 'night_market'].any(tags.contains)) {
        score -= 0.2;
      }
      break;
    case 'explore':
      if ([
        'museum',
        'heritage',
        'national_park',
        'lake_river',
        'beach',
        'waterfall',
        'creative_park',
        'temple',
        'night_market',
      ].any(tags.contains)) {
        score += 0.95;
      }
      if (textHas(['景點', '古蹟', '展覽', '歷史', '文化', '美術', '步道', '海景'])) {
        score += 0.55;
      }
      break;
    case 'couple':
      if ([
        'cafe',
        'creative_park',
        'beach',
        'lake_river',
        'heritage',
        'night_market',
      ].any(tags.contains)) {
        score += 0.95;
      }
      if (textHas(['夜景', '海景', '景觀', '咖啡', '約會', '老街', '散步'])) {
        score += 0.55;
      }
      break;
    case 'family':
      if ([
        'amusement_park',
        'zoo',
        'aquarium',
        'creative_park',
        'national_park',
      ].any(tags.contains)) {
        score += 0.95;
      }
      if (textHas(['親子', '農場', '動物', '遊樂', '體驗'])) {
        score += 0.55;
      }
      if (textHas(['酒吧', '夜店'])) {
        score -= 0.6;
      }
      break;
  }
  return score;
}

class _PlannerWeights {
  const _PlannerWeights({
    required this.interestWeight,
    required this.qualityWeight,
    required this.backpackerWeight,
    required this.priceWeight,
    required this.distancePenaltyWeight,
    required this.diversityPenaltyWeight,
    required this.cityCoherenceWeight,
    required this.dayMinutesBudget,
    required this.stayBudgetRatio,
    required this.tripPurpose,
    required this.travelBehavior,
    required this.tripPurposeScoreWeight,
    required this.preferLowBudget,
    required this.preferTransitFriendly,
    required this.preferHotspot,
    required this.preferHiddenGems,
  });

  final double interestWeight;
  final double qualityWeight;
  final double backpackerWeight;
  final double priceWeight;
  final double distancePenaltyWeight;
  final double diversityPenaltyWeight;
  final double cityCoherenceWeight;
  final int dayMinutesBudget;
  final double stayBudgetRatio;
  final String tripPurpose;
  final String travelBehavior;
  final double tripPurposeScoreWeight;

  final bool preferLowBudget;
  final bool preferTransitFriendly;
  final bool preferHotspot;
  final bool preferHiddenGems;

  factory _PlannerWeights.fromInputs({
    required String? targetPrice,
    required int? people,
    required String? tripPurpose,
    required String? travelBehavior,
    Map<String, dynamic>? backpackerAnswers,
  }) {
    final answers = backpackerAnswers ?? const <String, dynamic>{};
    final budgetStyle = answers['budgetStyle']?.toString();
    final transport = answers['transport']?.toString();
    final pace = answers['pace']?.toString();
    final hotspot = answers['preferHotspot'] == true;
    final hidden = answers['preferHiddenGems'] == true;
    final lowBudget =
        targetPrice == 'low' ||
        budgetStyle == 'low' ||
        answers['lowBudget'] == true;
    final normalizedTripPurpose = _normalizeTripPurpose(tripPurpose);
    final normalizedTravelBehavior = _normalizeTravelBehavior(travelBehavior);

    var distancePenaltyWeight = 0.08;
    var dayMinutesBudget = 600;
    var stayBudgetRatio = 0.72;
    var qualityWeight = 1.8;
    var cityCoherenceWeight = 1.0;
    var tripPurposeScoreWeight = 2.3;
    var preferTransitFriendly =
        transport == 'public' || (people != null && people <= 2);
    if (pace == 'relaxed') {
      distancePenaltyWeight = 0.12;
      dayMinutesBudget = 520;
    } else if (pace == 'compact') {
      distancePenaltyWeight = 0.06;
      dayMinutesBudget = 680;
    }

    switch (normalizedTripPurpose) {
      case 'relax':
        distancePenaltyWeight = max(distancePenaltyWeight, 0.12);
        dayMinutesBudget = min(dayMinutesBudget, 520);
        stayBudgetRatio = 0.80;
        tripPurposeScoreWeight = 3.0;
        break;
      case 'explore':
        dayMinutesBudget = max(dayMinutesBudget, 620);
        stayBudgetRatio = 0.68;
        cityCoherenceWeight = 1.15;
        tripPurposeScoreWeight = 2.0;
        break;
      case 'couple':
        dayMinutesBudget = min(dayMinutesBudget, 560);
        stayBudgetRatio = 0.76;
        qualityWeight = 1.95;
        tripPurposeScoreWeight = 3.1;
        break;
      case 'family':
        distancePenaltyWeight = max(distancePenaltyWeight, 0.12);
        dayMinutesBudget = min(dayMinutesBudget, 520);
        stayBudgetRatio = 0.76;
        preferTransitFriendly = true;
        tripPurposeScoreWeight = 3.2;
        break;
    }
    switch (normalizedTravelBehavior) {
      case 'family':
        distancePenaltyWeight = max(distancePenaltyWeight, 0.12);
        dayMinutesBudget = min(dayMinutesBudget, 520);
        stayBudgetRatio = max(stayBudgetRatio, 0.78);
        preferTransitFriendly = true;
        tripPurposeScoreWeight = max(tripPurposeScoreWeight, 3.1);
        break;
      case 'couple':
        qualityWeight = max(qualityWeight, 1.9);
        cityCoherenceWeight = max(cityCoherenceWeight, 1.05);
        tripPurposeScoreWeight = max(tripPurposeScoreWeight, 3.0);
        break;
      case 'solo':
        preferTransitFriendly = true;
        break;
    }

    return _PlannerWeights(
      interestWeight: 2.2,
      qualityWeight: qualityWeight,
      backpackerWeight: 1.3,
      priceWeight: 1.2,
      distancePenaltyWeight: distancePenaltyWeight,
      diversityPenaltyWeight: 0.65,
      cityCoherenceWeight: cityCoherenceWeight,
      dayMinutesBudget: dayMinutesBudget,
      stayBudgetRatio: stayBudgetRatio,
      tripPurpose: normalizedTripPurpose,
      travelBehavior: normalizedTravelBehavior,
      tripPurposeScoreWeight: tripPurposeScoreWeight,
      preferLowBudget: lowBudget,
      preferTransitFriendly: preferTransitFriendly,
      preferHotspot: hotspot,
      preferHiddenGems: hidden,
    );
  }

  factory _PlannerWeights.tripPurposeProbe({
    required String tripPurpose,
    required String travelBehavior,
  }) {
    return _PlannerWeights(
      interestWeight: 0,
      qualityWeight: 0,
      backpackerWeight: 0,
      priceWeight: 0,
      distancePenaltyWeight: 0,
      diversityPenaltyWeight: 0,
      cityCoherenceWeight: 0,
      dayMinutesBudget: 0,
      stayBudgetRatio: 0,
      tripPurpose: _normalizeTripPurpose(tripPurpose),
      travelBehavior: _normalizeTravelBehavior(travelBehavior),
      tripPurposeScoreWeight: 1,
      preferLowBudget: false,
      preferTransitFriendly: false,
      preferHotspot: false,
      preferHiddenGems: false,
    );
  }

  Map<String, dynamic> toJson() => {
    'interestWeight': interestWeight,
    'qualityWeight': qualityWeight,
    'backpackerWeight': backpackerWeight,
    'priceWeight': priceWeight,
    'distancePenaltyWeight': distancePenaltyWeight,
    'diversityPenaltyWeight': diversityPenaltyWeight,
    'cityCoherenceWeight': cityCoherenceWeight,
    'dayMinutesBudget': dayMinutesBudget,
    'stayBudgetRatio': stayBudgetRatio,
    'tripPurpose': tripPurpose,
    'travelBehavior': travelBehavior,
    'tripPurposeScoreWeight': tripPurposeScoreWeight,
    'preferLowBudget': preferLowBudget,
    'preferTransitFriendly': preferTransitFriendly,
    'preferHotspot': preferHotspot,
    'preferHiddenGems': preferHiddenGems,
  };
}

double _diversityPenalty(Place place, List<Place> picked) {
  if (picked.isEmpty) return 0;
  final currentTags = place.tags.map((e) => e.toLowerCase()).toSet();
  if (currentTags.isEmpty) return 0;
  final pickedTags = picked
      .expand((p) => p.tags.map((t) => t.toLowerCase()))
      .toList();
  final overlap = pickedTags.where(currentTags.contains).length;
  return overlap * 0.35;
}

double _scorePlace(
  Place place, {
  required Set<String> preferredTags,
  required String? targetPrice,
  required _PlannerWeights weights,
}) {
  final rating = (place.rating ?? 0).clamp(0, 5) / 5.0;
  final reviewLog = place.userRatingsTotal == null
      ? 0.0
      : (log(place.userRatingsTotal!.clamp(0, 100000) + 1) / ln10) / 5.0;
  final infoCompleteness = _infoCompletenessScore(place);
  final qualityScore =
      (rating * 0.55 + reviewLog * 0.3 + infoCompleteness * 0.15) *
      weights.qualityWeight *
      3.0;

  var score = qualityScore;
  if (preferredTags.isNotEmpty) {
    final matched = place.tags
        .where((tag) => preferredTags.contains(tag.toLowerCase()))
        .length;
    final matchRatio = matched / preferredTags.length;
    score += matchRatio * weights.interestWeight * 4.0;
  }

  score += _tripPurposeScore(place, weights) * weights.tripPurposeScoreWeight;
  score -= _tripPurposePenalty(place, weights) * 2.2;

  score += _backpackerSignalScore(place, weights) * weights.backpackerWeight;

  if (targetPrice != null) {
    final category = _effectivePriceCategory(place);
    if (category == targetPrice) {
      score += 1.0 * weights.priceWeight;
    } else if (category != null) {
      score -= 0.6 * weights.priceWeight;
    }
  }

  if (weights.preferLowBudget) {
    final category = _effectivePriceCategory(place);
    if (category == 'free' || category == 'low') {
      score += 0.8;
    } else if (category == 'high') {
      score -= 1.0;
    }
  }

  if (weights.preferHotspot && (place.userRatingsTotal ?? 0) >= 5000) {
    score += 0.55;
  }
  if (weights.preferHiddenGems &&
      (place.userRatingsTotal != null && place.userRatingsTotal! <= 800)) {
    score += 0.45;
  }

  if (weights.preferTransitFriendly) {
    final transitHint = '${place.name} ${place.address} ${place.description}';
    if (transitHint.contains('車站') ||
        transitHint.contains('捷運') ||
        transitHint.contains('火車')) {
      score += 0.65;
    }
  }

  score += _itineraryLearningProfile.scoreBoost(
    place,
    preferredTags: preferredTags,
    targetPrice: targetPrice,
    weights: weights,
  );

  return score;
}

double _plannerPriorityBoost(Place place, Set<String> prioritizedCities) {
  if (prioritizedCities.isEmpty) return 0;
  final city = _normalizeLocationText(place.city);
  final address = _normalizeLocationText(place.address);
  for (final target in prioritizedCities) {
    if (target.isEmpty) continue;
    if (city.contains(target) || address.contains(target)) {
      return 0.9;
    }
  }
  return 0;
}

double _wishlistBoost(Place place, List<String> wishKeywords) {
  if (wishKeywords.isEmpty) return 0;
  final hay = _normalizeLocationText(
    '${place.name} ${place.city} ${place.address} ${place.description}',
  );
  var boost = 0.0;
  for (final keyword in wishKeywords) {
    if (keyword.isEmpty) continue;
    if (hay.contains(keyword)) {
      boost += 1.4;
    }
  }
  return boost;
}

double _infoCompletenessScore(Place place) {
  var score = 0.0;
  if (place.description.trim().length >= 30) score += 0.35;
  if (place.address.trim().length >= 6) score += 0.25;
  if (place.imageUrl.trim().isNotEmpty) score += 0.2;
  if (place.tags.isNotEmpty) score += 0.2;
  return score.clamp(0, 1);
}

double _backpackerSignalScore(Place place, _PlannerWeights weights) {
  const keywords = [
    '夜市',
    '老街',
    '步道',
    '公園',
    '市集',
    '市場',
    '古蹟',
    '車站',
    '小吃',
    '免費',
    '平價',
  ];
  final text =
      '${place.name} ${place.description} ${place.address} ${place.tags.join(' ')}';
  var hits = 0;
  for (final keyword in keywords) {
    if (text.contains(keyword)) {
      hits++;
    }
  }
  var score = hits * 0.18;
  if (weights.preferLowBudget &&
      (text.contains('免費') || text.contains('平價') || text.contains('小吃'))) {
    score += 0.45;
  }
  return score.clamp(0, 1.8);
}

int? _inferPriceLevelFromPlace(Place place) {
  final tags = place.tags.map((e) => e.toLowerCase()).toSet();
  final text = _normalizeLocationText(
    '${place.name} ${place.city} ${place.address} ${place.description} ${place.tags.join(' ')}',
  );
  const highPriceTags = <String>{
    'amusement_park',
    'aquarium',
    'zoo',
    'rv_park',
    'campground',
    'spa',
  };
  const freeDefaultTags = <String>{
    'lake_river',
    'beach',
    'national_park',
    'waterfall',
    'temple',
    'night_market',
  };
  const lowPriceTags = <String>{
    'museum',
    'heritage',
    'creative_park',
    'handcraft_shop',
  };

  bool containsAny(List<String> values) => values.any(text.contains);
  bool hasFreeTicketSignal() {
    final patterns = <RegExp>[
      RegExp(r'免門票'),
      RegExp(r'免收門票'),
      RegExp(r'免費入場'),
      RegExp(r'免費參觀'),
      RegExp(r'自由入場'),
      RegExp(r'門票免費'),
      RegExp(r'票價免費'),
      RegExp(r'入場免費'),
      RegExp(r'參觀免費'),
      RegExp(r'free admission', caseSensitive: false),
      RegExp(r'free entry', caseSensitive: false),
    ];
    return patterns.any((pattern) => pattern.hasMatch(text));
  }
  int? extractExplicitTicketAmount() {
    final patterns = <RegExp>[
      RegExp(r'(?:nt\$|twd|\$)\s*(\d{2,5})', caseSensitive: false),
      RegExp(r'(\d{2,5})\s*元'),
      RegExp(r'(?:門票|票價|全票|入園|入館|成人票|優待票|售價|收費)[^\d]{0,8}(\d{2,5})'),
      RegExp(r'(\d{2,5})[^\d]{0,6}(?:門票|票價|全票|入園|入館|成人票|優待票|售價|收費)'),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      final amount = int.tryParse(match.group(1) ?? '');
      if (amount != null && amount > 0) {
        return amount;
      }
    }
    return null;
  }
  bool hasExplicitPaidTicketSignal() => containsAny([
    '門票',
    '票價',
    '全票',
    '優待票',
    '成人票',
    '兒童票',
    '入園費',
    '入館費',
    '入場費',
    '購票',
    '售票',
    '售價',
    '收費',
  ]);

  final explicitAmount = extractExplicitTicketAmount();
  if (explicitAmount != null) {
    if (explicitAmount >= 300) return 3;
    return 1;
  }

  if (hasFreeTicketSignal()) {
    return 0;
  }

  if (hasExplicitPaidTicketSignal()) {
    if (tags.any(highPriceTags.contains) ||
        containsAny([
          '遊樂園',
          '主題樂園',
          '水族館',
          '動物園',
          '海洋公園',
          '纜車',
          '渡假村',
          '觀景台',
          '摩天輪',
          '台北101',
          '臺北101',
        ])) {
      return 3;
    }
    return 1;
  }

  if (tags.any(highPriceTags.contains) ||
      containsAny([
        '遊樂園',
        '主題樂園',
        '水族館',
        '動物園',
        '海洋公園',
        '纜車',
        '渡假村',
        '觀景台',
        '摩天輪',
        '台北101',
        '臺北101',
      ])) {
    return 3;
  }

  if (tags.any(freeDefaultTags.contains) ||
      containsAny([
        '公園',
        '老街',
        '步道',
        '古道',
        '海灘',
        '沙灘',
        '海岸',
        '湖',
        '溪',
        '瀑布',
        '河濱',
        '濕地',
        '夜市',
        '廟',
        '寺',
      ])) {
    return 0;
  }

  if (tags.any(lowPriceTags.contains) ||
      containsAny([
        '博物館',
        '美術館',
        '文學館',
        '文化館',
        '故事館',
        '紀念館',
        '教育園區',
        '園區',
        '展覽館',
        '古蹟',
        '觀光工廠',
        '文創',
      ])) {
    return 1;
  }

  return null;
}

bool _hasFreeTicketSignalFromPlace(Place place) {
  final text = _normalizeLocationText(
    '${place.name} ${place.city} ${place.address} ${place.description} ${place.tags.join(' ')}',
  );
  final patterns = <RegExp>[
    RegExp(r'免門票'),
    RegExp(r'免收門票'),
    RegExp(r'免費入場'),
    RegExp(r'免費參觀'),
    RegExp(r'自由入場'),
    RegExp(r'門票免費'),
    RegExp(r'票價免費'),
    RegExp(r'入場免費'),
    RegExp(r'參觀免費'),
    RegExp(r'free admission', caseSensitive: false),
    RegExp(r'free entry', caseSensitive: false),
  ];
  return patterns.any((pattern) => pattern.hasMatch(text));
}

int? _effectivePriceLevel(Place place) {
  final inferred = _inferPriceLevelFromPlace(place);
  if (inferred != null) {
    return inferred;
  }
  if (place.priceLevel == 0 && !_hasFreeTicketSignalFromPlace(place)) {
    return null;
  }
  return place.priceLevel;
}

String? _effectivePriceCategory(Place place) {
  final level = _effectivePriceLevel(place);
  if (level == null) {
    final explicit = place.priceCategory;
    if (explicit != null && explicit.trim().isNotEmpty) {
      return explicit;
    }
    return null;
  }
  if (level <= 0) return 'free';
  if (level <= 1) return 'low';
  return 'high';
}

Place _normalizePlaceForStorage(Place place) {
  final effectivePriceLevel = _effectivePriceLevel(place);
  final effectivePriceCategory = _effectivePriceCategory(place);
  if (place.priceLevel == effectivePriceLevel &&
      place.priceCategory == effectivePriceCategory) {
    return place;
  }
  return Place(
    id: place.id,
    name: place.name,
    tags: place.tags,
    city: place.city,
    address: place.address,
    lat: place.lat,
    lng: place.lng,
    description: place.description,
    imageUrl: place.imageUrl,
    rating: place.rating,
    userRatingsTotal: place.userRatingsTotal,
    priceLevel: effectivePriceLevel,
    priceCategory: effectivePriceCategory,
    openingHours: place.openingHours,
    source: place.source,
    updatedAt: place.updatedAt,
  );
}

bool _needsPriceBackfill(Place place) {
  final explicitLevel = place.priceLevel;
  final explicitCategory = place.priceCategory?.trim();
  final effectiveLevel = _effectivePriceLevel(place);
  final effectiveCategory = _effectivePriceCategory(place)?.trim();
  if (effectiveLevel == null && (effectiveCategory == null || effectiveCategory.isEmpty)) {
    return false;
  }
  return explicitLevel != effectiveLevel ||
      (explicitCategory ?? '') != (effectiveCategory ?? '');
}

Future<List<Place>> _backfillVisiblePlaces(
  DataStore store,
  List<Place> places,
) async {
  final normalized = <Place>[];
  for (final place in places) {
    if (_needsPriceBackfill(place)) {
      final updated = _normalizePlaceForStorage(place);
      await store.upsertPlace(updated);
      normalized.add(updated);
    } else {
      normalized.add(place);
    }
  }
  return normalized;
}

Map<String, dynamic> _placeToApiJson(Place place) {
  final explicitPriceLevel = place.priceLevel;
  final explicitPriceCategory = place.priceCategory;
  final effectivePriceLevel = _effectivePriceLevel(place);
  final effectivePriceCategory = _effectivePriceCategory(place);
  return {
    'id': place.id,
    'name': place.name,
    'tags': place.tags,
    'city': place.city,
    'address': place.address,
    'lat': place.lat,
    'lng': place.lng,
    'description': place.description,
    'imageUrl': place.imageUrl,
    'rating': place.rating,
    'userRatingsTotal': place.userRatingsTotal,
    'priceLevel': effectivePriceLevel,
    'priceCategory': effectivePriceCategory,
    'priceInferred':
        (explicitPriceLevel == null && (explicitPriceCategory == null || explicitPriceCategory.trim().isEmpty)) &&
        effectivePriceCategory != null,
    'openingHours': place.openingHours,
    'source': place.source,
    'updatedAt': place.updatedAt?.toUtc().toIso8601String(),
  };
}

Map<String, dynamic> _placeToPlanJson(Place place) {
  return {
    'id': place.id,
    'name': place.name,
    'city': place.city,
    'address': place.address,
    'description': place.description,
    'lat': place.lat,
    'lng': place.lng,
    'tags': place.tags,
    'rating': place.rating,
    'userRatingsTotal': place.userRatingsTotal,
    'priceLevel': _effectivePriceLevel(place),
    'priceCategory': _effectivePriceCategory(place),
    'imageUrl': place.imageUrl,
    'openingHours': place.openingHours,
    'kind': 'place',
  };
}

Future<List<Map<String, dynamic>>> _fetchLiveMealSuggestions({
  required Map<String, dynamic> previous,
  required Map<String, dynamic> next,
  required String query,
  required String mealType,
  required String city,
  required int limit,
}) async {
  final key = Platform.environment['GOOGLE_MAPS_API_KEY'] ?? '';
  if (key.isEmpty) {
    throw ApiException(400, '需要設定 GOOGLE_MAPS_API_KEY 才能即時搜尋餐廳');
  }

  final previousLat = _asDoubleValue(previous['lat']);
  final previousLng = _asDoubleValue(previous['lng']);
  final nextLat = _asDoubleValue(next['lat']);
  final nextLng = _asDoubleValue(next['lng']);
  final hasPrevious = previousLat != null && previousLng != null;
  final hasNext = nextLat != null && nextLng != null;
  if (!hasPrevious && !hasNext) {
    throw ApiException(400, '缺少前後站座標，無法搜尋附近餐廳');
  }

  late final double anchorLat;
  late final double anchorLng;
  if (hasPrevious && hasNext) {
    anchorLat = (previousLat + nextLat) / 2;
    anchorLng = (previousLng + nextLng) / 2;
  } else {
    anchorLat = previousLat ?? nextLat!;
    anchorLng = previousLng ?? nextLng!;
  }
  final prevName = _asString(previous, 'name').trim();
  final nextName = _asString(next, 'name').trim();
  final resolvedCity = city.trim().isNotEmpty
      ? city.trim()
      : _extractCityHint(_asString(previous, 'city')) ??
            _extractCityHint(_asString(next, 'city')) ??
            _extractCityHint(_asString(previous, 'address')) ??
            _extractCityHint(_asString(next, 'address')) ??
            '';

  final nearby = await _googlePlaceSearch(
    key: key,
    path: '/maps/api/place/nearbysearch/json',
    params: {
      'location': '$anchorLat,$anchorLng',
      'radius': hasPrevious && hasNext ? '3500' : '5000',
      'type': 'restaurant',
      'language': 'zh-TW',
      'region': 'tw',
      if (query.isNotEmpty) 'keyword': query,
    },
  );

  var candidates = _normalizeMealSearchResults(
    nearby,
    fallbackCity: resolvedCity,
    key: key,
    mealType: mealType,
  );

  if (candidates.length < max(5, limit ~/ 2)) {
    final textQuery = query.isNotEmpty
        ? '${query.trim()} ${resolvedCity.isNotEmpty ? resolvedCity : ''} 餐廳'
        : [
            if (resolvedCity.isNotEmpty) resolvedCity,
            if (prevName.isNotEmpty) prevName,
            if (nextName.isNotEmpty) nextName,
            mealType == 'dinner' ? '晚餐 餐廳' : '午餐 餐廳',
          ].join(' ').trim();
    if (textQuery.isNotEmpty) {
      final textSearch = await _googlePlaceSearch(
        key: key,
        path: '/maps/api/place/textsearch/json',
        params: {
          'query': textQuery,
          'language': 'zh-TW',
          'region': 'tw',
          'location': '$anchorLat,$anchorLng',
          'radius': '6000',
        },
      );
      candidates = [
        ...candidates,
        ..._normalizeMealSearchResults(
          textSearch,
          fallbackCity: resolvedCity,
          key: key,
          mealType: mealType,
        ),
      ];
    }
  }

  final unique = <String, Map<String, dynamic>>{};
  for (final candidate in candidates) {
    final lat = _asDoubleValue(candidate['lat']);
    final lng = _asDoubleValue(candidate['lng']);
    final distancePenalty =
        lat != null && lng != null
        ? _distanceKm(anchorLat, anchorLng, lat, lng)
        : 9999.0;
    candidate['fitDistanceKm'] = distancePenalty;
    candidate['fitScore'] =
        ((_asDoubleValue(candidate['rating']) ?? 0) * 10) - distancePenalty;
    final name = candidate['name']?.toString().trim() ?? '';
    final address = candidate['address']?.toString().trim() ?? '';
    if (name.isEmpty || address.isEmpty) continue;
    unique.putIfAbsent('$name|$address', () => candidate);
  }

  final sorted = unique.values.toList()
    ..sort((a, b) {
      final scoreA = _asDoubleValue(a['fitScore']) ?? 0;
      final scoreB = _asDoubleValue(b['fitScore']) ?? 0;
      return scoreB.compareTo(scoreA);
    });
  return sorted.take(limit).toList();
}

Future<List<Map<String, dynamic>>> _googlePlaceSearch({
  required String key,
  required String path,
  required Map<String, String> params,
}) async {
  final uri = Uri.https('maps.googleapis.com', path, {
    ...params,
    'key': key,
  });
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      return const <Map<String, dynamic>>[];
    }
    final body = await utf8.decodeStream(response);
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      return const <Map<String, dynamic>>[];
    }
    final status = decoded['status']?.toString() ?? '';
    if (status != 'OK' && status != 'ZERO_RESULTS') {
      _log.warning('Google Places search failed: $status');
      return const <Map<String, dynamic>>[];
    }
    final results = decoded['results'];
    if (results is! List) {
      return const <Map<String, dynamic>>[];
    }
    return results.whereType<Map>().map(Map<String, dynamic>.from).toList();
  } catch (error) {
    _log.warning('Google Places request error: $error');
    return const <Map<String, dynamic>>[];
  } finally {
    client.close(force: true);
  }
}

List<Map<String, dynamic>> _normalizeMealSearchResults(
  List<Map<String, dynamic>> results, {
  required String fallbackCity,
  required String key,
  required String mealType,
}) {
  final normalized = <Map<String, dynamic>>[];
  for (final result in results) {
    final types = (result['types'] as List?)
            ?.map((e) => e.toString().trim().toLowerCase())
            .where((e) => e.isNotEmpty)
            .toSet() ??
        <String>{};
    const allowedMealTypes = <String>{
      'restaurant',
      'cafe',
      'bakery',
      'meal_takeaway',
      'meal_delivery',
      'bar',
    };
    final name = result['name']?.toString().trim() ?? '';
    final address =
        result['formatted_address']?.toString().trim() ??
        result['vicinity']?.toString().trim() ??
        '';
    final text = _normalizeLocationText('$name $address ${types.join(' ')}');
    final hasAllowedMealType = types.any(allowedMealTypes.contains);
    final hasNonMealSignal =
        types.contains('museum') ||
        types.contains('art_gallery') ||
        types.contains('tourist_attraction') ||
        types.contains('park') ||
        text.contains(_normalizeLocationText('博物館')) ||
        text.contains(_normalizeLocationText('紀念館')) ||
        text.contains(_normalizeLocationText('公園')) ||
        text.contains(_normalizeLocationText('步道'));
    if (!hasAllowedMealType || hasNonMealSignal) {
      continue;
    }

    final location = result['geometry'] is Map
        ? Map<String, dynamic>.from(result['geometry'] as Map)
        : const <String, dynamic>{};
    final locationMap = location['location'] is Map
        ? Map<String, dynamic>.from(location['location'] as Map)
        : const <String, dynamic>{};
    final lat = _asDoubleValue(locationMap['lat']);
    final lng = _asDoubleValue(locationMap['lng']);
    if (lat == null || lng == null) {
      continue;
    }

    final photos = result['photos'];
    String imageUrl = '';
    if (photos is List && photos.isNotEmpty && photos.first is Map) {
      final photoRef = (photos.first as Map)['photo_reference']?.toString();
      if (photoRef != null && photoRef.isNotEmpty) {
        imageUrl = Uri.https(
          'maps.googleapis.com',
          '/maps/api/place/photo',
          {
            'maxwidth': '800',
            'photo_reference': photoRef,
            'key': key,
          },
        ).toString();
      }
    }

    normalized.add({
      'id': result['place_id']?.toString() ?? const Uuid().v4(),
      'name': name,
      'kind': 'place',
      'city': _extractCityHint(address) ?? fallbackCity,
      'address': address,
      'description':
          mealType == 'dinner'
          ? '即時搜尋到的晚餐候選，會依前後景點重算時間與交通。'
          : '即時搜尋到的午餐候選，會依前後景點重算時間與交通。',
      'imageUrl': imageUrl,
      'tags': <String>{
        if (types.contains('restaurant')) 'restaurant',
        if (types.contains('cafe')) 'cafe',
        if (types.contains('bakery')) 'bakery',
        if (types.contains('meal_takeaway')) 'meal_takeaway',
        if (types.contains('meal_delivery')) 'meal_delivery',
        if (types.contains('bar')) 'bar',
        'live_google_place',
      }.toList(),
      'rating': _asDoubleValue(result['rating']),
      'userRatingsTotal': _asIntValue(result['user_ratings_total']),
      'priceLevel': _asIntValue(result['price_level']),
      'lat': lat,
      'lng': lng,
      'source': 'google_places_live',
    });
  }
  return normalized;
}

String? _extractCityHint(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final parts = _parseLocationParts(text);
  if (parts.$1 != null && parts.$1!.trim().isNotEmpty) {
    return parts.$1!.trim();
  }
  return null;
}

String _asString(Map<String, dynamic> body, String key) {
  final value = body[key];
  if (value == null) {
    return '';
  }
  return value.toString();
}

Map<String, double> _doubleMapFromJson(dynamic raw) {
  if (raw is! Map) {
    return const <String, double>{};
  }
  final result = <String, double>{};
  for (final entry in raw.entries) {
    final key = entry.key.toString().trim().toLowerCase();
    if (key.isEmpty) continue;
    final value = entry.value;
    final parsed = value is num ? value.toDouble() : double.tryParse('$value');
    if (parsed == null) continue;
    result[key] = parsed;
  }
  return result;
}

Map<String, Map<String, double>> _nestedDoubleMapFromJson(dynamic raw) {
  if (raw is! Map) {
    return const <String, Map<String, double>>{};
  }
  final result = <String, Map<String, double>>{};
  for (final entry in raw.entries) {
    final key = entry.key.toString().trim().toLowerCase();
    if (key.isEmpty) continue;
    final value = _doubleMapFromJson(entry.value);
    if (value.isEmpty) continue;
    result[key] = value;
  }
  return result;
}

int? _asInt(Map<String, dynamic> body, String key) {
  final value = body[key];
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value.toString());
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
