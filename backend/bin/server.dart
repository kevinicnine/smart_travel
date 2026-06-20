import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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
late final bool _usingRenderBackend;
String? _openAiApiKey;
String? _openAiBaseUrl;
String? _openAiModel;
String? _llmProvider;
String? _geminiApiKey;
String? _geminiBaseUrl;
String? _geminiModel;
final List<String> _geminiApiKeys = [];
final Map<int, DateTime> _geminiKeyUnavailableUntil = {};
int _geminiApiKeyCursor = 0;
String? _lineChannelSecret;
String? _lineAddFriendUrl;
String? _reminderCronToken;
late final String _dataStoreLabel;
late final String? _adminToken;
late final String? _adminUser;
late final String? _adminPass;
late final String _dataDir;
late _ItineraryLearningProfile _itineraryLearningProfile;
late final DataStore _store;
late final NotificationService _notificationService;
_CrawlJob? _crawlJob;
List<Place>? _trainingPlacesExportCache;
Map<String, List<Place>>? _trainingPlacesExportIndexCache;
final Map<String, _LineLinkCode> _lineLinkCodes = {};
final Map<String, DateTime> _lineContextPushCooldown = {};
final Map<String, int> _requestPathCounts = {};
final List<Map<String, dynamic>> _recentRequestLogs = [];
final List<Map<String, dynamic>> _linePushHistory = [];
final List<Map<String, dynamic>> _reminderRunHistory = [];
final List<Map<String, dynamic>> _appEventHistory = [];
final List<Map<String, dynamic>> _aiUsageHistory = [];
final Map<String, _PlannerChatSession> _plannerChatSessions = {};
int _totalRequestCount = 0;
int _totalErrorCount = 0;
int _totalAiRequestCount = 0;
int _totalAiErrorCount = 0;

String _secretFingerprint(String? value) {
  if (value == null || value.isEmpty) return 'missing';
  return sha256.convert(utf8.encode(value)).toString().substring(0, 12);
}

String? _normalizedSecret(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String _googleMapsServerKey() {
  final preferred =
      Platform.environment['GOOGLE_PLACES_SERVER_API_KEY']?.trim() ?? '';
  if (preferred.isNotEmpty) {
    return preferred;
  }
  return Platform.environment['GOOGLE_MAPS_API_KEY']?.trim() ?? '';
}

class _AiUsageRecord {
  const _AiUsageRecord({
    required this.feature,
    required this.model,
    required this.success,
    required this.latencyMs,
    this.statusCode,
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.error,
  });

  final String feature;
  final String model;
  final bool success;
  final int latencyMs;
  final int? statusCode;
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  final String? error;
}

class _PlacePhotoPayload {
  const _PlacePhotoPayload({required this.bytes, required this.contentType});

  final Uint8List bytes;
  final String contentType;
}

class _LlmJsonResult {
  const _LlmJsonResult({
    required this.provider,
    required this.model,
    required this.statusCode,
    required this.latencyMs,
    required this.text,
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
  });

  final String provider;
  final String model;
  final int statusCode;
  final int latencyMs;
  final String text;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;

  String get usageModelLabel => '$provider:$model';
}

class _LlmRequestException implements Exception {
  const _LlmRequestException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _PlannerChatSession {
  _PlannerChatSession({
    required this.id,
    required this.startDate,
    required this.endDate,
    required this.originCity,
    required this.destinationCities,
    required this.userId,
    String? requirementsText,
  }) : requirementsText = requirementsText ?? '',
       createdAt = DateTime.now(),
       updatedAt = DateTime.now();

  final String id;
  final String? userId;
  final DateTime? startDate;
  final DateTime? endDate;
  final String originCity;
  final List<String> destinationCities;
  final List<Map<String, String>> messages = <Map<String, String>>[];
  final DateTime createdAt;
  DateTime updatedAt;
  String requirementsText;
  String? companion;
  String? transport;
  String? style;
  String? pacing;
  final Set<String> requiredPlaces = <String>{};
  final Set<String> excludedPlaces = <String>{};

  void touch() {
    updatedAt = DateTime.now();
  }
}

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
        interestTagWeights: _nestedDoubleMapFromJson(
          json['interestTagWeights'],
        ),
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
      score += (tripPurposeTagWeights[weights.tripPurpose]?[tag] ?? 0) * 0.45;
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
      score += (priceAffinity[normalizedTargetPrice]?[category] ?? 0) * 0.65;
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
  _usingRenderBackend =
      (Platform.environment['RENDER'] ?? '').isNotEmpty ||
      (Platform.environment['RENDER_SERVICE_ID'] ?? '').isNotEmpty ||
      (Platform.environment['RENDER_EXTERNAL_URL'] ?? '').isNotEmpty;
  _llmProvider = Platform.environment['LLM_PROVIDER'];
  _openAiApiKey = Platform.environment['OPENAI_API_KEY'];
  _openAiBaseUrl = Platform.environment['OPENAI_BASE_URL'];
  _openAiModel = Platform.environment['OPENAI_MODEL'] ?? 'gpt-4o-mini';
  _geminiApiKey = Platform.environment['GEMINI_API_KEY'];
  _geminiApiKeys
    ..clear()
    ..addAll(
      _parseGeminiApiKeys(
        Platform.environment['GEMINI_API_KEYS'],
        _geminiApiKey,
      ),
    );
  _geminiBaseUrl = Platform.environment['GEMINI_BASE_URL'];
  _geminiModel = Platform.environment['GEMINI_MODEL'] ?? 'gemini-2.5-flash';
  _lineChannelSecret = Platform.environment['LINE_CHANNEL_SECRET'];
  _lineAddFriendUrl = Platform.environment['LINE_ADD_FRIEND_URL'];
  _reminderCronToken = _normalizedSecret(
    Platform.environment['REMINDER_CRON_TOKEN'],
  );
  _reloadItineraryLearningProfile();

  _log.info('Using data directory: $_dataDir');
  _log.info(
    'Admin login enabled: ${_adminUser != null && _adminPass != null && _adminToken != null}',
  );
  _log.info(
    'LLM enabled: ${_isLlmConfigured()} provider=${_currentLlmProvider()}'
    '${_currentLlmProvider() == 'gemini' ? ' geminiKeys=${_geminiApiKeys.length}' : ''}',
  );
  _log.info(
    'Reminder cron token fingerprint: ${_secretFingerprint(_reminderCronToken)}',
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
    ..get('/favicon.ico', _emptySiteIconHandler)
    ..get('/apple-touch-icon.png', _emptySiteIconHandler)
    ..get('/apple-touch-icon-precomposed.png', _emptySiteIconHandler)
    ..get('/api/place-photo', _placePhotoProxyHandler)
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
        return successBody(message: '已取得餐廳候選', data: {'places': suggestions});
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
        final scope = req.url.queryParameters['scope']?.trim().toLowerCase();
        if (scope == 'places') {
          return jsonResponse(200, {
            'places': data.places.map((p) => p.toJson()).toList(),
          });
        }
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
          successBody(message: '已合併匯入 db.json 到資料庫', data: {'count': count}),
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
      '/api/admin/training/status',
      (req) => _withAdmin(req, () async {
        final snapshot = await _buildTrainingSnapshot();
        return jsonResponse(
          200,
          successBody(message: '已取得模型訓練資料狀態', data: snapshot),
        );
      }),
    )
    ..get(
      '/api/admin/training/agency-raw',
      (req) => _withAdmin(req, () async {
        final raw = await _readJsonMapFileIfExists(
          'agency_itineraries_raw.json',
        );
        final text = raw == null
            ? ''
            : const JsonEncoder.withIndent('  ').convert(raw);
        return jsonResponse(
          200,
          successBody(message: '已取得旅行社原始行程資料', data: {'text': text}),
        );
      }),
    )
    ..put(
      '/api/admin/training/agency-raw',
      (req) => _withAdmin(req, () async {
        final body = await parseJsonBody(req);
        final rawText = body['text']?.toString();
        dynamic decoded;
        if (rawText != null) {
          decoded = jsonDecode(rawText);
        } else {
          decoded = body['data'];
        }
        if (decoded is! Map) {
          throw ApiException(400, '旅行社原始行程 JSON 格式錯誤');
        }
        final payload = Map<String, dynamic>.from(decoded);
        final sources = payload['sources'];
        if (sources is! List) {
          throw ApiException(400, 'agency_itineraries_raw.json 缺少 sources 陣列');
        }
        await _writePrettyJsonFile('agency_itineraries_raw.json', payload);
        return jsonResponse(
          200,
          successBody(
            message: '已儲存旅行社原始行程資料',
            data: {'sourceCount': sources.length},
          ),
        );
      }),
    )
    ..post(
      '/api/admin/training/fetch-agency-url',
      (req) => _withAdmin(req, () async {
        final body = await parseJsonBody(req);
        final rawUrl = body['url']?.toString().trim() ?? '';
        if (rawUrl.isEmpty) {
          throw ApiException(400, '缺少旅行社行程網址');
        }
        final preview = await _buildAgencyTrainingPreviewFromUrl(rawUrl);
        return jsonResponse(
          200,
          successBody(message: '已抓取旅行社行程預覽', data: preview),
        );
      }),
    )
    ..get(
      '/api/admin/training/imported',
      (req) => _withAdmin(req, () async {
        final imported = await _requireJsonMapFile(
          'historical_itineraries.imported.json',
        );
        return jsonResponse(
          200,
          successBody(message: '已取得匯入後訓練樣本', data: imported),
        );
      }),
    )
    ..get(
      '/api/admin/training/match-report',
      (req) => _withAdmin(req, () async {
        final report = await _requireJsonMapFile(
          'agency_itinerary_match_report.json',
        );
        return jsonResponse(
          200,
          successBody(message: '已取得景點匹配報表', data: report),
        );
      }),
    )
    ..get(
      '/api/admin/training/match-overrides',
      (req) => _withAdmin(req, () async {
        final overrides =
            await _readJsonMapFileIfExists(
              'agency_itinerary_match_overrides.json',
            ) ??
            const <String, dynamic>{'overrides': <String, dynamic>{}};
        return jsonResponse(
          200,
          successBody(message: '已取得景點匹配修正規則', data: overrides),
        );
      }),
    )
    ..post(
      '/api/admin/training/match-overrides',
      (req) => _withAdmin(req, () async {
        final body = await parseJsonBody(req);
        final key = body['key']?.toString().trim() ?? '';
        final action = body['action']?.toString().trim().toLowerCase() ?? '';
        if (key.isEmpty) {
          throw ApiException(400, '缺少匹配修正 key');
        }
        if (!{'map', 'ignore', 'clear'}.contains(action)) {
          throw ApiException(400, 'action 必須為 map / ignore / clear');
        }
        final payload =
            await _readJsonMapFileIfExists(
              'agency_itinerary_match_overrides.json',
            ) ??
            <String, dynamic>{'overrides': <String, dynamic>{}};
        final rawOverrides = payload['overrides'];
        final overrides = rawOverrides is Map<String, dynamic>
            ? Map<String, dynamic>.from(rawOverrides)
            : rawOverrides is Map
            ? Map<String, dynamic>.from(rawOverrides)
            : <String, dynamic>{};
        if (action == 'clear') {
          overrides.remove(key);
        } else {
          final entry = <String, dynamic>{
            'action': action,
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
          };
          if (action == 'map') {
            final placeId = body['placeId']?.toString().trim() ?? '';
            if (placeId.isEmpty) {
              throw ApiException(400, 'map action 缺少 placeId');
            }
            entry['placeId'] = placeId;
            final placeName = body['placeName']?.toString().trim();
            if (placeName != null && placeName.isNotEmpty) {
              entry['placeName'] = placeName;
            }
          }
          overrides[key] = entry;
        }
        final next = <String, dynamic>{'overrides': overrides};
        await _writePrettyJsonFile(
          'agency_itinerary_match_overrides.json',
          next,
        );
        return jsonResponse(
          200,
          successBody(message: '已更新景點匹配修正規則', data: next),
        );
      }),
    )
    ..post(
      '/api/admin/training/import-google-place',
      (req) => _withAdmin(req, () async {
        final body = await parseJsonBody(req);
        final url = body['url']?.toString().trim() ?? '';
        final nameHint = body['name']?.toString().trim() ?? '';
        final cityHint = body['city']?.toString().trim() ?? '';
        if (url.isEmpty) {
          throw ApiException(400, '缺少 Google Maps 網址');
        }
        Place place;
        try {
          place = await _importPlaceFromGoogleMapsUrl(
            store: store,
            url: url,
            nameHint: nameHint,
            cityHint: cityHint,
          );
        } catch (error, stack) {
          _log.warning(
            'Google Maps 補景點失敗: url=$url, nameHint=$nameHint, cityHint=$cityHint, error=$error',
            error,
            stack,
          );
          rethrow;
        }
        return jsonResponse(
          200,
          successBody(
            message: '已從 Google Maps 補入景點資料',
            data: {'place': _placeToApiJson(place)},
          ),
        );
      }),
    )
    ..get(
      '/api/admin/training/weights',
      (req) => _withAdmin(req, () async {
        final weights = await _requireJsonMapFile(
          'itinerary_ranker_weights.json',
        );
        return jsonResponse(
          200,
          successBody(message: '已取得行程排序模型權重', data: weights),
        );
      }),
    )
    ..post(
      '/api/admin/training/import-agency',
      (req) => _withAdmin(req, () async {
        final placesPath = await _writeTrainingPlacesSnapshot();
        final result = await _runPythonTrainingScript(
          'import_agency_itineraries.py',
          environment: {
            'PLACES_SOURCE': 'local',
            'PLACES_DB_PATH': placesPath,
            'MATCH_OVERRIDE_PATH': _trainingDataPath(
              'agency_itinerary_match_overrides.json',
            ),
          },
        );
        if (result['ok'] == true) {
          await _persistTrainingArtifactsFromFiles(const [
            'historical_itineraries.imported.json',
            'agency_itinerary_match_report.json',
          ]);
        }
        final snapshot = await _buildTrainingSnapshot();
        return jsonResponse(
          200,
          successBody(
            message: result['ok'] == true ? '已完成旅行社行程匯入轉換' : '旅行社行程匯入失敗',
            data: {'run': result, 'snapshot': snapshot},
          ),
        );
      }),
    )
    ..post(
      '/api/admin/training/promote-imported',
      (req) => _withAdmin(req, () async {
        final result = await _promoteImportedHistoricalSamples();
        final summary = _summarizeTrainingFile(
          'historical_itineraries.json',
          data: await _readJsonMapFileIfExists('historical_itineraries.json'),
        );
        return jsonResponse(
          200,
          successBody(
            message: '已將匯入樣本併入正式訓練檔',
            data: {...result, 'historical': summary},
          ),
        );
      }),
    )
    ..post(
      '/api/admin/training/train-ranker',
      (req) => _withAdmin(req, () async {
        final placesPath = await _writeTrainingPlacesSnapshot();
        final result = await _runPythonTrainingScript(
          'train_itinerary_ranker.py',
          environment: {'PLACES_DB_PATH': placesPath},
        );
        if (result['ok'] == true) {
          await _persistTrainingArtifactsFromFiles(const [
            'itinerary_ranker_weights.json',
          ]);
          final weights = await _requireJsonMapFile(
            'itinerary_ranker_weights.json',
          );
          await _appendWeightVersion(weights);
          _reloadItineraryLearningProfile();
        }
        final snapshot = await _buildTrainingSnapshot();
        return jsonResponse(
          200,
          successBody(
            message: result['ok'] == true ? '已完成行程排序模型訓練' : '行程排序模型訓練失敗',
            data: {'run': result, 'snapshot': snapshot},
          ),
        );
      }),
    )
    ..post(
      '/api/admin/training/activate-weight-version',
      (req) => _withAdmin(req, () async {
        final body = await parseJsonBody(req);
        final versionId = body['versionId']?.toString().trim() ?? '';
        if (versionId.isEmpty) {
          throw ApiException(400, '缺少 versionId');
        }
        final activated = await _activateWeightVersion(versionId);
        _reloadItineraryLearningProfile();
        final snapshot = await _buildTrainingSnapshot();
        return jsonResponse(
          200,
          successBody(
            message: '已切換模型版本',
            data: {'activated': activated, 'snapshot': snapshot},
          ),
        );
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
    ..get(
      '/api/admin/plan-reviews',
      (req) => _withAdmin(req, () async {
        final reviews = await _readFormalPlanReviews();
        return jsonResponse(
          200,
          successBody(
            message: '已取得正式行程評審紀錄',
            data: {
              'reviews': reviews,
              'pendingCount': reviews
                  .where((review) => review['score'] == null)
                  .length,
              'reviewedCount': reviews
                  .where((review) => review['score'] != null)
                  .length,
            },
          ),
        );
      }),
    )
    ..put(
      '/api/admin/plan-reviews/<id>',
      (req, String id) => _withAdmin(req, () async {
        final body = await parseJsonBody(req);
        final score = _asInt(body, 'score');
        final notes = body['notes']?.toString().trim() ?? '';
        if (score == null || score < 1 || score > 5) {
          throw ApiException(400, '評分必須介於 1 到 5');
        }
        final reviews = await _readFormalPlanReviews();
        final index = reviews.indexWhere((review) => review['id'] == id);
        if (index < 0) {
          throw ApiException(404, '找不到正式行程評審紀錄');
        }
        reviews[index] = {
          ...reviews[index],
          'score': score,
          'notes': notes,
          'status': 'reviewed',
          'reviewedAt': DateTime.now().toUtc().toIso8601String(),
        };
        await _writeFormalPlanReviews(reviews);
        return jsonResponse(
          200,
          successBody(message: '已儲存行程評分', data: reviews[index]),
        );
      }),
    )
    ..post(
      '/api/admin/reminders/run-now',
      (req) => _withAdmin(req, () async {
        final result = await _runTrackedUpcomingReminderScan(
          triggerSource: 'admin',
        );
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
              'activePlanUpdatedAt': user.activePlanUpdatedAt
                  ?.toIso8601String(),
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
        final crawlProfile = _asString(
          body,
          'crawlProfile',
        ).trim().toLowerCase();
        if (_crawlJob != null && _crawlJob!.running) {
          throw ApiException(409, '已有爬取進行中');
        }
        final script = _crawlScriptForMode(mode);
        if (_crawlModeNeedsGoogleKey(mode)) {
          final googleKey = _googleMapsServerKey();
          if (googleKey.isEmpty) {
            throw ApiException(400, '需要設定 GOOGLE_PLACES_SERVER_API_KEY 或 GOOGLE_MAPS_API_KEY');
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
        final code = existing.isNotEmpty
            ? existing.first
            : _issueLineLinkCode(user.id);
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
        final requirementsText = body['requirementsText']?.toString().trim();
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
          requirementsText:
              (requirementsText == null || requirementsText.isEmpty)
              ? null
              : requirementsText,
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
        return successBody(message: '行程已生成', data: plan);
      }),
    )
    ..post(
      '/api/travel/planner-chat',
      (req) => _json(req, (body) async {
        final conversationId = _asString(body, 'conversationId').trim();
        final userId = _asString(body, 'userId').trim();
        final userMessage = _asString(body, 'userMessage').trim();
        final startDate = _parseDate(body['startDate']?.toString());
        final endDate = _parseDate(body['endDate']?.toString());
        final originCity = _asString(body, 'originCity').trim();
        final destinationCities =
            (body['destinationCities'] as List?)
                ?.map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
                .toList() ??
            const <String>[];
        final requirementsText = body['requirementsText']?.toString().trim();
        if (originCity.isEmpty || destinationCities.isEmpty) {
          throw ApiException(400, '缺少對話規劃所需的地點條件');
        }
        if (userMessage.isEmpty) {
          throw ApiException(400, '缺少對話內容');
        }

        _prunePlannerChatSessions();
        final session = _resolvePlannerChatSession(
          conversationId: conversationId,
          userId: userId.isEmpty ? null : userId,
          startDate: startDate,
          endDate: endDate,
          originCity: originCity,
          destinationCities: destinationCities,
          requirementsText: requirementsText,
        );
        final result = await _buildPlannerChatTurn(
          session: session,
          userMessage: userMessage,
        );
        return successBody(message: '對話回應已生成', data: result);
      }),
    )
    ..post(
      '/api/travel/confirm-plan',
      (req) => _json(req, (body) async {
        final userId = _asString(body, 'userId').trim();
        final source = _asString(body, 'source').trim();
        final rawPlan = body['plan'];
        if (rawPlan is! Map) {
          throw ApiException(400, '缺少行程資料');
        }
        final plan = Map<String, dynamic>.from(rawPlan);
        User? syncedUser;
        if (userId.isNotEmpty) {
          syncedUser = await _syncUserActivePlan(userId: userId, plan: plan);
        }
        Map<String, dynamic>? reviewRecord;
        try {
          reviewRecord = await _recordFormalPlanForReview(
            userId: userId,
            username: syncedUser?.username,
            plan: plan,
          );
        } catch (error, stack) {
          _log.warning(
            '正式行程已同步，但管理員評分紀錄寫入失敗：user=$userId error=$error',
            error,
            stack,
          );
        }
        var lineNotificationSent = false;
        if (userId.isNotEmpty && source == 'formal_itinerary_page') {
          try {
            await _sendLineItineraryGeneratedNotification(
              userId: userId,
              plan: plan,
            );
            lineNotificationSent = true;
          } catch (error, stack) {
            _log.warning(
              '正式行程已同步，但 LINE 行程建立通知發送失敗：user=$userId error=$error',
              error,
              stack,
            );
          }
        } else if (userId.isNotEmpty) {
          _log.info('略過 LINE 行程推播：確認來源不是正式行程頁 source=$source');
        }
        return successBody(
          message: '正式行程已確認',
          data: {
            'confirmed': true,
            'reviewRecorded': reviewRecord != null,
            'reviewRecordId': reviewRecord?['id'],
            'lineNotificationSent': lineNotificationSent,
            'activePlanUpdatedAt': syncedUser?.activePlanUpdatedAt
                ?.toIso8601String(),
          },
        );
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
        final updatedUser = await _syncUserActivePlan(
          userId: userId,
          plan: plan,
        );
        return successBody(
          message: '已同步目前行程到雲端提醒',
          data: {
            'activePlanSynced': true,
            'activePlanUpdatedAt': updatedUser.activePlanUpdatedAt
                ?.toIso8601String(),
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
        final result = await _runTrackedUpcomingReminderScan(
          triggerSource: 'cron',
        );
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
  // `\w` is ASCII-oriented in Dart. Using `\W` here removed Chinese text and
  // caused Chinese keyword checks to match an empty string.
  return input.toLowerCase().replaceAll(
    RegExp(r'[\s_，,。．·\-~～、：:；;（）()【】\[\]{}「」『』！!？?]+', unicode: true),
    '',
  );
}

class _RequirementSignals {
  const _RequirementSignals({
    required this.preferredTags,
    required this.preferOutdoor,
    required this.preferIndoor,
    required this.preferPhotoSpots,
    required this.preferShortDistance,
    required this.preferLowWalking,
    required this.preferFamilyFriendly,
    required this.preferFood,
    required this.preferRelaxedPacing,
    required this.preferNightMarket,
    required this.nightMarketDayIndex,
    required this.requirementKeywords,
  });

  final Set<String> preferredTags;
  final bool preferOutdoor;
  final bool preferIndoor;
  final bool preferPhotoSpots;
  final bool preferShortDistance;
  final bool preferLowWalking;
  final bool preferFamilyFriendly;
  final bool preferFood;
  final bool preferRelaxedPacing;
  final bool preferNightMarket;
  final int? nightMarketDayIndex;
  final List<String> requirementKeywords;

  bool get isEmpty =>
      preferredTags.isEmpty &&
      !preferOutdoor &&
      !preferIndoor &&
      !preferPhotoSpots &&
      !preferShortDistance &&
      !preferLowWalking &&
      !preferFamilyFriendly &&
      !preferFood &&
      !preferRelaxedPacing &&
      !preferNightMarket &&
      requirementKeywords.isEmpty;

  String get summary {
    final parts = <String>[];
    if (preferredTags.isNotEmpty) {
      parts.add('偏好標籤：${preferredTags.join('、')}');
    }
    if (preferOutdoor) parts.add('偏好戶外');
    if (preferIndoor) parts.add('偏好室內與逛街');
    if (preferPhotoSpots) parts.add('偏好拍照打卡');
    if (preferShortDistance) parts.add('希望點距離短');
    if (preferLowWalking) parts.add('希望步行負擔低');
    if (preferFamilyFriendly) parts.add('偏好親子家庭節奏');
    if (preferFood) parts.add('偏好用餐/小吃');
    if (preferRelaxedPacing) parts.add('偏好慢節奏');
    if (preferNightMarket) {
      parts.add(
        nightMarketDayIndex == null
            ? '希望安排晚間夜市'
            : '指定第 ${nightMarketDayIndex! + 1} 天晚上安排夜市',
      );
    }
    return parts.join('；');
  }

  Map<String, dynamic> toJson() => {
    'preferredTags': preferredTags.toList(),
    'preferOutdoor': preferOutdoor,
    'preferIndoor': preferIndoor,
    'preferPhotoSpots': preferPhotoSpots,
    'preferShortDistance': preferShortDistance,
    'preferLowWalking': preferLowWalking,
    'preferFamilyFriendly': preferFamilyFriendly,
    'preferFood': preferFood,
    'preferRelaxedPacing': preferRelaxedPacing,
    'preferNightMarket': preferNightMarket,
    'nightMarketDayIndex': nightMarketDayIndex,
    'requirementKeywords': requirementKeywords,
  };
}

_RequirementSignals _extractRequirementSignals(String? requirementsText) {
  final raw = requirementsText?.trim() ?? '';
  if (raw.isEmpty) {
    return const _RequirementSignals(
      preferredTags: <String>{},
      preferOutdoor: false,
      preferIndoor: false,
      preferPhotoSpots: false,
      preferShortDistance: false,
      preferLowWalking: false,
      preferFamilyFriendly: false,
      preferFood: false,
      preferRelaxedPacing: false,
      preferNightMarket: false,
      nightMarketDayIndex: null,
      requirementKeywords: <String>[],
    );
  }
  final text = _normalizeText(raw);

  bool hasAny(List<String> needles) =>
      needles.any((needle) => text.contains(_normalizeText(needle)));

  final preferIndoor = hasAny([
    '室內',
    '百貨',
    '百貨公司',
    '商場',
    '購物中心',
    '逛街',
    '展覽',
    '不要戶外',
    '少一點戶外',
    '減少戶外',
    '不要曬太陽',
    '避雨',
    '吹冷氣',
  ]);
  final preferOutdoor =
      !preferIndoor &&
      hasAny(['戶外', '走走', '散步', '自然', '景觀', '山景', '海景', '湖景', '步道', '看風景']);
  final preferPhotoSpots = hasAny([
    '拍照',
    '打卡',
    '網美',
    '美景',
    '取景',
    '拍美照',
    '打卡景點',
  ]);
  final preferShortDistance = hasAny([
    '不要太遠',
    '不要跑太遠',
    '距離不要太遠',
    '近一點',
    '順路',
    '沿途',
    '不要跨太多',
    '不要拉車',
    '少拉車',
    '不要開太久',
  ]);
  final preferLowWalking = hasAny([
    '不要走太多',
    '少走路',
    '不要太累',
    '輕鬆',
    '休閒',
    '長輩',
    '爸媽',
  ]);
  final preferFamilyFriendly = hasAny([
    '家庭',
    '親子',
    '小朋友',
    '小孩',
    '小朋友',
    '爸媽',
    '全家',
  ]);
  final preferFood = hasAny(['小吃', '美食', '餐廳', '下午茶', '咖啡', '吃飯', '在地吃']);
  final preferRelaxedPacing = hasAny(['不要太趕', '悠閒', '慢慢', '輕鬆', '放鬆', '慢遊']);
  final preferNightMarket = hasAny(['夜市', '晚上逛夜市', '晚上去夜市', '晚間夜市']);
  final nightMarketDayIndex = preferNightMarket
      ? _extractRequestedNightMarketDayIndex(raw)
      : null;

  final preferredTags = <String>{};
  if (preferOutdoor) {
    preferredTags.addAll(const ['national_park', 'lake_river', 'bike']);
  }
  if (preferIndoor) {
    preferredTags.addAll(const [
      'department_store',
      'museum',
      'creative_park',
      'handcraft_shop',
      'cafe',
    ]);
  }
  if (preferPhotoSpots) {
    preferredTags.addAll(const [
      'heritage',
      'national_park',
      'lake_river',
      'creative_park',
      'cafe',
    ]);
  }
  if (preferFamilyFriendly) {
    preferredTags.addAll(const ['creative_park', 'zoo']);
  }
  if (preferFood) {
    preferredTags.addAll(const ['restaurant', 'street_food', 'night_market']);
  }
  if (hasAny(['溫泉', '泡湯'])) {
    preferredTags.add('hot_spring');
  }
  if (hasAny(['老街', '古蹟', '教堂', '文物', '文化'])) {
    preferredTags.add('heritage');
  }

  final keywords = <String>{
    if (preferPhotoSpots) ...const ['景觀台', '花', '湖', '老街', '彩繪', '文創', '觀景'],
    if (preferOutdoor) ...const ['步道', '農場', '公園', '森林', '濕地', '海', '湖'],
    if (preferIndoor) ...const ['百貨', '商場', '博物館', '美術館', '展覽', '室內'],
    if (preferFood) ...const ['夜市', '老街', '小吃', '餐廳', '咖啡'],
    if (preferNightMarket) ...const ['夜市', '晚間', '商圈'],
  }.toList();

  return _RequirementSignals(
    preferredTags: preferredTags,
    preferOutdoor: preferOutdoor,
    preferIndoor: preferIndoor,
    preferPhotoSpots: preferPhotoSpots,
    preferShortDistance: preferShortDistance,
    preferLowWalking: preferLowWalking,
    preferFamilyFriendly: preferFamilyFriendly,
    preferFood: preferFood,
    preferRelaxedPacing: preferRelaxedPacing,
    preferNightMarket: preferNightMarket,
    nightMarketDayIndex: nightMarketDayIndex,
    requirementKeywords: keywords,
  );
}

int? _extractRequestedNightMarketDayIndex(String raw) {
  final text = _normalizeText(raw);
  const chineseDays = <String, int>{
    '第一天': 0,
    '第二天': 1,
    '第三天': 2,
    '第四天': 3,
    '第五天': 4,
    '第六天': 5,
    '第七天': 6,
  };
  for (final entry in chineseDays.entries) {
    if (text.contains(_normalizeText(entry.key))) {
      return entry.value;
    }
  }
  final match = RegExp(r'第(\d+)天').firstMatch(text);
  final dayNumber = int.tryParse(match?.group(1) ?? '');
  return dayNumber == null || dayNumber < 1 ? null : dayNumber - 1;
}

const Map<String, String> _trainingArtifactStateKeys = {
  'agency_itineraries_raw.json': 'training.agencyRaw',
  'historical_itineraries.imported.json': 'training.imported',
  'historical_itineraries.json': 'training.historical',
  'agency_itinerary_match_report.json': 'training.matchReport',
  'agency_itinerary_match_overrides.json': 'training.matchOverrides',
  'itinerary_ranker_weights.json': 'training.weights',
};

const String _trainingWeightVersionsStateKey = 'training.weightVersions';
const String _formalPlanReviewsStateKey = 'quality.formalPlanReviews';
const String _lineReminderSignaturesStateKey =
    'notifications.lineReminderSignatures';
const String _lineReminderPlansStateKey = 'notifications.lineReminderPlans';

String _trainingDataPath(String filename) => p.join(_dataDir, filename);

Future<Map<String, dynamic>> _readAppState() => _store.readAppState();

Future<void> _writeAppState(Map<String, dynamic> state) =>
    _store.writeAppState(state);

void _reloadItineraryLearningProfile() {
  _itineraryLearningProfile = _ItineraryLearningProfile.load(_dataDir);
}

Future<Map<String, dynamic>?> _readJsonMapFileIfExists(String filename) async {
  final stateKey = _trainingArtifactStateKeys[filename];
  if (stateKey != null) {
    final appState = await _readAppState();
    final stored = appState[stateKey];
    if (stored is Map<String, dynamic>) {
      return Map<String, dynamic>.from(stored);
    }
    if (stored is Map) {
      return Map<String, dynamic>.from(stored);
    }
  }
  final file = File(_trainingDataPath(filename));
  if (!await file.exists()) {
    return null;
  }
  final raw = jsonDecode(await file.readAsString());
  if (raw is! Map) {
    throw ApiException(500, '$filename 格式錯誤');
  }
  return Map<String, dynamic>.from(raw);
}

Future<Map<String, dynamic>> _requireJsonMapFile(String filename) async {
  final data = await _readJsonMapFileIfExists(filename);
  if (data == null) {
    throw ApiException(404, '找不到 $filename');
  }
  return data;
}

Future<void> _writePrettyJsonFile(String filename, Object data) async {
  final stateKey = _trainingArtifactStateKeys[filename];
  if (stateKey != null && data is Map<String, dynamic>) {
    final appState = await _readAppState();
    appState[stateKey] = Map<String, dynamic>.from(data);
    await _writeAppState(appState);
  }
  final file = File(_trainingDataPath(filename));
  await file.parent.create(recursive: true);
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(data),
    flush: true,
  );
}

Future<void> _mirrorTrainingArtifactsToFiles() async {
  for (final filename in _trainingArtifactStateKeys.keys) {
    final data = await _readJsonMapFileIfExists(filename);
    if (data == null) continue;
    final file = File(_trainingDataPath(filename));
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );
  }
}

Future<void> _persistTrainingArtifactsFromFiles(
  Iterable<String> filenames,
) async {
  final appState = await _readAppState();
  var changed = false;
  for (final filename in filenames) {
    final stateKey = _trainingArtifactStateKeys[filename];
    if (stateKey == null) continue;
    final file = File(_trainingDataPath(filename));
    if (!await file.exists()) continue;
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map) continue;
    appState[stateKey] = Map<String, dynamic>.from(raw);
    changed = true;
  }
  if (changed) {
    await _writeAppState(appState);
  }
}

Future<Map<String, dynamic>> _readTrainingWeightVersions() async {
  final appState = await _readAppState();
  final raw = appState[_trainingWeightVersionsStateKey];
  if (raw is Map<String, dynamic>) {
    return Map<String, dynamic>.from(raw);
  }
  if (raw is Map) {
    return Map<String, dynamic>.from(raw);
  }
  return <String, dynamic>{'activeVersionId': null, 'versions': <dynamic>[]};
}

Future<void> _writeTrainingWeightVersions(Map<String, dynamic> payload) async {
  final appState = await _readAppState();
  appState[_trainingWeightVersionsStateKey] = payload;
  await _writeAppState(appState);
}

Future<List<Map<String, dynamic>>> _readFormalPlanReviews() async {
  final appState = await _readAppState();
  final raw = appState[_formalPlanReviewsStateKey];
  if (raw is! List) return <Map<String, dynamic>>[];
  return raw
      .whereType<Map>()
      .map((entry) => Map<String, dynamic>.from(entry))
      .toList();
}

Future<void> _writeFormalPlanReviews(List<Map<String, dynamic>> reviews) async {
  final appState = await _readAppState();
  appState[_formalPlanReviewsStateKey] = reviews;
  await _writeAppState(appState);
}

List<String> _planDateKeys(Map<String, dynamic> plan) {
  final rawDays = plan['days'];
  if (rawDays is! List) return const <String>[];
  final dates = <String>{};
  for (final rawDay in rawDays) {
    if (rawDay is! Map) continue;
    final dateKey = _reminderDayDateKey(Map<String, dynamic>.from(rawDay));
    if (dateKey != null && dateKey.isNotEmpty) {
      dates.add(dateKey);
    }
  }
  final sorted = dates.toList()..sort();
  return sorted;
}

bool _reminderPlanIsRelevant(List<String> dateKeys, DateTime now) {
  if (dateKeys.isEmpty) return false;
  final today = DateTime(now.year, now.month, now.day);
  final cutoff = today.subtract(const Duration(days: 2));
  for (final dateKey in dateKeys) {
    final parsed = DateTime.tryParse(dateKey);
    if (parsed == null) continue;
    final date = DateTime(parsed.year, parsed.month, parsed.day);
    if (!date.isBefore(cutoff)) {
      return true;
    }
  }
  return false;
}

String _lineReminderPlanKey(String userId, Map<String, dynamic> plan) {
  final dates = _planDateKeys(plan).join(',');
  final cities =
      (plan['destinationCities'] as List?)
          ?.map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .join(',') ??
      '';
  final title = plan['title']?.toString().trim() ?? '';
  return '$userId|$dates|$cities|$title';
}

Future<List<Map<String, dynamic>>> _readLineReminderPlanRecords() async {
  final appState = await _readAppState();
  final raw = appState[_lineReminderPlansStateKey];
  if (raw is! List) return <Map<String, dynamic>>[];
  final now = _taipeiNow();
  final records = raw
      .whereType<Map>()
      .map((entry) => Map<String, dynamic>.from(entry))
      .where((entry) {
        final dateKeys =
            (entry['planDates'] as List?)
                ?.map((item) => item.toString())
                .where((item) => item.isNotEmpty)
                .toList() ??
            const <String>[];
        return _reminderPlanIsRelevant(dateKeys, now);
      })
      .toList();
  if (records.length != raw.length) {
    appState[_lineReminderPlansStateKey] = records;
    await _writeAppState(appState);
  }
  return records;
}

Future<void> _writeLineReminderPlanRecords(
  List<Map<String, dynamic>> records,
) async {
  final appState = await _readAppState();
  appState[_lineReminderPlansStateKey] = records;
  await _writeAppState(appState);
}

Future<void> _rememberLineReminderPlan({
  required User user,
  required Map<String, dynamic> plan,
  required DateTime updatedAt,
}) async {
  final dateKeys = _planDateKeys(plan);
  if (!_reminderPlanIsRelevant(dateKeys, _taipeiNow())) return;
  final records = await _readLineReminderPlanRecords();
  final key = _lineReminderPlanKey(user.id, plan);
  records.removeWhere((entry) => entry['id']?.toString() == key);
  records.insert(0, {
    'id': key,
    'userId': user.id,
    'username': user.username,
    'planDates': dateKeys,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'plan': Map<String, dynamic>.from(plan),
  });
  if (records.length > 200) {
    records.removeRange(200, records.length);
  }
  await _writeLineReminderPlanRecords(records);
}

Future<Map<String, dynamic>> _recordFormalPlanForReview({
  required String userId,
  String? username,
  required Map<String, dynamic> plan,
}) async {
  final reviews = await _readFormalPlanReviews();
  final user = userId.isEmpty || username != null
      ? null
      : await _store.findUserById(userId);
  final now = DateTime.now().toUtc();
  final record = <String, dynamic>{
    'id': const Uuid().v4(),
    'userId': userId.isEmpty ? null : userId,
    'username': username ?? user?.username ?? '匿名使用者',
    'confirmedAt': now.toIso8601String(),
    'status': 'pending',
    'score': null,
    'notes': '',
    'reviewedAt': null,
    'plan': plan,
  };
  reviews.insert(0, record);
  if (reviews.length > 500) {
    reviews.removeRange(500, reviews.length);
  }
  await _writeFormalPlanReviews(reviews);
  return record;
}

Future<Map<String, double>> _loadFormalPlanReviewPlaceBoosts() async {
  final reviews = await _readFormalPlanReviews();
  final scoreSums = <String, double>{};
  final scoreCounts = <String, int>{};
  for (final review in reviews) {
    final score = (review['score'] as num?)?.toDouble();
    if (score == null || score < 1 || score > 5) continue;
    final plan = review['plan'];
    if (plan is! Map || plan['days'] is! List) continue;
    final centeredScore = score - 3.0;
    for (final day in (plan['days'] as List).whereType<Map>()) {
      final items = day['items'];
      if (items is! List) continue;
      for (final item in items.whereType<Map>()) {
        final place = item['place'];
        if (place is! Map) continue;
        final id = place['id']?.toString().trim() ?? '';
        if (id.isEmpty || id.startsWith('meal-')) continue;
        scoreSums.update(
          id,
          (value) => value + centeredScore,
          ifAbsent: () => centeredScore,
        );
        scoreCounts.update(id, (value) => value + 1, ifAbsent: () => 1);
      }
    }
  }
  return {
    for (final entry in scoreSums.entries)
      entry.key: ((entry.value / (scoreCounts[entry.key] ?? 1)) * 0.35).clamp(
        -0.7,
        0.7,
      ),
  };
}

Future<Map<String, dynamic>> _appendWeightVersion(
  Map<String, dynamic> weights,
) async {
  final payload = await _readTrainingWeightVersions();
  final rawVersions = payload['versions'];
  final versions = rawVersions is List
      ? rawVersions
            .whereType<Map>()
            .map((entry) => Map<String, dynamic>.from(entry))
            .toList()
      : <Map<String, dynamic>>[];
  final metadata = weights['metadata'] is Map
      ? Map<String, dynamic>.from(weights['metadata'] as Map)
      : const <String, dynamic>{};
  final generatedAt =
      weights['generatedAt']?.toString().trim().isNotEmpty == true
      ? weights['generatedAt'].toString()
      : DateTime.now().toUtc().toIso8601String();
  final versionId = const Uuid().v4();
  final version = <String, dynamic>{
    'id': versionId,
    'createdAt': DateTime.now().toUtc().toIso8601String(),
    'generatedAt': generatedAt,
    'label':
        'samples=${metadata['samplesUsed'] ?? 0} / stops=${metadata['stopsUsed'] ?? 0}',
    'metadata': metadata,
    'weights': Map<String, dynamic>.from(weights),
  };
  versions.insert(0, version);
  final next = <String, dynamic>{
    'activeVersionId': versionId,
    'versions': versions.take(20).toList(),
  };
  await _writeTrainingWeightVersions(next);
  return version;
}

Future<Map<String, dynamic>> _activateWeightVersion(String versionId) async {
  final payload = await _readTrainingWeightVersions();
  final rawVersions = payload['versions'];
  final versions = rawVersions is List
      ? rawVersions
            .whereType<Map>()
            .map((entry) => Map<String, dynamic>.from(entry))
            .toList()
      : <Map<String, dynamic>>[];
  Map<String, dynamic>? target;
  for (final version in versions) {
    if ((version['id'] ?? '').toString() == versionId) {
      target = version;
      break;
    }
  }
  if (target == null) {
    throw ApiException(404, '找不到指定模型版本');
  }
  final weights = target['weights'];
  if (weights is! Map) {
    throw ApiException(500, '模型版本缺少 weights 內容');
  }
  await _writePrettyJsonFile(
    'itinerary_ranker_weights.json',
    Map<String, dynamic>.from(weights),
  );
  payload['activeVersionId'] = versionId;
  await _writeTrainingWeightVersions(payload);
  return target;
}

Future<Map<String, dynamic>> _exportCurrentPlacesPayload() async {
  final data = await _store.read();
  return {'places': data.places.map((place) => place.toJson()).toList()};
}

const List<String> _agencySupportedCityNames = <String>[
  '臺北市',
  '台北市',
  '新北市',
  '基隆市',
  '桃園市',
  '新竹市',
  '新竹縣',
  '苗栗縣',
  '臺中市',
  '台中市',
  '彰化縣',
  '南投縣',
  '雲林縣',
  '嘉義市',
  '嘉義縣',
  '臺南市',
  '台南市',
  '高雄市',
  '屏東縣',
  '宜蘭縣',
  '花蓮縣',
  '臺東縣',
  '台東縣',
  '澎湖縣',
  '金門縣',
  '連江縣',
];

final RegExp _agencyDayHeaderRegex = RegExp(
  r'^第\s*(\d+)\s*天[:：\s]*(.*)$',
  caseSensitive: false,
);
final RegExp _agencyTimeRangeRegex = RegExp(
  r'^[\s●•■◆◎○※]*'
  r'(\d{1,2}:\d{2})\s*[~～\-－]\s*(\d{1,2}:\d{2})(.*)$',
);
final RegExp _agencyTitleRegex = RegExp(
  r"""class\s*=\s*["']t6["'][^>]*>([^<]+)<""",
  caseSensitive: false,
);
final RegExp _agencyHtmlTagRegex = RegExp(r'<[^>]+>', multiLine: true);
final RegExp _agencyCityRegex = RegExp(
  '(${_agencySupportedCityNames.map(RegExp.escape).join('|')})',
);
final RegExp _agencyFooterStartRegex = RegExp(
  r'^(夜\s*宿|餐\s*食|備\s*註|附\s*註|費\s*用|特別說明|共同分攤|'
  r'活動當日|所列時間僅供參考|資料尚在處理中|正確報價|'
  r'樂在其中旅行社提供請款單|旅遊活動當中|【建議您|肖像權拍攝與使用告知|'
  r'簽訂契約後|收訂之後|如團員不同意)',
  caseSensitive: false,
);

Future<Map<String, dynamic>> _buildAgencyTrainingPreviewFromUrl(
  String rawUrl,
) async {
  final normalized = rawUrl.trim();
  final uri = Uri.tryParse(normalized);
  if (uri == null || !uri.hasScheme || uri.host.trim().isEmpty) {
    throw ApiException(400, '旅行社網址格式錯誤');
  }

  final html = await _fetchAgencyTrainingHtml(uri);
  final preview = _parseAgencyTrainingPreview(uri, html);
  if ((preview['source'] as Map?)?['days'] is! List ||
      ((preview['source'] as Map)['days'] as List).isEmpty) {
    throw ApiException(422, '找不到可解析的每日行程內容');
  }
  return preview;
}

Future<String> _fetchAgencyTrainingHtml(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(uri);
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/126.0 Safari/537.36 SmartTravelBot/1.0',
    );
    request.headers.set(HttpHeaders.acceptHeader, 'text/html,*/*');
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.isRedirect || response.redirects.isNotEmpty) {
      final location = response.headers
          .value(HttpHeaders.locationHeader)
          ?.trim();
      if (location != null && location.isNotEmpty) {
        return _fetchAgencyTrainingHtml(uri.resolve(location));
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(502, '抓取旅行社網址失敗：HTTP ${response.statusCode}');
    }
    final bytes = await response.fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    return utf8.decode(bytes, allowMalformed: true);
  } on TimeoutException {
    throw ApiException(504, '抓取旅行社網址逾時');
  } on SocketException {
    throw ApiException(502, '無法連線到旅行社網站');
  } finally {
    client.close(force: true);
  }
}

Map<String, dynamic> _parseAgencyTrainingPreview(Uri uri, String html) {
  final title = _extractAgencyTrainingTitle(html, uri);
  final lines = _extractAgencyTrainingLines(html);
  final sections = _extractAgencyTrainingDaySections(lines);
  if (sections.isEmpty) {
    throw ApiException(422, '頁面中找不到「第1天 / 第2天」格式的行程段落');
  }
  final warnings = <String>[];
  final baseDate = DateTime(DateTime.now().year, 1, 1);
  final days = <Map<String, dynamic>>[];
  final initialDestinationCities = _extractAgencyDestinationCities(
    [title, ...lines].join('\n'),
  );

  for (var index = 0; index < sections.length; index++) {
    final day = _parseAgencyTrainingDay(
      section: sections[index],
      fallbackCity: initialDestinationCities.length == 1
          ? initialDestinationCities.first
          : null,
      date: baseDate.add(Duration(days: index)),
      warnings: warnings,
    );
    days.add(day);
  }

  final allText = lines.join('\n');
  final normalizedDays = _postProcessAgencyTrainingDays(
    uri: uri,
    title: title,
    days: days,
    fullText: '$title\n$allText',
    warnings: warnings,
  );
  final normalizedText = [
    title,
    for (final day in normalizedDays) day['title']?.toString() ?? '',
    for (final day in normalizedDays)
      for (final item in ((day['items'] as List?) ?? const []))
        [
          item['name']?.toString() ?? '',
          item['notes']?.toString() ?? '',
          item['city']?.toString() ?? '',
        ].join('\n'),
  ].join('\n');
  final destinationCities = _deriveAgencyDestinationCitiesFromDays(
    normalizedDays,
    fallbackText: '$title\n$allText',
  );
  final interests = _inferAgencyInterestTags(normalizedText);
  final tripPurpose = _inferAgencyTripPurpose(normalizedText);
  final travelBehavior = _inferAgencyTravelBehavior(normalizedText);
  final targetPrice = _inferAgencyTargetPrice(normalizedText);

  final sourceId = _buildAgencyTrainingSourceId(uri, title);
  final source = <String, dynamic>{
    'id': sourceId,
    'title': title,
    'url': uri.toString(),
    'weight': 1.0,
    'context': <String, dynamic>{
      'interests': interests,
      'tripPurpose': tripPurpose,
      'travelBehavior': travelBehavior,
      'targetPrice': targetPrice,
      'destinationCities': destinationCities,
    },
    'days': normalizedDays,
  };
  final expandedSources = _expandAgencyTrainingSources(
    source,
    warnings: warnings,
  );
  final primarySource = expandedSources.isEmpty
      ? source
      : expandedSources.first;

  return <String, dynamic>{
    'host': uri.host,
    'url': uri.toString(),
    'supported': uri.host.toLowerCase().contains('welovetravel.com.tw'),
    'source': primarySource,
    'sources': expandedSources,
    'warnings': warnings,
    'summary': <String, dynamic>{
      'title': title,
      'dayCount':
          (primarySource['days'] as List?)?.length ?? normalizedDays.length,
      'itemCount': ((primarySource['days'] as List?) ?? const []).fold<int>(
        0,
        (sum, day) => sum + ((day['items'] as List?)?.length ?? 0),
      ),
      'destinationCities': destinationCities,
      'sourceCount': expandedSources.length,
    },
  };
}

String _extractAgencyTrainingTitle(String html, Uri uri) {
  final titleMatch = _agencyTitleRegex.firstMatch(html);
  if (titleMatch != null) {
    final title = _decodeAgencyHtmlEntities(titleMatch.group(1) ?? '').trim();
    if (title.isNotEmpty) {
      return title;
    }
  }
  final pageTitle = RegExp(
    r'<title[^>]*>([^<]+)</title>',
    caseSensitive: false,
  ).firstMatch(html);
  if (pageTitle != null) {
    final title = _decodeAgencyHtmlEntities(pageTitle.group(1) ?? '').trim();
    if (title.isNotEmpty) {
      return title;
    }
  }
  final queryCode = uri.queryParameters['c']?.trim();
  return queryCode == null || queryCode.isEmpty ? uri.host : queryCode;
}

List<String> _extractAgencyTrainingLines(String html) {
  var text = html;
  text = text.replaceAll(
    RegExp(r'<script[^>]*>.*?</script>', caseSensitive: false, dotAll: true),
    '\n',
  );
  text = text.replaceAll(
    RegExp(r'<style[^>]*>.*?</style>', caseSensitive: false, dotAll: true),
    '\n',
  );
  text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  text = text.replaceAll(
    RegExp(
      r'</(p|div|td|tr|li|h1|h2|h3|h4|h5|h6|table)>',
      caseSensitive: false,
    ),
    '\n',
  );
  text = text.replaceAll(_agencyHtmlTagRegex, ' ');
  text = _decodeAgencyHtmlEntities(text);
  return text
      .split(RegExp(r'[\r\n]+'))
      .map(
        (line) => line
            .replaceAll(RegExp(r'[\t\u00a0]+'), ' ')
            .replaceAll(RegExp(r'\s{2,}'), ' ')
            .trim(),
      )
      .where((line) => line.isNotEmpty)
      .toList();
}

String _decodeAgencyHtmlEntities(String input) {
  var text = input
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'");
  text = text.replaceAllMapped(RegExp(r'&#(\d+);'), (match) {
    final value = int.tryParse(match.group(1) ?? '');
    return value == null ? match.group(0)! : String.fromCharCode(value);
  });
  text = text.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (match) {
    final value = int.tryParse(match.group(1) ?? '', radix: 16);
    return value == null ? match.group(0)! : String.fromCharCode(value);
  });
  return text;
}

List<Map<String, dynamic>> _extractAgencyTrainingDaySections(
  List<String> lines,
) {
  final sections = <Map<String, dynamic>>[];
  Map<String, dynamic>? current;
  for (final line in lines) {
    final match = _agencyDayHeaderRegex.firstMatch(line);
    if (match != null) {
      if (current != null) {
        sections.add(current);
      }
      current = <String, dynamic>{
        'index': int.tryParse(match.group(1) ?? '') ?? sections.length + 1,
        'title': (match.group(2) ?? '').trim(),
        'lines': <String>[],
      };
      continue;
    }
    final currentLines = current?['lines'];
    if (currentLines is List<String>) {
      currentLines.add(line);
    }
  }
  if (current != null) {
    sections.add(current);
  }
  return sections;
}

Map<String, dynamic> _parseAgencyTrainingDay({
  required Map<String, dynamic> section,
  required DateTime date,
  required List<String> warnings,
  required String? fallbackCity,
}) {
  final lines =
      (section['lines'] as List?)?.whereType<String>().toList() ?? <String>[];
  final items = <Map<String, dynamic>>[];
  Map<String, dynamic>? pending;
  final pendingNotes = <String>[];
  var ignoreRemainder = false;

  void flushPending() {
    if (pending == null) return;
    if (pendingNotes.isNotEmpty) {
      pending!['notes'] = pendingNotes.join('\n');
      pendingNotes.clear();
    }
    items.add(pending!);
    pending = null;
  }

  for (final line in lines) {
    if (ignoreRemainder) {
      continue;
    }
    if (_shouldStopAgencyDayParsing(line)) {
      flushPending();
      ignoreRemainder = true;
      continue;
    }
    final timeMatch = _agencyTimeRangeRegex.firstMatch(line);
    if (timeMatch == null) {
      if (pending != null) {
        if (_shouldStopAgencyDayParsing(line)) {
          flushPending();
          ignoreRemainder = true;
          continue;
        }
        pendingNotes.add(line);
      }
      continue;
    }
    flushPending();
    final arrival = timeMatch.group(1)!.trim();
    final departure = timeMatch.group(2)!.trim();
    final remainder = (timeMatch.group(3) ?? '').trim();
    final itemText = _cleanupAgencyTimeLineText(remainder);
    if (itemText.isEmpty || _looksLikeAgencyNoise(itemText)) {
      continue;
    }
    final type = _classifyAgencyTrainingItemType(itemText);
    final name = _extractAgencyTrainingItemName(itemText, type);
    if (name.isEmpty) {
      warnings.add('第${section['index']}天有一筆時段無法判定名稱：$line');
    }
    final inferredCity = _extractAgencyDestinationCities(itemText).firstOrNull;
    pending = <String, dynamic>{
      'name': name.isEmpty ? itemText : name,
      'arrivalTime': arrival,
      'departureTime': departure,
      'type': type,
      if (inferredCity != null || fallbackCity != null)
        'city': inferredCity ?? fallbackCity,
    };
  }
  flushPending();

  if (items.isEmpty) {
    warnings.add('第${section['index']}天未解析出任何時段行程。');
  }

  return <String, dynamic>{
    'date':
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
    if (items.isNotEmpty) 'dayStartTime': items.first['arrivalTime'],
    if ((section['title']?.toString().trim().isNotEmpty ?? false))
      'title': section['title'].toString().trim(),
    'items': items,
  };
}

String _cleanupAgencyTimeLineText(String input) {
  return input
      .replaceAll(RegExp(r'^[•●■◆◎○※]+'), '')
      .replaceAll(RegExp(r'^[~～\-－/]+'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _classifyAgencyTrainingItemType(String text) {
  final normalized = text.toLowerCase();
  if (normalized.contains('返家') ||
      normalized.contains('賦歸') ||
      normalized.contains('回程') ||
      normalized.contains('返抵') ||
      normalized.contains('home')) {
    return 'arrival';
  }
  if (normalized.startsWith('集合') ||
      normalized.startsWith('出發') ||
      normalized.startsWith('退房') ||
      normalized.startsWith('早餐後出發') ||
      normalized.contains('上車出發')) {
    return 'departure';
  }
  if (normalized.contains('飯店') ||
      normalized.contains('旅店') ||
      normalized.contains('會館') ||
      normalized.contains('酒店') ||
      normalized.contains('check in') ||
      normalized.contains('入住') ||
      normalized.contains('下榻')) {
    return 'hotel';
  }
  if (normalized.contains('早餐') ||
      normalized.contains('午餐') ||
      normalized.contains('晚餐') ||
      normalized.contains('點心') ||
      normalized.contains('小吃') ||
      normalized.contains('餐點') ||
      normalized.contains('用餐')) {
    return 'meal';
  }
  if (normalized.startsWith('前往') ||
      normalized.startsWith('往') ||
      normalized.startsWith('經國道') ||
      normalized.startsWith('國道') ||
      normalized.startsWith('車程') ||
      normalized.startsWith('搭乘') ||
      normalized.startsWith('行車') ||
      normalized.contains('直行車程')) {
    return 'transport_note';
  }
  return 'place';
}

String _extractAgencyTrainingItemName(String text, String type) {
  final bracketMatch = RegExp(r'【([^】]+)】').firstMatch(text);
  if (bracketMatch != null) {
    final rawName = bracketMatch.group(1)?.trim() ?? '';
    final normalizedBracketName = _normalizeAgencyBracketName(rawName, type);
    if (normalizedBracketName.isNotEmpty) return normalizedBracketName;
  }
  final quoteMatch = RegExp(r'[「『](.+?)[」』]').firstMatch(text);
  if (quoteMatch != null) {
    final name = quoteMatch.group(1)?.trim() ?? '';
    if (name.isNotEmpty) return name;
  }

  final cleaned = text
      .replaceAll(RegExp(r'^(上午來到|下午來到|午後遊覽|安排|自由逛|造訪|前往|參觀|推薦[:：])'), '')
      .replaceAll(RegExp(r'※.*$'), '')
      .replaceAll(RegExp(r'[\(（].*$'), '')
      .replaceAll(RegExp(r'\{.*$'), '')
      .replaceAll(RegExp(r'[。．].*$'), '')
      .replaceAll(RegExp(r'[-－]\s*自由逛$'), '')
      .replaceAll(RegExp(r'自由逛$'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isNotEmpty) {
    if (type == 'hotel') {
      final hotelMatch = RegExp(
        r'(經典范特奇堡飯店|.+?(飯店|旅店|會館|酒店|溫泉會館|溫泉飯店))',
      ).firstMatch(cleaned);
      if (hotelMatch != null) {
        return hotelMatch.group(1)?.trim() ?? cleaned;
      }
    }
    return cleaned;
  }
  return text.trim();
}

String _normalizeAgencyBracketName(String rawName, String type) {
  var name = rawName
      .replaceAll(RegExp(r'^\s+|\s+$'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (name.isEmpty) return '';

  final segments = name
      .split(RegExp(r'[~～/]'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();

  if (segments.isNotEmpty) {
    if (type == 'meal') {
      final preferred = segments.lastWhere(
        (part) =>
            part.contains('餐廳') ||
            part.contains('小吃店') ||
            part.contains('食堂') ||
            part.contains('館') ||
            part.contains('午餐') ||
            part.contains('晚餐'),
        orElse: () => segments.last,
      );
      name = preferred;
    } else if (type == 'place') {
      name = segments.first;
    }
  }

  name = name
      .replaceAll(RegExp(r'^(鄉土風味桌餐|鄉土風味餐|午餐|晚餐|下午茶|早餐)\s*[-－~～:：]?\s*'), '')
      .replaceAll(RegExp(r'\{.*$'), '')
      .replaceAll(RegExp(r'[\(（].*$'), '')
      .trim();

  return name;
}

List<Map<String, dynamic>> _postProcessAgencyTrainingDays({
  required Uri uri,
  required String title,
  required List<Map<String, dynamic>> days,
  required String fullText,
  required List<String> warnings,
}) {
  if (!uri.host.toLowerCase().contains('welovetravel.com.tw')) {
    return days;
  }
  final processed = <Map<String, dynamic>>[];
  for (final day in days) {
    final rawItems =
        (day['items'] as List?)?.whereType<Map>().toList() ?? const [];
    final items = <Map<String, dynamic>>[];
    for (final rawItem in rawItems) {
      final item = Map<String, dynamic>.from(rawItem.cast<String, dynamic>());
      _normalizeWeloveTravelItem(
        item,
        dayTitle: day['title']?.toString() ?? '',
        fullText: fullText,
      );
      if (_shouldDropWeloveTravelItem(item)) {
        continue;
      }
      items.add(item);
    }
    _injectWeloveTravelOptionItems(items);
    _injectWeloveTravelDerivedItems(
      items,
      dayTitle: day['title']?.toString() ?? '',
      fullText: fullText,
      hasFollowingBreakfast:
          processed.isEmpty &&
          days.length > 1 &&
          (days[1]['title']?.toString().contains('早餐') ?? false),
    );
    _attachWeloveTravelBranchOptions(items);
    for (final item in items) {
      final resolvedCity = _guessAgencyCityForText(
        [
          title,
          day['title']?.toString() ?? '',
          item['name']?.toString() ?? '',
          item['notes']?.toString() ?? '',
        ].join('\n'),
      );
      if (resolvedCity != null) {
        item['city'] = resolvedCity;
      } else {
        item.remove('city');
      }
      item.remove('_rawNotes');
    }
    processed.add(<String, dynamic>{
      ...day,
      'items': items,
      if (items.isNotEmpty) 'dayStartTime': items.first['arrivalTime'],
    });
  }
  return processed;
}

void _normalizeWeloveTravelItem(
  Map<String, dynamic> item, {
  required String dayTitle,
  required String fullText,
}) {
  final originalName = item['name']?.toString().trim() ?? '';
  final notes = item['notes']?.toString().trim();
  final text = '$dayTitle\n$originalName\n${notes ?? ''}';
  final titleSegments = _extractWeloveTravelTitleSegments(dayTitle);
  var type = item['type']?.toString().trim() ?? 'place';
  var name = originalName;

  if (name.contains('退房')) {
    type = 'departure';
    name = '飯店退房出發';
  } else if (name.contains('集合後') ||
      name.contains('快樂出航') ||
      name.contains('上車出發')) {
    type = 'departure';
    name = '集合出發';
  } else if (name.contains('返回溫暖的家') ||
      name.contains('活動結束後') ||
      name.contains('快樂回程') ||
      name.contains('平安賦歸')) {
    type = 'arrival';
    name = '平安賦歸';
  } else if (name.contains('黃金小鎮')) {
    type = 'place';
    name = '黃金小鎮';
  } else if (name.contains('清安豆腐街')) {
    type = 'place';
    name = '清安豆腐街';
  } else if (name.contains('巧克力雲莊')) {
    type = 'place';
    name = '巧克力雲莊';
  } else if (name.contains('功維敘')) {
    type = 'place';
    name = '功維敘隧道';
  } else if (name.contains('清水地熱')) {
    type = 'place';
    name = '清水地熱谷';
  } else if (name.contains('彈珠汽水觀光工廠') || text.contains('彈珠汽水觀光工廠')) {
    type = 'place';
    name = '納姆內彈珠汽水觀光工廠';
  } else if (name.contains('北埔老街')) {
    type = 'place';
    name = '北埔老街';
  } else if (name.contains('下榻飯店') || text.contains('溫泉設施')) {
    type = 'hotel';
    if (text.contains('錦水溫泉') ||
        fullText.contains('錦水溫泉飯店') ||
        fullText.contains('苗栗泰安˙錦水溫泉飯店')) {
      name = '泰安溫泉錦水溫泉飯店';
    } else if (dayTitle.contains('享沐時光') || fullText.contains('享沐時光莊園')) {
      name = '享沐時光莊園';
    } else if (dayTitle.contains('泰安溫泉') || text.contains('泰安溫泉')) {
      name = '泰安溫泉飯店';
    } else {
      name = '下榻飯店';
    }
  } else if (name.contains('客家米食風味點心')) {
    type = 'meal';
    name = '客家米食風味點心';
  } else if (name.contains('晚餐')) {
    type = 'meal';
    name = '飯店晚餐';
  } else if (name.contains('早餐')) {
    type = 'meal';
    name = '飯店早餐';
  } else if (name.contains('往功')) {
    type = 'transport_note';
    name = '前往王功';
  } else if (name.contains('國道') ||
      name.contains('直行車程') ||
      name.contains('搭乘豪華遊覽車')) {
    type = 'transport_note';
  } else if (name.contains('九族文化村')) {
    type = 'place';
    name = '九族文化村主題遊樂園';
  }

  if (type == 'meal') {
    final normalizedMealName = _normalizeWeloveTravelMealName(
      name,
      notes: notes,
      dayTitle: dayTitle,
      titleSegments: titleSegments,
    );
    if (normalizedMealName.isNotEmpty) {
      name = normalizedMealName;
    }
  }

  item['type'] = type;
  item['name'] = name;
  if (type == 'hotel') {
    final departureTime = item['departureTime']?.toString().trim();
    if (departureTime != null && departureTime.isNotEmpty) {
      item['arrivalTime'] = departureTime;
      item.remove('departureTime');
    }
  } else if (type == 'departure' &&
      item['arrivalTime']?.toString() == item['departureTime']?.toString()) {
    item.remove('departureTime');
  } else if (type == 'arrival') {
    final departureTime = item['departureTime']?.toString().trim();
    if (departureTime != null && departureTime.isNotEmpty) {
      item['arrivalTime'] = departureTime;
    }
    item.remove('departureTime');
  }
  if (notes != null && notes.isNotEmpty) {
    item['_rawNotes'] = notes;
  }

  final compactNotes = _compactWeloveTravelNotes(
    name: name,
    type: type,
    notes: notes,
  );
  if (name == '清水地熱谷') {
    item['notes'] = '可泡腳、溫泉蛋體驗';
  } else if (compactNotes == null || compactNotes.isEmpty) {
    item.remove('notes');
  } else {
    item['notes'] = compactNotes;
  }
}

bool _shouldDropWeloveTravelItem(Map<String, dynamic> item) {
  final name = item['name']?.toString().trim() ?? '';
  final type = item['type']?.toString().trim() ?? '';
  if (name.isEmpty) return true;
  if (type == 'transport_note') return true;
  if (name.contains('今早集合後，搭乘豪華遊覽車快樂出航!') || name.contains('/按人事行政局規定之休假日')) {
    return true;
  }
  return false;
}

void _injectWeloveTravelOptionItems(List<Map<String, dynamic>> items) {
  final additions = <Map<String, dynamic>>[];
  for (final item in items) {
    final notes =
        item['_rawNotes']?.toString() ?? item['notes']?.toString() ?? '';
    if (notes.contains('選擇A：') &&
        notes.contains('彈珠汽水觀光工廠') &&
        !items.any(
          (candidate) =>
              (candidate['name']?.toString() ?? '').contains('彈珠汽水觀光工廠'),
        )) {
      additions.add(<String, dynamic>{
        'name': '納姆內彈珠汽水觀光工廠',
        'arrivalTime': '14:30',
        'departureTime': '16:30',
        'type': 'place',
        'notes': '導覽、DIY、汽水體驗',
      });
      additions.add(<String, dynamic>{
        'name': '客家米食風味點心',
        'arrivalTime': '16:40',
        'departureTime': '17:10',
        'type': 'meal',
        'notes': '菜包、水粄等',
      });
    }
  }
  if (additions.isEmpty) return;
  items.addAll(additions);
  items.sort((a, b) {
    final left = a['arrivalTime']?.toString() ?? '99:99';
    final right = b['arrivalTime']?.toString() ?? '99:99';
    return left.compareTo(right);
  });
}

void _injectWeloveTravelDerivedItems(
  List<Map<String, dynamic>> items, {
  required String dayTitle,
  required String fullText,
  required bool hasFollowingBreakfast,
}) {
  final hotelItem = items
      .where((item) => item['type'] == 'hotel')
      .cast<Map<String, dynamic>?>()
      .firstOrNull;
  final hotelNotes =
      hotelItem?['_rawNotes']?.toString() ??
      hotelItem?['notes']?.toString() ??
      '';
  final shouldAddDinner =
      dayTitle.contains('晚餐') ||
      hotelNotes.contains('晚餐') ||
      hotelNotes.contains('中式桌餐') ||
      fullText.contains('晚餐：') ||
      fullText.contains('中式桌餐') ||
      hasFollowingBreakfast;
  if (shouldAddDinner &&
      hotelItem != null &&
      !items.any((item) => (item['name']?.toString() ?? '').contains('晚餐'))) {
    items.add(<String, dynamic>{
      'name': '飯店晚餐',
      'arrivalTime': '18:30',
      'departureTime': '19:30',
      'type': 'meal',
      if (hotelItem['city'] != null) 'city': hotelItem['city'],
    });
  }
  items.sort((a, b) {
    final left = a['arrivalTime']?.toString() ?? '99:99';
    final right = b['arrivalTime']?.toString() ?? '99:99';
    return left.compareTo(right);
  });
}

void _attachWeloveTravelBranchOptions(List<Map<String, dynamic>> items) {
  for (final item in items) {
    final rawNotes = item['_rawNotes']?.toString().trim() ?? '';
    if (rawNotes.isEmpty) continue;
    if (!rawNotes.contains('選擇A：') && !rawNotes.contains('選擇B：')) {
      continue;
    }
    final options = _parseWeloveTravelBranchOptions(
      rawNotes,
      fallbackType: item['type']?.toString() ?? 'place',
      arrivalTime: item['arrivalTime']?.toString(),
      departureTime: item['departureTime']?.toString(),
      city: item['city']?.toString(),
    );
    if (options.length < 2) continue;
    item['_branchOptions'] = options;
  }
}

List<Map<String, dynamic>> _parseWeloveTravelBranchOptions(
  String rawNotes, {
  required String fallbackType,
  required String? arrivalTime,
  required String? departureTime,
  required String? city,
}) {
  final options = <Map<String, dynamic>>[];
  final matches = RegExp(
    r'選擇([A-ZＡ-Ｚ])[:：]\s*(.+)',
    multiLine: true,
  ).allMatches(rawNotes).toList();
  for (var index = 0; index < matches.length; index++) {
    final branch = _normalizeAgencyBranchKey(matches[index].group(1) ?? '');
    final start = matches[index].start;
    final end = index + 1 < matches.length
        ? matches[index + 1].start
        : rawNotes.length;
    final block = rawNotes.substring(start, end).trim();
    final body = block.replaceFirst(RegExp(r'^選擇[A-ZＡ-Ｚ][:：]\s*'), '').trim();
    if (body.isEmpty) continue;
    final type = _classifyAgencyTrainingItemType(body);
    final name = _extractAgencyBranchOptionName(
      body,
      fallbackType: fallbackType,
    );
    if (name.isEmpty) continue;
    final note = _compactAgencyBranchOptionNotes(body, name: name, type: type);
    final option = <String, dynamic>{
      'branch': branch,
      'name': name,
      'type': type == 'transport_note' ? fallbackType : type,
      if (arrivalTime != null && arrivalTime.isNotEmpty)
        'arrivalTime': arrivalTime,
      if (departureTime != null && departureTime.isNotEmpty)
        'departureTime': departureTime,
      if (city != null && city.isNotEmpty) 'city': city,
    };
    if (note != null && note.isNotEmpty) {
      option['notes'] = note;
    }
    options.add(option);
  }
  return options;
}

String _normalizeAgencyBranchKey(String raw) {
  final normalized = raw.trim().toUpperCase();
  switch (normalized) {
    case 'Ａ':
      return 'A';
    case 'Ｂ':
      return 'B';
    case 'Ｃ':
      return 'C';
    case 'Ｄ':
      return 'D';
  }
  return normalized;
}

List<String> _extractWeloveTravelTitleSegments(String dayTitle) {
  return dayTitle
      .split(RegExp(r'[~～]'))
      .map((segment) => segment.trim())
      .map(
        (segment) =>
            segment.replaceAll(RegExp(r'^(第\s*\d+\s*天)\s*'), '').trim(),
      )
      .map(
        (segment) => segment
            .replaceAll(RegExp(r'^(早餐|午餐|晚餐|HOME|出發|專車報到/出發)\s*'), '')
            .trim(),
      )
      .map((segment) => segment.replaceAll(RegExp(r'\{.*?\}'), '').trim())
      .where((segment) => segment.isNotEmpty)
      .toList();
}

String _normalizeWeloveTravelMealName(
  String rawName, {
  required String? notes,
  required String dayTitle,
  required List<String> titleSegments,
}) {
  var name = rawName.trim();
  name = name.replaceAll(RegExp(r'^(早餐|午餐|晚餐|下午茶)\s*[:：]?\s*'), '').trim();
  name = name
      .replaceAll(RegExp(r'\s+是.+$'), '')
      .replaceAll(RegExp(r'[，。,（(].*$'), '')
      .trim();
  if (name.isEmpty ||
      name == '中式桌餐' ||
      name == '桌餐' ||
      name == '早餐' ||
      name == '午餐' ||
      name == '晚餐') {
    final matchingTitleSegment = titleSegments.firstWhere(
      (segment) =>
          segment.contains('午餐') ||
          segment.contains('晚餐') ||
          segment.contains('下午茶') ||
          segment.contains('餐廳') ||
          segment.contains('小吃店') ||
          segment.contains('活海產'),
      orElse: () => '',
    );
    if (matchingTitleSegment.isNotEmpty) {
      final stripped = matchingTitleSegment
          .replaceAll(RegExp(r'^(早餐|午餐|晚餐|下午茶)\s*[:：]?\s*'), '')
          .replaceAll(RegExp(r'\{.*?\}'), '')
          .replaceAll(RegExp(r'[，。,（(].*$'), '')
          .trim();
      if (stripped.isNotEmpty) {
        name = stripped;
      }
    }
  }
  if (name.isEmpty) {
    return rawName.trim();
  }
  return name;
}

String _extractAgencyBranchOptionName(
  String body, {
  required String fallbackType,
}) {
  final bracketMatch = RegExp(r'【([^】]+)】').firstMatch(body);
  if (bracketMatch != null) {
    final rawName = bracketMatch.group(1)?.trim() ?? '';
    if (rawName.isNotEmpty) {
      return rawName
          .replaceAll(RegExp(r'[~～]'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
  }
  final extracted = _extractAgencyTrainingItemName(body, fallbackType);
  return extracted
      .replaceAll(RegExp(r'[~～]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String? _compactAgencyBranchOptionNotes(
  String body, {
  required String name,
  required String type,
}) {
  final withoutLabel = body
      .replaceFirst(RegExp(r'^【[^】]+】\s*'), '')
      .replaceAll(RegExp(r'※.*$'), '')
      .trim();
  if (withoutLabel.isEmpty) return null;
  return _compactWeloveTravelNotes(
        name: name,
        type: type,
        notes: withoutLabel,
      ) ??
      withoutLabel;
}

List<Map<String, dynamic>> _expandAgencyTrainingSources(
  Map<String, dynamic> source, {
  required List<String> warnings,
}) {
  final days = (source['days'] as List?)?.whereType<Map>().toList() ?? const [];
  final branchGroups = <Map<String, dynamic>>[];

  for (var dayIndex = 0; dayIndex < days.length; dayIndex++) {
    final items =
        (days[dayIndex]['items'] as List?)?.whereType<Map>().toList() ??
        const [];
    for (var itemIndex = 0; itemIndex < items.length; itemIndex++) {
      final options =
          (items[itemIndex]['_branchOptions'] as List?)
              ?.whereType<Map>()
              .map(
                (option) =>
                    Map<String, dynamic>.from(option.cast<String, dynamic>()),
              )
              .toList() ??
          const <Map<String, dynamic>>[];
      if (options.length < 2) continue;
      branchGroups.add(<String, dynamic>{
        'dayIndex': dayIndex,
        'itemIndex': itemIndex,
        'options': options,
      });
    }
  }

  if (branchGroups.isEmpty) {
    return <Map<String, dynamic>>[_sanitizeAgencyTrainingSource(source)];
  }

  final combinations = <List<Map<String, dynamic>>>[<Map<String, dynamic>>[]];
  for (final group in branchGroups) {
    final next = <List<Map<String, dynamic>>>[];
    final options = (group['options'] as List)
        .whereType<Map<String, dynamic>>()
        .toList();
    for (final base in combinations) {
      for (final option in options) {
        next.add(<Map<String, dynamic>>[
          ...base,
          <String, dynamic>{
            'dayIndex': group['dayIndex'],
            'itemIndex': group['itemIndex'],
            'option': option,
          },
        ]);
      }
    }
    combinations
      ..clear()
      ..addAll(next);
  }

  warnings.add(
    '偵測到 ${branchGroups.length} 組 A/B 選項，已自動展開為 ${combinations.length} 筆分支樣本。',
  );
  final baseWeight = (source['weight'] as num?)?.toDouble() ?? 1.0;
  final branchWeight = max(0.25, baseWeight / combinations.length);
  final expandedSources = <Map<String, dynamic>>[];

  for (final combo in combinations) {
    final cloned = _sanitizeAgencyTrainingSource(source);
    final clonedDays = (cloned['days'] as List)
        .whereType<Map<String, dynamic>>()
        .toList();
    final suffixParts = <String>[];
    for (final choice in combo) {
      final dayIndex = choice['dayIndex'] as int;
      final itemIndex = choice['itemIndex'] as int;
      final option = choice['option'] as Map<String, dynamic>;
      final branch = option['branch']?.toString().trim().toUpperCase() ?? 'X';
      suffixParts.add(branch.toLowerCase());
      final day = clonedDays[dayIndex];
      final items = (day['items'] as List)
          .whereType<Map<String, dynamic>>()
          .toList();
      items[itemIndex] = _sanitizeAgencyTrainingItem(option);
      day['items'] = items;
    }
    final suffix = suffixParts.join('');
    cloned['id'] = '${cloned['id']}-branch-$suffix';
    cloned['title'] = '${cloned['title']}（分支 $suffix）';
    cloned['weight'] = branchWeight;
    expandedSources.add(cloned);
  }
  return expandedSources;
}

Map<String, dynamic> _sanitizeAgencyTrainingSource(
  Map<String, dynamic> source,
) {
  final days = (source['days'] as List?)?.whereType<Map>().toList() ?? const [];
  return <String, dynamic>{
    ...source,
    'days': days.map((day) {
      final items =
          (day['items'] as List?)?.whereType<Map>().toList() ?? const [];
      return <String, dynamic>{
        ...Map<String, dynamic>.from(day.cast<String, dynamic>()),
        'items': items.map(_sanitizeAgencyTrainingItem).toList(),
      };
    }).toList(),
  }..removeWhere((key, _) => key.startsWith('_'));
}

Map<String, dynamic> _sanitizeAgencyTrainingItem(Map item) {
  final next = <String, dynamic>{};
  for (final entry in item.entries) {
    final key = entry.key.toString();
    if (key.startsWith('_') || key == 'branch') continue;
    next[key] = entry.value;
  }
  return next;
}

String? _compactWeloveTravelNotes({
  required String name,
  required String type,
  required String? notes,
}) {
  final text = notes?.trim();
  if (text == null || text.isEmpty) return null;
  if (type == 'departure' || type == 'arrival') {
    return null;
  }
  if (name == '黃金小鎮') {
    return '單車探索、石圍牆文化、風車DIY、鄉土午餐';
  }
  if (name == '清安豆腐街') {
    return '在地小吃';
  }
  if (name == '巧克力雲莊') {
    return '巧克力DIY、西式風味餐';
  }
  if (name == '納姆內彈珠汽水觀光工廠') {
    return '導覽、DIY、汽水體驗';
  }
  if (name == '客家米食風味點心') {
    return '菜包、水粄等';
  }
  if (type == 'hotel' && text.contains('溫泉')) {
    return '住宿與溫泉設施';
  }
  final summaries = <String>[];
  void addIf(bool condition, String summary) {
    if (condition && !summaries.contains(summary)) {
      summaries.add(summary);
    }
  }

  addIf(text.contains('單車') || text.contains('鐵馬'), '單車探索');
  addIf(text.contains('石圍牆'), '石圍牆文化');
  addIf(
    text.toLowerCase().contains('diy') ||
        text.contains('手作') ||
        text.contains('風車'),
    'DIY體驗',
  );
  addIf(
    text.contains('鄉土') || text.contains('午餐') || text.contains('西式綜合餐'),
    '特色餐食',
  );
  addIf(text.contains('溫泉') || text.contains('風呂'), '住宿與溫泉設施');
  addIf(text.contains('導覽'), '導覽');
  addIf(text.contains('汽水'), '汽水體驗');
  addIf(text.contains('巧克力'), '巧克力DIY');
  addIf(text.contains('老街'), '老街散策');
  addIf(text.contains('小吃'), '在地小吃');
  addIf(text.contains('九族') || text.contains('遊樂園'), '主題樂園');
  addIf(text.contains('纜車'), '纜車體驗');
  if (summaries.isEmpty) {
    final firstSentence = text
        .split(RegExp(r'[\n。]'))
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    if (firstSentence.isEmpty) {
      return null;
    }
    return firstSentence.length > 60
        ? '${firstSentence.substring(0, 60)}...'
        : firstSentence;
  }
  return summaries.join('、');
}

String? _guessAgencyCityForText(String text) {
  const keywordCity = <String, String>{
    '黃金小鎮': '苗栗縣',
    '清安豆腐街': '苗栗縣',
    '泰安溫泉': '苗栗縣',
    '錦水溫泉': '苗栗縣',
    '巧克力雲莊': '苗栗縣',
    '彈珠汽水觀光工廠': '苗栗縣',
    '納姆內': '苗栗縣',
    '大湖': '苗栗縣',
    '鹿港': '彰化縣',
    '王功': '彰化縣',
    '九族文化村': '南投縣',
    '日月潭': '南投縣',
    '北埔老街': '新竹縣',
    '東海大學': '臺中市',
    '高美濕地': '臺中市',
    '逢甲夜市': '臺中市',
    '台中國家歌劇院': '臺中市',
    '臺中國家歌劇院': '臺中市',
    '審計新村': '臺中市',
    '勤美誠品': '臺中市',
    '宮原眼科': '臺中市',
  };
  for (final entry in keywordCity.entries) {
    if (text.contains(entry.key)) {
      return entry.value;
    }
  }
  return _extractAgencyDestinationCities(text).firstOrNull;
}

List<String> _deriveAgencyDestinationCitiesFromDays(
  List<Map<String, dynamic>> days, {
  required String fallbackText,
}) {
  final counts = <String, int>{};
  for (final day in days) {
    final items =
        (day['items'] as List?)?.whereType<Map>().toList() ?? const [];
    for (final rawItem in items) {
      final item = rawItem.cast<String, dynamic>();
      final city = item['city']?.toString().trim();
      if (city == null || city.isEmpty) continue;
      counts.update(city, (value) => value + 1, ifAbsent: () => 1);
    }
  }
  if (counts.isEmpty) {
    return _extractAgencyDestinationCities(fallbackText);
  }
  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return [sorted.first.key];
}

bool _shouldStopAgencyDayParsing(String line) {
  final normalized = line.replaceAll(RegExp(r'\s+'), '');
  if (_agencyFooterStartRegex.hasMatch(line)) {
    return true;
  }
  if (normalized.startsWith('夜宿') ||
      normalized.startsWith('餐食') ||
      normalized.startsWith('備註') ||
      normalized.startsWith('附註') ||
      normalized.startsWith('費用包含') ||
      normalized.startsWith('費用不含')) {
    return true;
  }
  if (line.contains('每台車/') ||
      line.contains('平日出發') ||
      line.contains('假日出發') ||
      line.contains('旺日出發') ||
      line.contains('品保履約') ||
      line.contains('旅遊責任保險') ||
      line.contains('共同分攤')) {
    return true;
  }
  return false;
}

bool _looksLikeAgencyNoise(String text) {
  if (text.length > 120) {
    return true;
  }
  if (text.contains('旅責保險') ||
      text.contains('共同分攤') ||
      text.contains('定型化契約') ||
      text.contains('旅遊活動') ||
      text.contains('資料尚在處理中')) {
    return true;
  }
  return false;
}

String _buildAgencyTrainingSourceId(Uri uri, String title) {
  final code = uri.queryParameters['c']?.trim();
  final host = uri.host.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '-');
  if (code != null && code.isNotEmpty) {
    return 'agency-$host-${code.toLowerCase()}';
  }
  final normalizedTitle = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return 'agency-$host-${normalizedTitle.isEmpty ? DateTime.now().millisecondsSinceEpoch : normalizedTitle}';
}

List<String> _extractAgencyDestinationCities(String text) {
  final matches = _agencyCityRegex.allMatches(text);
  final cities = <String>[];
  for (final match in matches) {
    final city = match.group(0)?.trim();
    if (city == null || city.isEmpty) continue;
    final normalized = switch (city) {
      '台北市' => '臺北市',
      '台中市' => '臺中市',
      '台南市' => '臺南市',
      '台東縣' => '臺東縣',
      _ => city,
    };
    if (!cities.contains(normalized)) {
      cities.add(normalized);
    }
  }
  return cities;
}

List<String> _inferAgencyInterestTags(String text) {
  final normalized = text.toLowerCase();
  final tags = <String>{};
  void addIf(bool condition, String tag) {
    if (condition) tags.add(tag);
  }

  addIf(
    normalized.contains('老街') ||
        normalized.contains('古蹟') ||
        normalized.contains('文化') ||
        normalized.contains('聚落'),
    'heritage',
  );
  addIf(
    normalized.contains('寺') ||
        normalized.contains('廟') ||
        normalized.contains('宮') ||
        normalized.contains('媽祖'),
    'temple',
  );
  addIf(normalized.contains('夜市') || normalized.contains('市場'), 'night_market');
  addIf(
    normalized.contains('outlet') ||
        normalized.contains('百貨') ||
        normalized.contains('商圈'),
    'department_store',
  );
  addIf(
    normalized.contains('美食') ||
        normalized.contains('小吃') ||
        normalized.contains('午餐') ||
        normalized.contains('晚餐') ||
        normalized.contains('點心'),
    'street_food',
  );
  addIf(
    normalized.contains('餐廳') ||
        normalized.contains('午餐') ||
        normalized.contains('晚餐') ||
        normalized.contains('早餐'),
    'restaurant',
  );
  addIf(normalized.contains('溫泉') || normalized.contains('風呂'), 'hot_spring');
  addIf(
    normalized.contains('遊樂園') ||
        normalized.contains('樂園') ||
        normalized.contains('九族'),
    'amusement',
  );
  addIf(normalized.contains('博物館') || normalized.contains('歌劇院'), 'museum');
  addIf(
    normalized.contains('步道') ||
        normalized.contains('生態') ||
        normalized.contains('濕地') ||
        normalized.contains('海岸') ||
        normalized.contains('採蚵') ||
        normalized.contains('海田') ||
        normalized.contains('單車探索'),
    'national_park',
  );
  addIf(
    normalized.contains('diy') || normalized.contains('手作'),
    'handcraft_shop',
  );

  return tags.toList()..sort();
}

String _inferAgencyTripPurpose(String text) {
  final normalized = text.toLowerCase();
  if (normalized.contains('溫泉') ||
      normalized.contains('渡假') ||
      normalized.contains('飯店') ||
      normalized.contains('住宿')) {
    return 'relax';
  }
  if (normalized.contains('樂園') ||
      normalized.contains('遊樂園') ||
      normalized.contains('親子')) {
    return 'family_fun';
  }
  return 'explore';
}

String _inferAgencyTravelBehavior(String text) {
  final normalized = text.toLowerCase();
  if (normalized.contains('親子') ||
      normalized.contains('兒童') ||
      normalized.contains('小朋友') ||
      normalized.contains('全家大小') ||
      normalized.contains('diy') ||
      normalized.contains('觀光工廠') ||
      normalized.contains('遊樂園')) {
    return 'family';
  }
  if (normalized.contains('情侶') || normalized.contains('浪漫')) {
    return 'couple';
  }
  return 'general';
}

String _inferAgencyTargetPrice(String text) {
  final normalized = text.toLowerCase();
  if (normalized.contains('高級') || normalized.contains('五星')) {
    return 'high';
  }
  if (normalized.contains('溫泉飯店') ||
      normalized.contains('飯店晚餐') ||
      normalized.contains('觀光工廠') ||
      normalized.contains('巧克力雲莊') ||
      normalized.contains('九族文化村') ||
      normalized.contains('遊樂園')) {
    return 'mid';
  }
  if (normalized.contains('平價') || normalized.contains('小吃')) {
    return 'low';
  }
  return 'mid';
}

Future<String> _writeTrainingPlacesSnapshot() async {
  final file = File(_trainingDataPath('training_places_export.json'));
  final payload = await _exportCurrentPlacesPayload();
  await file.writeAsString(jsonEncode(payload), flush: true);
  return file.path;
}

Future<Map<String, dynamic>> _runPythonTrainingScript(
  String scriptName, {
  Map<String, String>? environment,
}) async {
  await _mirrorTrainingArtifactsToFiles();
  final scriptPath = p.join(_dataDir, '..', 'scripts', scriptName);
  if (!File(scriptPath).existsSync()) {
    throw ApiException(404, '找不到腳本：$scriptName');
  }
  final process = await Process.start(
    'python3',
    [scriptPath],
    workingDirectory: p.dirname(scriptPath),
    environment: {
      ...Platform.environment,
      'PYTHONUNBUFFERED': '1',
      'PYTHONIOENCODING': 'utf-8',
      ...?environment,
    },
  );
  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  final exitCode = await process.exitCode;
  final stdout = await stdoutFuture;
  final stderr = await stderrFuture;
  return {
    'script': scriptName,
    'exitCode': exitCode,
    'ok': exitCode == 0,
    'stdout': stdout.trim(),
    'stderr': stderr.trim(),
  };
}

Map<String, dynamic> _summarizeTrainingFile(
  String filename, {
  required Map<String, dynamic>? data,
}) {
  final stateKey = _trainingArtifactStateKeys[filename];
  final file = File(_trainingDataPath(filename));
  final exists = file.existsSync();
  final storedInState = stateKey != null && data != null;
  final summary = <String, dynamic>{
    'filename': filename,
    'path': file.path,
    'exists': exists || storedInState,
    'storedInAppState': storedInState,
    'sizeBytes': exists ? file.lengthSync() : 0,
    'updatedAt': exists
        ? file.lastModifiedSync().toUtc().toIso8601String()
        : null,
  };
  if (data == null) {
    return summary;
  }
  if (filename == 'agency_itineraries_raw.json') {
    final sources = data['sources'];
    summary['sourceCount'] = sources is List ? sources.length : 0;
  } else if (filename == 'historical_itineraries.imported.json' ||
      filename == 'historical_itineraries.json') {
    final samples = data['samples'];
    summary['sampleCount'] = samples is List ? samples.length : 0;
  } else if (filename == 'agency_itinerary_match_report.json') {
    summary['samplesGenerated'] = data['samplesGenerated'] ?? 0;
    summary['matchedItems'] = data['matchedItems'] ?? 0;
    summary['unmatchedItems'] = data['unmatchedItems'] ?? 0;
    summary['skippedItems'] = data['skippedItems'] ?? 0;
    final sources = data['sources'];
    summary['sourceCount'] = sources is List ? sources.length : 0;
  } else if (filename == 'agency_itinerary_match_overrides.json') {
    final overrides = data['overrides'];
    summary['overrideCount'] = overrides is Map ? overrides.length : 0;
  } else if (filename == 'itinerary_ranker_weights.json') {
    summary['metadata'] = data['metadata'];
    summary['generatedAt'] = data['generatedAt'];
  }
  return summary;
}

Future<Map<String, dynamic>> _buildTrainingSnapshot() async {
  final raw = await _readJsonMapFileIfExists('agency_itineraries_raw.json');
  final imported = await _readJsonMapFileIfExists(
    'historical_itineraries.imported.json',
  );
  final historical = await _readJsonMapFileIfExists(
    'historical_itineraries.json',
  );
  final report = await _readJsonMapFileIfExists(
    'agency_itinerary_match_report.json',
  );
  final matchOverrides = await _readJsonMapFileIfExists(
    'agency_itinerary_match_overrides.json',
  );
  final filteredReport = _filterTrainingMatchReportByOverrides(
    report,
    matchOverrides,
  );
  final weights = await _readJsonMapFileIfExists(
    'itinerary_ranker_weights.json',
  );
  final weightVersions = await _readTrainingWeightVersions();
  return {
    'files': {
      'agencyRaw': _summarizeTrainingFile(
        'agency_itineraries_raw.json',
        data: raw,
      ),
      'imported': _summarizeTrainingFile(
        'historical_itineraries.imported.json',
        data: imported,
      ),
      'historical': _summarizeTrainingFile(
        'historical_itineraries.json',
        data: historical,
      ),
      'matchReport': _summarizeTrainingFile(
        'agency_itinerary_match_report.json',
        data: filteredReport,
      ),
      'matchOverrides': _summarizeTrainingFile(
        'agency_itinerary_match_overrides.json',
        data: matchOverrides,
      ),
      'weights': _summarizeTrainingFile(
        'itinerary_ranker_weights.json',
        data: weights,
      ),
    },
    'raw': raw,
    'imported': imported,
    'historical': historical,
    'matchReport': filteredReport,
    'matchOverrides': matchOverrides,
    'weights': weights,
    'weightVersions': weightVersions,
    'storageBackend': _store.runtimeType.toString(),
  };
}

String _buildTrainingMatchOverrideKey(
  String sourceId,
  Map<String, dynamic> item,
) {
  return [
    sourceId,
    item['name']?.toString() ?? '',
    item['type']?.toString() ?? 'place',
    item['arrivalTime']?.toString() ?? '',
    item['departureTime']?.toString() ?? '',
  ].join('||');
}

Map<String, dynamic>? _filterTrainingMatchReportByOverrides(
  Map<String, dynamic>? report,
  Map<String, dynamic>? matchOverrides,
) {
  if (report == null) return null;
  final rawSources = report['sources'];
  if (rawSources is! List) {
    return Map<String, dynamic>.from(report);
  }
  final rawOverrides = matchOverrides?['overrides'];
  final overrides = rawOverrides is Map<String, dynamic>
      ? rawOverrides
      : rawOverrides is Map
      ? Map<String, dynamic>.from(rawOverrides)
      : const <String, dynamic>{};

  final filteredSources = <Map<String, dynamic>>[];
  var unmatchedItems = 0;

  for (final source in rawSources.whereType<Map>()) {
    final sourceMap = Map<String, dynamic>.from(source);
    final sourceId = sourceMap['id']?.toString() ?? '';
    final rawItems = sourceMap['unmatchedItems'];
    if (rawItems is! List) {
      filteredSources.add(sourceMap);
      continue;
    }

    final keptItems = <Map<String, dynamic>>[];
    for (final item in rawItems.whereType<Map>()) {
      final itemMap = Map<String, dynamic>.from(item);
      final key = itemMap['overrideKey']?.toString().trim().isNotEmpty == true
          ? itemMap['overrideKey']!.toString().trim()
          : _buildTrainingMatchOverrideKey(sourceId, itemMap);
      final override = overrides[key];
      if (override is Map) {
        final action = override['action']?.toString().trim().toLowerCase();
        if (action == 'map' || action == 'ignore') {
          continue;
        }
      }
      keptItems.add(itemMap);
    }

    sourceMap['unmatchedItems'] = keptItems;
    unmatchedItems += keptItems.length;
    filteredSources.add(sourceMap);
  }

  final next = Map<String, dynamic>.from(report);
  next['sources'] = filteredSources;
  next['unmatchedItems'] = unmatchedItems;
  return next;
}

Future<Map<String, dynamic>> _promoteImportedHistoricalSamples() async {
  final imported = await _requireJsonMapFile(
    'historical_itineraries.imported.json',
  );
  final importedSamples = imported['samples'];
  if (importedSamples is! List) {
    throw ApiException(500, 'historical_itineraries.imported.json 缺少 samples');
  }

  final historical =
      await _readJsonMapFileIfExists('historical_itineraries.json') ??
      <String, dynamic>{'samples': <dynamic>[]};
  final existingSamplesRaw = historical['samples'];
  final existingSamples = existingSamplesRaw is List
      ? existingSamplesRaw
            .whereType<Map>()
            .map(Map<String, dynamic>.from)
            .toList()
      : <Map<String, dynamic>>[];

  final byId = <String, Map<String, dynamic>>{};
  final merged = <Map<String, dynamic>>[];
  for (final sample in existingSamples) {
    final id = (sample['id'] ?? '').toString().trim();
    if (id.isEmpty) continue;
    byId[id] = sample;
    merged.add(sample);
  }

  var inserted = 0;
  var replaced = 0;
  for (final rawSample in importedSamples.whereType<Map>()) {
    final sample = Map<String, dynamic>.from(rawSample);
    final id = (sample['id'] ?? '').toString().trim();
    if (id.isEmpty) continue;
    final existing = byId[id];
    if (existing == null) {
      byId[id] = sample;
      merged.add(sample);
      inserted += 1;
      continue;
    }
    final index = merged.indexOf(existing);
    if (index >= 0) {
      merged[index] = sample;
    }
    byId[id] = sample;
    replaced += 1;
  }

  final payload = <String, dynamic>{'notes': '由後台模型訓練流程維護', 'samples': merged};
  await _writePrettyJsonFile('historical_itineraries.json', payload);
  return {
    'inserted': inserted,
    'replaced': replaced,
    'totalSamples': merged.length,
  };
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
  'reclassify_places',
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
  'reclassify_places' => 'reclassify_places.py',
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
      if (mode == 'reclassify_places' && city != null && city.trim().isNotEmpty)
        'RECLASSIFY_CITY': city.trim(),
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
  _appendBounded(_recentRequestLogs, {
    'timestamp': startedAt.toUtc().toIso8601String(),
    'method': request.method,
    'path': '/${request.url.path}',
    'status': statusCode,
    'durationMs': durationMs,
    'query': request.url.queryParameters.isEmpty
        ? null
        : request.url.queryParameters,
    if (error != null && error.isNotEmpty) 'error': error,
  }, limit: 120);
}

void _recordAppEvent({
  required Request request,
  required String event,
  String? page,
  String? userId,
  String? sessionId,
  Map<String, dynamic>? payload,
}) {
  _appendBounded(_appEventHistory, {
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
  }, limit: 600);
}

Future<void> _sendTrackedLinePush({
  required String to,
  required String text,
  required String category,
  String? userId,
  String? username,
  String? imageUrl,
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
    await _notificationService.sendLinePush(
      to: to,
      text: text,
      imageUrl: imageUrl,
    );
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
  _appendBounded(_reminderRunHistory, {
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'source': source,
    ...result,
  }, limit: 60);
}

void _recordAiUsage(_AiUsageRecord record) {
  _totalAiRequestCount += 1;
  if (!record.success) {
    _totalAiErrorCount += 1;
  }
  _appendBounded(_aiUsageHistory, {
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'feature': record.feature,
    'model': record.model,
    'success': record.success,
    'statusCode': record.statusCode,
    'latencyMs': record.latencyMs,
    'promptTokens': record.promptTokens ?? 0,
    'completionTokens': record.completionTokens ?? 0,
    'totalTokens': record.totalTokens ?? 0,
    if (record.error != null && record.error!.trim().isNotEmpty)
      'error': record.error,
  }, limit: 240);
}

Map<String, int> _extractAiUsageFromResponse(Map decoded) {
  final usage = decoded['usage'];
  if (usage is! Map) {
    return const {'promptTokens': 0, 'completionTokens': 0, 'totalTokens': 0};
  }
  return {
    'promptTokens': (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
    'completionTokens': (usage['completion_tokens'] as num?)?.toInt() ?? 0,
    'totalTokens': (usage['total_tokens'] as num?)?.toInt() ?? 0,
  };
}

String _currentLlmProvider() {
  final value = (_llmProvider ?? 'openai').trim().toLowerCase();
  return value == 'gemini' ? 'gemini' : 'openai';
}

List<String> _parseGeminiApiKeys(String? rawKeys, String? fallbackKey) {
  final keys = <String>[];
  void addKeys(String? value) {
    if (value == null || value.trim().isEmpty) return;
    for (final candidate in value.split(RegExp(r'[\n,;]+'))) {
      final key = candidate.trim();
      if (key.isEmpty || keys.contains(key)) continue;
      keys.add(key);
    }
  }

  addKeys(rawKeys);
  addKeys(fallbackKey);
  return keys;
}

int? _nextGeminiApiKeyIndex() {
  if (_geminiApiKeys.isEmpty) return null;
  final now = DateTime.now();
  final expired = _geminiKeyUnavailableUntil.entries
      .where((entry) => !entry.value.isAfter(now))
      .map((entry) => entry.key)
      .toList();
  for (final index in expired) {
    _geminiKeyUnavailableUntil.remove(index);
  }
  for (var offset = 0; offset < _geminiApiKeys.length; offset++) {
    final index = (_geminiApiKeyCursor + offset) % _geminiApiKeys.length;
    final unavailableUntil = _geminiKeyUnavailableUntil[index];
    if (unavailableUntil == null || !unavailableUntil.isAfter(now)) {
      _geminiApiKeyCursor = (index + 1) % _geminiApiKeys.length;
      return index;
    }
  }
  return null;
}

Duration? _geminiKeyCooldownForError({
  required int statusCode,
  required String body,
}) {
  if (statusCode == 429) {
    return const Duration(hours: 1);
  }
  if (statusCode == 403) {
    return const Duration(hours: 6);
  }
  final normalizedBody = body.toLowerCase();
  if (normalizedBody.contains('quota') ||
      normalizedBody.contains('rate limit') ||
      normalizedBody.contains('resource_exhausted')) {
    return const Duration(hours: 1);
  }
  return null;
}

bool _isTransientGeminiStatus(int statusCode) {
  return const {408, 425, 429, 500, 502, 503, 504}.contains(statusCode);
}

int _geminiMaxAttempts() {
  final configured = int.tryParse(
    Platform.environment['GEMINI_MAX_ATTEMPTS'] ?? '',
  );
  return (configured ?? 3).clamp(1, 5);
}

Duration _geminiRequestTimeout() {
  final configured = int.tryParse(
    Platform.environment['GEMINI_TIMEOUT_SECONDS'] ?? '',
  );
  return Duration(seconds: (configured ?? 30).clamp(10, 60));
}

int _geminiMaxOutputTokens(String feature) {
  final configured = int.tryParse(
    Platform.environment['GEMINI_MAX_OUTPUT_TOKENS'] ?? '',
  );
  if (configured != null) {
    return configured.clamp(512, 4096);
  }
  return switch (feature) {
    'planner_chat' => 1024,
    'place_discovery' => 1024,
    'planner_assist' => 1536,
    'itinerary_insight' => 1536,
    _ => 1280,
  };
}

int _geminiThinkingBudget() {
  final configured = int.tryParse(
    Platform.environment['GEMINI_THINKING_BUDGET'] ?? '',
  );
  return (configured ?? 0).clamp(0, 1024);
}

Map<String, dynamic>? _geminiResponseSchema(String feature) {
  const stringArray = {
    'type': 'ARRAY',
    'items': {'type': 'STRING'},
  };
  return switch (feature) {
    'place_discovery' => {
      'type': 'OBJECT',
      'required': ['queries'],
      'properties': {'queries': stringArray},
    },
    'planner_assist' => {
      'type': 'OBJECT',
      'properties': {
        'prioritized_cities': stringArray,
        'daily_stop_cap': {'type': 'INTEGER'},
        'recommended_start_time': {'type': 'STRING'},
        'warnings': stringArray,
        'improvements': stringArray,
        'planning_focus': {'type': 'STRING'},
        'stay_style': {'type': 'STRING'},
        'lunch_start_time': {'type': 'STRING'},
        'dinner_start_time': {'type': 'STRING'},
        'alternative_plan': {'type': 'STRING'},
      },
    },
    'itinerary_insight' => {
      'type': 'OBJECT',
      'properties': {
        'summary': {'type': 'STRING'},
        'route_reason': {'type': 'STRING'},
        'user_like_reason': {'type': 'STRING'},
        'tips': stringArray,
        'warnings': stringArray,
        'improvements': stringArray,
        'pacing': {'type': 'STRING'},
        'meal_plan': {'type': 'STRING'},
        'stop_highlights': {
          'type': 'ARRAY',
          'items': {
            'type': 'OBJECT',
            'properties': {
              'id': {'type': 'STRING'},
              'highlight': {'type': 'STRING'},
              'icon': {'type': 'STRING'},
            },
          },
        },
      },
    },
    'planner_chat' => {
      'type': 'OBJECT',
      'required': ['reply', 'ready_to_generate'],
      'properties': {
        'reply': {'type': 'STRING'},
        'ready_to_generate': {'type': 'BOOLEAN'},
        'suggested_quick_replies': stringArray,
      },
    },
    'stop_explanation' => {
      'type': 'OBJECT',
      'properties': {
        'summary': {'type': 'STRING'},
        'why_included': {'type': 'STRING'},
        'why_timing': {'type': 'STRING'},
        'why_duration': {'type': 'STRING'},
        'tips': stringArray,
      },
    },
    _ => null,
  };
}

Duration _geminiRetryDelay(
  int attempt, {
  String? retryAfter,
  String? responseBody,
  int? statusCode,
}) {
  final retryAfterSeconds = int.tryParse(retryAfter?.trim() ?? '');
  if (retryAfterSeconds != null && retryAfterSeconds > 0) {
    return Duration(seconds: retryAfterSeconds.clamp(1, 20));
  }
  final bodyRetryMatch = RegExp(
    r'"retryDelay"\s*:\s*"(\d+(?:\.\d+)?)s"',
  ).firstMatch(responseBody ?? '');
  final bodyRetrySeconds = double.tryParse(bodyRetryMatch?.group(1) ?? '');
  if (bodyRetrySeconds != null && bodyRetrySeconds > 0) {
    return Duration(
      milliseconds: (bodyRetrySeconds * 1000).round().clamp(1000, 20000),
    );
  }
  final baseDelaysMs = statusCode == 429
      ? const [5000, 12000, 20000, 20000]
      : const [900, 2200, 4800, 8000];
  final base = baseDelaysMs[min(attempt, baseDelaysMs.length - 1)];
  return Duration(milliseconds: base + Random().nextInt(450));
}

void _markGeminiKeyUnavailable(
  int index, {
  required Duration cooldown,
  required String reason,
}) {
  final until = DateTime.now().add(cooldown);
  final existing = _geminiKeyUnavailableUntil[index];
  if (existing == null || until.isAfter(existing)) {
    _geminiKeyUnavailableUntil[index] = until;
  }
  _log.warning(
    'Gemini key #${index + 1}/${_geminiApiKeys.length} paused for ${cooldown.inMinutes}m: $reason',
  );
}

bool _isLlmConfigured([String? provider]) {
  final resolved = (provider ?? _currentLlmProvider()).trim().toLowerCase();
  if (resolved == 'gemini') {
    return _geminiApiKeys.isNotEmpty;
  }
  return _openAiApiKey != null && _openAiApiKey!.trim().isNotEmpty;
}

String _resolvedLlmModel([String? provider]) {
  final resolved = (provider ?? _currentLlmProvider()).trim().toLowerCase();
  if (resolved == 'gemini') {
    final model = _geminiModel?.trim();
    return (model == null || model.isEmpty) ? 'gemini-2.5-flash' : model;
  }
  final model = _openAiModel?.trim();
  return (model == null || model.isEmpty) ? 'gpt-4o-mini' : model;
}

Map<String, int> _extractGeminiUsageFromResponse(Map decoded) {
  final usage = decoded['usageMetadata'];
  if (usage is! Map) {
    return const {'promptTokens': 0, 'completionTokens': 0, 'totalTokens': 0};
  }
  return {
    'promptTokens': (usage['promptTokenCount'] as num?)?.toInt() ?? 0,
    'completionTokens': (usage['candidatesTokenCount'] as num?)?.toInt() ?? 0,
    'totalTokens': (usage['totalTokenCount'] as num?)?.toInt() ?? 0,
  };
}

String? _extractOpenAiTextFromResponse(Map decoded) {
  final choices = decoded['choices'];
  if (choices is! List || choices.isEmpty || choices.first is! Map) {
    return null;
  }
  final message = (choices.first as Map)['message'];
  return message is Map ? message['content']?.toString() : null;
}

String? _extractGeminiTextFromResponse(Map decoded) {
  final candidates = decoded['candidates'];
  if (candidates is! List || candidates.isEmpty || candidates.first is! Map) {
    return null;
  }
  final candidate = Map<String, dynamic>.from(candidates.first as Map);
  final content = candidate['content'];
  if (content is! Map) {
    return null;
  }
  final parts = content['parts'];
  if (parts is! List || parts.isEmpty) {
    return null;
  }
  final buffer = StringBuffer();
  for (final part in parts) {
    if (part is! Map) continue;
    final text = part['text']?.toString();
    if (text == null || text.trim().isEmpty) continue;
    if (buffer.isNotEmpty) buffer.writeln();
    buffer.write(text.trim());
  }
  final result = buffer.toString().trim();
  return result.isEmpty ? null : result;
}

List<Map<String, dynamic>> _buildGeminiContents(
  List<Map<String, String>> messages,
) {
  return messages
      .where((message) => (message['content'] ?? '').trim().isNotEmpty)
      .map((message) {
        final role = (message['role'] ?? 'user').trim().toLowerCase();
        return {
          'role': role == 'assistant' || role == 'model' ? 'model' : 'user',
          'parts': [
            {'text': (message['content'] ?? '').trim()},
          ],
        };
      })
      .toList();
}

Future<_LlmJsonResult> _generateJsonWithLlm({
  required String feature,
  required String systemPrompt,
  required List<Map<String, String>> messages,
  required double temperature,
}) async {
  final provider = _currentLlmProvider();
  final model = _resolvedLlmModel(provider);
  final aiStartedAt = DateTime.now();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    if (provider == 'gemini') {
      if (_geminiApiKeys.isEmpty) {
        throw const _LlmRequestException('Gemini API key 未設定');
      }
      final base = (_geminiBaseUrl == null || _geminiBaseUrl!.trim().isEmpty)
          ? 'https://generativelanguage.googleapis.com'
          : _geminiBaseUrl!.trim();
      final uri = Uri.parse(
        base,
      ).resolve('/v1beta/models/$model:generateContent');
      final payload = {
        'system_instruction': {
          'parts': [
            {'text': systemPrompt},
          ],
        },
        'contents': _buildGeminiContents(messages),
        'generationConfig': {
          'temperature': temperature,
          'responseMimeType': 'application/json',
          'maxOutputTokens': _geminiMaxOutputTokens(feature),
          'thinkingConfig': {'thinkingBudget': _geminiThinkingBudget()},
          if (_geminiResponseSchema(feature) case final schema?)
            'responseSchema': schema,
        },
      };
      final maxAttempts = _geminiMaxAttempts();
      final requestTimeout = _geminiRequestTimeout();
      String? lastError;
      int? lastStatusCode;
      var lastUsageModel = '$provider:$model';
      for (var attempt = 0; attempt < maxAttempts; attempt++) {
        final keyIndex = _nextGeminiApiKeyIndex();
        if (keyIndex == null) {
          lastError = 'Gemini API key 目前都在暫停或不可用';
          break;
        }
        final key = _geminiApiKeys[keyIndex];
        final usageModel = '$provider:$model#key${keyIndex + 1}';
        lastUsageModel = usageModel;
        try {
          final request = await client.postUrl(uri).timeout(requestTimeout);
          request.headers.contentType = ContentType.json;
          request.headers.set('x-goog-api-key', key);
          request.add(utf8.encode(jsonEncode(payload)));
          final response = await request.close().timeout(requestTimeout);
          final body = await utf8
              .decodeStream(response)
              .timeout(requestTimeout);
          lastStatusCode = response.statusCode;
          if (response.statusCode >= 400) {
            lastError = body;
            final cooldown = _geminiKeyCooldownForError(
              statusCode: response.statusCode,
              body: body,
            );
            final canRetry =
                attempt + 1 < maxAttempts &&
                (_isTransientGeminiStatus(response.statusCode) ||
                    cooldown != null);
            // A single key should get a real retry opportunity for short-lived
            // rate limits. With multiple keys, pause immediately and rotate.
            if (cooldown != null && (_geminiApiKeys.length > 1 || !canRetry)) {
              _markGeminiKeyUnavailable(
                keyIndex,
                cooldown: cooldown,
                reason: 'HTTP ${response.statusCode}',
              );
            }
            if (canRetry) {
              final delay = _geminiRetryDelay(
                attempt,
                retryAfter: response.headers.value(
                  HttpHeaders.retryAfterHeader,
                ),
                responseBody: body,
                statusCode: response.statusCode,
              );
              _log.warning(
                'Gemini $feature attempt ${attempt + 1}/$maxAttempts '
                'HTTP ${response.statusCode}; retrying in ${delay.inMilliseconds}ms',
              );
              await Future<void>.delayed(delay);
              continue;
            }
            _recordAiUsage(
              _AiUsageRecord(
                feature: feature,
                model: usageModel,
                success: false,
                latencyMs: DateTime.now()
                    .difference(aiStartedAt)
                    .inMilliseconds,
                statusCode: response.statusCode,
                error: body,
              ),
            );
            throw _LlmRequestException(
              'Gemini HTTP ${response.statusCode}: $body',
            );
          }
          final decoded = jsonDecode(body);
          if (decoded is! Map) {
            throw const FormatException('Gemini 回傳格式不是 JSON object');
          }
          final usage = _extractGeminiUsageFromResponse(decoded);
          final text = _extractGeminiTextFromResponse(decoded);
          if (text == null || text.trim().isEmpty) {
            throw const FormatException('Gemini 回傳內容為空');
          }
          if (attempt > 0) {
            _log.info(
              'Gemini $feature recovered after ${attempt + 1} attempts',
            );
          }
          return _LlmJsonResult(
            provider: provider,
            model: '$model#key${keyIndex + 1}',
            statusCode: response.statusCode,
            latencyMs: DateTime.now().difference(aiStartedAt).inMilliseconds,
            text: text,
            promptTokens: usage['promptTokens'] ?? 0,
            completionTokens: usage['completionTokens'] ?? 0,
            totalTokens: usage['totalTokens'] ?? 0,
          );
        } on _LlmRequestException {
          rethrow;
        } catch (error) {
          lastStatusCode = null;
          lastError = error is TimeoutException
              ? 'Gemini request timeout after ${requestTimeout.inSeconds}s'
              : error.toString();
          if (attempt + 1 < maxAttempts) {
            final delay = _geminiRetryDelay(attempt);
            _log.warning(
              'Gemini $feature attempt ${attempt + 1}/$maxAttempts failed: '
              '$lastError; retrying in ${delay.inMilliseconds}ms',
            );
            await Future<void>.delayed(delay);
            continue;
          }
        }
      }
      _recordAiUsage(
        _AiUsageRecord(
          feature: feature,
          model: lastUsageModel,
          success: false,
          latencyMs: DateTime.now().difference(aiStartedAt).inMilliseconds,
          statusCode: lastStatusCode,
          error: lastError ?? 'Gemini 呼叫失敗',
        ),
      );
      throw _LlmRequestException(lastError ?? 'Gemini 呼叫失敗');
    }

    final key = _openAiApiKey;
    if (key == null || key.trim().isEmpty) {
      throw const _LlmRequestException('OpenAI API key 未設定');
    }
    final base = (_openAiBaseUrl == null || _openAiBaseUrl!.trim().isEmpty)
        ? 'https://api.openai.com'
        : _openAiBaseUrl!.trim();
    final uri = Uri.parse(base).resolve('/v1/chat/completions');
    final payload = {
      'model': model,
      'temperature': temperature,
      'response_format': {'type': 'json_object'},
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        ...messages
            .where((message) => (message['content'] ?? '').trim().isNotEmpty)
            .map(
              (message) => {
                'role': message['role'] ?? 'user',
                'content': (message['content'] ?? '').trim(),
              },
            ),
      ],
    };
    final request = await client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
    request.add(utf8.encode(jsonEncode(payload)));
    final response = await request.close().timeout(const Duration(seconds: 18));
    final body = await utf8.decodeStream(response);
    if (response.statusCode >= 400) {
      _recordAiUsage(
        _AiUsageRecord(
          feature: feature,
          model: '$provider:$model',
          success: false,
          latencyMs: DateTime.now().difference(aiStartedAt).inMilliseconds,
          statusCode: response.statusCode,
          error: body,
        ),
      );
      throw _LlmRequestException('OpenAI HTTP ${response.statusCode}: $body');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      _recordAiUsage(
        _AiUsageRecord(
          feature: feature,
          model: '$provider:$model',
          success: false,
          latencyMs: DateTime.now().difference(aiStartedAt).inMilliseconds,
          statusCode: response.statusCode,
          error: 'OpenAI 回傳格式不是 JSON object',
        ),
      );
      throw const _LlmRequestException('OpenAI 回傳格式不是 JSON object');
    }
    final usage = _extractAiUsageFromResponse(decoded);
    final text = _extractOpenAiTextFromResponse(decoded);
    if (text == null || text.trim().isEmpty) {
      _recordAiUsage(
        _AiUsageRecord(
          feature: feature,
          model: '$provider:$model',
          success: false,
          latencyMs: DateTime.now().difference(aiStartedAt).inMilliseconds,
          statusCode: response.statusCode,
          promptTokens: usage['promptTokens'],
          completionTokens: usage['completionTokens'],
          totalTokens: usage['totalTokens'],
          error: 'OpenAI message.content 為空',
        ),
      );
      throw const _LlmRequestException('OpenAI 回傳內容為空');
    }
    return _LlmJsonResult(
      provider: provider,
      model: model,
      statusCode: response.statusCode,
      latencyMs: DateTime.now().difference(aiStartedAt).inMilliseconds,
      text: text,
      promptTokens: usage['promptTokens'] ?? 0,
      completionTokens: usage['completionTokens'] ?? 0,
      totalTokens: usage['totalTokens'] ?? 0,
    );
  } on _LlmRequestException {
    rethrow;
  } catch (error) {
    _recordAiUsage(
      _AiUsageRecord(
        feature: feature,
        model: '$provider:$model',
        success: false,
        latencyMs: DateTime.now().difference(aiStartedAt).inMilliseconds,
        error: error.toString(),
      ),
    );
    throw _LlmRequestException('$provider 呼叫失敗：$error');
  } finally {
    client.close(force: true);
  }
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
  final syncCapabilities = _buildSyncCapabilities();
  final recentAiWindow = _aiUsageHistory.where((entry) {
    final timestamp = DateTime.tryParse(entry['timestamp']?.toString() ?? '');
    return timestamp != null && timestamp.isAfter(recentFiveMinutes);
  }).toList();
  final recentAiErrors = recentAiWindow
      .where((entry) => entry['success'] != true)
      .length;
  final totalAiTransportSuccesses = _aiUsageHistory.where((entry) {
    final statusCode = entry['statusCode'] as int?;
    return statusCode != null && statusCode >= 200 && statusCode < 300;
  }).length;
  final recentAiAvgLatency = recentAiWindow.isEmpty
      ? 0
      : recentAiWindow
                .map((entry) => (entry['latencyMs'] as int?) ?? 0)
                .reduce((a, b) => a + b) ~/
            recentAiWindow.length;
  final totalPromptTokens = _aiUsageHistory.fold<int>(
    0,
    (sum, entry) => sum + ((entry['promptTokens'] as int?) ?? 0),
  );
  final totalCompletionTokens = _aiUsageHistory.fold<int>(
    0,
    (sum, entry) => sum + ((entry['completionTokens'] as int?) ?? 0),
  );
  final totalAiTokens = _aiUsageHistory.fold<int>(
    0,
    (sum, entry) => sum + ((entry['totalTokens'] as int?) ?? 0),
  );
  final linePushSuccesses = _linePushHistory
      .where((entry) => entry['status'] == 'success')
      .length;
  final linePushFailures = _linePushHistory.length - linePushSuccesses;
  int successfulLinePushesByCategory(String category) => _linePushHistory
      .where(
        (entry) =>
            entry['status'] == 'success' && entry['category'] == category,
      )
      .length;
  final reminderSuccesses = _reminderRunHistory.where((entry) {
    final status = entry['status']?.toString();
    return status == null || status == 'success';
  }).length;
  final reminderFailures = _reminderRunHistory.length - reminderSuccesses;
  final reminderDurationTotal = _reminderRunHistory.fold<int>(
    0,
    (sum, entry) => sum + ((entry['durationMs'] as int?) ?? 0),
  );
  final cronRuns = _reminderRunHistory
      .where((entry) => entry['source'] == 'cron')
      .toList();
  final lastCronRun = cronRuns.isEmpty ? null : cronRuns.last;
  final lastCronRunAt = lastCronRun == null
      ? null
      : DateTime.tryParse(lastCronRun['timestamp']?.toString() ?? '');
  final cronRecentlyActive =
      lastCronRunAt != null &&
      lastCronRunAt.isAfter(now.subtract(const Duration(minutes: 15)));
  final aiFeatureStats = <String, Map<String, dynamic>>{};
  for (final entry in _aiUsageHistory) {
    final feature = entry['feature']?.toString() ?? 'unknown';
    final stat = aiFeatureStats.putIfAbsent(
      feature,
      () => {
        'feature': feature,
        'requests': 0,
        'errors': 0,
        'promptTokens': 0,
        'completionTokens': 0,
        'totalTokens': 0,
        'totalLatencyMs': 0,
      },
    );
    stat['requests'] = (stat['requests'] as int) + 1;
    if (entry['success'] != true) {
      stat['errors'] = (stat['errors'] as int) + 1;
    }
    stat['promptTokens'] =
        (stat['promptTokens'] as int) + ((entry['promptTokens'] as int?) ?? 0);
    stat['completionTokens'] =
        (stat['completionTokens'] as int) +
        ((entry['completionTokens'] as int?) ?? 0);
    stat['totalTokens'] =
        (stat['totalTokens'] as int) + ((entry['totalTokens'] as int?) ?? 0);
    stat['totalLatencyMs'] =
        (stat['totalLatencyMs'] as int) + ((entry['latencyMs'] as int?) ?? 0);
  }
  final aiFeatureList =
      aiFeatureStats.values.map((entry) {
        final requests = entry['requests'] as int? ?? 0;
        final errors = entry['errors'] as int? ?? 0;
        final successRate = requests == 0
            ? 0.0
            : ((requests - errors) / requests * 100);
        return {
          'feature': entry['feature'],
          'requests': requests,
          'errors': errors,
          'successRate': successRate,
          'avgLatencyMs': requests == 0
              ? 0
              : ((entry['totalLatencyMs'] as int? ?? 0) ~/ requests),
          'promptTokens': entry['promptTokens'],
          'completionTokens': entry['completionTokens'],
          'totalTokens': entry['totalTokens'],
        };
      }).toList()..sort(
        (a, b) => ((b['requests'] as int?) ?? 0).compareTo(
          (a['requests'] as int?) ?? 0,
        ),
      );

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
      'llmProvider': _currentLlmProvider(),
      'llmConfigured': _isLlmConfigured(),
      'openAiConfigured': _openAiApiKey != null && _openAiApiKey!.isNotEmpty,
      'geminiConfigured': _geminiApiKeys.isNotEmpty,
      'geminiKeyCount': _geminiApiKeys.length,
      'geminiPausedKeyCount': _geminiKeyUnavailableUntil.length,
      'lineConfigured':
          (_lineChannelSecret?.isNotEmpty ?? false) &&
          ((Platform.environment['LINE_CHANNEL_ACCESS_TOKEN'] ?? '')
              .isNotEmpty),
      'googleMapsConfigured':
          _googleMapsServerKey().isNotEmpty,
      'itineraryLearningConfigured': _itineraryLearningProfile.enabled,
      'cronConfigured':
          _reminderCronToken != null && _reminderCronToken!.isNotEmpty,
      'cronRecentlyActive': cronRecentlyActive,
      'crawlRunning': _crawlJob?.running == true,
      'environment': _usingRenderBackend ? 'render' : 'local',
      'timestamp': now.toUtc().toIso8601String(),
    },
    'syncCapabilities': syncCapabilities,
    'topRoutes': topRoutes
        .take(12)
        .map((entry) => {'route': entry.key, 'count': entry.value})
        .toList(),
    'recentRequests': _recentRequestLogs.reversed.take(30).toList(),
    'linePushHistory': _linePushHistory.reversed.take(30).toList(),
    'reminderRuns': _reminderRunHistory.reversed.take(20).toList(),
    'notificationMetrics': {
      'linePushAttempts': _linePushHistory.length,
      'linePushSuccesses': linePushSuccesses,
      'linePushFailures': linePushFailures,
      'linePushSuccessRate': _linePushHistory.isEmpty
          ? 0.0
          : (linePushSuccesses / _linePushHistory.length * 100),
      'itineraryGeneratedPushes': successfulLinePushesByCategory(
        'itinerary_generated',
      ),
      'tomorrowSummaryPushes': successfulLinePushesByCategory(
        'tomorrow_itinerary_summary',
      ),
      'upcomingReminderPushes': successfulLinePushesByCategory(
        'upcoming_reminder',
      ),
      'lastLinePushAt': _linePushHistory.isEmpty
          ? null
          : _linePushHistory.last['timestamp'],
      'reminderRuns': _reminderRunHistory.length,
      'reminderSuccesses': reminderSuccesses,
      'reminderFailures': reminderFailures,
      'reminderSuccessRate': _reminderRunHistory.isEmpty
          ? 0.0
          : (reminderSuccesses / _reminderRunHistory.length * 100),
      'avgReminderDurationMs': _reminderRunHistory.isEmpty
          ? 0
          : reminderDurationTotal ~/ _reminderRunHistory.length,
      'cronRuns': cronRuns.length,
      'lastCronRunAt': lastCronRun?['timestamp'],
      'lastCronStatus': lastCronRun?['status'] ?? 'success',
      'cronRecentlyActive': cronRecentlyActive,
    },
    'appEvents': _buildAppEventSnapshot(),
    'crawlJob': _crawlJob?.toJson(),
    'aiMetrics': {
      'totalRequests': _totalAiRequestCount,
      'totalErrors': _totalAiErrorCount,
      'transportSuccessRate': _totalAiRequestCount == 0
          ? 0.0
          : (totalAiTransportSuccesses / _totalAiRequestCount * 100),
      'successRate': _totalAiRequestCount == 0
          ? 0.0
          : ((_totalAiRequestCount - _totalAiErrorCount) /
                _totalAiRequestCount *
                100),
      'requestsLast5Min': recentAiWindow.length,
      'errorsLast5Min': recentAiErrors,
      'avgLatencyMsLast5Min': recentAiAvgLatency,
      'totalPromptTokens': totalPromptTokens,
      'totalCompletionTokens': totalCompletionTokens,
      'totalTokens': totalAiTokens,
      'features': aiFeatureList.take(12).toList(),
      'recentCalls': _aiUsageHistory.reversed.take(30).toList(),
    },
  };
}

Map<String, dynamic> _buildSyncCapabilities() {
  final syncSourceConfigured =
      (_syncSourceUrl?.trim().isNotEmpty ?? false) &&
      (_syncSourceToken?.trim().isNotEmpty ?? false);
  final localSyncConfigured =
      (_localSyncUrl?.trim().isNotEmpty ?? false) &&
      (_localSyncToken?.trim().isNotEmpty ?? false);

  String? syncFromRemoteReason;
  if (!syncSourceConfigured) {
    syncFromRemoteReason = '缺少 SYNC_SOURCE_URL 或 SYNC_SOURCE_TOKEN';
  }

  String? syncToLocalReason;
  if (!localSyncConfigured) {
    syncToLocalReason = '缺少 LOCAL_SYNC_URL 或 LOCAL_SYNC_TOKEN';
  } else if (_usingRenderBackend && _looksLikeLoopbackUrl(_localSyncUrl)) {
    syncToLocalReason = '目前是雲端 Render 後台，無法直接連到 localhost/127.0.0.1';
  }

  return {
    'environment': _usingRenderBackend ? 'render' : 'local',
    'syncFromRemoteAvailable': syncSourceConfigured,
    'syncFromRemoteReason': syncFromRemoteReason,
    'syncFromRemoteSource': _syncSourceUrl,
    'syncToLocalAvailable': syncToLocalReason == null,
    'syncToLocalReason': syncToLocalReason,
    'syncToLocalTarget': _localSyncUrl,
  };
}

bool _looksLikeLoopbackUrl(String? rawUrl) {
  if (rawUrl == null || rawUrl.trim().isEmpty) return false;
  final uri = Uri.tryParse(rawUrl.trim());
  final host = uri?.host.toLowerCase() ?? '';
  return host == 'localhost' || host == '127.0.0.1' || host == '::1';
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
    _log.warning(
      'Reminder cron unauthorized: expectedFingerprint='
      '${_secretFingerprint(_reminderCronToken)} '
      'receivedFingerprint=${_secretFingerprint(token)}',
    );
    return jsonResponse(
      401,
      errorBody(
        '未授權',
        details: {
          'expectedTokenFingerprint': _secretFingerprint(_reminderCronToken),
          'receivedTokenFingerprint': _secretFingerprint(token),
        },
      ),
    );
  }
  return _handle(action);
}

Future<Response> _adminPageHandler(Request request) async {
  final file = File(p.join(_dataDir, '..', 'web', 'admin.html'));
  if (!await file.exists()) {
    return Response.notFound('admin.html not found');
  }
  final html = await file.readAsString();
  final modifiedAt = await file.lastModified();
  return Response.ok(
    html,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
      'Pragma': 'no-cache',
      'Expires': '0',
      'Last-Modified': HttpDate.format(modifiedAt.toUtc()),
      'X-Admin-Build-Time': modifiedAt.toUtc().toIso8601String(),
    },
  );
}

Future<Response> _placePhotoProxyHandler(Request request) async {
  final googleKey = _googleMapsServerKey();
  if (googleKey.isEmpty) {
    return jsonResponse(
      503,
      errorBody('尚未設定 GOOGLE_PLACES_SERVER_API_KEY 或 GOOGLE_MAPS_API_KEY'),
    );
  }

  final placeId = request.url.queryParameters['place_id']?.trim() ?? '';
  final photoReference =
      request.url.queryParameters['photo_reference']?.trim() ?? '';
  if (placeId.isEmpty && photoReference.isEmpty) {
    return jsonResponse(400, errorBody('缺少 place_id 或 photo_reference'));
  }

  final requestedMaxWidth = int.tryParse(
    request.url.queryParameters['maxwidth'] ?? '',
  );
  final maxWidth = (requestedMaxWidth ?? 800).clamp(64, 1600);
  try {
    if (placeId.isNotEmpty) {
      final byPlaceId = await _fetchPlacePhotoByPlaceIdNew(
        key: googleKey,
        placeId: placeId,
        maxWidth: maxWidth,
      );
      if (byPlaceId != null) {
        return Response(
          200,
          body: byPlaceId.bytes,
          headers: {
            'content-type': byPlaceId.contentType,
            'cache-control': 'public, max-age=86400',
          },
        );
      }
    }

    if (photoReference.isNotEmpty) {
      final byLegacyReference = await _fetchPlacePhotoByLegacyReference(
        key: googleKey,
        photoReference: photoReference,
        maxWidth: maxWidth,
      );
      if (byLegacyReference != null) {
        return Response(
          200,
          body: byLegacyReference.bytes,
          headers: {
            'content-type': byLegacyReference.contentType,
            'cache-control': 'public, max-age=86400',
          },
        );
      }
    }

    if (placeId.isNotEmpty) {
      _log.warning(
        'Place photo proxy failed for place_id=$placeId '
        'photoRefPrefix=${photoReference.substring(0, min(12, photoReference.length))}',
      );
    }
    return jsonResponse(404, errorBody('找不到景點圖片'));
  } on TimeoutException catch (error) {
    _log.warning('Place photo proxy timeout: $error');
    return jsonResponse(504, errorBody('景點圖片讀取逾時'));
  } catch (error, stack) {
    _log.warning('Place photo proxy error: $error', error, stack);
    return jsonResponse(502, errorBody('景點圖片代理失敗'));
  }
}

Future<_PlacePhotoPayload?> _fetchPlacePhotoByLegacyReference({
  required String key,
  required String photoReference,
  required int maxWidth,
}) async {
  final uri = Uri.https('maps.googleapis.com', '/maps/api/place/photo', {
    'maxwidth': '$maxWidth',
    'photo_reference': photoReference,
    'key': key,
  });
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    final upstreamRequest = await client.getUrl(uri);
    final upstreamResponse =
        await upstreamRequest.close().timeout(const Duration(seconds: 20));
    if (upstreamResponse.statusCode != 200) {
      final body = await utf8.decodeStream(upstreamResponse).catchError(
        (_) => '',
      );
      _log.warning(
        'Legacy place photo failed: status=${upstreamResponse.statusCode} '
        'photoReference=${photoReference.substring(0, min(12, photoReference.length))} '
        'body=${body.toString().trim()}',
      );
      return null;
    }

    final bytesBuilder = await upstreamResponse.fold<BytesBuilder>(
      BytesBuilder(copy: false),
      (builder, chunk) {
        builder.add(chunk);
        return builder;
      },
    );
    final contentType =
        upstreamResponse.headers.contentType?.mimeType ?? 'image/jpeg';
    return _PlacePhotoPayload(
      bytes: bytesBuilder.takeBytes(),
      contentType: contentType,
    );
  } finally {
    client.close(force: true);
  }
}

Future<_PlacePhotoPayload?> _fetchPlacePhotoByPlaceIdNew({
  required String key,
  required String placeId,
  required int maxWidth,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    final detailsUri = Uri.https(
      'places.googleapis.com',
      '/v1/places/$placeId',
      {'languageCode': 'zh-TW'},
    );
    final detailsRequest = await client.getUrl(detailsUri);
    detailsRequest.headers.set('X-Goog-Api-Key', key);
    detailsRequest.headers.set('X-Goog-FieldMask', 'photos');
    final detailsResponse =
        await detailsRequest.close().timeout(const Duration(seconds: 20));
    if (detailsResponse.statusCode != 200) {
      final body = await utf8.decodeStream(detailsResponse).catchError(
        (_) => '',
      );
      _log.warning(
        'Place photo details (new) failed: status=${detailsResponse.statusCode} '
        'placeId=$placeId body=${body.toString().trim()}',
      );
      return null;
    }

    final detailsText = await utf8.decodeStream(detailsResponse);
    final decoded = jsonDecode(detailsText);
    if (decoded is! Map) {
      return null;
    }
    final photos =
        (decoded['photos'] as List?)
            ?.whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList() ??
        const <Map<String, dynamic>>[];
    if (photos.isEmpty) {
      _log.info('Place photo details (new) has no photos: placeId=$placeId');
      return null;
    }
    final photoName = photos.first['name']?.toString().trim() ?? '';
    if (photoName.isEmpty) {
      return null;
    }

    final mediaUri = Uri.https(
      'places.googleapis.com',
      '/v1/$photoName/media',
      {'maxWidthPx': '$maxWidth', 'skipHttpRedirect': 'true'},
    );
    final mediaRequest = await client.getUrl(mediaUri);
    mediaRequest.headers.set('X-Goog-Api-Key', key);
    final mediaResponse =
        await mediaRequest.close().timeout(const Duration(seconds: 20));
    if (mediaResponse.statusCode != 200) {
      final body = await utf8.decodeStream(mediaResponse).catchError(
        (_) => '',
      );
      _log.warning(
        'Place photo media (new) failed: status=${mediaResponse.statusCode} '
        'placeId=$placeId photoName=$photoName body=${body.toString().trim()}',
      );
      return null;
    }

    final mediaText = await utf8.decodeStream(mediaResponse);
    final mediaJson = jsonDecode(mediaText);
    if (mediaJson is! Map) {
      return null;
    }
    final photoUriText = mediaJson['photoUri']?.toString().trim() ?? '';
    if (photoUriText.isEmpty) {
      return null;
    }

    final photoUri = Uri.tryParse(photoUriText);
    if (photoUri == null) {
      return null;
    }
    final photoRequest = await client.getUrl(photoUri);
    final photoResponse =
        await photoRequest.close().timeout(const Duration(seconds: 20));
    if (photoResponse.statusCode != 200) {
      final body = await utf8.decodeStream(photoResponse).catchError(
        (_) => '',
      );
      _log.warning(
        'Resolved photoUri fetch failed: status=${photoResponse.statusCode} '
        'placeId=$placeId body=${body.toString().trim()}',
      );
      return null;
    }

    final bytesBuilder = await photoResponse.fold<BytesBuilder>(
      BytesBuilder(copy: false),
      (builder, chunk) {
        builder.add(chunk);
        return builder;
      },
    );
    final contentType =
        photoResponse.headers.contentType?.mimeType ?? 'image/jpeg';
    return _PlacePhotoPayload(
      bytes: bytesBuilder.takeBytes(),
      contentType: contentType,
    );
  } finally {
    client.close(force: true);
  }
}

Response _emptySiteIconHandler(Request request) {
  return Response(
    HttpStatus.noContent,
    headers: const {'Cache-Control': 'public, max-age=86400'},
  );
}

Future<User?> _findUserById(String userId) async {
  return _store.findUserById(userId);
}

Future<User> _syncUserActivePlan({
  required String userId,
  required Map<String, dynamic> plan,
}) async {
  try {
    final user = await _store.findUserById(userId);
    if (user == null) {
      throw ApiException(404, '找不到使用者');
    }
    final normalizedPlan = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(plan)) as Map,
    );
    final updatedAt = DateTime.now();
    final updatedUser = user.copyWith(
      activePlan: normalizedPlan,
      activePlanUpdatedAt: updatedAt,
    );
    await _store.updateUser(updatedUser);
    await _rememberLineReminderPlan(
      user: updatedUser,
      plan: normalizedPlan,
      updatedAt: updatedAt,
    );
    return updatedUser;
  } on ApiException {
    rethrow;
  } catch (error, stack) {
    _log.severe('同步正式行程失敗：user=$userId error=$error', error, stack);
    throw ApiException(503, '正式行程雲端同步暫時失敗，請稍後再試');
  }
}

DateTime _taipeiNow() {
  final taipei = DateTime.now().toUtc().add(const Duration(hours: 8));
  return DateTime(
    taipei.year,
    taipei.month,
    taipei.day,
    taipei.hour,
    taipei.minute,
    taipei.second,
    taipei.millisecond,
    taipei.microsecond,
  );
}

String _reminderDateKey(DateTime value) {
  final year = value.year.toString().padLeft(4, '0');
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

String? _reminderDayDateKey(Map<String, dynamic> day) {
  final raw = day['date']?.toString().trim() ?? '';
  if (raw.isEmpty) return null;
  final match = RegExp(r'^(\d{4}-\d{2}-\d{2})').firstMatch(raw);
  return match?.group(1);
}

DateTime _parseTaipeiReferenceTime(Object? raw) {
  final text = raw?.toString().trim() ?? '';
  final parsed = DateTime.tryParse(text);
  if (parsed == null) {
    return _taipeiNow();
  }
  final hasTimezone = RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(text);
  if (parsed.isUtc || hasTimezone) {
    final taipei = parsed.toUtc().add(const Duration(hours: 8));
    return DateTime(
      taipei.year,
      taipei.month,
      taipei.day,
      taipei.hour,
      taipei.minute,
      taipei.second,
      taipei.millisecond,
      taipei.microsecond,
    );
  }
  return parsed;
}

int _reminderEnvHour(String name, int fallback) {
  final parsed = int.tryParse(Platform.environment[name]?.trim() ?? '');
  return parsed == null ? fallback : parsed.clamp(0, 23);
}

int _nextStopReminderMinutes() {
  final parsed = int.tryParse(
    Platform.environment['REMINDER_NEXT_STOP_MINUTES']?.trim() ?? '',
  );
  return parsed == null ? 20 : parsed.clamp(5, 90);
}

int _nextStopReminderGraceMinutes() {
  final parsed = int.tryParse(
    Platform.environment['REMINDER_NEXT_STOP_GRACE_MINUTES']?.trim() ?? '',
  );
  return parsed == null ? 30 : parsed.clamp(5, 120);
}

Future<bool> _lineReminderWasSent(String signature) async {
  final appState = await _readAppState();
  final raw = appState[_lineReminderSignaturesStateKey];
  if (raw is! Map) return false;
  return raw.containsKey(signature);
}

Future<void> _markLineReminderSent(String signature) async {
  final appState = await _readAppState();
  final raw = appState[_lineReminderSignaturesStateKey];
  final signatures = raw is Map
      ? Map<String, dynamic>.from(raw)
      : <String, dynamic>{};
  final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 14));
  signatures.removeWhere((_, value) {
    final sentAt = DateTime.tryParse(value?.toString() ?? '');
    return sentAt == null || sentAt.isBefore(cutoff);
  });
  signatures[signature] = DateTime.now().toUtc().toIso8601String();
  appState[_lineReminderSignaturesStateKey] = signatures;
  await _writeAppState(appState);
}

Future<Map<String, dynamic>> _runTrackedUpcomingReminderScan({
  required String triggerSource,
}) async {
  final startedAt = DateTime.now();
  try {
    return await _runUpcomingReminderScan(triggerSource: triggerSource);
  } catch (error) {
    _recordReminderRun(
      source: triggerSource,
      result: {
        'status': 'failed',
        'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
        'scannedUsers': 0,
        'actualScanned': 0,
        'syncedPlans': 0,
        'lineEligibleUsers': 0,
        'todayPlanUsers': 0,
        'tomorrowPlanUsers': 0,
        'skippedNoLineBinding': 0,
        'skippedPushDisabled': 0,
        'skippedNoTodayPlan': 0,
        'skippedInvalidPlan': 0,
        'linePushed': 0,
        'failedUsers': 0,
        'errors': [error.toString()],
        'checkedAt': _taipeiNow().toIso8601String(),
      },
    );
    rethrow;
  }
}

Future<Map<String, dynamic>> _runUpcomingReminderScan({
  required String triggerSource,
}) async {
  final startedAt = DateTime.now();
  final users = (await _store.read()).users;
  final now = _taipeiNow();
  final userById = {for (final user in users) user.id: user};
  final planCandidates = <Map<String, dynamic>>[];
  final seenPlanKeys = <String>{};

  for (final user in users) {
    final plan = user.activePlan;
    if (plan == null) {
      continue;
    }
    final key = _lineReminderPlanKey(user.id, plan);
    seenPlanKeys.add(key);
    planCandidates.add({
      'user': user,
      'plan': plan,
      'source': 'active_plan',
      'key': key,
    });
  }

  final reminderPlanRecords = await _readLineReminderPlanRecords();
  for (final record in reminderPlanRecords) {
    final userId = record['userId']?.toString().trim() ?? '';
    final user = userById[userId];
    final rawPlan = record['plan'];
    if (user == null || rawPlan is! Map) {
      continue;
    }
    final plan = Map<String, dynamic>.from(rawPlan);
    final recordId = record['id']?.toString().trim() ?? '';
    final key = recordId.isNotEmpty ? recordId : _lineReminderPlanKey(user.id, plan);
    if (!seenPlanKeys.add(key)) {
      continue;
    }
    planCandidates.add({
      'user': user,
      'plan': plan,
      'source': 'reminder_history',
      'key': key,
    });
  }

  _log.info(
    '提醒掃描開始：source=$triggerSource users=${users.length} planCandidates=${planCandidates.length} checkedAt=${now.toIso8601String()}',
  );
  final todayText = _reminderDateKey(now);
  final tomorrowText = _reminderDateKey(now.add(const Duration(days: 1)));
  final eveningStart = _reminderEnvHour('REMINDER_EVENING_START_HOUR', 20);
  final eveningEnd = _reminderEnvHour('REMINDER_EVENING_END_HOUR', 23);
  final shouldSendTomorrowSummary =
      now.hour >= eveningStart && now.hour <= eveningEnd;
  var scanned = 0;
  var actualScanned = 0;
  var syncedPlans = 0;
  var lineEligibleUsers = 0;
  var todayPlanUsers = 0;
  var tomorrowPlanUsers = 0;
  var skippedNoLineBinding = 0;
  var skippedPushDisabled = 0;
  var skippedNoTodayPlan = 0;
  var skippedInvalidPlan = 0;
  var pushed = 0;
  var tomorrowSummariesPushed = 0;
  var upcomingRemindersPushed = 0;
  var contextAlertsPushed = 0;
  var failedUsers = 0;
  final pushedUsers = <String>[];
  final upcomingChecks = <Map<String, dynamic>>[];
  final errors = <String>[];

  for (final candidate in planCandidates) {
    final user = candidate['user'] as User;
    final plan = Map<String, dynamic>.from(candidate['plan'] as Map);
    final candidateSource = candidate['source']?.toString() ?? 'unknown';
    final planDates = _planDateKeys(plan);
    syncedPlans += 1;
    final rawDays = plan['days'];
    if (rawDays is! List) {
      skippedInvalidPlan += 1;
      continue;
    }
    final days = rawDays
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    if (days.isEmpty) {
      skippedInvalidPlan += 1;
      continue;
    }
    scanned += 1;
    final todayDay = days.firstWhere(
      (item) => _reminderDayDateKey(item) == todayText,
      orElse: () => const <String, dynamic>{},
    );
    final tomorrowDay = days.firstWhere(
      (item) => _reminderDayDateKey(item) == tomorrowText,
      orElse: () => const <String, dynamic>{},
    );
    if (todayDay.isNotEmpty) {
      todayPlanUsers += 1;
    }
    if (tomorrowDay.isNotEmpty) {
      tomorrowPlanUsers += 1;
    }

    if (user.lineUserId == null || user.lineUserId!.trim().isEmpty) {
      skippedNoLineBinding += 1;
      continue;
    }
    if (user.linePushEnabled != true) {
      skippedPushDisabled += 1;
      continue;
    }
    lineEligibleUsers += 1;

    if (todayDay.isEmpty) {
      skippedNoTodayPlan += 1;
      upcomingChecks.add({
        'username': user.username,
        'source': candidateSource,
        'planDates': planDates,
        'status': 'skipped',
        'reason': 'no_today_plan',
        'todayDate': todayText,
        'availableDates': days
            .map(_reminderDayDateKey)
            .whereType<String>()
            .toSet()
            .toList(),
      });
    } else {
      actualScanned += 1;
      try {
        final result = await _buildContextAwareness({
          'day': todayDay,
          'userId': user.id,
          'triggerLinePush': true,
          'currentTime': now.toIso8601String(),
        });
        final upcomingReminder = result['upcomingReminder'];
        if (upcomingReminder is Map) {
          final shouldPush = upcomingReminder['shouldPush'] == true;
          final linePushed = result['linePushed'] == true;
          upcomingChecks.add({
            'username': user.username,
            'source': candidateSource,
            'planDates': planDates,
            'status': linePushed
                ? 'pushed'
                : (shouldPush ? 'push_blocked_or_duplicate' : 'not_due'),
            'targetPlaceName': upcomingReminder['targetPlaceName'],
            'scheduledTime': upcomingReminder['scheduledTime'],
            'departureTime': upcomingReminder['departureTime'],
            'minutesUntilDeparture': upcomingReminder['minutesUntilDeparture'],
            'triggerWindowMinutes': upcomingReminder['triggerWindowMinutes'],
            'graceWindowMinutes': upcomingReminder['graceWindowMinutes'],
            'shouldPush': shouldPush,
            'linePushed': linePushed,
          });
        } else {
          upcomingChecks.add({
            'username': user.username,
            'source': candidateSource,
            'planDates': planDates,
            'status': 'no_upcoming_stop',
            'todayDate': todayText,
          });
        }
        if (result['linePushed'] == true) {
          pushed += 1;
          if (upcomingReminder is Map &&
              upcomingReminder['shouldPush'] == true) {
            upcomingRemindersPushed += 1;
          } else {
            contextAlertsPushed += 1;
          }
          pushedUsers.add(user.username);
        }
      } catch (error) {
        failedUsers += 1;
        errors.add('${user.username}: $error');
        _log.warning('提醒掃描使用者失敗：user=${user.id} error=$error');
      }
    }

    if (shouldSendTomorrowSummary) {
      if (tomorrowDay.isNotEmpty) {
        try {
          if (await _sendLineTomorrowSummaryNotification(
            user: user,
            day: tomorrowDay,
          )) {
            pushed += 1;
            tomorrowSummariesPushed += 1;
            pushedUsers.add(user.username);
          }
        } catch (error) {
          failedUsers += 1;
          errors.add('${user.username}: $error');
          _log.warning('前一晚摘要推播失敗：user=${user.id} error=$error');
        }
      }
    }
  }

  final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
  final result = {
    'status': failedUsers == 0 ? 'success' : 'partial',
    'scannedUsers': scanned,
    'actualScanned': actualScanned,
    'syncedPlans': syncedPlans,
    'lineEligibleUsers': lineEligibleUsers,
    'todayPlanUsers': todayPlanUsers,
    'tomorrowPlanUsers': tomorrowPlanUsers,
    'skippedNoLineBinding': skippedNoLineBinding,
    'skippedPushDisabled': skippedPushDisabled,
    'skippedNoTodayPlan': skippedNoTodayPlan,
    'skippedInvalidPlan': skippedInvalidPlan,
    'linePushed': pushed,
    'tomorrowSummariesPushed': tomorrowSummariesPushed,
    'upcomingRemindersPushed': upcomingRemindersPushed,
    'contextAlertsPushed': contextAlertsPushed,
    'failedUsers': failedUsers,
    'durationMs': durationMs,
    if (errors.isNotEmpty) 'errors': errors.take(10).toList(),
    'pushedUsers': pushedUsers,
    'upcomingChecks': upcomingChecks.take(20).toList(),
    'checkedAt': now.toIso8601String(),
  };
  _recordReminderRun(source: triggerSource, result: result);
  _log.info(
    '提醒掃描完成：source=$triggerSource scannedUsers=$scanned actualScanned=$actualScanned syncedPlans=$syncedPlans '
    'lineEligibleUsers=$lineEligibleUsers todayPlanUsers=$todayPlanUsers '
    'tomorrowPlanUsers=$tomorrowPlanUsers skippedNoLineBinding=$skippedNoLineBinding '
    'skippedPushDisabled=$skippedPushDisabled skippedNoTodayPlan=$skippedNoTodayPlan '
    'skippedInvalidPlan=$skippedInvalidPlan '
    'linePushed=$pushed upcomingRemindersPushed=$upcomingRemindersPushed '
    'tomorrowSummariesPushed=$tomorrowSummariesPushed failedUsers=$failedUsers '
    'durationMs=$durationMs',
  );
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

  final metaMap = meta is Map
      ? Map<String, dynamic>.from(meta)
      : const <String, dynamic>{};
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
  final triggerLinePush = body['triggerLinePush'] == true;
  final referenceTime = _parseTaipeiReferenceTime(body['currentTime']);
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
  final itemMaps =
      (day['items'] as List?)
          ?.whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList() ??
      const <Map<String, dynamic>>[];
  final visitItems = itemMaps.where((item) {
    final place = item['place'];
    if (place is! Map) return false;
    final kind = place['kind']?.toString() ?? 'place';
    return kind != 'meal_break';
  }).toList();
  final focus = _resolveContextFocus(
    dayDate: dayDate,
    visitItems: visitItems,
    referenceTime: referenceTime,
  );

  final visitPlaces = visitItems
      .map(
        (item) =>
            _planPlaceToPlace(Map<String, dynamic>.from(item['place'] as Map)),
      )
      .toList();
  final outdoorCount = visitPlaces.where(_isOutdoorPlace).length;
  final severeRain =
      (weather != null &&
      ((_asIntValue(weather['code']) ?? 0) >= 95 ||
          (_asIntValue(weather['precipitationProbability']) ?? 0) >= 60));
  final hotOutdoorDay =
      (weather != null &&
      (_asDoubleValue(weather['temperatureMax']) ?? 0) >= 33 &&
      outdoorCount >= 2);

  if (weather != null) {
    final rainProb = _asIntValue(weather['precipitationProbability']) ?? 0;
    final weatherCode = _asIntValue(weather['code']);
    final tempMax = _asDoubleValue(weather['temperatureMax']);
    final summary =
        weather['summary']?.toString() ?? _weatherCodeToText(weatherCode);

    if (weatherCode != null && weatherCode >= 95 && outdoorCount > 0) {
      alerts.add(
        _contextAlert(
          type: 'weather_thunder',
          severity: 'high',
          title: '雷雨風險偏高',
          message: '今天預報為 $summary，戶外景點建議提前或改成室內點。',
        ),
      );
      suggestions.add('優先把戶外景點移到上午，午後改排室內景點或餐食休息。');
    } else if (rainProb >= 70 && outdoorCount > 0) {
      alerts.add(
        _contextAlert(
          type: 'weather_rain',
          severity: 'high',
          title: '午後降雨機率高',
          message: '降雨機率約 $rainProb%，戶外行程可能受影響。',
        ),
      );
      suggestions.add('保留雨備方案，將步道、海邊、公園等戶外點前移。');
    } else if (rainProb >= 40 && outdoorCount >= 2) {
      alerts.add(
        _contextAlert(
          type: 'weather_rain',
          severity: 'medium',
          title: '有降雨風險',
          message: '降雨機率約 $rainProb%，今天的戶外景點較多，建議預留彈性。',
        ),
      );
      suggestions.add('下午時段可預留咖啡館、博物館等室內替代點。');
    }

    if (tempMax != null && tempMax >= 34 && outdoorCount >= 2) {
      alerts.add(
        _contextAlert(
          type: 'weather_heat',
          severity: 'high',
          title: '高溫曝曬風險',
          message: '今日高溫約 ${tempMax.toStringAsFixed(0)}°C，連續戶外停留可能偏累。',
        ),
      );
      suggestions.add('中午前後優先安排冷氣室內點或午餐休息，避免長時間曝曬。');
    } else if (tempMax != null && tempMax >= 31 && outdoorCount >= 3) {
      alerts.add(
        _contextAlert(
          type: 'weather_heat',
          severity: 'medium',
          title: '中午體感偏熱',
          message: '今日高溫約 ${tempMax.toStringAsFixed(0)}°C，戶外景點密度偏高。',
        ),
      );
      suggestions.add('最曬的 12:00-14:00 盡量安排午餐或室內景點。');
    }
  } else {
    alerts.add(
      _contextAlert(
        type: 'weather_pending',
        severity: 'low',
        title: '天氣資料尚未同步',
        message: '目前無法取得今日天氣，建議出發前再確認一次。',
      ),
    );
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
        _setContextNextAction(day, {
          'type': severeRain ? 'swap_for_weather' : 'swap_for_heat',
          'severity': severeRain ? 'high' : 'medium',
          'phase': focus.phase,
          'targetPlaceId': place.id,
          'targetPlaceName': place.name,
          'scheduledTime': item['time']?.toString(),
          'title': focus.phase == 'current' ? '建議立即調整目前景點' : '建議調整接下來的景點',
          'message': severeRain
              ? '${place.name} 目前受降雨風險影響，建議不要硬走原本戶外安排。'
              : '${place.name} 遇到高溫曝曬風險，建議改成室內點再回來。',
          'recommendedAction': topNames.isEmpty
              ? '先改排同城市室內備案。'
              : '先改去 $topNames，等天氣穩定後再回來。',
          'alternatives': candidates
              .take(3)
              .map(_contextReplacementToJson)
              .toList(),
        });
      }
    }
    if (backupPlans.isNotEmpty) {
      final sample = backupPlans.first;
      final replacements = (sample['replacements'] as List)
          .take(2)
          .map((e) => e['name'])
          .join(' / ');
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
      final closureText = weekdayText == null
          ? '今天的營業資訊無法判讀。'
          : '今日營業資訊顯示：$weekdayText';
      alerts.add(
        _contextAlert(
          type: 'opening_closed_or_unknown',
          severity: 'high',
          title: '${place.name} 今日可能未開放',
          message: closureText,
        ),
      );
      suggestions.add('建議先電話確認 ${place.name} 是否營業，或改用同城市備案景點。');
      if (focus != null && focus.targetIndex == visitIndex) {
        _setContextNextAction(day, {
          'type': 'opening_unknown',
          'severity': 'high',
          'phase': focus.phase,
          'targetPlaceId': place.id,
          'targetPlaceName': place.name,
          'scheduledTime': item['time']?.toString(),
          'title': '下一站營業狀態不明',
          'message': '${place.name} 今天的營業資訊無法可靠判讀，不建議直接前往。',
          'recommendedAction': '先電話確認，若無法確認就改用同城市備案景點。',
        });
      }
      continue;
    }
    if (place.openingHours == null) {
      alerts.add(
        _contextAlert(
          type: 'opening_missing',
          severity: 'low',
          title: '${place.name} 缺少營業時間',
          message: '目前沒有 ${place.name} 的營業時段資料，建議出發前再確認。',
        ),
      );
      continue;
    }
    if (scheduleStart == null || window == null) {
      continue;
    }

    final openMinute = window.$1;
    final closeMinute = window.$2;
    if (scheduleStart < openMinute) {
      alerts.add(
        _contextAlert(
          type: 'opening_before_open',
          severity: 'high',
          title: '${place.name} 可能尚未開門',
          message:
              '行程安排 ${item['time']} 到訪，但今日約 ${_minutesToHm(openMinute)} 才開放。',
        ),
      );
      suggestions.add(
        '將 ${place.name} 延後到 ${_minutesToHm(openMinute)} 後，或先安排附近早開景點。',
      );
      if (focus != null && focus.targetIndex == visitIndex) {
        _setContextNextAction(day, {
          'type': 'delay_until_open',
          'severity': 'high',
          'phase': focus.phase,
          'targetPlaceId': place.id,
          'targetPlaceName': place.name,
          'scheduledTime': item['time']?.toString(),
          'title': '建議延後前往下一站',
          'message':
              '${place.name} 約 ${_minutesToHm(openMinute)} 才開放，照原時間過去會撲空。',
          'recommendedAction':
              '把 ${place.name} 延後到 ${_minutesToHm(openMinute)} 後，或先換去附近早開景點。',
        });
      }
      continue;
    }
    if (scheduleStart >= closeMinute) {
      alerts.add(
        _contextAlert(
          type: 'opening_after_close',
          severity: 'high',
          title: '${place.name} 抵達時可能已打烊',
          message:
              '行程安排 ${item['time']} 到訪，但今日約 ${_minutesToHm(closeMinute)} 前結束營業。',
        ),
      );
      suggestions.add('把 ${place.name} 提前，或改成當天較早時段的景點。');
      if (focus != null && focus.targetIndex == visitIndex) {
        _setContextNextAction(day, {
          'type': 'skip_closed',
          'severity': 'high',
          'phase': focus.phase,
          'targetPlaceId': place.id,
          'targetPlaceName': place.name,
          'scheduledTime': item['time']?.toString(),
          'title': '下一站可能已打烊',
          'message': '${place.name} 抵達時段可能已結束營業，不建議照原順序前往。',
          'recommendedAction': '改成當天較早時段景點，或直接換成備案景點。',
        });
      }
      continue;
    }
    if (scheduleEnd != null && scheduleEnd > closeMinute) {
      alerts.add(
        _contextAlert(
          type: 'opening_short_window',
          severity: 'medium',
          title: '${place.name} 停留時間可能不足',
          message:
              '預計待到 ${item['endTime']}，但今日約 ${_minutesToHm(closeMinute)} 前結束營業。',
        ),
      );
      suggestions.add('縮短前一站停留或提早出發，避免 ${place.name} 只逛到一半。');
      if (focus != null && focus.targetIndex == visitIndex) {
        _setContextNextAction(day, {
          'type': 'shorten_before_stop',
          'severity': 'medium',
          'phase': focus.phase,
          'targetPlaceId': place.id,
          'targetPlaceName': place.name,
          'scheduledTime': item['time']?.toString(),
          'title': '下一站停留時間會被壓縮',
          'message': '${place.name} 的可用營業時段偏短，照原節奏過去可能來不及完整停留。',
          'recommendedAction': '提早出發，或先縮短前一站停留時間。',
        });
      }
      continue;
    }
    if (closeMinute - scheduleStart <= 30) {
      alerts.add(
        _contextAlert(
          type: 'opening_near_close',
          severity: 'medium',
          title: '${place.name} 接近打烊時段',
          message:
              '預計 ${item['time']} 到訪，距離今日打烊只剩 ${closeMinute - scheduleStart} 分鐘。',
        ),
      );
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
      alerts.add(
        _contextAlert(
          type: 'origin_transit_long',
          severity: 'high',
          title: '第一段移動時間很長',
          message: '$fromLabel 到 $toLabel 預估需 $minutes 分鐘（$label），第一天節奏可能偏趕。',
        ),
      );
      suggestions.add('若可行，建議前一晚先接近旅遊城市，或第一天減少景點數。');
      if (focus != null && focus.targetIndex == 0) {
        _setContextNextAction(day, {
          'type': 'origin_transit_too_long',
          'severity': 'high',
          'phase': focus.phase,
          'targetPlaceName': toLabel,
          'title': '出發段過長，建議立即縮減第一天安排',
          'message': '$fromLabel 到 $toLabel 預估需 $minutes 分鐘，第一天前段移動成本過高。',
          'recommendedAction': '優先保留第一站與核心景點，其餘景點往後移或刪減 1 站。',
        });
      }
    } else if (minutes >= 120) {
      alerts.add(
        _contextAlert(
          type: 'origin_transit_long',
          severity: 'medium',
          title: '出發段交通偏長',
          message: '$fromLabel 到 $toLabel 預估需 $minutes 分鐘（$label）。',
        ),
      );
      suggestions.add('第一站後可預留午餐或休息時間，避免一路趕行程。');
      if (focus != null && focus.targetIndex == 0) {
        _setContextNextAction(day, {
          'type': 'origin_transit_long',
          'severity': 'medium',
          'phase': focus.phase,
          'targetPlaceName': toLabel,
          'title': '第一站前交通偏長',
          'message': '$fromLabel 到 $toLabel 需要約 $minutes 分鐘，照原節奏會偏趕。',
          'recommendedAction': '第一站後先預留休息或午餐，後段景點數不要再加。',
        });
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

  final isToday =
      dayDate.year == referenceTime.year &&
      dayDate.month == referenceTime.month &&
      dayDate.day == referenceTime.day;
  if (triggerLinePush && isToday && userId.isNotEmpty) {
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
  final isToday =
      dayDate != null &&
      _reminderDateKey(dayDate) == _reminderDateKey(referenceTime);

  final transitLabel = transit?['label']?.toString().trim() ?? '';
  final fromLabel = transit?['fromLabel']?.toString().trim() ?? '';
  final toLabel = transit?['toLabel']?.toString().trim().isNotEmpty == true
      ? transit!['toLabel']!.toString().trim()
      : place['name']?.toString().trim() ?? '下一站';
  final transitMinutes = _asIntValue(transit?['minutes']);
  final distanceText = transit?['distanceText']?.toString().trim() ?? '';
  // Remind at the recommended departure time instead of relying on the
  // previous stop's end time. This also handles long meal/rest gaps.
  final estimatedTransitMinutes = transitMinutes ?? 20;
  final departureMinute = startMinute - estimatedTransitMinutes;
  final minutesUntilDeparture = departureMinute - nowMinute;
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

  final planPlace = Map<String, dynamic>.from(place);
  final placeModel = _planPlaceToPlace(planPlace);
  final endTime = targetItem['endTime']?.toString() ?? '';
  final durationMinutes =
      _asIntValue(targetItem['durationMinutes']) ??
      (_parseHmToMinute(endTime) != null
          ? _parseHmToMinute(endTime)! - startMinute
          : null);
  final openingHoursText = dayDate == null
      ? null
      : _openingWeekdayText(placeModel, dayDate);
  final navigationUrl = _googleMapsNavigationUrl(
    place: planPlace,
    transitMode: transit?['mode']?.toString(),
  );
  final triggerWindow = _nextStopReminderMinutes();
  final graceWindow = _nextStopReminderGraceMinutes();
  final shouldPush =
      isToday &&
      minutesUntilDeparture <= triggerWindow &&
      minutesUntilDeparture >= -graceWindow &&
      minutesUntil >= -graceWindow;
  return {
    'phase': focus.phase == 'current' ? 'after_current' : 'upcoming',
    'targetIndex': targetIndex,
    'targetPlaceName': place['name']?.toString() ?? '下一站',
    'scheduledTime': scheduledTime,
    'minutesUntil': minutesUntil,
    'departureTime': _minutesToHm(departureMinute),
    'minutesUntilDeparture': minutesUntilDeparture,
    'triggerWindowMinutes': triggerWindow,
    'graceWindowMinutes': graceWindow,
    'fromLabel': fromLabel,
    'toLabel': toLabel,
    'transitLabel': transitLabel,
    'transitMinutes': transitMinutes,
    'distanceText': distanceText,
    'navigationUrl': navigationUrl,
    'endTime': endTime,
    'durationMinutes': durationMinutes,
    'description': placeModel.description,
    'placeId': placeModel.id,
    'tags': placeModel.tags,
    'rating': placeModel.rating,
    'userRatingsTotal': placeModel.userRatingsTotal,
    'imageUrl': placeModel.imageUrl,
    'openingHoursText': openingHoursText,
    'bestVisitTime': _bestVisitTimeLabel(placeModel, scheduledTime),
    'ticketCost': _ticketCostLabel(placeModel),
    'parkingCost': '尚無可靠停車費資料，請以現場公告為準',
    'transportCost': _transportCostLabel(
      transitMode: transit?['mode']?.toString(),
      distanceText: distanceText,
    ),
    'trafficStatus': _trafficStatusLabel(transit),
    'weatherSummary': weather?['summary']?.toString(),
    'rainProbability': _asIntValue(weather?['precipitationProbability']),
    'temporaryStatus': _temporaryPlaceStatusLabel(
      placeModel,
      dayDate: dayDate,
      scheduledTime: scheduledTime,
    ),
    'notes': cautionNotes.take(3).toList(),
    'shouldPush': shouldPush,
  };
}

String _googleMapsNavigationUrl({
  required Map<String, dynamic> place,
  String? transitMode,
}) {
  final lat = _asDoubleValue(place['lat']);
  final lng = _asDoubleValue(place['lng']);
  final destination = lat != null && lng != null && (lat != 0 || lng != 0)
      ? '$lat,$lng'
      : place['name']?.toString().trim() ?? '';
  final travelMode = switch (transitMode?.toLowerCase()) {
    'walk' || 'walking' => 'walking',
    'transit' || 'bus' || 'rail' => 'transit',
    _ => 'driving',
  };
  return Uri.https('www.google.com', '/maps/dir/', {
    'api': '1',
    'destination': destination,
    'travelmode': travelMode,
  }).toString();
}

String _bestVisitTimeLabel(Place place, String scheduledTime) {
  final tags = place.tags.map((tag) => tag.toLowerCase()).toSet();
  if (tags.contains('night_market')) return '傍晚至晚間';
  if (tags.contains('museum') || tags.contains('heritage')) {
    return '開館後至下午閉館前';
  }
  if (_isOutdoorPlace(place)) return '上午或傍晚，避開正午曝曬';
  return scheduledTime.isEmpty ? '依現場人流調整' : '本行程安排於 $scheduledTime';
}

String _ticketCostLabel(Place place) {
  final text = '${place.name} ${place.description}';
  final amount = RegExp(
    r'(?:門票|票價|全票|成人票|入場費|入園費)[^\d]{0,8}(\d{2,5})',
  ).firstMatch(text);
  if (amount != null) return '約 NT\$${amount.group(1)}，請以現場公告為準';
  return switch (_effectivePriceCategory(place)) {
    'free' => '資料顯示可能免費，請以現場公告為準',
    'low' => '低價或小額消費，尚無確切票價',
    'high' => '可能需要付費，尚無確切票價',
    _ => '尚無可靠票價資料',
  };
}

String _transportCostLabel({
  required String? transitMode,
  required String distanceText,
}) {
  return switch (transitMode?.toLowerCase()) {
    'walk' || 'walking' => '步行不另計交通費',
    'transit' || 'bus' || 'rail' => '依實際搭乘路線與票制計費',
    _ => distanceText.isEmpty ? '尚無可靠交通費估算' : '開車費用依油耗、停車與路況而定',
  };
}

String _trafficStatusLabel(Map<String, dynamic>? transit) {
  if (transit == null) return '尚無路段資料';
  final provider = transit['provider']?.toString() ?? '';
  if (provider == 'google_directions') {
    return '已採用 Google 路線時間；尚未提供獨立壅塞等級';
  }
  return '尚無即時壅塞資料';
}

String _temporaryPlaceStatusLabel(
  Place place, {
  required DateTime? dayDate,
  required String scheduledTime,
}) {
  if (dayDate == null) return '尚未確認臨時休館資訊';
  final opening = _openingWindowForDate(place, dayDate);
  final scheduled = _parseHmToMinute(scheduledTime);
  if (opening != null &&
      scheduled != null &&
      (scheduled < opening.$1 || scheduled >= opening.$2)) {
    return '安排時間可能不在一般營業時段，出發前請再次確認';
  }
  return opening == null ? '尚未確認臨時休館資訊' : '一般營業時段可用；臨時異動仍請以官方公告為準';
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
    final aScore =
        (a.rating ?? 0) * 10 -
        _distanceKm(a.lat, a.lng, targetPlace.lat, targetPlace.lng);
    final bScore =
        (b.rating ?? 0) * 10 -
        _distanceKm(b.lat, b.lng, targetPlace.lat, targetPlace.lng);
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
    alerts.add(
      _contextAlert(
        type: 'transit_rain_walk',
        severity: minutes >= 25 ? 'high' : 'medium',
        title: '$fromLabel 到 $toLabel 可能遇雨',
        message: '$label 約 $minutes 分鐘，若下雨可能明顯影響移動體驗。',
      ),
    );
    suggestions.add('下雨時可改搭車或把步行較長的景點順序往後調整。');
  }
  if (rainRisk && isTransit && (minutes >= 45 || lines.length >= 2)) {
    alerts.add(
      _contextAlert(
        type: 'transit_rain_transfer',
        severity: minutes >= 80 ? 'high' : 'medium',
        title: '$fromLabel 到 $toLabel 轉乘風險提高',
        message:
            '$label 約 $minutes 分鐘${lines.isNotEmpty ? '，含 ${lines.join(' / ')}' : ''}，遇雨時轉乘與等車可能更花時間。',
      ),
    );
    suggestions.add('雨勢較大時，保留多 15-20 分鐘轉乘緩衝較穩妥。');
  }
  if (heatRisk && isWalk && minutes >= 15) {
    alerts.add(
      _contextAlert(
        type: 'transit_heat_walk',
        severity: minutes >= 30 ? 'high' : 'medium',
        title: '$fromLabel 到 $toLabel 步行曝曬偏高',
        message: '$label 約 $minutes 分鐘，若正午高溫可能較耗體力。',
      ),
    );
    suggestions.add('高溫時段可優先改搭車，或先插入室內休息點。');
  }
}

Place _planPlaceToPlace(Map<String, dynamic> json) {
  return Place(
    id: json['id']?.toString() ?? json['name']?.toString() ?? '_place_',
    name: json['name']?.toString() ?? '未命名景點',
    tags:
        (json['tags'] as List?)?.map((e) => e.toString()).toList() ?? const [],
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
    final alerts =
        (result['alerts'] as List?)
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList() ??
        const <Map<String, dynamic>>[];
    final upcomingReminder = result['upcomingReminder'] is Map
        ? Map<String, dynamic>.from(result['upcomingReminder'] as Map)
        : null;
    final shouldPushReminder = upcomingReminder?['shouldPush'] == true;
    if (shouldPushReminder && upcomingReminder != null) {
      await _enrichUpcomingReminderLiveData(upcomingReminder);
    }
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
    final persistentReminderKey = 'upcoming|$cooldownKey';
    if (shouldPushReminder &&
        await _lineReminderWasSent(persistentReminderKey)) {
      return false;
    }
    final lastSentAt = _lineContextPushCooldown[cooldownKey];
    final now = DateTime.now().toUtc();
    final cooldownWindow = shouldPushReminder && alerts.isEmpty
        ? const Duration(minutes: 20)
        : const Duration(minutes: 45);
    if (lastSentAt != null && now.difference(lastSentAt) < cooldownWindow) {
      return false;
    }

    final suggestions =
        (result['suggestions'] as List?)?.map((e) => e.toString()).toList() ??
        const <String>[];
    final backupPlans =
        (result['backupPlans'] as List?)
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
      imageUrl: shouldPushReminder
          ? upcomingReminder == null
                ? null
                : upcomingReminder['imageUrl']?.toString()
          : null,
    );
    _lineContextPushCooldown[cooldownKey] = now;
    if (shouldPushReminder) {
      await _markLineReminderSent(persistentReminderKey);
    }
    _log.info('LINE 情境感知提醒已送出：user=$userId lineUserId=$lineUserId');
    return true;
  } catch (error, stack) {
    _log.warning('LINE 情境感知提醒失敗：user=$userId error=$error');
    _log.fine(stack.toString());
    return false;
  }
}

Future<void> _enrichUpcomingReminderLiveData(
  Map<String, dynamic> reminder,
) async {
  final key = _googleMapsServerKey();
  final placeId = reminder['placeId']?.toString().trim() ?? '';
  if (key.isEmpty || placeId.isEmpty) return;
  final details = await _googlePlaceDetails(key: key, placeId: placeId);
  if (details == null) return;

  final businessStatus = details['business_status']?.toString().trim() ?? '';
  final opening = details['current_opening_hours'] is Map
      ? Map<String, dynamic>.from(details['current_opening_hours'] as Map)
      : details['opening_hours'] is Map
      ? Map<String, dynamic>.from(details['opening_hours'] as Map)
      : null;
  final openNow = opening?['open_now'];
  reminder['temporaryStatus'] = switch (businessStatus) {
    'CLOSED_TEMPORARILY' => 'Google Places 顯示暫時停業',
    'CLOSED_PERMANENTLY' => 'Google Places 顯示永久停業',
    _ when openNow == true => 'Google Places 顯示目前營業中',
    _ when openNow == false => 'Google Places 顯示目前未營業',
    _ => reminder['temporaryStatus'],
  };
  reminder['rating'] = _asDoubleValue(details['rating']) ?? reminder['rating'];
  reminder['userRatingsTotal'] =
      _asIntValue(details['user_ratings_total']) ??
      reminder['userRatingsTotal'];
  final weekdayText = opening?['weekday_text'];
  if (weekdayText is List && weekdayText.isNotEmpty) {
    final now = _taipeiNow();
    final weekdayIndex = now.weekday - 1;
    if (weekdayIndex >= 0 && weekdayIndex < weekdayText.length) {
      reminder['openingHoursText'] = weekdayText[weekdayIndex].toString();
    }
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
    final departureTime =
        upcomingReminder['departureTime']?.toString().trim() ?? '';
    final endTime = upcomingReminder['endTime']?.toString() ?? '';
    final transitLabel = upcomingReminder['transitLabel']?.toString() ?? '';
    final transitMinutes = _asIntValue(upcomingReminder['transitMinutes']);
    final distanceText = upcomingReminder['distanceText']?.toString() ?? '';
    final navigationUrl = upcomingReminder['navigationUrl']?.toString() ?? '';
    final description =
        upcomingReminder['description']?.toString().trim() ?? '';
    final tags =
        (upcomingReminder['tags'] as List?)
            ?.map((e) => e.toString())
            .where((e) => e.trim().isNotEmpty)
            .take(5)
            .join('、') ??
        '';
    final rating = _asDoubleValue(upcomingReminder['rating']);
    final ratingCount = _asIntValue(upcomingReminder['userRatingsTotal']);
    final rainProbability = _asIntValue(upcomingReminder['rainProbability']);
    final weatherSummary =
        upcomingReminder['weatherSummary']?.toString().trim() ?? '';
    final notes =
        (upcomingReminder['notes'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];
    lines.add('$dateLabel 下一站提醒：$target');
    if (departureTime.isNotEmpty) {
      lines.add('⏰ 建議 $departureTime 開始前往');
    }
    if (description.isNotEmpty) {
      lines.add('📍 ${_shortLine(description, 140)}');
    }
    if (tags.isNotEmpty) lines.add('🏷️ 類型：$tags');
    if (rating != null) {
      lines.add(
        '⭐ 評分：${rating.toStringAsFixed(1)}'
        '${ratingCount != null ? '（$ratingCount 則評價）' : ''}',
      );
    }
    if (scheduled.isNotEmpty) {
      lines.add(
        '🕒 行程：$scheduled${endTime.isNotEmpty ? '–$endTime' : ''}'
        '；建議停留 ${upcomingReminder['durationMinutes'] ?? '依現場調整'} 分鐘',
      );
    }
    lines.add('🗓️ 營業時間：${upcomingReminder['openingHoursText'] ?? '尚無資料'}');
    lines.add('✨ 最佳時段：${upcomingReminder['bestVisitTime'] ?? '依現場調整'}');
    if (transitLabel.isNotEmpty || transitMinutes != null) {
      lines.add(
        '🚗 路線：${transitLabel.isNotEmpty ? transitLabel : '依目前路況出發'}'
        '${distanceText.isNotEmpty ? '，$distanceText' : ''}'
        '${transitMinutes != null ? '，約 $transitMinutes 分鐘' : ''}',
      );
    }
    if (navigationUrl.isNotEmpty) lines.add('🧭 導航：$navigationUrl');
    if (weatherSummary.isNotEmpty || rainProbability != null) {
      lines.add(
        '🌦️ 天氣：${weatherSummary.isEmpty ? '尚無摘要' : weatherSummary}'
        '${rainProbability != null ? '，降雨機率 $rainProbability%' : ''}',
      );
    }
    lines.add('🚦 交通狀況：${upcomingReminder['trafficStatus'] ?? '尚無即時資料'}');
    lines.add('🏛️ 開放狀態：${upcomingReminder['temporaryStatus'] ?? '出發前請再次確認'}');
    lines.add('🎟️ 門票：${upcomingReminder['ticketCost'] ?? '尚無資料'}');
    lines.add('🅿️ 停車：${upcomingReminder['parkingCost'] ?? '尚無資料'}');
    lines.add('💰 交通費：${upcomingReminder['transportCost'] ?? '尚無資料'}');
    lines.add('🧾 行程總預算：尚未建立可靠總額，請依門票、餐飲與交通實支估算');
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
  return _limitLineMessage(lines.join('\n'));
}

String _shortLine(String value, int maxLength) {
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return normalized.length <= maxLength
      ? normalized
      : '${normalized.substring(0, maxLength)}…';
}

String _limitLineMessage(String value) =>
    value.length <= 4900 ? value : '${value.substring(0, 4899)}…';

Future<bool> _sendLineTomorrowSummaryNotification({
  required User user,
  required Map<String, dynamic> day,
}) async {
  final lineUserId = user.lineUserId?.trim() ?? '';
  final dateText = day['date']?.toString().substring(0, 10) ?? '';
  if (lineUserId.isEmpty || dateText.isEmpty) return false;
  final signature = 'tomorrow|${user.id}|$dateText';
  if (await _lineReminderWasSent(signature)) return false;

  final message = await _buildLineTomorrowSummary(day);
  try {
    await _sendTrackedLinePush(
      to: lineUserId,
      text: message,
      category: 'tomorrow_itinerary_summary',
      userId: user.id,
      username: user.username,
    );
    await _markLineReminderSent(signature);
    return true;
  } catch (error) {
    _log.warning('LINE 前一晚行程摘要失敗：user=${user.id} error=$error');
    return false;
  }
}

Future<String> _buildLineTomorrowSummary(Map<String, dynamic> day) async {
  final dateText = day['date']?.toString().substring(0, 10) ?? '';
  final items =
      (day['items'] as List?)
          ?.whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList() ??
      const <Map<String, dynamic>>[];
  final weather = await _weatherForReminderDay(day);
  final lines = <String>['Smart Travel 明日行程提醒', '📅 日期：$dateText'];
  if (weather != null) {
    final rain = _asIntValue(weather['precipitationProbability']);
    final minTemp = _asDoubleValue(weather['temperatureMin']);
    final maxTemp = _asDoubleValue(weather['temperatureMax']);
    lines.add(
      '🌦️ 天氣：${weather['summary'] ?? '尚無摘要'}'
      '${rain != null ? '，降雨機率 $rain%' : ''}'
      '${minTemp != null && maxTemp != null ? '，${minTemp.round()}–${maxTemp.round()}°C' : ''}',
    );
  }
  lines.add('明日安排：');
  for (final item in items.take(12)) {
    final place = item['place'];
    if (place is! Map) continue;
    final name = place['name']?.toString().trim() ?? '';
    if (name.isEmpty) continue;
    final start = item['time']?.toString() ?? '';
    final end = item['endTime']?.toString() ?? '';
    final transit = item['transitToNext'];
    lines.add('• $start${end.isNotEmpty ? '–$end' : ''}｜$name');
    if (transit is Map &&
        transit['label']?.toString().trim().isNotEmpty == true) {
      lines.add(
        '  下一段：${transit['label']}'
        '${transit['distanceText']?.toString().trim().isNotEmpty == true ? '，${transit['distanceText']}' : ''}'
        '${_asIntValue(transit['minutes']) != null ? '，約 ${_asIntValue(transit['minutes'])} 分鐘' : ''}',
      );
    }
  }
  lines.add('請今晚確認門票、預約、交通方式與雨具；即時異動以官方公告為準。');
  return _limitLineMessage(lines.join('\n'));
}

Future<Map<String, dynamic>?> _weatherForReminderDay(
  Map<String, dynamic> day,
) async {
  if (day['weather'] is Map) {
    return Map<String, dynamic>.from(day['weather'] as Map);
  }
  final dateText = day['date']?.toString().substring(0, 10) ?? '';
  final coordinate = _resolveDayWeatherCoordinate(day);
  if (dateText.isEmpty || coordinate == null) return null;
  final forecast = await _fetchDailyWeatherForecast(
    lat: coordinate.$1,
    lng: coordinate.$2,
    startDate: dateText,
    endDate: dateText,
  );
  return forecast[dateText];
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
    _log.info(
      'LINE 綁定成功：user=${target.id} username=${target.username} lineUserId=$lineUserId code=$text',
    );
    await _sendTrackedLinePush(
      to: lineUserId,
      text: 'LINE 綁定成功。之後你會在這裡收到 Smart Travel 的行程提醒與通知。回到 App 按「重新整理」即可看到最新狀態。',
      category: 'line_linked',
      userId: target.id,
      username: target.username,
    );
  } catch (error, stack) {
    _log.severe(
      'LINE 綁定處理失敗：code=$text user=${target.id} lineUserId=$lineUserId',
      error,
      stack,
    );
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
  return List<Place>.from(places)..sort((a, b) {
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
  return List<Place>.from(places)..sort((a, b) {
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
  final hasPrice =
      _effectivePriceLevel(place) != null ||
      (_effectivePriceCategory(place)?.trim().isNotEmpty ?? false);
  final hasOpeningHours =
      place.openingHours != null && place.openingHours!.isNotEmpty;
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
  String? requirementsText,
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
  var places = await _store.listPlaces();
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
  final requirementSignals = _extractRequirementSignals(requirementsText);
  final effectiveWishlistPlaces = <String>{
    ...wishlistPlaces
        .map((place) => place.trim())
        .where((place) => place.isNotEmpty),
    ..._extractRequiredPlaceNames(requirementsText ?? ''),
  }.toList();
  final preferredTags = {
    ...interests.map((tag) => tag.toLowerCase()),
    ...requirementSignals.preferredTags.map((tag) => tag.toLowerCase()),
  };
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
        (city) =>
            containsLoc(place.city, city) || containsLoc(place.address, city),
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
    requirementSignals: requirementSignals,
  );
  final discoveredPlaces = await _discoverItineraryPlacesFromGoogle(
    existingPlaces: places,
    currentCandidates: candidates,
    interests: interests,
    preferredTags: preferredTags,
    requirementSignals: requirementSignals,
    totalDays: totalDays,
    destinationCities: destinationCities,
    location: location,
    requirementsText: requirementsText,
    wishlistPlaces: effectiveWishlistPlaces,
  );
  if (discoveredPlaces.isNotEmpty) {
    final byId = <String, Place>{for (final place in places) place.id: place};
    for (final place in discoveredPlaces) {
      byId[place.id] = place;
    }
    places = byId.values.toList();
    final candidateIds = candidates.map((place) => place.id).toSet();
    final extraCandidates = discoveredPlaces.where((place) {
      if (candidateIds.contains(place.id)) return false;
      return matchesCityScope(place) && matchesTownshipScope(place);
    }).toList();
    if (extraCandidates.isNotEmpty) {
      candidates = _filterCandidatesByTripPurpose(
        [...candidates, ...extraCandidates],
        normalizedTripPurpose,
        requirementSignals: requirementSignals,
      );
    }
  }
  if (requirementSignals.preferNightMarket) {
    final candidateIds = candidates.map((place) => place.id).toSet();
    final nightMarkets = places.where((place) {
      return !candidateIds.contains(place.id) &&
          matchesCityScope(place) &&
          _isNightMarketPlace(place);
    });
    candidates = [...candidates, ...nightMarkets];
  }
  final requiredPlaceCandidates = <Place>[];
  for (final requestedName in effectiveWishlistPlaces) {
    final match = _findRequestedPlaceMatch(
      places.where(matchesCityScope),
      requestedName,
    );
    if (match == null ||
        requiredPlaceCandidates.any((place) => place.id == match.id)) {
      continue;
    }
    requiredPlaceCandidates.add(match);
    if (!candidates.any((place) => place.id == match.id)) {
      candidates.add(match);
    }
  }
  final requiredPlaceIds = requiredPlaceCandidates
      .map((place) => place.id)
      .toSet();

  final plannerAssist = await _buildAiPlannerAssist(
    allPlaces: places,
    candidates: candidates,
    interests: interests,
    startDate: startDate,
    endDate: endDate,
    totalDays: totalDays,
    originCity: originCity,
    destinationCities: destinationCities,
    requirementsText: requirementsText,
    requirementSignals: requirementSignals,
    tripPurpose: normalizedTripPurpose,
    travelBehavior: normalizedTravelBehavior,
    location: location,
    budget: budget,
    people: people,
    dayStartTime: dayStartTime,
    dayEndTime: dayEndTime,
    extraSpots: extraSpots,
    wishlistPlaces: effectiveWishlistPlaces,
  );
  final prioritizedCities = _stringListFromJson(
    plannerAssist['prioritizedCities'],
    maxItems: 6,
  ).map(_normalizeLocationText).where((e) => e.isNotEmpty).toSet();
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
  final wishKeywords = effectiveWishlistPlaces
      .map(_normalizeLocationText)
      .where((e) => e.isNotEmpty)
      .toList();
  final originAnchor = _resolveOriginAnchor(
    places: places,
    originCity: normalizedOriginCity,
  );
  final formalPlanReviewBoosts = await _loadFormalPlanReviewPlaceBoosts();
  final baseScores = <String, double>{
    for (final place in candidates)
      place.id:
          _scorePlace(
            place,
            preferredTags: preferredTags,
            targetPrice: targetPrice,
            weights: weights,
            requirementSignals: requirementSignals,
            originAnchor: originAnchor,
          ) +
          _plannerPriorityBoost(place, prioritizedCities) +
          _wishlistBoost(place, wishKeywords) +
          (formalPlanReviewBoosts[place.id] ?? 0),
  };
  candidates.sort(
    (a, b) => (baseScores[b.id] ?? 0).compareTo(baseScores[a.id] ?? 0),
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
    final requiresNightMarketToday =
        requirementSignals.preferNightMarket &&
        (requirementSignals.nightMarketDayIndex ?? 0) == dayIndex;
    if (requiresNightMarketToday) {
      dayPreferredEndMinute = max(dayPreferredEndMinute, 21 * 60 + 30);
    }
    if ((dayStartTime == null || dayStartTime.trim().isEmpty) &&
        dayIndex == 0) {
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
    final dayDailyMinutesBudget = min(
      weights.dayMinutesBudget,
      dayTimeWindowMinutes,
    );
    final dayStayMinutesBudget = max(
      180,
      (dayDailyMinutesBudget * weights.stayBudgetRatio).round(),
    );
    final items = <Map<String, dynamic>>[];
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
        score += _openingFeasibilityScore(
          place,
          dayDate: dayDate,
          dayStartMinute: dayPreferredStartMinute,
          dayEndMinute: dayPreferredEndMinute,
        );
        adjustedScores[place.id] = score;
      }

      var dayPicked = _selectDayPlacesByBackpacker(
        candidates: remaining,
        scores: adjustedScores,
        maxStops: perDay,
        stayBudgetMinutes: dayStayMinutesBudget,
        weights: weights,
        requirementSignals: requirementSignals,
        plannerAssist: plannerAssist,
      );
      if (dayPicked.isEmpty) {
        dayPicked = [remaining.first];
      }
      final requiredForDay = <Place>[
        for (
          var i = dayIndex;
          i < requiredPlaceCandidates.length;
          i += totalDays
        )
          if (remaining.any(
            (place) => place.id == requiredPlaceCandidates[i].id,
          ))
            requiredPlaceCandidates[i],
      ];
      if (requiredForDay.isNotEmpty) {
        final selectedIds = dayPicked.map((place) => place.id).toSet();
        dayPicked = [
          ...requiredForDay.where((place) => !selectedIds.contains(place.id)),
          ...dayPicked,
        ];
        while (dayPicked.length > perDay) {
          final removableIndex = dayPicked.lastIndexWhere(
            (place) => !requiredPlaceIds.contains(place.id),
          );
          if (removableIndex < 0) break;
          dayPicked.removeAt(removableIndex);
        }
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
        protectedPlaceIds: requiredPlaceIds,
      );
      if (requiresNightMarketToday) {
        ordered = _ensureNightMarketInRoute(
          route: ordered,
          candidates: remaining,
          scores: adjustedScores,
          maxStops: perDay,
        );
      }
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
      if (requiresNightMarketToday) {
        ordered = _moveNightMarketToEnd(ordered);
      }

      var currentMinute = dayPreferredStartMinute;
      var hadLunchBreak = false;
      var hadDinnerBreak = false;
      for (var i = 0; i < ordered.length; i++) {
        final place = ordered[i];
        final nextPlace = i < ordered.length - 1 ? ordered[i + 1] : null;
        if (requiresNightMarketToday && _isNightMarketPlace(place)) {
          currentMinute = max(currentMinute, 17 * 60 + 30);
        }

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
        if (!requiresNightMarketToday &&
            !hadDinnerBreak &&
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
        if (!requiresNightMarketToday &&
            !hadDinnerBreak &&
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
    requirementsText: requirementsText,
    tripPurpose: normalizedTripPurpose,
    travelBehavior: normalizedTravelBehavior,
    location: location,
    budget: budget,
    people: people,
    targetPrice: targetPrice,
    allowLlm: plannerAssist['source'] != 'gemini',
  );
  final mergedInsight = _mergePlannerAssistIntoInsight(
    insight: insight,
    plannerAssist: plannerAssist,
  );
  _attachTravelHighlightsToDays(days, mergedInsight['stopHighlights']);
  final scheduledPlaceIds = globallyPicked.map((place) => place.id).toSet();
  final scheduledRequiredPlaces = requiredPlaceCandidates
      .where((place) => scheduledPlaceIds.contains(place.id))
      .map((place) => place.name)
      .toList();
  final missingRequiredPlaces = effectiveWishlistPlaces.where((requestedName) {
    final match = _findRequestedPlaceMatch(
      requiredPlaceCandidates,
      requestedName,
    );
    return match == null || !scheduledPlaceIds.contains(match.id);
  }).toList();

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
      'wishlistPlaces': effectiveWishlistPlaces,
      'requiredPlacesScheduled': scheduledRequiredPlaces,
      'missingRequiredPlaces': missingRequiredPlaces,
      'requirementsSignals': requirementSignals.toJson(),
      'weights': weights.toJson(),
      'insightSource': mergedInsight['source'],
      'plannerAssist': plannerAssist,
      'discoveredPlaces': discoveredPlaces.map(_placeToApiJson).toList(),
      'placeDiscovery': {
        'enabled': _googleMapsServerKey().isNotEmpty,
        'newPlacesImported': discoveredPlaces.length,
        'selectedOnlinePlaces': globallyPicked
            .where((place) => place.source == 'google_place_discovery')
            .map((place) => place.name)
            .toList(),
        'selectedOnlinePlaceCount': globallyPicked
            .where((place) => place.source == 'google_place_discovery')
            .length,
        'source': 'google_places_verified',
      },
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
    },
    'insight': mergedInsight,
    'days': days,
  };
}

Future<List<Place>> _discoverItineraryPlacesFromGoogle({
  required List<Place> existingPlaces,
  required List<Place> currentCandidates,
  required List<String> interests,
  required Set<String> preferredTags,
  required _RequirementSignals requirementSignals,
  required int totalDays,
  required List<String> destinationCities,
  required String? location,
  required String? requirementsText,
  required List<String> wishlistPlaces,
}) async {
  final key = _googleMapsServerKey();
  if (key.trim().isEmpty) {
    return const <Place>[];
  }

  final hasSpecificRequirements =
      (requirementsText ?? '').trim().length >= 6 ||
      !requirementSignals.isEmpty;
  final minUsefulCandidates = hasSpecificRequirements
      ? max(48, totalDays * 18)
      : max(24, totalDays * 10);
  final tagDiversity = currentCandidates
      .expand((place) => place.tags.map((tag) => tag.toLowerCase()))
      .toSet()
      .length;
  final shouldDiscover =
      (Platform.environment['PLACE_DISCOVERY_ALWAYS'] ?? 'true')
              .toLowerCase() !=
          'false' ||
      hasSpecificRequirements ||
      currentCandidates.length < minUsefulCandidates ||
      tagDiversity < (hasSpecificRequirements ? 6 : 4);
  if (!shouldDiscover) {
    return const <Place>[];
  }

  final cityHints = <String>{
    ...destinationCities
        .map((city) => city.trim())
        .where((city) => city.isNotEmpty),
    if (_parseLocationParts(location).$1 != null)
      _parseLocationParts(location).$1!.trim(),
  }.where((city) => city.isNotEmpty).toList();
  if (cityHints.isEmpty) {
    return const <Place>[];
  }

  final queries = await _buildPlaceDiscoveryQueries(
    existingPlaces: existingPlaces,
    currentCandidates: currentCandidates,
    interests: interests,
    preferredTags: preferredTags,
    requirementSignals: requirementSignals,
    totalDays: totalDays,
    cityHints: cityHints,
    requirementsText: requirementsText,
    wishlistPlaces: wishlistPlaces,
  );
  if (queries.isEmpty) {
    return const <Place>[];
  }

  _log.info(
    'Place discovery started: cities=${cityHints.join(',')} candidates=${currentCandidates.length} tagDiversity=$tagDiversity queries=${queries.length}',
  );

  final normalizedExisting = existingPlaces
      .map((place) => _normalizePlaceNameForMatch(place.name))
      .where((name) => name.isNotEmpty)
      .toSet();
  final imported = <Place>[];
  final importedKeys = <String>{};
  final configuredMaxImports =
      int.tryParse(Platform.environment['PLACE_DISCOVERY_MAX_IMPORTS'] ?? '') ??
      max(24, totalDays * 10);
  final maxImports = configuredMaxImports.clamp(8, 40);

  for (final query in queries.take(18)) {
    if (imported.length >= maxImports) break;
    final results = await _googlePlaceSearch(
      key: key,
      path: '/maps/api/place/textsearch/json',
      params: {'query': query, 'language': 'zh-TW', 'region': 'tw'},
    );
    final requestedTarget = wishlistPlaces
        .where(
          (place) =>
              place.trim().isNotEmpty &&
              _normalizeLocationText(
                query,
              ).contains(_normalizeLocationText(place)),
        )
        .firstOrNull;
    final ranked =
        results.where((result) {
          return _isUsefulDiscoveredPlaceCandidate(
            result,
            cityHints: cityHints,
          );
        }).toList()..sort((a, b) {
          final aScore =
              _scoreDiscoveredGooglePlace(a, cityHints: cityHints) +
              (requestedTarget == null
                  ? 0
                  : _scoreGooglePlaceCandidate(
                      a,
                      rawName: requestedTarget,
                      cityHint: cityHints.first,
                    ));
          final bScore =
              _scoreDiscoveredGooglePlace(b, cityHints: cityHints) +
              (requestedTarget == null
                  ? 0
                  : _scoreGooglePlaceCandidate(
                      b,
                      rawName: requestedTarget,
                      cityHint: cityHints.first,
                    ));
          return bScore.compareTo(aScore);
        });
    // Check several results because the top result is often already in the
    // database. Stopping at rank one prevented discovery from adding variety.
    for (final result in ranked.take(12)) {
      if (imported.length >= maxImports) break;
      final placeId = result['place_id']?.toString().trim() ?? '';
      Map<String, dynamic> hydrated = result;
      if (placeId.isNotEmpty) {
        final details = await _googlePlaceDetails(key: key, placeId: placeId);
        if (details != null) {
          hydrated = {...result, 'details': details};
        }
      }
      var place = _buildPlaceFromGoogleResult(
        key: key,
        result: hydrated,
        fallbackName: result['name']?.toString().trim() ?? query,
        fallbackCity: cityHints.first,
      );
      place = _normalizePlaceForStorage(
        _copyPlaceWithSource(place, source: 'google_place_discovery'),
      );
      final normalizedName = _normalizePlaceNameForMatch(place.name);
      final keyPart =
          '$normalizedName|${_normalizeLocationText(place.address)}';
      if (normalizedName.isEmpty ||
          normalizedExisting.contains(normalizedName) ||
          importedKeys.contains(keyPart)) {
        continue;
      }
      if (!_placeMatchesAnyCityHint(place, cityHints)) {
        continue;
      }
      await _store.upsertPlace(place);
      imported.add(place);
      importedKeys.add(keyPart);
    }
  }

  _log.info('Place discovery completed: imported=${imported.length}');
  return imported;
}

Future<List<String>> _buildPlaceDiscoveryQueries({
  required List<Place> existingPlaces,
  required List<Place> currentCandidates,
  required List<String> interests,
  required Set<String> preferredTags,
  required _RequirementSignals requirementSignals,
  required int totalDays,
  required List<String> cityHints,
  required String? requirementsText,
  required List<String> wishlistPlaces,
}) async {
  final requiredQueries = <String>[
    for (final city in cityHints)
      for (final place in wishlistPlaces)
        if (place.trim().isNotEmpty) '$city ${place.trim()}',
  ];
  final fallback = <String>[
    ...requiredQueries,
    ..._ruleBasedPlaceDiscoveryQueries(
      preferredTags: preferredTags,
      requirementSignals: requirementSignals,
      cityHints: cityHints,
      requirementsText: requirementsText,
    ),
  ].toSet().toList();
  final enableDiscoveryLlm =
      (Platform.environment['PLACE_DISCOVERY_LLM'] ?? 'true').toLowerCase() !=
      'false';
  if (!_isLlmConfigured() || !enableDiscoveryLlm) {
    return fallback;
  }

  final existingNames = existingPlaces
      .take(120)
      .map((place) => place.name)
      .where((name) => name.trim().isNotEmpty)
      .join('、');
  final candidateNames = currentCandidates
      .take(30)
      .map((place) => place.name)
      .where((name) => name.trim().isNotEmpty)
      .join('、');
  try {
    final llmResult = await _generateJsonWithLlm(
      feature: 'place_discovery',
      systemPrompt:
          '你是台灣旅遊資料補強助手。只輸出 JSON，任務是產生 Google Places Text Search 查詢字串，不直接編造行程。',
      messages: [
        {
          'role': 'user',
          'content':
              '''
請先理解使用者真正想要的旅遊體驗，再產生 12 到 18 個 Google Places 搜尋查詢，讓後端驗證景點並補進資料庫。

固定 JSON 格式：
{
  "queries": ["臺中市 博物館 戶外 親子 景點", "臺中市 夜市"]
}

規則：
- 只能回傳 JSON，不要加說明文字。
- 查詢要包含城市名稱。
- 至少一半查詢要是你依需求推薦的「具名景點」，格式如「臺中市 國立自然科學博物館」；後端會用 Google Places 驗證，找不到就不採用。
- 其餘查詢使用「城市 + 體驗類型」，用來探索你不知道名稱的新景點。
- 查詢目標以實際可到訪景點為主；除非需求明確提到夜市或美食，否則避免只查餐廳。
- 不要重複目前候選或資料庫已有景點，優先尋找能增加行程多樣性的新景點。
- 必須優先遵守使用者原句，例如室內多一點、百貨逛街、情侶約會、低步行負擔、拍照等。
- 使用者指定必去景點必須原名加入查詢：${wishlistPlaces.isEmpty ? '無' : wishlistPlaces.join('、')}
- 具名景點可以大膽提出，但不得直接當成已驗證資料，最終由 Google Places 結果決定是否採用。

城市：${cityHints.join('、')}
天數：$totalDays
使用者興趣：${interests.isEmpty ? '未提供' : interests.join('、')}
需求標籤：${preferredTags.isEmpty ? '未提供' : preferredTags.join('、')}
需求摘要：${requirementSignals.summary.isEmpty ? '無' : requirementSignals.summary}
補充需求：${requirementsText == null || requirementsText.trim().isEmpty ? '未提供' : requirementsText}
目前候選：${candidateNames.isEmpty ? '無' : candidateNames}
資料庫已有景點範例：${existingNames.isEmpty ? '無' : existingNames}
''',
        },
      ],
      temperature: 0.35,
    );
    final parsed = _extractJsonMap(llmResult.text);
    final queries = _stringListFromJson(
      parsed?['queries'],
      maxItems: 18,
    ).where((query) => query.trim().length >= 3).toList();
    _recordAiUsage(
      _AiUsageRecord(
        feature: 'place_discovery',
        model: llmResult.usageModelLabel,
        success: queries.isNotEmpty,
        latencyMs: llmResult.latencyMs,
        statusCode: llmResult.statusCode,
        promptTokens: llmResult.promptTokens,
        completionTokens: llmResult.completionTokens,
        totalTokens: llmResult.totalTokens,
        error: queries.isEmpty ? 'LLM 未產生可用搜尋查詢' : null,
      ),
    );
    return queries.isEmpty
        ? fallback
        : [...queries, ...fallback].toSet().toList();
  } catch (error) {
    if (error is! _LlmRequestException) {
      _recordAiUsage(
        _AiUsageRecord(
          feature: 'place_discovery',
          model: '${_currentLlmProvider()}:${_resolvedLlmModel()}',
          success: false,
          latencyMs: 0,
          error: error.toString(),
        ),
      );
    }
    _log.warning('LLM place discovery fallback to rule-based: $error');
    return fallback;
  }
}

List<String> _ruleBasedPlaceDiscoveryQueries({
  required Set<String> preferredTags,
  required _RequirementSignals requirementSignals,
  required List<String> cityHints,
  required String? requirementsText,
}) {
  final queryTypes = <String>{};
  final normalizedRequirements = _normalizeLocationText(requirementsText ?? '');
  if (preferredTags.contains('museum') ||
      normalizedRequirements.contains(_normalizeLocationText('博物館'))) {
    queryTypes.addAll(const ['博物館', '美術館', '文化園區']);
  }
  if (preferredTags.contains('night_market') ||
      preferredTags.contains('street_food') ||
      normalizedRequirements.contains(_normalizeLocationText('夜市'))) {
    queryTypes.addAll(const ['夜市', '老街 小吃']);
  }
  if (requirementSignals.preferOutdoor ||
      preferredTags.contains('national_park') ||
      preferredTags.contains('lake_river')) {
    queryTypes.addAll(const ['戶外 景點', '公園 步道', '濕地 景觀']);
  }
  if (requirementSignals.preferIndoor ||
      preferredTags.contains('department_store') ||
      preferredTags.contains('museum')) {
    queryTypes.addAll(const ['室內 景點', '百貨 商場', '博物館 美術館', '展覽 文化館']);
  }
  if (requirementSignals.preferPhotoSpots) {
    queryTypes.addAll(const ['拍照 景點', '景觀台']);
  }
  if (preferredTags.contains('creative_park')) {
    queryTypes.add('文創園區');
  }
  if (queryTypes.isEmpty) {
    queryTypes.addAll(const [
      '熱門景點',
      '特色景點',
      '文化體驗',
      '在地人推薦 景點',
      '新景點',
      '雨天備案',
    ]);
  }
  return [
    for (final city in cityHints)
      for (final type in queryTypes) '$city $type',
  ];
}

bool _isUsefulDiscoveredPlaceCandidate(
  Map<String, dynamic> result, {
  required List<String> cityHints,
}) {
  final name = result['name']?.toString().trim() ?? '';
  if (name.isEmpty) return false;
  final address =
      result['formatted_address']?.toString().trim() ??
      result['vicinity']?.toString().trim() ??
      '';
  final normalizedAddress = _normalizeLocationText(address);
  if (normalizedAddress.isNotEmpty &&
      !cityHints.any(
        (city) => normalizedAddress.contains(_normalizeLocationText(city)),
      )) {
    return false;
  }
  final types =
      (result['types'] as List?)
          ?.map((e) => e.toString().trim().toLowerCase())
          .where((e) => e.isNotEmpty)
          .toSet() ??
      <String>{};
  const disallowed = <String>{
    'lodging',
    'real_estate_agency',
    'local_government_office',
    'police',
    'hospital',
    'bank',
    'atm',
    'gas_station',
    'parking',
  };
  if (types.any(disallowed.contains)) return false;
  final isFoodOnly =
      types.contains('restaurant') ||
      types.contains('meal_takeaway') ||
      types.contains('food') ||
      types.contains('bakery');
  if (isFoodOnly) return false;
  final hasPlaceSignal =
      types.contains('tourist_attraction') ||
      types.contains('museum') ||
      types.contains('park') ||
      types.contains('art_gallery') ||
      types.contains('amusement_park') ||
      types.contains('zoo') ||
      types.contains('aquarium') ||
      types.contains('shopping_mall') ||
      types.contains('university') ||
      types.contains('natural_feature') ||
      types.contains('place_of_worship') ||
      types.contains('point_of_interest') ||
      types.contains('establishment');
  return hasPlaceSignal;
}

int _scoreDiscoveredGooglePlace(
  Map<String, dynamic> result, {
  required List<String> cityHints,
}) {
  var score = 0;
  final address =
      result['formatted_address']?.toString().trim() ??
      result['vicinity']?.toString().trim() ??
      '';
  final normalizedAddress = _normalizeLocationText(address);
  if (cityHints.any(
    (city) => normalizedAddress.contains(_normalizeLocationText(city)),
  )) {
    score += 250;
  }
  final types =
      (result['types'] as List?)
          ?.map((e) => e.toString().trim().toLowerCase())
          .where((e) => e.isNotEmpty)
          .toSet() ??
      <String>{};
  if (types.contains('tourist_attraction')) score += 180;
  if (types.contains('museum') || types.contains('art_gallery')) score += 120;
  if (types.contains('park') || types.contains('natural_feature')) score += 90;
  if (types.contains('point_of_interest')) score += 60;
  score += min(_asIntValue(result['user_ratings_total']) ?? 0, 700);
  final rating = _asDoubleValue(result['rating']) ?? 0;
  if (rating >= 4.2) score += 60;
  return score;
}

bool _placeMatchesAnyCityHint(Place place, List<String> cityHints) {
  final haystack = _normalizeLocationText('${place.city} ${place.address}');
  if (haystack.isEmpty) return true;
  return cityHints.any(
    (city) => haystack.contains(_normalizeLocationText(city)),
  );
}

Place _copyPlaceWithSource(Place place, {required String source}) {
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
    priceLevel: place.priceLevel,
    priceCategory: place.priceCategory,
    openingHours: place.openingHours,
    source: source,
    updatedAt: DateTime.now().toUtc(),
  );
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
  required _RequirementSignals requirementSignals,
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
    _ when !requirementSignals.isEmpty =>
      ranked.take(min(48, ranked.length)).toList(),
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
    final pickedPlaces = [for (final idx in picked) pool[idx]];
    final matchedCount = picked.where((idx) => purposeMatchedFlags[idx]).length;
    final mismatchCount = picked.length - matchedCount;
    final purposeBonus = requirementSignals.isEmpty
        ? switch (weights.tripPurpose) {
            'relax' => matchedCount * 2.1 - mismatchCount * 1.5,
            'couple' => matchedCount * 2.3 - mismatchCount * 1.6,
            'family' => matchedCount * 2.5 - mismatchCount * 1.9,
            'explore' => _exploreSelectionBonus(pickedPlaces),
            _ => 0.0,
          }
        : matchedCount * 0.15;
    final scoreWithCountBonus =
        score +
        picked.length * 0.12 +
        purposeBonus -
        _selectionDistancePenalty(pickedPlaces, weights) -
        _selectionTagOverlapPenalty(pickedPlaces, weights);
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

double _selectionDistancePenalty(List<Place> places, _PlannerWeights weights) {
  if (places.length <= 1) return 0;
  var totalKm = 0.0;
  var pairs = 0;
  for (var i = 0; i < places.length - 1; i++) {
    for (var j = i + 1; j < places.length; j++) {
      totalKm += _distanceKm(
        places[i].lat,
        places[i].lng,
        places[j].lat,
        places[j].lng,
      );
      pairs++;
    }
  }
  return (totalKm / max(1, pairs)) * weights.distancePenaltyWeight * 0.45;
}

double _selectionTagOverlapPenalty(
  List<Place> places,
  _PlannerWeights weights,
) {
  if (places.length <= 1) return 0;
  var overlap = 0;
  for (var i = 0; i < places.length - 1; i++) {
    final tags = places[i].tags.map((tag) => tag.toLowerCase()).toSet();
    for (var j = i + 1; j < places.length; j++) {
      overlap += places[j].tags
          .map((tag) => tag.toLowerCase())
          .where(tags.contains)
          .length;
    }
  }
  return overlap * weights.diversityPenaltyWeight * 0.35;
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
  Set<String> protectedPlaceIds = const <String>{},
}) {
  var output = List<Place>.from(route);
  while (output.length > 1 &&
      _estimateDayMinutes(output, weights, plannerAssist: plannerAssist) >
          dailyMinutesBudget) {
    var removeIdx = 0;
    var removeScore = 999999.0;
    for (var i = 0; i < output.length; i++) {
      final place = output[i];
      if (protectedPlaceIds.contains(place.id)) continue;
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
    if (protectedPlaceIds.contains(output[removeIdx].id)) break;
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

double _openingFeasibilityScore(
  Place place, {
  required DateTime dayDate,
  required int dayStartMinute,
  required int dayEndMinute,
}) {
  final openingHours = place.openingHours;
  if (openingHours == null || openingHours['periods'] is! List) {
    return 0;
  }
  final window = _openingWindowForDate(place, dayDate);
  if (window == null) {
    return -12;
  }
  final overlapStart = max(dayStartMinute, window.$1);
  final overlapEnd = min(dayEndMinute, window.$2);
  final overlapMinutes = overlapEnd - overlapStart;
  if (overlapMinutes < 45) {
    return -8;
  }
  if (overlapMinutes >= 180) {
    return 0.8;
  }
  return 0.35;
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
  final lat =
      cityPlaces.map((place) => place.lat).reduce((a, b) => a + b) /
      cityPlaces.length;
  final lng =
      cityPlaces.map((place) => place.lng).reduce((a, b) => a + b) /
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
  final exactWindow = dayDate == null
      ? null
      : _openingWindowForDate(place, dayDate);

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

int _estimateStayMinutes(Place place, {Map<String, dynamic>? plannerAssist}) {
  var minutes = 70;
  final tags = place.tags.map((e) => e.toLowerCase()).toSet();
  final text = '${place.name} ${place.description} ${place.tags.join(' ')}'
      .toLowerCase();

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
  if (hasAny([
    'museum',
    'heritage',
    'creative_park',
    'gallery',
    'exhibition',
  ])) {
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
  final stayStyle = plannerAssist?['stayStyle']
      ?.toString()
      .trim()
      .toLowerCase();
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
  final stayStyle = plannerAssist?['stayStyle']
      ?.toString()
      .trim()
      .toLowerCase();
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

Future<Map<String, dynamic>?> _fetchTransitSegmentFromGoogle({
  required Place from,
  required Place to,
  required DateTime dayDate,
  required int departureMinute,
  required _PlannerWeights weights,
}) async {
  final key = _googleMapsServerKey();
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

  final ratio = estimatedMinutes <= 0
      ? 99.0
      : durationMinutes / estimatedMinutes;
  if (distanceKm >= 80 && durationMinutes >= 5 * 60) {
    return false;
  }
  if (distanceKm >= 40 &&
      ratio >= 2.8 &&
      durationMinutes - estimatedMinutes >= 120) {
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
  required String? requirementsText,
  required String? tripPurpose,
  required String? travelBehavior,
  required String? location,
  required int? budget,
  required int? people,
  required String? targetPrice,
  required bool allowLlm,
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
  if (!allowLlm || !_isLlmConfigured()) {
    return fallback;
  }

  try {
    final prompt = _buildItineraryInsightPrompt(
      allPlaces: allPlaces,
      days: days,
      interests: interests,
      originCity: originCity,
      destinationCities: destinationCities,
      requirementsText: requirementsText,
      tripPurpose: tripPurpose,
      travelBehavior: travelBehavior,
      location: location,
      budget: budget,
      people: people,
      targetPrice: targetPrice,
    );
    final llmResult = await _generateJsonWithLlm(
      feature: 'itinerary_insight',
      systemPrompt: '你是資深旅遊規劃師。請用繁體中文，清楚說明排程理由。只能回傳 JSON 物件。',
      messages: [
        {'role': 'user', 'content': prompt},
      ],
      temperature: 0.35,
    );
    final aiJson = _extractJsonMap(llmResult.text);
    if (aiJson == null) {
      _recordAiUsage(
        _AiUsageRecord(
          feature: 'itinerary_insight',
          model: llmResult.usageModelLabel,
          success: false,
          latencyMs: llmResult.latencyMs,
          statusCode: llmResult.statusCode,
          promptTokens: llmResult.promptTokens,
          completionTokens: llmResult.completionTokens,
          totalTokens: llmResult.totalTokens,
          error: 'LLM 回傳內容無法解析成 JSON',
        ),
      );
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
    final stopHighlights = _mergeStopHighlights(
      aiJson['stop_highlights'],
      fallback['stopHighlights'],
    );

    final summary = aiJson['summary']?.toString().trim();
    final routeReason = aiJson['route_reason']?.toString().trim();
    final userLikeReason = aiJson['user_like_reason']?.toString().trim();
    final pacing = aiJson['pacing']?.toString().trim();
    final mealPlan = aiJson['meal_plan']?.toString().trim();
    if ((summary == null || summary.isEmpty) &&
        (routeReason == null || routeReason.isEmpty) &&
        (userLikeReason == null || userLikeReason.isEmpty)) {
      _recordAiUsage(
        _AiUsageRecord(
          feature: 'itinerary_insight',
          model: llmResult.usageModelLabel,
          success: false,
          latencyMs: llmResult.latencyMs,
          statusCode: llmResult.statusCode,
          promptTokens: llmResult.promptTokens,
          completionTokens: llmResult.completionTokens,
          totalTokens: llmResult.totalTokens,
          error: 'LLM 回傳缺少核心欄位',
        ),
      );
      return fallback;
    }
    _recordAiUsage(
      _AiUsageRecord(
        feature: 'itinerary_insight',
        model: llmResult.usageModelLabel,
        success: true,
        latencyMs: llmResult.latencyMs,
        statusCode: llmResult.statusCode,
        promptTokens: llmResult.promptTokens,
        completionTokens: llmResult.completionTokens,
        totalTokens: llmResult.totalTokens,
      ),
    );
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
      'stopHighlights': stopHighlights,
      'source': llmResult.provider,
    };
  } catch (error) {
    if (error is! _LlmRequestException) {
      _recordAiUsage(
        _AiUsageRecord(
          feature: 'itinerary_insight',
          model: '${_currentLlmProvider()}:${_resolvedLlmModel()}',
          success: false,
          latencyMs: 0,
          error: error.toString(),
        ),
      );
    }
    _log.warning('LLM insight fallback to rule-based: $error');
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

  final avgStayMinutes = stopCount == 0
      ? 0
      : (totalStayMinutes / stopCount).round();
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
    if (longestTransitMinutes >= 90)
      '最長交通段約 $longestTransitMinutes 分鐘，可考慮把遠距景點拆到不同天。',
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
    'stopHighlights': _buildRuleBasedStopHighlights(days),
    'source': 'rule',
  };
}

String _buildItineraryInsightPrompt({
  required List<Place> allPlaces,
  required List<Map<String, dynamic>> days,
  required List<String> interests,
  required String? originCity,
  required List<String> destinationCities,
  required String? requirementsText,
  required String? tripPurpose,
  required String? travelBehavior,
  required String? location,
  required int? budget,
  required int? people,
  required String? targetPrice,
}) {
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
    "meal_plan": "午餐晚餐與休息安排說明",
    "stop_highlights": [
      {"id": "景點id", "highlight": "15至35字的旅遊重點", "icon": "一個適合的emoji"}
    ]
  }
- 每個行程站點都要在 stop_highlights 提供一筆，重點要具體說明適合做什麼、看什麼或體驗什麼
- icon 只能是一個符合景點特色的 emoji，不要使用文字或多個 emoji
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
- 補充需求：${requirementsText == null || requirementsText.isEmpty ? '未提供' : requirementsText}
- 可行性提醒：${feasibilityTips.isEmpty ? '目前沒有明顯跨城風險' : feasibilityTips.join('；')}

行程：
${_buildInsightStopPrompt(days)}
''';
}

String _buildInsightStopPrompt(List<Map<String, dynamic>> days) {
  final lines = <String>[];
  for (final day in days.take(5)) {
    final dayNo = day['day']?.toString() ?? '?';
    final items = day['items'];
    if (items is! List) continue;
    for (final item in items.whereType<Map>()) {
      final rawPlace = item['place'];
      if (rawPlace is! Map) continue;
      final place = Map<String, dynamic>.from(rawPlace);
      final id = place['id']?.toString().trim() ?? '';
      final name = place['name']?.toString().trim() ?? '';
      if (id.isEmpty || name.isEmpty) continue;
      final tags =
          (place['tags'] as List?)
              ?.map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .take(5)
              .join(',') ??
          '';
      final description = place['description']?.toString().trim() ?? '';
      final shortDescription = description.length > 80
          ? '${description.substring(0, 80)}…'
          : description;
      lines.add(
        'Day$dayNo | id=$id | $name | tags=$tags | 說明=$shortDescription',
      );
    }
  }
  return lines.join('\n');
}

List<Map<String, dynamic>> _mergeStopHighlights(
  dynamic rawAiHighlights,
  dynamic rawFallbackHighlights,
) {
  final merged = <String, Map<String, dynamic>>{};
  if (rawFallbackHighlights is List) {
    for (final raw in rawFallbackHighlights.whereType<Map>()) {
      final item = Map<String, dynamic>.from(raw);
      final id = item['id']?.toString().trim() ?? '';
      if (id.isNotEmpty) merged[id] = item;
    }
  }
  if (rawAiHighlights is List) {
    for (final raw in rawAiHighlights.whereType<Map>()) {
      final item = Map<String, dynamic>.from(raw);
      final id = item['id']?.toString().trim() ?? '';
      final highlight = item['highlight']?.toString().trim() ?? '';
      final icon = item['icon']?.toString().trim() ?? '';
      if (id.isEmpty || highlight.isEmpty) continue;
      merged[id] = {
        'id': id,
        'highlight': highlight,
        'icon': icon.isEmpty ? (merged[id]?['icon'] ?? '📍') : icon,
      };
    }
  }
  return merged.values.toList();
}

List<Map<String, dynamic>> _buildRuleBasedStopHighlights(
  List<Map<String, dynamic>> days,
) {
  final highlights = <Map<String, dynamic>>[];
  for (final day in days) {
    final items = day['items'];
    if (items is! List) continue;
    for (final item in items.whereType<Map>()) {
      final rawPlace = item['place'];
      if (rawPlace is! Map) continue;
      final place = Map<String, dynamic>.from(rawPlace);
      final id = place['id']?.toString().trim() ?? '';
      final name = place['name']?.toString().trim() ?? '';
      if (id.isEmpty || name.isEmpty) continue;
      final tags =
          (place['tags'] as List?)?.map((e) => e.toString()).toSet() ??
          const <String>{};
      final description = place['description']?.toString().trim() ?? '';
      final (icon, fallbackText) = _stopHighlightStyle(tags, name);
      final highlight = description.isNotEmpty
          ? (description.length > 38
                ? '${description.substring(0, 38)}…'
                : description)
          : fallbackText;
      highlights.add({'id': id, 'highlight': highlight, 'icon': icon});
    }
  }
  return highlights;
}

(String, String) _stopHighlightStyle(Set<String> tags, String name) {
  if (tags.contains('meal_break') || name.contains('餐時間')) {
    return ('🍽️', '保留用餐與休息時間，補充體力後再繼續行程。');
  }
  if (tags.any(const {'night_market', 'street_food', 'market'}.contains)) {
    return ('🍢', '適合邊走邊吃、感受在地生活與特色小吃。');
  }
  if (tags.any(const {'museum', 'heritage', 'campus'}.contains)) {
    return ('🏛️', '慢慢欣賞文化故事、建築細節與展覽內容。');
  }
  if (tags.any(const {'national_park', 'forest', 'lake_river'}.contains)) {
    return ('🌿', '適合散步看風景、放慢步調並拍攝自然景色。');
  }
  if (tags.any(const {'department_store', 'shopping'}.contains)) {
    return ('🛍️', '可逛街購物、休息用餐，也適合雨天安排。');
  }
  if (tags.any(const {'diy', 'creative_park', 'handcraft_shop'}.contains)) {
    return ('🎨', '安排互動體驗、文創探索與特色拍照。');
  }
  if (tags.any(const {'cafe', 'restaurant'}.contains)) {
    return ('☕', '適合休息用餐，享受悠閒的旅遊節奏。');
  }
  return ('📍', '保留時間探索景點特色、散步與拍照。');
}

void _attachTravelHighlightsToDays(
  List<Map<String, dynamic>> days,
  dynamic rawHighlights,
) {
  final byId = <String, Map<String, dynamic>>{};
  if (rawHighlights is List) {
    for (final raw in rawHighlights.whereType<Map>()) {
      final item = Map<String, dynamic>.from(raw);
      final id = item['id']?.toString().trim() ?? '';
      if (id.isNotEmpty) byId[id] = item;
    }
  }
  for (final day in days) {
    final items = day['items'];
    if (items is! List) continue;
    for (final rawItem in items.whereType<Map>()) {
      final place = rawItem['place'];
      if (place is! Map) continue;
      final id = place['id']?.toString().trim() ?? '';
      final highlight = byId[id];
      if (highlight == null) continue;
      rawItem['travelHighlight'] = highlight['highlight'];
      rawItem['icon'] = highlight['icon'];
    }
  }
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
        maxPairKm = max(maxPairKm, _distanceKm(a.$1, a.$2, b.$1, b.$2));
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

  final prioritizedCities =
      _stringListFromJson(plannerAssist['prioritizedCities'], maxItems: 6)
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
        _distanceKm(
          originAnchor.$1,
          originAnchor.$2,
          cityAnchor.$1,
          cityAnchor.$2,
        ),
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
      ? prioritizedCities
            .take(min(prioritizedCities.length, max(1, totalDays)))
            .toList()
      : normalizedDestinationCities
            .take(min(normalizedDestinationCities.length, max(1, totalDays)))
            .toList();
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
  required String? requirementsText,
  required _RequirementSignals requirementSignals,
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
    requirementsText: requirementsText,
    requirementSignals: requirementSignals,
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
  if (!_isLlmConfigured() || candidates.isEmpty) {
    return fallback;
  }

  try {
    final llmResult = await _generateJsonWithLlm(
      feature: 'planner_assist',
      systemPrompt: '你是資深旅遊行程規劃師。請只回傳 JSON，使用繁體中文，重點是改善路線合理性而不是只寫漂亮文案。',
      messages: [
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
            requirementsText: requirementsText,
            requirementSignals: requirementSignals,
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
      temperature: 0.25,
    );
    final aiJson = _extractJsonMap(llmResult.text);
    if (aiJson == null) {
      _recordAiUsage(
        _AiUsageRecord(
          feature: 'planner_assist',
          model: llmResult.usageModelLabel,
          success: false,
          latencyMs: llmResult.latencyMs,
          statusCode: llmResult.statusCode,
          promptTokens: llmResult.promptTokens,
          completionTokens: llmResult.completionTokens,
          totalTokens: llmResult.totalTokens,
          error: 'LLM 回傳內容無法解析成 JSON',
        ),
      );
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
    final lunchStartTime = aiJson['lunch_start_time']?.toString().trim() ?? '';
    final dinnerStartTime =
        aiJson['dinner_start_time']?.toString().trim() ?? '';
    final parsedLunch = _parseHmToMinute(lunchStartTime);
    final parsedDinner = _parseHmToMinute(dinnerStartTime);
    final alternativePlan = aiJson['alternative_plan']?.toString().trim() ?? '';

    _recordAiUsage(
      _AiUsageRecord(
        feature: 'planner_assist',
        model: llmResult.usageModelLabel,
        success: true,
        latencyMs: llmResult.latencyMs,
        statusCode: llmResult.statusCode,
        promptTokens: llmResult.promptTokens,
        completionTokens: llmResult.completionTokens,
        totalTokens: llmResult.totalTokens,
      ),
    );
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
      'source': llmResult.provider,
    };
  } catch (error) {
    if (error is! _LlmRequestException) {
      _recordAiUsage(
        _AiUsageRecord(
          feature: 'planner_assist',
          model: '${_currentLlmProvider()}:${_resolvedLlmModel()}',
          success: false,
          latencyMs: 0,
          error: error.toString(),
        ),
      );
    }
    _log.warning('LLM planner assist fallback to rule-based: $error');
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
  required String? requirementsText,
  required _RequirementSignals requirementSignals,
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
      : [if (fallbackCity != null && fallbackCity.isNotEmpty) fallbackCity];

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
  }).toList()..sort((a, b) => b.score.compareTo(a.score));

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
      final distancePenalty = originAnchor != null && cityAnchor != null
          ? _distanceKm(
                  originAnchor.$1,
                  originAnchor.$2,
                  cityAnchor.$1,
                  cityAnchor.$2,
                ) *
                0.015
          : 0.0;
      final score =
          (scoreEntry?.score ?? bucket.length.toDouble()) - distancePenalty;
      return (city: city, score: score);
    }).toList()..sort((a, b) => b.score.compareTo(a.score));
    prioritizedCities.addAll(
      rankedSelected
          .take(min(max(1, totalDays + 1), rankedSelected.length))
          .map((entry) => entry.city),
    );
  } else {
    prioritizedCities.addAll(
      cityRank
          .take(min(max(1, totalDays + 1), cityRank.length))
          .map((entry) => entry.city),
    );
  }
  if (requirementSignals.preferShortDistance && prioritizedCities.length > 1) {
    prioritizedCities.removeRange(
      min(1, prioritizedCities.length),
      prioritizedCities.length,
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

  final firstPriority = prioritizedCities.isEmpty
      ? null
      : prioritizedCities.first;
  final originAnchor = _resolveCityAnchor(
    places: allPlaces,
    city: normalizedOriginCity,
  );
  final firstAnchor = _resolveCityAnchor(
    places: allPlaces,
    city: firstPriority,
  );
  final originToFirstKm = originAnchor != null && firstAnchor != null
      ? _distanceKm(
          originAnchor.$1,
          originAnchor.$2,
          firstAnchor.$1,
          firstAnchor.$2,
        )
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
        recommendedStartTime = originToFirstKm < 40
            ? '09:00'
            : recommendedStartTime;
      }
      break;
    case 'explore':
      dailyStopCap = min(8, dailyStopCap + 1);
      recommendedStartTime = originToFirstKm < 20
          ? '08:30'
          : recommendedStartTime;
      break;
    case 'couple':
      if (dayStartTime == null || dayStartTime.trim().isEmpty) {
        recommendedStartTime = originToFirstKm < 40
            ? '09:00'
            : recommendedStartTime;
      }
      break;
    case 'family':
      dailyStopCap = max(2, dailyStopCap - 1);
      if (dayStartTime == null || dayStartTime.trim().isEmpty) {
        recommendedStartTime = originToFirstKm < 40
            ? '09:00'
            : recommendedStartTime;
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
  if (requirementSignals.preferShortDistance) {
    dailyStopCap = max(2, dailyStopCap - 1);
    if (dayStartTime == null || dayStartTime.trim().isEmpty) {
      recommendedStartTime = originToFirstKm < 25
          ? '09:00'
          : recommendedStartTime;
    }
  }
  if (requirementSignals.preferLowWalking ||
      requirementSignals.preferRelaxedPacing) {
    dailyStopCap = max(2, dailyStopCap - 1);
  }
  if (requirementSignals.preferFamilyFriendly) {
    dailyStopCap = max(2, dailyStopCap - 1);
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
  if (requirementSignals.preferShortDistance && originToFirstKm >= 25) {
    warnings.add('你補充需求希望點跟點不要太遠，但目前第一段移動仍偏長，建議集中在單一城市或近郊。');
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
  if (requirementSignals.preferPhotoSpots) {
    improvements.add('這次會優先提高拍照打卡、景觀與辨識度高的景點比重。');
  }
  if (requirementSignals.preferOutdoor) {
    improvements.add('這次會優先選擇戶外散步、景觀與自然類型景點。');
  }
  if (requirementSignals.preferShortDistance) {
    improvements.add('這次會優先縮短點與點之間距離，減少跨城與長時間拉車。');
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
    if (requirementSignals.summary.isNotEmpty) requirementSignals.summary,
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

void _prunePlannerChatSessions() {
  if (_plannerChatSessions.isEmpty) return;
  final cutoff = DateTime.now().subtract(const Duration(hours: 6));
  final expired = _plannerChatSessions.entries
      .where((entry) => entry.value.updatedAt.isBefore(cutoff))
      .map((entry) => entry.key)
      .toList();
  for (final key in expired) {
    _plannerChatSessions.remove(key);
  }
}

_PlannerChatSession _resolvePlannerChatSession({
  required String conversationId,
  required String? userId,
  required DateTime? startDate,
  required DateTime? endDate,
  required String originCity,
  required List<String> destinationCities,
  required String? requirementsText,
}) {
  final existing = conversationId.isEmpty
      ? null
      : _plannerChatSessions[conversationId];
  if (existing != null) {
    if ((requirementsText ?? '').trim().isNotEmpty) {
      existing.requirementsText = requirementsText!.trim();
      _updatePlannerChatKnownPreferences(existing, requirementsText);
      _updatePlannerChatPlaceConstraints(existing, requirementsText);
    }
    existing.touch();
    return existing;
  }

  final id = const Uuid().v4();
  final session = _PlannerChatSession(
    id: id,
    userId: userId,
    startDate: startDate,
    endDate: endDate,
    originCity: originCity,
    destinationCities: List<String>.from(destinationCities),
    requirementsText: requirementsText,
  );
  _updatePlannerChatKnownPreferences(session, requirementsText ?? '');
  _updatePlannerChatPlaceConstraints(session, requirementsText ?? '');
  _plannerChatSessions[id] = session;
  return session;
}

Future<Map<String, dynamic>> _buildPlannerChatTurn({
  required _PlannerChatSession session,
  required String userMessage,
}) async {
  session.messages.add({'role': 'user', 'content': userMessage});
  _updatePlannerChatKnownPreferences(session, userMessage);
  _updatePlannerChatPlaceConstraints(session, userMessage);
  final currentRequirements = session.requirementsText.trim();
  final normalizedCurrent = currentRequirements.replaceAll('；', '').trim();
  final normalizedMessage = userMessage.trim();
  if (currentRequirements.isEmpty) {
    session.requirementsText = normalizedMessage;
  } else if (normalizedCurrent != normalizedMessage) {
    session.requirementsText = [
      currentRequirements,
      normalizedMessage,
    ].join('；');
  }
  session.touch();

  final requirementSignals = _extractRequirementSignals(
    session.requirementsText,
  );
  final fallback = _buildRuleBasedPlannerChatReply(
    session: session,
    latestInput: userMessage,
    requirementSignals: requirementSignals,
  );

  String assistantReply =
      fallback['assistantReply']?.toString() ?? '收到，我會把這些需求一起納入。';
  var readyToGenerate = fallback['readyToGenerate'] == true;
  var suggestedQuickReplies = _stringListFromJson(
    fallback['suggestedQuickReplies'],
    maxItems: 4,
  );

  if (_isLlmConfigured()) {
    try {
      final llmResult = await _generateJsonWithLlm(
        feature: 'planner_chat',
        systemPrompt: _buildPlannerChatSystemPrompt(),
        messages: [
          {
            'role': 'system',
            'content': _buildPlannerChatContextPrompt(
              session: session,
              requirementSignals: requirementSignals,
            ),
          },
          ...session.messages
              .skip(max(0, session.messages.length - 12))
              .map(
                (message) => {
                  'role': (message['role'] ?? 'user').toString(),
                  'content': (message['content'] ?? '').toString(),
                },
              ),
        ],
        temperature: 0.45,
      );
      final aiJson = _extractJsonMap(llmResult.text);
      if (aiJson != null) {
        final reply = aiJson['reply']?.toString().trim();
        if (reply != null && reply.isNotEmpty) {
          assistantReply = reply;
        }
        readyToGenerate = aiJson['ready_to_generate'] == true;
        final aiQuickReplies = _stringListFromJson(
          aiJson['suggested_quick_replies'],
          maxItems: 4,
        );
        if (aiQuickReplies.isNotEmpty) {
          suggestedQuickReplies = aiQuickReplies;
        }
        if (_plannerChatReplyRepeatsKnownQuestion(session, assistantReply)) {
          assistantReply =
              fallback['assistantReply']?.toString() ??
              '收到，我已記住前面確認過的條件。你可以繼續補充需求，或直接開始產生行程草稿。';
          suggestedQuickReplies = _stringListFromJson(
            fallback['suggestedQuickReplies'],
            maxItems: 4,
          );
        }
        _recordAiUsage(
          _AiUsageRecord(
            feature: 'planner_chat',
            model: llmResult.usageModelLabel,
            success: true,
            latencyMs: llmResult.latencyMs,
            statusCode: llmResult.statusCode,
            promptTokens: llmResult.promptTokens,
            completionTokens: llmResult.completionTokens,
            totalTokens: llmResult.totalTokens,
          ),
        );
      } else {
        _recordAiUsage(
          _AiUsageRecord(
            feature: 'planner_chat',
            model: llmResult.usageModelLabel,
            success: false,
            latencyMs: llmResult.latencyMs,
            statusCode: llmResult.statusCode,
            promptTokens: llmResult.promptTokens,
            completionTokens: llmResult.completionTokens,
            totalTokens: llmResult.totalTokens,
            error: 'LLM 回傳內容無法解析成 JSON',
          ),
        );
      }
    } catch (error) {
      if (error is! _LlmRequestException) {
        _recordAiUsage(
          _AiUsageRecord(
            feature: 'planner_chat',
            model: '${_currentLlmProvider()}:${_resolvedLlmModel()}',
            success: false,
            latencyMs: 0,
            error: error.toString(),
          ),
        );
      }
      _log.warning('LLM planner chat fallback to rule-based: $error');
    }
  }

  session.messages.add({'role': 'assistant', 'content': assistantReply});
  session.touch();
  return {
    'conversationId': session.id,
    'assistantReply': assistantReply,
    'readyToGenerate': readyToGenerate,
    'requirementsText': session.requirementsText,
    'suggestedQuickReplies': suggestedQuickReplies,
    'requirementsSignals': {
      'summary': requirementSignals.summary,
      'keywords': requirementSignals.requirementKeywords,
      ...requirementSignals.toJson(),
      'preferFoodStops': requirementSignals.preferFood,
      'preferRelaxedPace': requirementSignals.preferRelaxedPacing,
      'preferLowWalkingLoad': requirementSignals.preferLowWalking,
    },
    'hardConstraints': {
      'requiredPlaces': session.requiredPlaces.toList(),
      'excludedPlaces': session.excludedPlaces.toList(),
    },
    'conversationState': {
      'companion': session.companion,
      'transport': session.transport,
      'style': session.style,
      'pacing': session.pacing,
    },
  };
}

void _updatePlannerChatKnownPreferences(
  _PlannerChatSession session,
  String rawInput,
) {
  final input = rawInput.trim();
  if (input.isEmpty) return;

  bool contains(List<String> keywords) => keywords.any(input.contains);
  final normalized = input.replaceAll(RegExp(r'[\s，。！？、,.!?]+'), '');

  if (normalized == '自己' ||
      normalized == '我自己' ||
      normalized == '就我' ||
      normalized == '只有我' ||
      contains(const ['獨旅', '一個人', '自己旅行', '自己去', '單人旅行', '獨自旅行'])) {
    session.companion = '獨自旅行';
  } else if (contains(const ['伴侶', '情侶', '另一半', '夫妻', '男友', '女友'])) {
    session.companion = '伴侶／情侶';
  } else if (contains(const ['朋友', '同學', '同事'])) {
    session.companion = '朋友同行';
  } else if (contains(const ['爸媽', '父母', '長輩'])) {
    session.companion = '帶爸媽長輩';
  } else if (contains(const ['親子', '家庭', '小朋友', '小孩', '兒童'])) {
    session.companion = '親子家庭';
  }

  if (contains(const ['自駕', '自己開車', '開車'])) {
    session.transport = '自駕';
  } else if (contains(const ['大眾運輸', '公共運輸', '公車', '火車', '捷運'])) {
    session.transport = '大眾運輸';
  } else if (contains(const ['機車', '騎車'])) {
    session.transport = '機車';
  } else if (contains(const ['步行為主', '走路為主'])) {
    session.transport = '步行為主';
  } else if (contains(const ['交通方式不限', '交通不限'])) {
    session.transport = '交通方式不限';
  }

  if (contains(const ['室內', '百貨', '商場', '購物中心', '逛街', '展覽'])) {
    session.style = '室內逛街';
  } else if (contains(const ['戶外自然', '戶外', '自然', '步道', '海景', '山景'])) {
    session.style = '戶外自然';
  } else if (contains(const ['文化歷史', '歷史', '古蹟', '老街', '博物館'])) {
    session.style = '文化歷史';
  } else if (contains(const ['美食小吃', '美食', '小吃'])) {
    session.style = '美食小吃';
  } else if (contains(const ['拍照打卡', '拍照', '打卡', '網美'])) {
    session.style = '拍照打卡';
  } else if (contains(const ['親子體驗'])) {
    session.style = '親子體驗';
  }

  if (contains(const ['輕鬆慢遊', '輕鬆', '慢遊', '不要太趕', '放鬆', '悠閒'])) {
    session.pacing = '輕鬆慢遊';
  } else if (contains(const ['充實踩點', '踩點', '排滿', '充實'])) {
    session.pacing = '充實踩點';
  } else if (contains(const ['短距離優先', '不要太遠', '距離不要太遠', '順路', '不要拉車'])) {
    session.pacing = '短距離優先';
  } else if (contains(const ['少走路', '不要走太多', '不要太累'])) {
    session.pacing = '少走路';
  } else if (contains(const ['節奏不限'])) {
    session.pacing = '節奏不限';
  }
}

void _updatePlannerChatPlaceConstraints(
  _PlannerChatSession session,
  String rawInput,
) {
  final input = rawInput.trim();
  if (input.isEmpty) return;

  final excludedPatterns = <RegExp>[
    RegExp(r'(?:不要去|不想去|排除|移除|刪除|取消)([^，。；、,\n]+)'),
  ];
  var requiredSource = input;
  for (final pattern in excludedPatterns) {
    for (final match in pattern.allMatches(input)) {
      final place = _cleanRequestedPlaceName(match.group(1) ?? '');
      if (place == null) continue;
      session.requiredPlaces.remove(place);
      session.excludedPlaces.add(place);
    }
    requiredSource = requiredSource.replaceAll(pattern, '');
  }

  final requiredPatterns = <RegExp>[
    RegExp(r'(?:想去|我要去|要去|必去|一定要去|希望去|排入|加入|保留)([^，。；、,\n]+)'),
  ];
  for (final place in _extractRequiredPlaceNames(
    requiredSource,
    patterns: requiredPatterns,
  )) {
    session.excludedPlaces.remove(place);
    session.requiredPlaces.add(place);
  }
}

List<String> _extractRequiredPlaceNames(
  String input, {
  List<RegExp>? patterns,
}) {
  final output = <String>{};
  final effectivePatterns =
      patterns ??
      <RegExp>[RegExp(r'(?:想去|我要去|要去|必去|一定要去|希望去|排入|加入|保留)([^，。；、,\n]+)')];
  for (final pattern in effectivePatterns) {
    for (final match in pattern.allMatches(input)) {
      final place = _cleanRequestedPlaceName(match.group(1) ?? '');
      if (place != null) output.add(place);
    }
  }
  return output.toList();
}

String? _cleanRequestedPlaceName(String raw) {
  var value = raw.trim();
  value = value
      .split(RegExp(r'(?:然後|之後|接著|再去|晚上|白天|早上|下午|但是|但|可是|不過|卻|結果)'))
      .first;
  value = value
      .replaceFirst(RegExp(r'^(?:的|到|逛|看看|走走)'), '')
      .replaceFirst(RegExp(r'(?:逛街|拍照|打卡|走走|看看|吃飯)$'), '')
      .trim();
  const genericRequests = <String>{
    '夜市',
    '商場',
    '百貨',
    '景點',
    '戶外',
    '室內',
    '博物館',
    '美術館',
    '老街',
  };
  if (value.length < 2 ||
      value.length > 32 ||
      genericRequests.contains(value)) {
    return null;
  }
  return value;
}

bool _plannerChatReplyRepeatsKnownQuestion(
  _PlannerChatSession session,
  String reply,
) {
  final normalized = reply.replaceAll(RegExp(r'\s+'), '');
  if (!normalized.contains('?') && !normalized.contains('？')) {
    return false;
  }
  bool asks(List<String> phrases) => phrases.any(normalized.contains);
  if (session.companion != null &&
      asks(const ['和誰一起旅行', '幾位同行', '幾個人同行', '同行者', '有幾位同行'])) {
    return true;
  }
  if (session.companion == '獨自旅行' &&
      asks(const ['小朋友', '小孩', '孩子年齡', '同行人數'])) {
    return true;
  }
  if (session.transport != null &&
      asks(const ['交通方式', '交通工具', '怎麼移動', '如何移動'])) {
    return true;
  }
  if (session.style != null && asks(const ['旅遊風格', '想要哪種風格', '偏好哪種景點'])) {
    return true;
  }
  if (session.pacing != null && asks(const ['行程節奏', '什麼節奏', '想排多滿'])) {
    return true;
  }
  return false;
}

Map<String, dynamic> _buildRuleBasedPlannerChatReply({
  required _PlannerChatSession session,
  required String latestInput,
  required _RequirementSignals requirementSignals,
}) {
  final combinedText = session.requirementsText;
  final latestHints = <String>[];
  final currentStyle = <String>[];
  final quickReplies = <String>[];

  bool contains(List<String> keywords, [String? source]) =>
      keywords.any((keyword) => (source ?? combinedText).contains(keyword));

  if (contains(const ['獨旅', '一個人', '自己', '單人'], latestInput)) {
    latestHints.add('我會把節奏調成更適合獨旅');
  }
  if (contains(const ['家庭', '親子', '小朋友', '小孩', '爸媽', '長輩'], latestInput)) {
    latestHints.add('會優先照顧家庭同行的節奏');
  }
  if (contains(const ['戶外', '走走', '散步', '步道', '自然', '海景', '山景'], latestInput)) {
    latestHints.add('會保留戶外走走的安排');
  }
  if (contains(const ['室內', '百貨', '商場', '購物中心', '逛街', '展覽'], latestInput)) {
    latestHints.add('會提高室內景點與逛街行程的比例');
  }
  if (contains(const ['拍照', '打卡', '網美', '取景'], latestInput)) {
    latestHints.add('會提高拍照和打卡點的比重');
  }
  if (contains(const ['夜市', '晚上想去夜市', '晚上市集'], latestInput)) {
    latestHints.add('晚間會優先保留夜市或商圈時段');
  }
  if (contains(const ['不要太遠', '距離不要太遠', '不要拉車', '順路', '近一點'], latestInput)) {
    latestHints.add('我會盡量縮短點跟點距離');
  }
  if (contains(const ['不要走太多', '少走路', '不要太累'], latestInput)) {
    latestHints.add('會降低步行負擔');
  }
  if (contains(const ['吃飯', '晚餐', '午餐', '小吃', '咖啡', '下午茶'], latestInput)) {
    latestHints.add('也會兼顧美食時段');
  }
  if (session.requiredPlaces.isNotEmpty) {
    latestHints.add('必排景點會保留：${session.requiredPlaces.join('、')}');
  }

  if (contains(const ['獨旅', '一個人', '自己', '單人'])) currentStyle.add('獨旅');
  if (contains(const ['家庭', '親子', '小朋友', '小孩', '爸媽', '長輩']))
    currentStyle.add('家庭友善');
  if (requirementSignals.preferOutdoor) currentStyle.add('戶外');
  if (requirementSignals.preferIndoor) currentStyle.add('室內逛街');
  if (requirementSignals.preferPhotoSpots) currentStyle.add('拍照打卡');
  if (requirementSignals.preferShortDistance) currentStyle.add('順路不拉車');
  if (contains(const ['夜市', '晚上想去夜市', '晚上市集'])) currentStyle.add('晚間夜市');
  if (requirementSignals.preferFood) currentStyle.add('美食');
  if (requirementSignals.preferRelaxedPacing) currentStyle.add('放鬆節奏');
  if (requirementSignals.preferLowWalking) currentStyle.add('低步行負擔');

  if (!requirementSignals.preferLowWalking) {
    quickReplies.add('帶爸媽，不要走太多路');
  }
  if (!requirementSignals.preferPhotoSpots) {
    quickReplies.add('想沿途拍照打卡');
  }
  if (!requirementSignals.preferShortDistance) {
    quickReplies.add('希望景點之間不要太遠');
  }
  if (!requirementSignals.preferFood) {
    quickReplies.add('中午安排在地小吃');
  }

  final reply = [
    latestHints.isEmpty ? '收到，我會把這句需求一起納入。' : '收到，${latestHints.join('、')}。',
    currentStyle.isEmpty
        ? '目前先按你提供的日期和城市來排。'
        : '目前這版會偏向 ${currentStyle.join('、')} 的路線。',
    quickReplies.isEmpty
        ? '如果條件差不多了，你可以直接按「照這個安排」。'
        : '如果還想補一個方向，可以再說「${quickReplies.first}」。',
  ].join('\n');

  final readyToGenerate =
      combinedText.trim().length >= 8 &&
      (requirementSignals.preferredTags.isNotEmpty ||
          contains(const ['家庭', '親子', '獨旅', '夜市', '不要太遠', '不要走太多']));
  return {
    'assistantReply': reply,
    'readyToGenerate': readyToGenerate,
    'suggestedQuickReplies': quickReplies.take(4).toList(),
  };
}

String _buildPlannerChatSystemPrompt() {
  return '''
你是 Smart Travel 的 AI 行程規劃助理。你的工作不是直接生成完整行程，而是先透過自然對話幫使用者補齊需求。

規則：
- 使用繁體中文
- 回覆自然、簡短、像 ChatGPT 對話，不要模板化
- 必須明確回應使用者剛剛最新一句新增了什麼條件
- 要記住前文，不要忽略之前的需求
- 新需求與舊需求衝突時，以使用者最新且更具體的需求為準；例如先選戶外、後來要求室內多一點，就不得再說偏向戶外
- 每次最多只追問 1 個最有價值的澄清問題
- 優先確認同行對象、交通方式、旅遊風格、行程節奏；已經回答過的項目不要重複詢問
- 四個核心項目都已確認後，才追問餐飲、必去景點、住宿或其他特殊限制
- suggested_quick_replies 必須直接對應目前追問的問題，使用簡短且可直接選擇的答案
- 不要發明具體景點名稱
- 不要直接輸出 itinerary
- 如果需求已經足夠，可以明確告知可以直接按照這個安排
- 只回傳 JSON，不要有其他文字

固定輸出格式：
{
  "reply": "給使用者看的自然回覆",
  "ready_to_generate": true,
  "suggested_quick_replies": ["可選短句1", "可選短句2"]
}
''';
}

String _buildPlannerChatContextPrompt({
  required _PlannerChatSession session,
  required _RequirementSignals requirementSignals,
}) {
  final dayCount = _calculateDays(session.startDate, session.endDate);
  return '''
本次基本條件：
- 日期：${session.startDate?.toIso8601String().split('T').first ?? '未指定'} 到 ${session.endDate?.toIso8601String().split('T').first ?? '未指定'}
- 天數：$dayCount
- 出發地：${session.originCity}
- 目的地：${session.destinationCities.join('、')}
- 目前累積需求原文：${session.requirementsText.isEmpty ? '未提供' : session.requirementsText}
- 必排景點：${session.requiredPlaces.isEmpty ? '無' : session.requiredPlaces.join('、')}
- 排除景點：${session.excludedPlaces.isEmpty ? '無' : session.excludedPlaces.join('、')}
- 已確認同行對象：${session.companion ?? '未確認'}
- 已確認交通方式：${session.transport ?? '未確認'}
- 已確認旅遊風格：${session.style ?? '未確認'}
- 已確認行程節奏：${session.pacing ?? '未確認'}
- 需求抽取摘要：${requirementSignals.summary}
- 已推測偏好標籤：${requirementSignals.preferredTags.isEmpty ? '未推測' : requirementSignals.preferredTags.join('、')}
- 是否偏好順路短距離：${requirementSignals.preferShortDistance ? '是' : '否'}
- 是否偏好戶外：${requirementSignals.preferOutdoor ? '是' : '否'}
- 是否偏好室內與逛街：${requirementSignals.preferIndoor ? '是' : '否'}
- 是否偏好拍照：${requirementSignals.preferPhotoSpots ? '是' : '否'}
- 是否偏好家庭友善：${requirementSignals.preferFamilyFriendly ? '是' : '否'}
- 是否偏好美食：${requirementSignals.preferFood ? '是' : '否'}
- 是否偏好放鬆節奏：${requirementSignals.preferRelaxedPacing ? '是' : '否'}
- 是否偏好低步行負擔：${requirementSignals.preferLowWalking ? '是' : '否'}
''';
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
  required String? requirementsText,
  required _RequirementSignals requirementSignals,
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
- 補充需求：${requirementsText == null || requirementsText.isEmpty ? '未提供' : requirementsText}
- 需求抽取摘要：${requirementSignals.summary.isEmpty ? '未抽取到明確偏好' : requirementSignals.summary}
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
  if (!_isLlmConfigured()) {
    return fallback;
  }

  try {
    final llmResult = await _generateJsonWithLlm(
      feature: 'stop_explanation',
      systemPrompt: '你是旅遊行程規劃助理。用繁體中文，解釋單一景點安排理由。只回傳 JSON。',
      messages: [
        {'role': 'user', 'content': _buildStopExplanationPrompt(body, place)},
      ],
      temperature: 0.35,
    );
    final aiJson = _extractJsonMap(llmResult.text);
    if (aiJson == null) {
      _recordAiUsage(
        _AiUsageRecord(
          feature: 'stop_explanation',
          model: llmResult.usageModelLabel,
          success: false,
          latencyMs: llmResult.latencyMs,
          statusCode: llmResult.statusCode,
          promptTokens: llmResult.promptTokens,
          completionTokens: llmResult.completionTokens,
          totalTokens: llmResult.totalTokens,
          error: 'LLM 回傳內容無法解析成 JSON',
        ),
      );
      return fallback;
    }

    final tips =
        (aiJson['tips'] as List?)
            ?.map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .take(4)
            .toList() ??
        const <String>[];
    _recordAiUsage(
      _AiUsageRecord(
        feature: 'stop_explanation',
        model: llmResult.usageModelLabel,
        success: true,
        latencyMs: llmResult.latencyMs,
        statusCode: llmResult.statusCode,
        promptTokens: llmResult.promptTokens,
        completionTokens: llmResult.completionTokens,
        totalTokens: llmResult.totalTokens,
      ),
    );
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
      'source': llmResult.provider,
    };
  } catch (error) {
    if (error is! _LlmRequestException) {
      _recordAiUsage(
        _AiUsageRecord(
          feature: 'stop_explanation',
          model: '${_currentLlmProvider()}:${_resolvedLlmModel()}',
          success: false,
          latencyMs: 0,
          error: error.toString(),
        ),
      );
    }
    _log.warning('LLM stop explanation fallback to rule-based: $error');
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
          if (prevName.isNotEmpty && nextName.isNotEmpty)
            '落在「$prevName」與「$nextName」之間，順路性較高',
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
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      if (response.statusCode != 200) {
        _log.warning(
          'Open-Meteo request failed: HTTP ${response.statusCode} ($uri)',
        );
        lastError = 'HTTP ${response.statusCode}';
        if (attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: 400 * (attempt + 1)),
          );
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
        final rainProb = _asIntValue(
          i < precipMax.length ? precipMax[i] : null,
        );
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
    'explore' ||
    '景點探索' ||
    '綜合推薦' ||
    'balanced' ||
    '美食探索' ||
    '美食' ||
    '人文走讀' ||
    '人文' ||
    '文化' ||
    '走讀' ||
    '自然療癒' ||
    '自然' ||
    '戶外' => 'explore',
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

bool _placeMatchesTripPurpose(Place place, String purpose) {
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
  String purpose, {
  _RequirementSignals? requirementSignals,
}) {
  if (candidates.length <= 6 || purpose == 'explore') {
    return candidates;
  }

  final explicitMatches =
      requirementSignals == null || requirementSignals.isEmpty
      ? const <Place>[]
      : candidates
            .where(
              (place) =>
                  _requirementsSignalScore(place, requirementSignals) >= 0.9,
            )
            .toList();
  final matched = candidates
      .where((place) => _placeMatchesTripPurpose(place, purpose))
      .toList();
  List<Place> mergeWithExplicit(List<Place> purposeCandidates) {
    final byId = <String, Place>{};
    for (final place in [...explicitMatches, ...purposeCandidates]) {
      byId[place.id] = place;
    }
    return byId.values.toList();
  }

  if (matched.length >= max(4, (candidates.length * 0.28).round())) {
    return mergeWithExplicit(matched);
  }
  if (matched.length >= 3) {
    final extras = candidates
        .where((place) => !matched.any((picked) => picked.id == place.id))
        .take(max(2, candidates.length ~/ 7))
        .toList();
    return mergeWithExplicit([...matched, ...extras]);
  }
  return mergeWithExplicit(candidates);
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
  required _RequirementSignals requirementSignals,
  required (double, double)? originAnchor,
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

  score += _requirementsSignalScore(place, requirementSignals);
  score += _originProximityBoost(
    place,
    originAnchor: originAnchor,
    requirementSignals: requirementSignals,
  );

  score += _itineraryLearningProfile.scoreBoost(
    place,
    preferredTags: preferredTags,
    targetPrice: targetPrice,
    weights: weights,
  );

  return score;
}

double _requirementsSignalScore(
  Place place,
  _RequirementSignals requirementSignals,
) {
  if (requirementSignals.isEmpty) return 0;
  final tags = place.tags.map((tag) => tag.toLowerCase()).toSet();
  final text = _normalizeLocationText(
    '${place.name} ${place.description} ${place.address} ${place.city} ${place.tags.join(' ')}',
  );
  var score = 0.0;

  final matchedTags = requirementSignals.preferredTags
      .where((tag) => tags.contains(tag.toLowerCase()))
      .length;
  score += matchedTags * 0.75;

  bool textHasAny(List<String> keywords) =>
      keywords.any((keyword) => text.contains(_normalizeLocationText(keyword)));

  if (requirementSignals.preferPhotoSpots &&
      textHasAny(const [
        '景觀台',
        '好望角',
        '花',
        '湖',
        '彩繪',
        '老街',
        '觀景',
        '天空步道',
        '夜景',
      ])) {
    score += 1.15;
  }
  if (requirementSignals.preferOutdoor &&
      textHasAny(const ['步道', '農場', '公園', '濕地', '森林', '湖', '海', '草原', '河濱'])) {
    score += 1.0;
  }
  if (requirementSignals.preferIndoor) {
    if (_isIndoorPlace(place)) {
      score += 3.6;
      if ([
        'department_store',
        'museum',
        'creative_park',
        'handcraft_shop',
        'concert_hall',
        'cinema',
      ].any(tags.contains)) {
        score += 2.4;
      }
      if (!requirementSignals.preferFood &&
          ['restaurant', 'cafe'].any(tags.contains)) {
        score -= 2.4;
      }
    } else if (textHasAny(const [
      '步道',
      '古道',
      '公園',
      '濕地',
      '森林',
      '河濱',
      '海灘',
      '農場',
    ])) {
      score -= 2.8;
    }
  }
  if (requirementSignals.preferFood &&
      textHasAny(const ['小吃', '餐廳', '咖啡', '夜市', '下午茶'])) {
    score += 0.75;
  }
  if (requirementSignals.preferNightMarket) {
    if (_isNightMarketPlace(place)) {
      score += 0.8;
    } else if (textHasAny(const ['商圈', '市集', '老街'])) {
      score += 0.35;
    }
  }
  if (requirementSignals.preferFamilyFriendly &&
      textHasAny(const ['農場', '親子', '動物', '牧場', '樂園', '體驗'])) {
    score += 0.95;
  }
  if (requirementSignals.preferLowWalking &&
      textHasAny(const ['園區', '老街', '湖', '咖啡', '觀景', '博物館'])) {
    score += 0.45;
  }
  if (requirementSignals.preferLowWalking &&
      textHasAny(const ['步道', '古道', '登山', '健行'])) {
    score -= 0.9;
  }

  return score;
}

bool _isNightMarketPlace(Place place) {
  final tags = place.tags.map((tag) => tag.toLowerCase()).toSet();
  if (tags.contains('night_market')) return true;
  final text = _normalizeLocationText(
    '${place.name} ${place.description} ${place.address}',
  );
  return text.contains(_normalizeLocationText('夜市'));
}

List<Place> _ensureNightMarketInRoute({
  required List<Place> route,
  required List<Place> candidates,
  required Map<String, double> scores,
  required int maxStops,
}) {
  if (route.any(_isNightMarketPlace)) {
    return _moveNightMarketToEnd(route);
  }
  final markets = candidates.where(_isNightMarketPlace).toList()
    ..sort(
      (a, b) => (scores[b.id] ?? double.negativeInfinity).compareTo(
        scores[a.id] ?? double.negativeInfinity,
      ),
    );
  if (markets.isEmpty) return route;

  final output = List<Place>.from(route);
  final market = markets.first;
  if (output.length >= maxStops && output.isNotEmpty) {
    var removeIndex = 0;
    var lowestScore = double.infinity;
    for (var i = 0; i < output.length; i++) {
      final score = scores[output[i].id] ?? double.negativeInfinity;
      if (score < lowestScore) {
        lowestScore = score;
        removeIndex = i;
      }
    }
    output.removeAt(removeIndex);
  }
  output.add(market);
  return _moveNightMarketToEnd(output);
}

List<Place> _moveNightMarketToEnd(List<Place> route) {
  final regular = route.where((place) => !_isNightMarketPlace(place)).toList();
  final markets = route.where(_isNightMarketPlace).toList();
  return [...regular, ...markets];
}

double _originProximityBoost(
  Place place, {
  required (double, double)? originAnchor,
  required _RequirementSignals requirementSignals,
}) {
  if (originAnchor == null || !requirementSignals.preferShortDistance) {
    return 0;
  }
  if (place.lat == 0 || place.lng == 0) return 0;
  final distanceKm = _distanceKm(
    originAnchor.$1,
    originAnchor.$2,
    place.lat,
    place.lng,
  );
  if (distanceKm <= 10) return 1.3;
  if (distanceKm <= 20) return 0.95;
  if (distanceKm <= 35) return 0.55;
  if (distanceKm >= 80) return -1.4;
  if (distanceKm >= 50) return -0.8;
  return 0;
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
  if (effectiveLevel == null &&
      (effectiveCategory == null || effectiveCategory.isEmpty)) {
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
    var updated = place;
    var changed = false;
    final localExportMatch = await _findTrainingExportBackfill(place);
    if (localExportMatch != null) {
      final merged = _mergePlaceWithBackfillCandidate(updated, localExportMatch);
      changed = changed || !_samePlaceData(updated, merged);
      updated = merged;
    }
    if (_needsPriceBackfill(updated)) {
      updated = _normalizePlaceForStorage(updated);
      changed = true;
    }
    if (changed) {
      await store.upsertPlace(updated);
    }
    normalized.add(updated);
  }
  return normalized;
}

Future<Place?> _findTrainingExportBackfill(Place place) async {
  if (!_needsLocalExportBackfill(place)) {
    return null;
  }
  final index = await _trainingPlacesExportIndex();
  final normalizedName = _normalizePlaceNameForMatch(place.name);
  if (normalizedName.isEmpty) {
    return null;
  }

  final exactCandidates = index[normalizedName] ?? const <Place>[];
  final exactMatch = _bestTrainingExportMatch(place, exactCandidates);
  if (exactMatch != null) {
    return exactMatch;
  }

  final allPlaces = _trainingPlacesExportCache ?? const <Place>[];
  final partialCandidates = allPlaces.where((candidate) {
    final candidateName = _normalizePlaceNameForMatch(candidate.name);
    if (candidateName.isEmpty) {
      return false;
    }
    return candidateName.contains(normalizedName) ||
        normalizedName.contains(candidateName);
  });
  return _bestTrainingExportMatch(place, partialCandidates);
}

bool _needsLocalExportBackfill(Place place) {
  return place.imageUrl.trim().isEmpty ||
      place.rating == null ||
      place.userRatingsTotal == null;
}

Future<Map<String, List<Place>>> _trainingPlacesExportIndex() async {
  final cached = _trainingPlacesExportIndexCache;
  if (cached != null) {
    return cached;
  }

  final file = File(p.join(_dataDir, 'training_places_export.json'));
  if (!await file.exists()) {
    _trainingPlacesExportCache = const <Place>[];
    _trainingPlacesExportIndexCache = const <String, List<Place>>{};
    return _trainingPlacesExportIndexCache!;
  }

  try {
    final decoded = jsonDecode(await file.readAsString());
    final rawPlaces = decoded is List
        ? decoded
        : decoded is Map<String, dynamic>
        ? (decoded['places'] as List? ?? const [])
        : const [];
    final parsed = rawPlaces
        .whereType<Map>()
        .map((item) => Place.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    final index = <String, List<Place>>{};
    for (final place in parsed) {
      final key = _normalizePlaceNameForMatch(place.name);
      if (key.isEmpty) continue;
      index.putIfAbsent(key, () => <Place>[]).add(place);
    }
    _trainingPlacesExportCache = parsed;
    _trainingPlacesExportIndexCache = index;
    return index;
  } catch (error, stack) {
    _log.warning('Load training_places_export.json failed: $error', error, stack);
    _trainingPlacesExportCache = const <Place>[];
    _trainingPlacesExportIndexCache = const <String, List<Place>>{};
    return _trainingPlacesExportIndexCache!;
  }
}

Place? _bestTrainingExportMatch(Place target, Iterable<Place> candidates) {
  final normalizedCity = _normalizeLocationText(target.city);
  final normalizedAddress = _normalizeLocationText(target.address);
  Place? best;
  var bestScore = -1;

  for (final candidate in candidates) {
    var score = 0;
    if (candidate.imageUrl.trim().isNotEmpty) score += 500;
    if (candidate.rating != null) score += 60;
    if (candidate.userRatingsTotal != null) score += 30;

    final candidateCity = _normalizeLocationText(candidate.city);
    final candidateAddress = _normalizeLocationText(candidate.address);
    if (normalizedCity.isNotEmpty && candidateCity == normalizedCity) {
      score += 220;
    }
    if (normalizedAddress.isNotEmpty &&
        candidateAddress.isNotEmpty &&
        (candidateAddress.contains(normalizedAddress) ||
            normalizedAddress.contains(candidateAddress))) {
      score += 180;
    }
    if (candidate.lat != 0 || candidate.lng != 0) {
      score += 20;
    }

    if (score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }

  return bestScore >= 220 ? best : null;
}

Place _mergePlaceWithBackfillCandidate(Place current, Place candidate) {
  return Place(
    id: current.id,
    name: current.name,
    tags: current.tags.isNotEmpty ? current.tags : candidate.tags,
    city: current.city.trim().isNotEmpty ? current.city : candidate.city,
    address: current.address.trim().isNotEmpty
        ? current.address
        : candidate.address,
    lat: current.lat != 0 ? current.lat : candidate.lat,
    lng: current.lng != 0 ? current.lng : candidate.lng,
    description: current.description.trim().isNotEmpty
        ? current.description
        : candidate.description,
    imageUrl: current.imageUrl.trim().isNotEmpty
        ? current.imageUrl
        : candidate.imageUrl,
    rating: current.rating ?? candidate.rating,
    userRatingsTotal: current.userRatingsTotal ?? candidate.userRatingsTotal,
    priceLevel: current.priceLevel ?? candidate.priceLevel,
    priceCategory: current.priceCategory ?? candidate.priceCategory,
    openingHours: current.openingHours ?? candidate.openingHours,
    source: current.source ?? candidate.source,
    updatedAt: DateTime.now().toUtc(),
  );
}

bool _samePlaceData(Place a, Place b) {
  return a.id == b.id &&
      a.name == b.name &&
      _listEquals(a.tags, b.tags) &&
      a.city == b.city &&
      a.address == b.address &&
      a.lat == b.lat &&
      a.lng == b.lng &&
      a.description == b.description &&
      a.imageUrl == b.imageUrl &&
      a.rating == b.rating &&
      a.userRatingsTotal == b.userRatingsTotal &&
      a.priceLevel == b.priceLevel &&
      a.priceCategory == b.priceCategory &&
      jsonEncode(a.openingHours) == jsonEncode(b.openingHours) &&
      a.source == b.source;
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
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
        (explicitPriceLevel == null &&
            (explicitPriceCategory == null ||
                explicitPriceCategory.trim().isEmpty)) &&
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
    'source': place.source,
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
  final key = _googleMapsServerKey();
  if (key.isEmpty) {
    throw ApiException(
      400,
      '需要設定 GOOGLE_PLACES_SERVER_API_KEY 或 GOOGLE_MAPS_API_KEY 才能即時搜尋餐廳',
    );
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
    final distancePenalty = lat != null && lng != null
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
  final uri = Uri.https('maps.googleapis.com', path, {...params, 'key': key});
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

Future<Map<String, dynamic>?> _googlePlaceDetails({
  required String key,
  required String placeId,
}) async {
  final uri = Uri.https('maps.googleapis.com', '/maps/api/place/details/json', {
    'place_id': placeId,
    'language': 'zh-TW',
    'reviews_sort': 'most_relevant',
    'fields': [
      'place_id',
      'name',
      'formatted_address',
      'geometry',
      'editorial_summary',
      'rating',
      'user_ratings_total',
      'price_level',
      'types',
      'address_components',
      'photos',
      'opening_hours',
      'current_opening_hours',
      'business_status',
      'website',
      'formatted_phone_number',
    ].join(','),
    'key': key,
  });
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      return null;
    }
    final body = await utf8.decodeStream(response);
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      return null;
    }
    final status = decoded['status']?.toString() ?? '';
    if (status != 'OK') {
      _log.warning('Google Place details failed: $status placeId=$placeId');
      return null;
    }
    final result = decoded['result'];
    if (result is! Map) {
      return null;
    }
    return Map<String, dynamic>.from(result);
  } catch (error) {
    _log.warning('Google Place details request error: $error');
    return null;
  } finally {
    client.close(force: true);
  }
}

String _googlePhotoUrl(String key, String photoReference) {
  return Uri.https('maps.googleapis.com', '/maps/api/place/photo', {
    'maxwidth': '800',
    'photo_reference': photoReference,
    'key': key,
  }).toString();
}

String _extractGooglePlaceNameFromUrl(Uri uri) {
  final queryKeys = ['query', 'q'];
  for (final key in queryKeys) {
    final value = uri.queryParameters[key]?.trim() ?? '';
    if (value.isNotEmpty) {
      return value.replaceAll('+', ' ').trim();
    }
  }
  final segments = uri.pathSegments;
  final placeIndex = segments.indexOf('place');
  if (placeIndex >= 0 && placeIndex + 1 < segments.length) {
    return segments[placeIndex + 1].replaceAll('+', ' ').trim();
  }
  if (segments.isNotEmpty) {
    return segments.last.replaceAll('+', ' ').trim();
  }
  return '';
}

Future<Uri> _resolveGoogleMapsUrl(Uri uri) async {
  final host = uri.host.toLowerCase();
  if (!host.contains('maps.app.goo.gl')) {
    return uri;
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    var current = uri;
    for (var i = 0; i < 6; i++) {
      final request = await client.getUrl(current);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'SmartTravelAdmin/1.0');
      final response = await request.close();
      await response.drain<void>();
      final status = response.statusCode;
      if (status >= 300 && status < 400) {
        final location =
            response.headers.value(HttpHeaders.locationHeader)?.trim() ?? '';
        if (location.isEmpty) {
          break;
        }
        current = current.resolve(location);
        continue;
      }
      return current;
    }
    return current;
  } catch (_) {
    return uri;
  } finally {
    client.close(force: true);
  }
}

String _normalizePlaceNameForMatch(String input) {
  var text = _normalizeLocationText(input);
  const suffixes = <String>[
    '台中市',
    '臺中市',
    '台北市',
    '臺北市',
    '新北市',
    '桃園市',
    '台南市',
    '臺南市',
    '高雄市',
    '苗栗縣',
    '新竹縣',
    '新竹市',
    '彰化縣',
    '南投縣',
    '雲林縣',
    '嘉義縣',
    '嘉義市',
    '屏東縣',
    '宜蘭縣',
    '花蓮縣',
    '台東縣',
    '臺東縣',
    '金門縣',
    '連江縣',
    '基隆市',
    '商圈',
    '景觀',
    '觀景',
    '觀景平台',
    '生態景觀',
    '生態景觀公園',
    '觀光工廠',
    'outlet park',
    'outlet mall',
  ];
  for (final suffix in suffixes) {
    final normalizedSuffix = _normalizeLocationText(suffix);
    if (normalizedSuffix.isNotEmpty && text.endsWith(normalizedSuffix)) {
      text = text.substring(0, text.length - normalizedSuffix.length).trim();
    }
  }
  return text.trim();
}

Place? _findRequestedPlaceMatch(Iterable<Place> places, String requestedName) {
  final target = _normalizePlaceNameForMatch(requestedName);
  if (target.isEmpty) return null;
  Place? partialMatch;
  for (final place in places) {
    final candidate = _normalizePlaceNameForMatch(place.name);
    if (candidate == target) return place;
    if (candidate.isNotEmpty &&
        (candidate.contains(target) || target.contains(candidate))) {
      partialMatch ??= place;
    }
  }
  return partialMatch;
}

int _scoreGooglePlaceCandidate(
  Map<String, dynamic> result, {
  required String rawName,
  required String cityHint,
}) {
  final normalizedTarget = _normalizePlaceNameForMatch(rawName);
  final candidateName = result['name']?.toString().trim() ?? '';
  final normalizedCandidate = _normalizePlaceNameForMatch(candidateName);
  var score = 0;
  if (normalizedTarget.isNotEmpty && normalizedCandidate == normalizedTarget) {
    score += 1000;
  } else if (normalizedTarget.isNotEmpty &&
      (normalizedCandidate.contains(normalizedTarget) ||
          normalizedTarget.contains(normalizedCandidate))) {
    score += 600;
  }
  final address =
      result['formatted_address']?.toString().trim() ??
      result['vicinity']?.toString().trim() ??
      '';
  final candidateCity = _extractCityHint(address) ?? '';
  final normalizedCityHint = _normalizeLocationText(cityHint);
  if (normalizedCityHint.isNotEmpty &&
      _normalizeLocationText(candidateCity) == normalizedCityHint) {
    score += 250;
  }
  final ratingTotal = _asIntValue(result['user_ratings_total']) ?? 0;
  score += min(ratingTotal, 500);
  if ((_asDoubleValue(result['rating']) ?? 0) >= 4.2) {
    score += 30;
  }
  return score;
}

List<String> _googlePlaceTags({
  required String name,
  required String address,
  required String description,
  required Iterable<String> types,
}) {
  final typeSet = types.map((e) => e.toString().trim().toLowerCase()).toSet();
  final text = _normalizeLocationText(
    '$name $address $description ${typeSet.join(' ')}',
  );
  final tags = <String>{};

  if (typeSet.contains('university') || typeSet.contains('school')) {
    tags.addAll(const ['heritage', 'national_park', 'campus']);
  }
  if (typeSet.contains('museum') || typeSet.contains('art_gallery')) {
    tags.add('museum');
  }
  if (typeSet.contains('shopping_mall')) {
    tags.add('department_store');
  }
  if (typeSet.contains('amusement_park')) {
    tags.add('amusement');
  }
  if (typeSet.contains('campground') || typeSet.contains('rv_park')) {
    tags.add('camping');
  }
  if (typeSet.contains('aquarium')) {
    tags.add('aquarium');
  }
  if (typeSet.contains('zoo')) {
    tags.add('zoo');
  }
  if (typeSet.contains('movie_theater')) {
    tags.add('cinema');
  }
  if (typeSet.contains('cafe')) {
    tags.add('cafe');
  }
  if (typeSet.contains('restaurant')) {
    tags.add('restaurant');
  }
  if (typeSet.contains('spa')) {
    tags.add('hot_spring');
  }
  if (typeSet.contains('church') ||
      typeSet.contains('hindu_temple') ||
      typeSet.contains('place_of_worship')) {
    tags.addAll(const ['temple', 'heritage']);
  }
  if (typeSet.contains('park') ||
      typeSet.contains('natural_feature') ||
      typeSet.contains('tourist_attraction')) {
    if (text.contains(_normalizeLocationText('濕地')) ||
        text.contains(_normalizeLocationText('步道')) ||
        text.contains(_normalizeLocationText('公園')) ||
        text.contains(_normalizeLocationText('景觀台')) ||
        text.contains(_normalizeLocationText('綠園道')) ||
        text.contains(_normalizeLocationText('植物園'))) {
      tags.add('national_park');
    }
  }

  if (text.contains(_normalizeLocationText('夜市'))) {
    tags.addAll(const ['night_market', 'street_food']);
  }
  if (text.contains(_normalizeLocationText('商圈')) ||
      text.contains(_normalizeLocationText('outlet')) ||
      text.contains(_normalizeLocationText('百貨'))) {
    tags.add('department_store');
  }
  if (text.contains(_normalizeLocationText('老街')) ||
      text.contains(_normalizeLocationText('古蹟')) ||
      text.contains(_normalizeLocationText('教堂')) ||
      text.contains(_normalizeLocationText('校園'))) {
    tags.add('heritage');
  }
  if (text.contains(_normalizeLocationText('溪')) ||
      text.contains(_normalizeLocationText('濕地'))) {
    tags.add('lake_river');
  }
  if (text.contains(_normalizeLocationText('創意')) ||
      text.contains(_normalizeLocationText('彩繪')) ||
      text.contains(_normalizeLocationText('文創'))) {
    tags.add('creative_park');
  }
  return tags.toList();
}

Place _buildPlaceFromGoogleResult({
  required String key,
  required Map<String, dynamic> result,
  required String fallbackName,
  required String fallbackCity,
}) {
  final details = result['details'] is Map
      ? Map<String, dynamic>.from(result['details'] as Map)
      : const <String, dynamic>{};
  final source = details.isNotEmpty ? details : result;
  final geometry = source['geometry'] is Map
      ? Map<String, dynamic>.from(source['geometry'] as Map)
      : const <String, dynamic>{};
  final location = geometry['location'] is Map
      ? Map<String, dynamic>.from(geometry['location'] as Map)
      : const <String, dynamic>{};
  final photos = source['photos'];
  String imageUrl = '';
  if (photos is List && photos.isNotEmpty && photos.first is Map) {
    final photoRef =
        (photos.first as Map)['photo_reference']?.toString().trim() ?? '';
    if (photoRef.isNotEmpty) {
      imageUrl = _googlePhotoUrl(key, photoRef);
    }
  }
  final openingHours = source['opening_hours'] is Map
      ? Map<String, dynamic>.from(source['opening_hours'] as Map)
      : null;
  final types =
      (source['types'] as List?)
          ?.map((e) => e.toString().trim().toLowerCase())
          .where((e) => e.isNotEmpty)
          .toList() ??
      const <String>[];
  final description =
      (details['editorial_summary'] is Map
          ? (details['editorial_summary'] as Map)['overview']?.toString().trim()
          : null) ??
      (source['formatted_phone_number']?.toString().trim() ?? '');
  final name = source['name']?.toString().trim().isNotEmpty == true
      ? source['name']!.toString().trim()
      : fallbackName;
  final address =
      source['formatted_address']?.toString().trim() ??
      source['vicinity']?.toString().trim() ??
      '';
  final city = _extractCityHint(address) ?? fallbackCity;
  return Place(
    id: source['place_id']?.toString().trim().isNotEmpty == true
        ? source['place_id']!.toString().trim()
        : const Uuid().v4(),
    name: name,
    tags: _googlePlaceTags(
      name: name,
      address: address,
      description: description,
      types: types,
    ),
    city: city,
    address: address,
    lat: _asDoubleValue(location['lat']) ?? 0,
    lng: _asDoubleValue(location['lng']) ?? 0,
    description: description,
    imageUrl: imageUrl,
    rating: _asDoubleValue(source['rating']),
    userRatingsTotal: _asIntValue(source['user_ratings_total']),
    priceLevel: _asIntValue(source['price_level']),
    openingHours: openingHours,
    source: 'google_place_url_import',
    updatedAt: DateTime.now().toUtc(),
  );
}

Future<Place> _importPlaceFromGoogleMapsUrl({
  required DataStore store,
  required String url,
  required String nameHint,
  required String cityHint,
}) async {
  final key = _googleMapsServerKey();
  if (key.isEmpty) {
    throw ApiException(
      400,
      '需要設定 GOOGLE_PLACES_SERVER_API_KEY 或 GOOGLE_MAPS_API_KEY 才能從 Google Maps 補景點',
    );
  }
  final uri = Uri.tryParse(url);
  if (uri == null) {
    throw ApiException(400, 'Google Maps 網址格式錯誤');
  }
  final resolvedUri = await _resolveGoogleMapsUrl(uri);
  final placeId =
      resolvedUri.queryParameters['query_place_id']?.trim() ??
      resolvedUri.queryParameters['place_id']?.trim() ??
      '';
  final extractedName = _extractGooglePlaceNameFromUrl(resolvedUri);
  final resolvedName = extractedName.isNotEmpty ? extractedName : nameHint;
  final resolvedCity = cityHint.trim();

  Map<String, dynamic>? result;
  if (placeId.isNotEmpty) {
    final details = await _googlePlaceDetails(key: key, placeId: placeId);
    if (details != null) {
      result = {'place_id': placeId, ...details, 'details': details};
    }
  }

  if (result == null) {
    final queries = <String>{
      [
        if (resolvedName.isNotEmpty) resolvedName,
        if (resolvedCity.isNotEmpty) resolvedCity,
      ].join(' ').trim(),
      [
        if (resolvedName.isNotEmpty) resolvedName,
        if (resolvedCity.isNotEmpty) resolvedCity,
        '台灣',
      ].join(' ').trim(),
      [if (resolvedName.isNotEmpty) resolvedName, '台灣'].join(' ').trim(),
      [
        if (nameHint.isNotEmpty) nameHint,
        if (resolvedCity.isNotEmpty) resolvedCity,
      ].join(' ').trim(),
      [if (nameHint.isNotEmpty) nameHint, '台灣'].join(' ').trim(),
    }..removeWhere((query) => query.isEmpty);
    if (queries.isEmpty) {
      throw ApiException(400, '無法從網址解析景點名稱，請提供可辨識的 Google Maps 網址');
    }
    List<Map<String, dynamic>> results = const [];
    String attemptedQuery = '';
    for (final query in queries) {
      attemptedQuery = query;
      results = await _googlePlaceSearch(
        key: key,
        path: '/maps/api/place/textsearch/json',
        params: {'query': query, 'language': 'zh-TW', 'region': 'tw'},
      );
      if (results.isNotEmpty) {
        break;
      }
    }
    if (results.isEmpty) {
      throw ApiException(404, 'Google Places 找不到對應景點（查詢：$attemptedQuery）');
    }
    results.sort((a, b) {
      final aScore = _scoreGooglePlaceCandidate(
        a,
        rawName: resolvedName,
        cityHint: resolvedCity,
      );
      final bScore = _scoreGooglePlaceCandidate(
        b,
        rawName: resolvedName,
        cityHint: resolvedCity,
      );
      return bScore.compareTo(aScore);
    });
    result = results.first;
    final resolvedPlaceId = result['place_id']?.toString().trim() ?? '';
    if (resolvedPlaceId.isNotEmpty) {
      final details = await _googlePlaceDetails(
        key: key,
        placeId: resolvedPlaceId,
      );
      if (details != null) {
        result = {...result, 'details': details};
      }
    }
  }

  var imported = _buildPlaceFromGoogleResult(
    key: key,
    result: result,
    fallbackName: resolvedName,
    fallbackCity: resolvedCity,
  );

  imported = _normalizePlaceForStorage(imported);
  await store.upsertPlace(imported);
  return imported;
}

List<Map<String, dynamic>> _normalizeMealSearchResults(
  List<Map<String, dynamic>> results, {
  required String fallbackCity,
  required String key,
  required String mealType,
}) {
  final normalized = <Map<String, dynamic>>[];
  for (final result in results) {
    final types =
        (result['types'] as List?)
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
        imageUrl = Uri.https('maps.googleapis.com', '/maps/api/place/photo', {
          'maxwidth': '800',
          'photo_reference': photoRef,
          'key': key,
        }).toString();
      }
    }

    normalized.add({
      'id': result['place_id']?.toString() ?? const Uuid().v4(),
      'name': name,
      'kind': 'place',
      'city': _extractCityHint(address) ?? fallbackCity,
      'address': address,
      'description': mealType == 'dinner'
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
