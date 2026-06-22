import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';

import '../state/user_state.dart';
import 'backend_api.dart';

class LocationSyncService with WidgetsBindingObserver {
  LocationSyncService._();

  static final LocationSyncService instance = LocationSyncService._();

  final BackendApi _api = BackendApi.instance;
  StreamSubscription<Position>? _positionSubscription;
  Timer? _heartbeatTimer;

  bool _initialized = false;
  bool _starting = false;
  bool _sending = false;
  double? _lastSentLat;
  double? _lastSentLng;
  DateTime? _lastSentAt;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    await refreshTracking();
  }

  Future<void> refreshTracking() async {
    final userId = UserState.userId?.trim() ?? '';
    if (userId.isEmpty) {
      await stopTracking();
      return;
    }
    await _startTracking();
  }

  Future<void> stopTracking() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> _startTracking() async {
    if (_starting || _positionSubscription != null) return;
    _starting = true;
    try {
      if (!await _ensurePermission()) {
        return;
      }
      final settings = _locationSettings();
      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: settings,
      ).listen(
        (position) => unawaited(
          _maybeSendPosition(position, source: 'stream'),
        ),
      );
      try {
        final position = await Geolocator.getCurrentPosition().timeout(
          const Duration(seconds: 8),
        );
        await _maybeSendPosition(position, source: 'bootstrap', force: true);
      } catch (_) {
        // Ignore bootstrap failures; stream/heartbeat can retry.
      }
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(minutes: 10), (_) {
        unawaited(_sendCurrentPosition());
      });
    } finally {
      _starting = false;
    }
  }

  Future<bool> _ensurePermission() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      return false;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return false;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS &&
        permission == LocationPermission.whileInUse) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  LocationSettings _locationSettings() {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.best,
        activityType: ActivityType.otherNavigation,
        distanceFilter: 120,
        pauseLocationUpdatesAutomatically: true,
        showBackgroundLocationIndicator: false,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 120,
    );
  }

  Future<void> _sendCurrentPosition({bool force = false}) async {
    try {
      final position = await Geolocator.getCurrentPosition().timeout(
        const Duration(seconds: 8),
      );
      await _maybeSendPosition(position, source: 'heartbeat', force: force);
    } catch (_) {
      // Ignore periodic failures.
    }
  }

  Future<void> _maybeSendPosition(
    Position position, {
    required String source,
    bool force = false,
  }) async {
    if (_sending) return;
    final userId = UserState.userId?.trim() ?? '';
    if (userId.isEmpty) return;

    final now = DateTime.now();
    if (!force &&
        _lastSentAt != null &&
        _lastSentLat != null &&
        _lastSentLng != null) {
      final movedMeters = Geolocator.distanceBetween(
        _lastSentLat!,
        _lastSentLng!,
        position.latitude,
        position.longitude,
      );
      if (movedMeters < 120 &&
          now.difference(_lastSentAt!) < const Duration(minutes: 8)) {
        return;
      }
    }

    _sending = true;
    try {
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      final isBackground =
          lifecycle == AppLifecycleState.paused ||
          lifecycle == AppLifecycleState.inactive ||
          lifecycle == AppLifecycleState.hidden;
      await _api.updateLocation(
        userId: userId,
        lat: position.latitude,
        lng: position.longitude,
        accuracy: position.accuracy,
        speed: position.speed.isFinite ? position.speed : null,
        heading: position.heading.isFinite ? position.heading : null,
        background: isBackground,
        timestamp: now,
        source: source,
      );
      _lastSentAt = now;
      _lastSentLat = position.latitude;
      _lastSentLng = position.longitude;
    } on ApiClientException {
      // Ignore location sync failures to avoid disturbing the user.
    } finally {
      _sending = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refreshTracking());
      unawaited(_sendCurrentPosition(force: true));
    }
  }
}
