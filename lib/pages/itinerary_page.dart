import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../services/backend_api.dart';
import '../state/user_state.dart';

class ItineraryPage extends StatefulWidget {
  const ItineraryPage({
    super.key,
    required this.plan,
    this.confirmOnOpen = false,
  });

  final Map<String, dynamic> plan;
  final bool confirmOnOpen;

  @override
  State<ItineraryPage> createState() => _ItineraryPageState();
}

class _ItineraryPageState extends State<ItineraryPage> {
  static const _googleMapsApiKey = String.fromEnvironment(
    'GOOGLE_MAPS_API_KEY',
  );

  final BackendApi _api = BackendApi.instance;
  late _ItineraryPlan _plan;
  late Map<String, dynamic> _planJson;
  late final PageController _dayPageController;
  final ScrollController _timelineScrollController = ScrollController();
  int _selectedDayIndex = 0;
  bool _replanning = false;
  TimeOfDay _preferredStartTime = const TimeOfDay(hour: 9, minute: 30);
  TimeOfDay _preferredEndTime = const TimeOfDay(hour: 18, minute: 30);
  int _extraSpotsPreference = 0;
  final List<String> _wishlistPlaces = [];
  final Map<String, String> _transitModeOverrides = {};
  final Set<String> _manuallyEditedDayKeys = <String>{};
  bool _formalPlanConfirmationStarted = false;

  @override
  void initState() {
    super.initState();
    _planJson = Map<String, dynamic>.from(widget.plan);
    _plan = _ItineraryPlan.fromJson(_planJson);
    _dayPageController = PageController();
    _hydrateArrangementPreferencesFromPlanMeta();
    if (widget.confirmOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_confirmFormalPlanAfterOpen());
      });
    } else {
      unawaited(_syncActivePlanToCloud());
    }
    unawaited(
      _reportEvent(
        'page_view',
        payload: {
          'days': _plan.days.length,
          'location': _planJson['meta'] is Map
              ? (_planJson['meta'] as Map)['location']?.toString()
              : null,
        },
      ),
    );
  }

  @override
  void dispose() {
    _dayPageController.dispose();
    _timelineScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final days = _plan.days;
    return Scaffold(
      backgroundColor: const Color(0xFFE2D6C9),
      appBar: AppBar(
        backgroundColor: const Color(0xFFE2D6C9),
        elevation: 0,
        title: const Text(
          '行程安排',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: Color(0xFF1F1F23),
          ),
        ),
        actions: [
          IconButton(
            tooltip: '查看當日路線地圖',
            onPressed: () => _openDayRouteMap(days[_selectedDayIndex]),
            icon: const Icon(Icons.map_outlined, color: Color(0xFF1F1F23)),
          ),
          IconButton(
            tooltip: '旅程細節調整',
            onPressed: _openArrangementSettings,
            icon: const Icon(Icons.tune_rounded, color: Color(0xFF1F1F23)),
          ),
        ],
      ),
      body: days.isEmpty
          ? const Center(
              child: Text(
                '目前沒有可顯示的行程',
                style: TextStyle(fontSize: 16, color: Colors.black54),
              ),
            )
          : Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: ListView(
                    controller: _timelineScrollController,
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 20),
                    children: [
                      _buildDaySelector(days),
                      if (_hasArrangementPreferences) ...[
                        const SizedBox(height: 8),
                        _buildArrangementPreferenceCard(),
                      ],
                      const SizedBox(height: 10),
                      ..._buildTimelineChildren(days[_selectedDayIndex]),
                    ],
                  ),
                ),
                if (_replanning)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(
                      minHeight: 2.5,
                      backgroundColor: Colors.white.withValues(alpha: 0.4),
                      color: const Color(0xFF6E8BD8),
                    ),
                  ),
              ],
            ),
    );
  }

  bool get _hasArrangementPreferences =>
      _extraSpotsPreference > 0 || _wishlistPlaces.isNotEmpty;

  Future<void> _openDayRouteMap(_ItineraryDay day) async {
    final stops = <_DayRouteStop>[];
    for (var i = 0; i < day.items.length; i++) {
      final item = day.items[i];
      final lat = item.place.lat;
      final lng = item.place.lng;
      if (lat == null || lng == null) continue;
      stops.add(
        _DayRouteStop(
          order: stops.length + 1,
          itemIndex: i,
          item: item,
          position: LatLng(lat, lng),
        ),
      );
    }

    if (stops.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('這一天的景點沒有座標，無法顯示路線地圖。')));
      return;
    }

    final segments = <_DayRouteSegment>[];
    for (var i = 0; i < stops.length - 1; i++) {
      final fromStop = stops[i];
      final toStop = stops[i + 1];
      final options = _transitComparisonOptions(
        day,
        fromStop.itemIndex,
        toStop.itemIndex,
        fromStop.item,
        toStop.item,
      );
      final selectedMode = _normalizeTransitMode(
        _transitModeOverrides[_transitSegmentKey(day, fromStop.itemIndex)],
      );
      segments.add(
        _DayRouteSegment(
          from: fromStop,
          to: toStop,
          selectedMode: selectedMode,
          transit: options[selectedMode] ?? options['car']!,
        ),
      );
    }

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.9,
        child: _DayRouteMapSheet(
          day: day,
          stops: stops,
          segments: segments,
          dateLabel: _formatDateLabel(day.date),
        ),
      ),
    );
  }

  Widget _buildArrangementPreferenceCard() {
    final timeRange =
        '${_timeOfDayLabel(_preferredStartTime)} - ${_timeOfDayLabel(_preferredEndTime)}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE1D8CC)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.tune_rounded,
                size: 15,
                color: Color(0xFF625A8A),
              ),
              const SizedBox(width: 6),
              Text(
                '旅程細節偏好 · $timeRange',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF312C42),
                ),
              ),
            ],
          ),
          if (_extraSpotsPreference > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '想再增加景點數：$_extraSpotsPreference（作為下次重排行程偏好）',
                style: const TextStyle(fontSize: 11, color: Color(0xFF5C576F)),
              ),
            ),
          if (_wishlistPlaces.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _wishlistPlaces
                  .map(
                    (name) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEDE7F6),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(name, style: const TextStyle(fontSize: 11)),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openArrangementSettings() async {
    final start = _preferredStartTime;
    final end = _preferredEndTime;
    final initialWishlist = List<String>.from(_wishlistPlaces);
    final inputController = TextEditingController();
    var tempStart = start;
    var tempEnd = end;
    var tempExtraSpots = _extraSpotsPreference;
    final tempWishlist = List<String>.from(initialWishlist);
    var shouldReplan = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> pickTime(bool isStart) async {
              final picked = await showTimePicker(
                context: context,
                initialTime: isStart ? tempStart : tempEnd,
              );
              if (picked == null) return;
              setSheetState(() {
                if (isStart) {
                  tempStart = picked;
                } else {
                  tempEnd = picked;
                }
              });
            }

            void addWish() {
              final value = inputController.text.trim();
              if (value.isEmpty) return;
              if (tempWishlist.contains(value)) {
                inputController.clear();
                return;
              }
              setSheetState(() {
                tempWishlist.add(value);
                inputController.clear();
              });
            }

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 12,
                  right: 12,
                  bottom: MediaQuery.of(context).viewInsets.bottom + 12,
                  top: 12,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '旅程細節調整',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: _settingChipButton(
                              label: '開始 ${_timeOfDayLabel(tempStart)}',
                              icon: Icons.schedule,
                              onTap: () => pickTime(true),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _settingChipButton(
                              label: '結束 ${_timeOfDayLabel(tempEnd)}',
                              icon: Icons.timer_outlined,
                              onTap: () => pickTime(false),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const Text(
                            '想再多排景點',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: tempExtraSpots > 0
                                ? () => setSheetState(() => tempExtraSpots--)
                                : null,
                          ),
                          Text(
                            '$tempExtraSpots',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.add_circle_outline),
                            onPressed: tempExtraSpots < 5
                                ? () => setSheetState(() => tempExtraSpots++)
                                : null,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        '想新增什麼景點（先存成偏好，供下次重排行程比較）',
                        style: TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: inputController,
                              decoration: InputDecoration(
                                hintText: '例如：安平老街、奇美博物館',
                                isDense: true,
                                filled: true,
                                fillColor: const Color(0xFFF6F2EC),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              onSubmitted: (_) => addWish(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: addWish,
                            child: const Text('加入'),
                          ),
                        ],
                      ),
                      if (tempWishlist.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: tempWishlist
                              .map(
                                (item) => InputChip(
                                  label: Text(item),
                                  onDeleted: () => setSheetState(
                                    () => tempWishlist.remove(item),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('取消'),
                          ),
                          const Spacer(),
                          ElevatedButton(
                            onPressed: () {
                              setState(() {
                                _preferredStartTime = tempStart;
                                _preferredEndTime = tempEnd;
                                _extraSpotsPreference = tempExtraSpots;
                                _wishlistPlaces
                                  ..clear()
                                  ..addAll(tempWishlist);
                              });
                              shouldReplan = true;
                              Navigator.pop(context);
                            },
                            child: const Text('套用並重排'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    inputController.dispose();
    if (shouldReplan) {
      await _replanWithCurrentPreferences();
    }
  }

  void _hydrateArrangementPreferencesFromPlanMeta() {
    final meta = _planJson['meta'];
    if (meta is! Map) return;
    final start = _parseTimeOfDay(meta['dayStartTime']?.toString());
    final end = _parseTimeOfDay(meta['dayEndTime']?.toString());
    final extra = meta['extraSpots'];
    final wishlist = meta['wishlistPlaces'];
    if (start != null) _preferredStartTime = start;
    if (end != null) _preferredEndTime = end;
    if (extra is num) {
      _extraSpotsPreference = extra.toInt().clamp(0, 5);
    }
    if (wishlist is List) {
      _wishlistPlaces
        ..clear()
        ..addAll(
          wishlist.map((e) => e.toString().trim()).where((e) => e.isNotEmpty),
        );
    }
  }

  TimeOfDay? _parseTimeOfDay(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final parts = raw.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h.clamp(0, 23), minute: m.clamp(0, 59));
  }

  Future<void> _replanWithCurrentPreferences() async {
    final meta = _planJson['meta'];
    if (meta is! Map) return;

    final firstDate = _plan.days.isNotEmpty ? _plan.days.first.date : null;
    final lastDate = _plan.days.isNotEmpty ? _plan.days.last.date : null;
    final rawTags = meta['tags'];
    final interests = rawTags is List
        ? rawTags.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : const <String>[];
    if (interests.isEmpty) return;

    setState(() {
      _replanning = true;
    });
    try {
      final result = await _api.generateItinerary(
        interestIds: interests,
        userId: UserState.userId,
        startDate: firstDate,
        endDate: lastDate,
        location: meta['location']?.toString(),
        people: meta['people'] is num ? (meta['people'] as num).toInt() : null,
        budget: meta['budget'] is num ? (meta['budget'] as num).toInt() : null,
        backpackerAnswers: meta['backpackerAnswers'] is Map
            ? Map<String, dynamic>.from(meta['backpackerAnswers'] as Map)
            : null,
        dayStartTime: _timeOfDayLabel(_preferredStartTime),
        dayEndTime: _timeOfDayLabel(_preferredEndTime),
        extraSpots: _extraSpotsPreference,
        wishlistPlaces: _wishlistPlaces,
      );
      if (!mounted) return;
      setState(() {
        _planJson = result;
        _plan = _ItineraryPlan.fromJson(result);
        _transitModeOverrides.clear();
        _manuallyEditedDayKeys.clear();
        _selectedDayIndex = 0;
      });
      if (_dayPageController.hasClients) {
        _dayPageController.jumpToPage(0);
      }
      if (_timelineScrollController.hasClients) {
        _timelineScrollController.jumpTo(0);
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_timelineScrollController.hasClients) return;
          _timelineScrollController.jumpTo(0);
        });
      }
      unawaited(_syncActivePlanToCloud());
      _showTopMessage('已套用並切換到新編排行程（第 1 天）');
    } on ApiClientException catch (error) {
      if (!mounted) return;
      _showTopMessage(error.message);
    } finally {
      if (mounted) {
        setState(() {
          _replanning = false;
        });
      }
    }
  }

  void _showTopMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _confirmFormalPlanAfterOpen() async {
    if (_formalPlanConfirmationStarted) return;
    _formalPlanConfirmationStarted = true;
    final userId = UserState.userId?.trim() ?? '';
    try {
      await _api.confirmItinerary(userId: userId, plan: _planJson);
      unawaited(
        _reportEvent(
          'formal_plan_confirmed',
          payload: {'days': _plan.days.length},
        ),
      );
    } on ApiClientException catch (error) {
      unawaited(
        _reportEvent(
          'formal_plan_confirmation_failed',
          payload: {'message': error.message},
        ),
      );
      _showTopMessage('正式行程已開啟，但雲端確認失敗：${error.message}');
    }
  }

  Future<void> _syncActivePlanToCloud() async {
    final userId = UserState.userId?.trim() ?? '';
    if (userId.isEmpty) {
      return;
    }
    try {
      await _api.syncActivePlan(userId: userId, plan: _planJson);
      unawaited(
        _reportEvent(
          'active_plan_sync_success',
          payload: {'days': _plan.days.length},
        ),
      );
    } on ApiClientException {
      unawaited(_reportEvent('active_plan_sync_failed'));
      // 保持前端可用；雲端同步失敗時不阻斷本地行程操作。
    }
  }

  String _dayEditKey(_ItineraryDay day) {
    return day.date?.toIso8601String() ?? 'day-${day.day}';
  }

  Future<void> _applyManualDayEdit(
    _ItineraryDay day,
    List<Map<String, dynamic>> items,
  ) async {
    final rawDays = _planJson['days'];
    if (rawDays is! List || _selectedDayIndex >= rawDays.length) {
      return;
    }
    final rawDay = rawDays[_selectedDayIndex];
    if (rawDay is! Map) {
      return;
    }
    final dayMap = Map<String, dynamic>.from(rawDay);
    final sanitizedItems = items
        .map(
          (item) =>
              Map<String, dynamic>.from(jsonDecode(jsonEncode(item)) as Map),
        )
        .toList();
    for (var i = 0; i < sanitizedItems.length; i++) {
      sanitizedItems[i].remove('transitToNext');
    }
    dayMap['items'] = sanitizedItems;
    dayMap.remove('originTransit');
    final updatedDays = List<dynamic>.from(rawDays);
    updatedDays[_selectedDayIndex] = dayMap;
    final updatedPlan = Map<String, dynamic>.from(_planJson)
      ..['days'] = updatedDays;

    setState(() {
      _planJson = updatedPlan;
      _plan = _ItineraryPlan.fromJson(updatedPlan);
      _transitModeOverrides.clear();
      _manuallyEditedDayKeys.add(_dayEditKey(day));
    });
    _recomputeManualDayTimes(_plan.days[_selectedDayIndex]);
    unawaited(_syncActivePlanToCloud());
  }

  void _recomputeManualDayTimes(_ItineraryDay day) {
    final rawDays = _planJson['days'];
    if (rawDays is! List || _selectedDayIndex >= rawDays.length) {
      return;
    }
    final rawDay = rawDays[_selectedDayIndex];
    if (rawDay is! Map) {
      return;
    }
    final items = rawDay['items'];
    if (items is! List) {
      return;
    }
    var current = _preferredDayStartDateTime(day);
    for (var i = 0; i < day.items.length && i < items.length; i++) {
      final rawItem = items[i];
      if (rawItem is! Map) continue;
      final duration = _resolvedItemDurationMinutes(day, i);
      rawItem['time'] = _toHm(current);
      final end = current.add(Duration(minutes: duration));
      rawItem['endTime'] = _toHm(end);
      current = end;
      if (i < day.items.length - 1) {
        current = current.add(
          Duration(minutes: _resolvedTransitMinutes(day, i, i + 1)),
        );
      }
    }
    final updatedPlan = Map<String, dynamic>.from(_planJson);
    setState(() {
      _planJson = updatedPlan;
      _plan = _ItineraryPlan.fromJson(updatedPlan);
    });
  }

  Future<void> _reorderDayStop(
    _ItineraryDay day,
    int fromIndex,
    int toIndex,
  ) async {
    if (fromIndex == toIndex) return;
    final rawDays = _planJson['days'];
    if (rawDays is! List || _selectedDayIndex >= rawDays.length) {
      return;
    }
    final rawDay = rawDays[_selectedDayIndex];
    if (rawDay is! Map) {
      return;
    }
    final rawItems = rawDay['items'];
    if (rawItems is! List ||
        fromIndex < 0 ||
        fromIndex >= rawItems.length ||
        toIndex < 0 ||
        toIndex >= rawItems.length) {
      return;
    }
    final fromItem = day.items[fromIndex];
    final toItem = day.items[toIndex];
    if (fromItem.place.isMealBreak || toItem.place.isMealBreak) {
      return;
    }
    final items = rawItems
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final moved = items.removeAt(fromIndex);
    var insertIndex = toIndex;
    if (fromIndex < toIndex) {
      insertIndex -= 1;
    }
    items.insert(insertIndex.clamp(0, items.length), moved);
    await _applyManualDayEdit(day, items);
    unawaited(
      _reportEvent(
        'itinerary_stop_reordered',
        payload: {
          'day': day.day,
          'fromIndex': fromIndex,
          'toIndex': toIndex,
          'place': fromItem.place.name,
        },
      ),
    );
    _showTopMessage('已更新景點順序並重算時間');
  }

  Future<int?> _promptStopDuration(_ItineraryDay day, int itemIndex) async {
    final controller = TextEditingController(
      text: (_resolvedItemDurationMinutes(day, itemIndex)).toString(),
    );
    final result = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (routeContext) => Scaffold(
          backgroundColor: const Color(0xFFF7F4EE),
          appBar: AppBar(
            title: const Text('調整停留時間'),
            backgroundColor: Colors.white,
            foregroundColor: const Color(0xFF3C3552),
            elevation: 0,
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '設定停留分鐘數',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF3C3552),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '分鐘',
                      hintText: '例如 90',
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '建議至少 10 分鐘。',
                    style: TextStyle(fontSize: 13, color: Color(0xFF6D6880)),
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(routeContext).pop(),
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            final minutes = int.tryParse(
                              controller.text.trim(),
                            );
                            if (minutes == null || minutes < 10) {
                              return;
                            }
                            FocusManager.instance.primaryFocus?.unfocus();
                            Navigator.of(routeContext).pop(minutes);
                          },
                          child: const Text('套用'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _applyStopDuration(
    _ItineraryDay day,
    int itemIndex,
    _ItineraryItem item,
    int result,
  ) async {
    final rawDays = _planJson['days'];
    if (rawDays is! List || _selectedDayIndex >= rawDays.length) {
      return;
    }
    final rawDay = rawDays[_selectedDayIndex];
    if (rawDay is! Map) return;
    final rawItems = rawDay['items'];
    if (rawItems is! List || itemIndex >= rawItems.length) return;
    final items = rawItems
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    items[itemIndex]['durationMinutes'] = result;
    await _applyManualDayEdit(day, items);
    unawaited(
      _reportEvent(
        'itinerary_stop_duration_updated',
        payload: {
          'day': day.day,
          'index': itemIndex,
          'place': item.place.name,
          'durationMinutes': result,
        },
      ),
    );
    _showTopMessage('已更新 ${item.place.name} 的停留時間');
  }

  Future<bool?> _promptDeleteStop(_ItineraryItem item) async {
    final confirmed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (routeContext) => Scaffold(
          backgroundColor: const Color(0xFFF7F4EE),
          appBar: AppBar(
            title: const Text('刪除景點'),
            backgroundColor: Colors.white,
            foregroundColor: const Color(0xFF3C3552),
            elevation: 0,
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '要從今天行程中刪除「${item.place.name}」嗎？',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF3C3552),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '刪除後會重新計算後續時間與交通。',
                    style: TextStyle(fontSize: 14, color: Color(0xFF6D6880)),
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () =>
                              Navigator.of(routeContext).pop(false),
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => Navigator.of(routeContext).pop(true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFB24C3A),
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('刪除'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return confirmed;
  }

  Future<void> _applyDeleteStop(
    _ItineraryDay day,
    int itemIndex,
    _ItineraryItem item,
  ) async {
    final rawDays = _planJson['days'];
    if (rawDays is! List || _selectedDayIndex >= rawDays.length) {
      return;
    }
    final rawDay = rawDays[_selectedDayIndex];
    if (rawDay is! Map) return;
    final rawItems = rawDay['items'];
    if (rawItems is! List || itemIndex >= rawItems.length) return;
    final items = rawItems
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    items.removeAt(itemIndex);
    await _applyManualDayEdit(day, items);
    unawaited(
      _reportEvent(
        'itinerary_stop_deleted',
        payload: {'day': day.day, 'index': itemIndex, 'place': item.place.name},
      ),
    );
    _showTopMessage('已刪除 ${item.place.name}');
  }

  Future<void> _handleStopEditAction(
    _ItineraryDay day,
    int itemIndex,
    _ItineraryItem item,
    String action,
  ) async {
    if (!mounted) return;
    await Future<void>.delayed(const Duration(milliseconds: 160));
    if (!mounted) return;
    switch (action) {
      case 'duration':
        final duration = await _promptStopDuration(day, itemIndex);
        if (duration == null || !mounted) return;
        await Future<void>.delayed(const Duration(milliseconds: 120));
        if (!mounted) return;
        await _applyStopDuration(day, itemIndex, item, duration);
        break;
      case 'delete':
        final confirmed = await _promptDeleteStop(item);
        if (confirmed != true || !mounted) return;
        await Future<void>.delayed(const Duration(milliseconds: 120));
        if (!mounted) return;
        await _applyDeleteStop(day, itemIndex, item);
        break;
    }
  }

  _ItineraryItem? _previousNonMealItem(_ItineraryDay day, int index) {
    for (var i = index - 1; i >= 0; i--) {
      final item = day.items[i];
      if (!item.place.isMealBreak) {
        return item;
      }
    }
    return null;
  }

  _ItineraryItem? _nextNonMealItem(_ItineraryDay day, int index) {
    for (var i = index + 1; i < day.items.length; i++) {
      final item = day.items[i];
      if (!item.place.isMealBreak) {
        return item;
      }
    }
    return null;
  }

  bool _isMealVenueCandidate(_ItineraryPlace place, {String query = ''}) {
    final tags = place.tags.map((tag) => tag.toLowerCase().trim()).toSet();
    final text = [
      place.name,
      place.description,
      place.address,
      place.tags.join(' '),
    ].join(' ').toLowerCase();
    final queryText = query.trim().toLowerCase();

    const strongFoodTags = <String>{
      'restaurant',
      'food',
      'street_food',
      'night_market',
    };
    const softFoodTags = <String>{
      'cafe',
      'bakery',
      'dessert',
      'breakfast',
      'brunch',
    };
    const foodKeywords = <String>{
      '餐廳',
      '美食',
      '小吃',
      '火鍋',
      '燒肉',
      '拉麵',
      '咖啡',
      '早午餐',
      '甜點',
      '下午茶',
      '牛排',
      '壽司',
      '便當',
      '餐酒館',
      '麵店',
      '食堂',
      'restaurant',
      'cafe',
      'coffee',
      'brunch',
      'breakfast',
      'dessert',
      'bistro',
      'barbecue',
      'steak',
      'sushi',
      'ramen',
    };
    const strongNonFoodTags = <String>{
      'museum',
      'heritage',
      'creative_park',
      'gallery',
      'exhibition',
      'national_park',
      'lake_river',
      'beach',
      'waterfall',
      'forest',
      'trail',
      'hiking',
      'temple',
      'church',
      'zoo',
      'aquarium',
      'theme_park',
      'amusement',
      'park',
      'garden',
      'shopping',
      'department_store',
    };
    const nonFoodKeywords = <String>{
      '博物館',
      '美術館',
      '紀念館',
      '文化館',
      '展覽館',
      '樂園',
      '公園',
      '步道',
      '古蹟',
      '濕地',
      '觀景台',
      '神社',
      '寺',
      '廟',
      'museum',
      'gallery',
      'park',
      'trail',
      'memorial',
      'temple',
      'church',
    };

    bool hasAnyTag(Iterable<String> values) =>
        values.any((value) => tags.contains(value));
    bool hasAnyText(Iterable<String> values) =>
        values.any((value) => text.contains(value.toLowerCase()));

    final hasStrongFoodTag = hasAnyTag(strongFoodTags);
    final hasSoftFoodTag = hasAnyTag(softFoodTags);
    final hasFoodKeyword = hasAnyText(foodKeywords);
    final hasStrongNonFoodTag = hasAnyTag(strongNonFoodTags);
    final hasNonFoodKeyword = hasAnyText(nonFoodKeywords);

    final foodSignalCount =
        strongFoodTags.where(tags.contains).length +
        softFoodTags.where(tags.contains).length +
        foodKeywords
            .where((value) => text.contains(value.toLowerCase()))
            .length;
    final nonFoodSignalCount =
        strongNonFoodTags.where(tags.contains).length +
        nonFoodKeywords
            .where((value) => text.contains(value.toLowerCase()))
            .length;

    if (queryText.isNotEmpty &&
        !text.contains(queryText) &&
        !place.name.toLowerCase().contains(queryText)) {
      return false;
    }
    if (!hasStrongFoodTag && !hasSoftFoodTag && !hasFoodKeyword) {
      return false;
    }
    if ((hasStrongNonFoodTag || hasNonFoodKeyword) &&
        foodSignalCount <= nonFoodSignalCount) {
      return false;
    }
    return true;
  }

  Future<List<_MealCandidateOption>> _fetchMealCandidates({
    required _ItineraryDay day,
    required int itemIndex,
    required _ItineraryItem item,
    String query = '',
  }) async {
    final previousItem = _previousNonMealItem(day, itemIndex);
    final nextItem = _nextNonMealItem(day, itemIndex);
    final city = item.place.city.isNotEmpty
        ? item.place.city
        : previousItem?.place.city.isNotEmpty == true
        ? previousItem!.place.city
        : nextItem?.place.city ?? '';
    final mealType = item.place.tags.contains('dinner') ? 'dinner' : 'lunch';
    List<Map<String, dynamic>> raw;
    try {
      raw = await _api.fetchMealSuggestions(
        previous: previousItem == null
            ? null
            : {
                'name': previousItem.place.name,
                'city': previousItem.place.city,
                'address': previousItem.place.address,
                'lat': previousItem.place.lat,
                'lng': previousItem.place.lng,
              },
        next: nextItem == null
            ? null
            : {
                'name': nextItem.place.name,
                'city': nextItem.place.city,
                'address': nextItem.place.address,
                'lat': nextItem.place.lat,
                'lng': nextItem.place.lng,
              },
        city: city.isEmpty ? null : city,
        query: query.trim().isEmpty ? null : query.trim(),
        mealType: mealType,
        limit: 18,
      );
    } on ApiClientException catch (error) {
      if (error.statusCode == 404 && _googleMapsApiKey.trim().isNotEmpty) {
        raw = await _fetchMealSuggestionsFromGoogleDirect(
          previousItem: previousItem,
          nextItem: nextItem,
          city: city,
          query: query,
          mealType: mealType,
        );
      } else {
        throw ApiClientException(
          '餐廳即時搜尋失敗：${error.message}${error.message.contains('GOOGLE_MAPS_API_KEY') ? '。請先設定後端 Google Maps API key 並重啟後端。' : ''}',
          statusCode: error.statusCode,
          details: error.details,
          cause: error,
        );
      }
    }
    final seen = <String>{};
    final options = <_MealCandidateOption>[];
    for (final entry in raw) {
      final map = Map<String, dynamic>.from(entry);
      final place = _ItineraryPlace.fromJson(map);
      if (!_hasValidPlaceCoordinate(place)) {
        continue;
      }
      if (!_isMealVenueCandidate(place, query: query)) {
        continue;
      }
      final dedupeKey = '${place.name}|${place.address}';
      if (!seen.add(dedupeKey)) {
        continue;
      }
      final fromPrevMinutes =
          previousItem != null && _hasValidPlaceCoordinate(previousItem.place)
          ? _estimateTransitByMode(previousItem.place, place, 'car').minutes
          : 0;
      final toNextMinutes =
          nextItem != null && _hasValidPlaceCoordinate(nextItem.place)
          ? _estimateTransitByMode(place, nextItem.place, 'car').minutes
          : 0;
      final fitScore =
          (place.rating ?? 0) * 18 -
          fromPrevMinutes * 0.7 -
          toNextMinutes * 0.7;
      options.add(
        _MealCandidateOption(
          raw: map,
          place: place,
          fromPrevMinutes: fromPrevMinutes,
          toNextMinutes: toNextMinutes,
          fitScore: fitScore,
        ),
      );
    }
    options.sort((a, b) => b.fitScore.compareTo(a.fitScore));
    return options.take(8).toList();
  }

  Future<List<Map<String, dynamic>>> _fetchMealSuggestionsFromGoogleDirect({
    required _ItineraryItem? previousItem,
    required _ItineraryItem? nextItem,
    required String city,
    required String query,
    required String mealType,
  }) async {
    final prevLat = previousItem?.place.lat;
    final prevLng = previousItem?.place.lng;
    final nextLat = nextItem?.place.lat;
    final nextLng = nextItem?.place.lng;
    final hasPrev = prevLat != null && prevLng != null;
    final hasNext = nextLat != null && nextLng != null;
    if (!hasPrev && !hasNext) {
      throw ApiClientException('缺少前後站座標，無法即時搜尋餐廳。');
    }

    late final double anchorLat;
    late final double anchorLng;
    if (hasPrev && hasNext) {
      anchorLat = (prevLat + nextLat) / 2;
      anchorLng = (prevLng + nextLng) / 2;
    } else {
      anchorLat = prevLat ?? nextLat!;
      anchorLng = prevLng ?? nextLng!;
    }

    final nearby = await _googleMealSearch(
      path: '/maps/api/place/nearbysearch/json',
      params: {
        'location': '$anchorLat,$anchorLng',
        'radius': hasPrev && hasNext ? '3500' : '5000',
        'type': 'restaurant',
        'language': 'zh-TW',
        'region': 'tw',
        if (query.trim().isNotEmpty) 'keyword': query.trim(),
      },
    );

    var results = _normalizeDirectGoogleMealResults(
      nearby,
      fallbackCity: city,
      mealType: mealType,
    );

    if (results.length < 5) {
      final textQuery = query.trim().isNotEmpty
          ? '${query.trim()} ${city.trim()} 餐廳'.trim()
          : '${city.trim()} ${mealType == 'dinner' ? '晚餐' : '午餐'} 餐廳'.trim();
      if (textQuery.isNotEmpty) {
        final textSearch = await _googleMealSearch(
          path: '/maps/api/place/textsearch/json',
          params: {
            'query': textQuery,
            'language': 'zh-TW',
            'region': 'tw',
            'location': '$anchorLat,$anchorLng',
            'radius': '6000',
          },
        );
        results = [
          ...results,
          ..._normalizeDirectGoogleMealResults(
            textSearch,
            fallbackCity: city,
            mealType: mealType,
          ),
        ];
      }
    }

    final unique = <String, Map<String, dynamic>>{};
    for (final result in results) {
      final name = result['name']?.toString().trim() ?? '';
      final address = result['address']?.toString().trim() ?? '';
      if (name.isEmpty || address.isEmpty) continue;
      unique.putIfAbsent('$name|$address', () => result);
    }
    return unique.values.toList();
  }

  Future<List<Map<String, dynamic>>> _googleMealSearch({
    required String path,
    required Map<String, String> params,
  }) async {
    if (_googleMapsApiKey.trim().isEmpty) {
      return const <Map<String, dynamic>>[];
    }
    final uri = Uri.https('maps.googleapis.com', path, {
      ...params,
      'key': _googleMapsApiKey,
    });
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        return const <Map<String, dynamic>>[];
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const <Map<String, dynamic>>[];
      }
      final status = decoded['status']?.toString() ?? '';
      if (status != 'OK' && status != 'ZERO_RESULTS') {
        return const <Map<String, dynamic>>[];
      }
      final results = decoded['results'];
      if (results is! List) {
        return const <Map<String, dynamic>>[];
      }
      return results.whereType<Map>().map(Map<String, dynamic>.from).toList();
    } on Exception {
      return const <Map<String, dynamic>>[];
    }
  }

  List<Map<String, dynamic>> _normalizeDirectGoogleMealResults(
    List<Map<String, dynamic>> results, {
    required String fallbackCity,
    required String mealType,
  }) {
    const allowedMealTypes = <String>{
      'restaurant',
      'cafe',
      'bakery',
      'meal_takeaway',
      'meal_delivery',
      'bar',
    };
    final normalized = <Map<String, dynamic>>[];
    for (final result in results) {
      final types =
          (result['types'] as List?)
              ?.map((e) => e.toString().trim().toLowerCase())
              .where((e) => e.isNotEmpty)
              .toSet() ??
          <String>{};
      if (!types.any(allowedMealTypes.contains)) {
        continue;
      }
      final name = result['name']?.toString().trim() ?? '';
      final address =
          result['formatted_address']?.toString().trim() ??
          result['vicinity']?.toString().trim() ??
          '';
      final text = '$name $address ${types.join(' ')}'.toLowerCase();
      if (text.contains('博物館') ||
          text.contains('紀念館') ||
          text.contains('公園') ||
          text.contains('步道') ||
          text.contains('museum') ||
          text.contains('park') ||
          text.contains('trail')) {
        continue;
      }
      final geometry = result['geometry'];
      final geometryMap = geometry is Map
          ? Map<String, dynamic>.from(geometry)
          : const <String, dynamic>{};
      final location = geometryMap['location'];
      final locationMap = location is Map
          ? Map<String, dynamic>.from(location)
          : const <String, dynamic>{};
      final lat = (locationMap['lat'] as num?)?.toDouble();
      final lng = (locationMap['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) {
        continue;
      }
      String imageUrl = '';
      final photos = result['photos'];
      if (photos is List && photos.isNotEmpty && photos.first is Map) {
        final photoRef = (photos.first as Map)['photo_reference']?.toString();
        if (photoRef != null && photoRef.isNotEmpty) {
          imageUrl = Uri.https('maps.googleapis.com', '/maps/api/place/photo', {
            'maxwidth': '800',
            'photo_reference': photoRef,
            'key': _googleMapsApiKey,
          }).toString();
        }
      }
      normalized.add({
        'id': result['place_id']?.toString() ?? '$name|$address',
        'name': name,
        'kind': 'place',
        'city': _extractCityFromAddress(address) ?? fallbackCity,
        'address': address,
        'description': mealType == 'dinner'
            ? 'Google Places 即時搜尋到的晚餐候選。'
            : 'Google Places 即時搜尋到的午餐候選。',
        'imageUrl': imageUrl,
        'tags': <String>[
          if (types.contains('restaurant')) 'restaurant',
          if (types.contains('cafe')) 'cafe',
          if (types.contains('bakery')) 'bakery',
          if (types.contains('meal_takeaway')) 'meal_takeaway',
          if (types.contains('meal_delivery')) 'meal_delivery',
          if (types.contains('bar')) 'bar',
          'live_google_place',
        ],
        'rating': (result['rating'] as num?)?.toDouble(),
        'userRatingsTotal': (result['user_ratings_total'] as num?)?.toInt(),
        'priceLevel': (result['price_level'] as num?)?.toInt(),
        'lat': lat,
        'lng': lng,
        'source': 'google_places_client',
      });
    }
    return normalized;
  }

  String? _extractCityFromAddress(String address) {
    final match = RegExp(r'[\u4e00-\u9fff]{1,8}(縣|市)').firstMatch(address);
    return match?.group(0);
  }

  String _mealCandidateLoadErrorText(Object? error) {
    if (error is ApiClientException) {
      return error.message;
    }
    final text = error?.toString().trim() ?? '';
    if (text.isEmpty) {
      return '餐廳推薦載入失敗';
    }
    return text;
  }

  Future<Map<String, dynamic>> _fetchMealFitExplanation({
    required _ItineraryDay day,
    required int itemIndex,
    required _ItineraryItem mealItem,
    required _MealCandidateOption candidate,
  }) async {
    final meta = _planJson['meta'];
    final metaMap = meta is Map
        ? Map<String, dynamic>.from(meta)
        : <String, dynamic>{};
    final previousItem = _previousNonMealItem(day, itemIndex);
    final nextItem = _nextNonMealItem(day, itemIndex);
    final range = _buildTimeRange(day, itemIndex);
    final durationMinutes = _rangeDurationMinutes(range);
    String? weatherSummary;
    String? weatherTempRange;
    if (day.weather != null) {
      weatherSummary = day.weather!.summary;
      final min = day.weather!.temperatureMin;
      final max = day.weather!.temperatureMax;
      if (min != null && max != null) {
        weatherTempRange = '${min.round()}~${max.round()}°C';
      }
    }

    final payload = <String, dynamic>{
      'explanationContext': 'meal_selection',
      'date': day.date?.toIso8601String().substring(0, 10),
      'day': day.day,
      'startTime': range.start,
      'endTime': range.end,
      'durationMinutes': durationMinutes,
      'location': metaMap['location'],
      'budget': metaMap['budget'],
      'people': metaMap['people'],
      'weatherSummary': weatherSummary,
      'weatherTempRange': weatherTempRange,
      'prevPlaceName': previousItem?.place.name,
      'nextPlaceName': nextItem?.place.name,
      'transitFromPrev': previousItem == null
          ? null
          : _estimateTransitByMode(
              previousItem.place,
              candidate.place,
              'car',
            ).primaryLine,
      'transitToNext': nextItem == null
          ? null
          : _estimateTransitByMode(
              candidate.place,
              nextItem.place,
              'car',
            ).primaryLine,
      'place': candidate.raw,
    };
    try {
      return await _api.explainItineraryStop(payload: payload);
    } catch (_) {
      return {
        'summary':
            '${candidate.place.name} 位於前後站點之間，適合作為${mealItem.place.name}安排。',
        'whyIncluded':
            '前一站約 ${candidate.fromPrevMinutes} 分鐘、下一站約 ${candidate.toNextMinutes} 分鐘，動線仍屬合理。',
        'whyTiming': '餐期安排在 ${range.start}-${range.end}，可銜接前後景點並保留休息時間。',
        'whyDuration': '維持原本用餐停留時長，減少對整體節奏的破壞。',
        'tips': [
          if (candidate.fromPrevMinutes >= 25) '前往餐廳前建議預留一些交通緩衝時間',
          if (candidate.toNextMinutes >= 25) '用餐後到下一站移動稍長，可避免再加其他繞路點',
          '若現場候位時間過長，可改選同城市備選餐廳',
        ],
        'source': 'rule',
      };
    }
  }

  Future<void> _confirmAndApplyMealSelection({
    required _ItineraryDay day,
    required int itemIndex,
    required _ItineraryItem mealItem,
    required _MealCandidateOption candidate,
  }) async {
    final explanation = await _fetchMealFitExplanation(
      day: day,
      itemIndex: itemIndex,
      mealItem: mealItem,
      candidate: candidate,
    );
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final tips =
            (explanation['tips'] as List?)
                ?.map((e) => e.toString())
                .where((e) => e.trim().isNotEmpty)
                .toList() ??
            const <String>[];
        return AlertDialog(
          title: Text('套用 ${candidate.place.name}？'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if ((explanation['summary']?.toString() ?? '')
                    .trim()
                    .isNotEmpty)
                  Text(
                    explanation['summary'].toString(),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                const SizedBox(height: 8),
                Text(explanation['whyIncluded']?.toString() ?? ''),
                const SizedBox(height: 6),
                Text(explanation['whyTiming']?.toString() ?? ''),
                const SizedBox(height: 6),
                Text(explanation['whyDuration']?.toString() ?? ''),
                const SizedBox(height: 10),
                Text(
                  '前一站約 ${candidate.fromPrevMinutes} 分鐘，下一站約 ${candidate.toNextMinutes} 分鐘',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF5A5670),
                  ),
                ),
                if (tips.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final tip in tips.take(3))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '• $tip',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF5A5670),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('套用餐廳'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    await _applyMealSelection(day, itemIndex, mealItem, candidate.raw);
    unawaited(
      _reportEvent(
        'meal_break_place_applied',
        payload: {
          'day': day.day,
          'mealType': mealItem.place.tags.contains('dinner')
              ? 'dinner'
              : 'lunch',
          'place': candidate.place.name,
          'fromPrevMinutes': candidate.fromPrevMinutes,
          'toNextMinutes': candidate.toNextMinutes,
        },
      ),
    );
    _showTopMessage('已套用 ${candidate.place.name} 並重算時間交通');
  }

  Future<void> _reportEvent(
    String event, {
    Map<String, dynamic>? payload,
  }) async {
    try {
      await _api.reportAppEvent(
        event: event,
        page: 'itinerary',
        userId: UserState.userId,
        payload: payload,
      );
    } on ApiClientException {
      // Ignore analytics failures.
    }
  }

  Future<void> _applyMealSelection(
    _ItineraryDay day,
    int itemIndex,
    _ItineraryItem mealItem,
    Map<String, dynamic> candidateRaw,
  ) async {
    final rawDays = _planJson['days'];
    if (rawDays is! List || _selectedDayIndex >= rawDays.length) {
      return;
    }
    final rawDay = rawDays[_selectedDayIndex];
    if (rawDay is! Map) return;
    final rawItems = rawDay['items'];
    if (rawItems is! List || itemIndex >= rawItems.length) return;
    final items = rawItems
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    final selected = Map<String, dynamic>.from(candidateRaw);
    final originalTags = mealItem.place.tags;
    final mealType = originalTags.contains('dinner') ? 'dinner' : 'lunch';
    selected['kind'] = 'meal_break';
    selected['tags'] = <String>{
      ...((selected['tags'] as List?)?.map((e) => e.toString()) ??
          const <String>[]),
      'meal_break',
      mealType,
    }.toList();
    selected['description'] =
        selected['description']?.toString().trim().isNotEmpty == true
        ? selected['description']
        : '已選擇${mealType == 'lunch' ? '午餐' : '晚餐'}餐廳，會依前後景點重新調整交通與時間。';
    items[itemIndex]['place'] = selected;
    await _applyManualDayEdit(day, items);
  }

  Future<void> _openMealBreakPlanner(
    _ItineraryDay day,
    int itemIndex,
    _ItineraryItem item,
  ) async {
    final previousItem = _previousNonMealItem(day, itemIndex);
    final nextItem = _nextNonMealItem(day, itemIndex);
    final searchController = TextEditingController();
    Future<List<_MealCandidateOption>> candidatesFuture = _fetchMealCandidates(
      day: day,
      itemIndex: itemIndex,
      item: item,
    );

    final selectedCandidate = await showModalBottomSheet<_MealCandidateOption>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.78,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.place.name,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${previousItem?.place.name ?? '前一站未定'} -> ${item.place.name} -> ${nextItem?.place.name ?? '下一站未定'}',
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF5A5670),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: searchController,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: '搜尋想要的餐廳名稱',
                          suffixIcon: IconButton(
                            onPressed: () {
                              setModalState(() {
                                candidatesFuture = _fetchMealCandidates(
                                  day: day,
                                  itemIndex: itemIndex,
                                  item: item,
                                  query: searchController.text,
                                );
                              });
                            },
                            icon: const Icon(Icons.search_rounded),
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onSubmitted: (_) {
                          setModalState(() {
                            candidatesFuture = _fetchMealCandidates(
                              day: day,
                              itemIndex: itemIndex,
                              item: item,
                              query: searchController.text,
                            );
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '推薦餐廳',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: FutureBuilder<List<_MealCandidateOption>>(
                          future: candidatesFuture,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const Center(
                                child: CircularProgressIndicator(),
                              );
                            }
                            if (snapshot.hasError) {
                              return Center(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                  ),
                                  child: Text(
                                    _mealCandidateLoadErrorText(snapshot.error),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      color: Color(0xFF5A5670),
                                    ),
                                  ),
                                ),
                              );
                            }
                            final candidates =
                                snapshot.data ?? const <_MealCandidateOption>[];
                            if (candidates.isEmpty) {
                              return const Center(child: Text('找不到符合的餐廳'));
                            }
                            return ListView.separated(
                              itemCount: candidates.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                final candidate = candidates[index];
                                return Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFFBF7),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: const Color(0xFFF0D8C9),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  candidate.place.name,
                                                  style: const TextStyle(
                                                    fontSize: 15,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  candidate
                                                          .place
                                                          .address
                                                          .isNotEmpty
                                                      ? candidate.place.address
                                                      : candidate.place.city,
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    color: Colors.black54,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (candidate.place.rating != null)
                                            Text(
                                              '${candidate.place.rating!.toStringAsFixed(1)}★',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        '前一站約 ${candidate.fromPrevMinutes} 分鐘，下一站約 ${candidate.toNextMinutes} 分鐘',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF5A5670),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: ElevatedButton(
                                          onPressed: () {
                                            Navigator.of(
                                              context,
                                            ).pop(candidate);
                                          },
                                          child: const Text('AI 檢查並套用'),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    searchController.dispose();
    if (!mounted || selectedCandidate == null) return;
    await _confirmAndApplyMealSelection(
      day: day,
      itemIndex: itemIndex,
      mealItem: item,
      candidate: selectedCandidate,
    );
  }

  Widget _settingChipButton({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF6F2EC),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: const Color(0xFF5C5774)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _timeOfDayLabel(TimeOfDay t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Widget _buildDaySelector(List<_ItineraryDay> days) {
    return SizedBox(
      height: 178,
      child: Column(
        children: [
          Row(
            children: [
              _dayArrowButton(
                icon: Icons.chevron_left,
                enabled: _selectedDayIndex > 0,
                onPressed: () => _animateToDay(_selectedDayIndex - 1),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    '${_selectedDayIndex + 1} / ${days.length}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF59566A),
                    ),
                  ),
                ),
              ),
              _dayArrowButton(
                icon: Icons.chevron_right,
                enabled: _selectedDayIndex < days.length - 1,
                onPressed: () => _animateToDay(_selectedDayIndex + 1),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: PageView.builder(
              controller: _dayPageController,
              itemCount: days.length,
              onPageChanged: (index) {
                setState(() {
                  _selectedDayIndex = index;
                });
                if (_timelineScrollController.hasClients) {
                  _timelineScrollController.animateTo(
                    0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                  );
                }
              },
              itemBuilder: (context, index) {
                final day = days[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _dayCard(day),
                );
              },
            ),
          ),
          if (days.length > 1) ...[
            const SizedBox(height: 4),
            const Text(
              '可左右滑動切換每日行程',
              style: TextStyle(
                fontSize: 11,
                color: Color(0xFF6B687C),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _dayArrowButton({
    required IconData icon,
    required bool enabled,
    required VoidCallback onPressed,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: enabled ? onPressed : null,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: enabled ? Colors.white : Colors.white.withValues(alpha: 0.5),
          border: Border.all(color: const Color(0xFFDBD1C5)),
        ),
        child: Icon(
          icon,
          size: 22,
          color: enabled ? const Color(0xFF3A3849) : Colors.black26,
        ),
      ),
    );
  }

  Widget _dayCard(_ItineraryDay day) {
    final weatherPrimary = _weatherPrimaryText(day);
    final weatherSecondary = _weatherSecondaryText(day);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFFFFC369), Color(0xFFF6A2AF), Color(0xFF84B2FF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _formatDateLabel(day.date),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '第 ${day.day} 天',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  weatherPrimary,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (weatherSecondary.isNotEmpty)
                  Text(
                    weatherSecondary,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Icon(_weatherIcon(day.weather?.code), color: Colors.white, size: 28),
        ],
      ),
    );
  }

  void _animateToDay(int index) {
    if (index < 0 || index >= _plan.days.length) return;
    if (_timelineScrollController.hasClients) {
      _timelineScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
    _dayPageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  List<Widget> _buildTimelineChildren(_ItineraryDay day) {
    if (day.items.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: Center(
            child: Text(
              '這一天沒有安排景點',
              style: TextStyle(fontSize: 16, color: Colors.black54),
            ),
          ),
        ),
      ];
    }

    final children = <Widget>[];
    for (var stopIndex = 0; stopIndex < day.items.length; stopIndex++) {
      if (stopIndex > 0) {
        final fromIndex = stopIndex - 1;
        final from = day.items[fromIndex];
        final to = day.items[stopIndex];
        final transit = _resolvedTransitInfoForTimeline(
          day,
          fromIndex,
          stopIndex,
          from,
          to,
        );
        if (transit != null) {
          final selectedModeKey = _normalizeTransitMode(
            _transitModeOverrides[_transitSegmentKey(day, fromIndex)],
          );
          children.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(width: 20),
                  Container(
                    width: 2,
                    height: 24,
                    color: const Color(0xFFE2D7EA),
                  ),
                  const SizedBox(width: 12),
                  Icon(transit.icon, size: 16, color: const Color(0xFF5B5779)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                transit.primaryLine,
                                style: const TextStyle(
                                  color: Color(0xFF5B5779),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            _buildTransitModeMenu(
                              day: day,
                              segmentIndex: fromIndex,
                              selected: selectedModeKey,
                            ),
                          ],
                        ),
                        if (transit.secondaryLine.isNotEmpty)
                          Text(
                            transit.secondaryLine,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF726E88),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }
      }

      final item = day.items[stopIndex];
      final range = _buildTimeRange(day, stopIndex);
      final stopCard = item.place.isMealBreak
          ? _buildMealBreakCard(day: day, itemIndex: stopIndex, item: item)
          : _buildPlaceStopCard(
              day: day,
              itemIndex: stopIndex,
              item: item,
              range: range,
            );
      final stopContent = item.place.isMealBreak
          ? stopCard
          : DragTarget<int>(
              onWillAcceptWithDetails: (details) {
                final fromIndex = details.data;
                if (fromIndex == stopIndex) return false;
                if (fromIndex < 0 || fromIndex >= day.items.length) {
                  return false;
                }
                return !day.items[fromIndex].place.isMealBreak;
              },
              onAcceptWithDetails: (details) {
                unawaited(_reorderDayStop(day, details.data, stopIndex));
              },
              builder: (context, candidateData, rejectedData) {
                final highlighted = candidateData.isNotEmpty;
                return LongPressDraggable<int>(
                  data: stopIndex,
                  feedback: Material(
                    color: Colors.transparent,
                    child: SizedBox(
                      width: MediaQuery.of(context).size.width - 120,
                      child: Opacity(opacity: 0.92, child: stopCard),
                    ),
                  ),
                  childWhenDragging: Opacity(opacity: 0.35, child: stopCard),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: highlighted
                        ? const EdgeInsets.all(4)
                        : EdgeInsets.zero,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      color: highlighted
                          ? const Color(0x336E8BD8)
                          : Colors.transparent,
                    ),
                    child: stopCard,
                  ),
                );
              },
            );
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 64,
                child: Text(
                  '${range.start}\n${range.end}',
                  style: const TextStyle(
                    height: 1.2,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF555266),
                  ),
                ),
              ),
              Column(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: item.place.isMealBreak
                          ? const Color(0xFFEC8F64)
                          : const Color(0xFF6E8BD8),
                      shape: BoxShape.circle,
                    ),
                  ),
                  Container(
                    width: 2,
                    height: 88,
                    color: const Color(0xFFE2D7EA),
                  ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(child: stopContent),
            ],
          ),
        ),
      );
    }

    return children;
  }

  Widget _imagePlaceholder() {
    return Container(
      width: 68,
      height: 68,
      color: const Color(0xFFF1ECE6),
      alignment: Alignment.center,
      child: const Icon(Icons.landscape, color: Colors.black38, size: 18),
    );
  }

  Widget _buildMealBreakCard({
    required _ItineraryDay day,
    required int itemIndex,
    required _ItineraryItem item,
  }) {
    final isLunch = item.place.tags.contains('lunch');
    final hasRestaurant = _hasValidPlaceCoordinate(item.place);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _openMealBreakPlanner(day, itemIndex, item),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFBF7),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFF0D8C9)),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: const Color(0xFFFDE9DE),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: Icon(
                isLunch
                    ? Icons.lunch_dining_rounded
                    : Icons.dinner_dining_rounded,
                color: const Color(0xFFB5623D),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.place.name,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF574351),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hasRestaurant
                        ? (item.place.address.isNotEmpty
                              ? item.place.address
                              : item.place.city)
                        : (item.place.description.isNotEmpty
                              ? item.place.description
                              : '預留用餐與休息時間，讓後續行程不會過趕。'),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF726E88),
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hasRestaurant ? '點擊可更換餐廳並重算交通時間' : '點擊可查看推薦餐廳並套用',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFB5623D),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceStopCard({
    required _ItineraryDay day,
    required int itemIndex,
    required _ItineraryItem item,
    required _TimeRange range,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _showPlaceDetail(
        day: day,
        itemIndex: itemIndex,
        item: item,
        range: range,
      ),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          item.place.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '編輯景點',
                        onSelected: (value) {
                          unawaited(
                            _handleStopEditAction(day, itemIndex, item, value),
                          );
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: 'duration',
                            child: Text('調整停留時間'),
                          ),
                          PopupMenuItem(value: 'delete', child: Text('刪除景點')),
                        ],
                        child: const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Icon(
                            Icons.more_horiz_rounded,
                            size: 18,
                            color: Color(0xFF6D6880),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.place.address.isNotEmpty
                        ? item.place.address
                        : item.place.city,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (item.place.rating != null) ...[
                        Text(
                          item.place.rating!.toStringAsFixed(1),
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.star,
                          size: 14,
                          color: Color(0xFF5A4E7C),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        '查看景點詳情',
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.6),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '長按可拖曳排序',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.42),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _api
                      .resolveImageUrl(
                        item.place.imageUrl,
                        placeId: item.place.id,
                      )
                      .isNotEmpty
                  ? Image.network(
                      _api.resolveImageUrl(
                        item.place.imageUrl,
                        placeId: item.place.id,
                      ),
                      width: 68,
                      height: 68,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _imagePlaceholder(),
                    )
                  : _imagePlaceholder(),
            ),
          ],
        ),
      ),
    );
  }

  void _showPlaceDetail({
    required _ItineraryDay day,
    required int itemIndex,
    required _ItineraryItem item,
    required _TimeRange range,
  }) {
    if (item.place.isMealBreak) return;
    final place = item.place;
    final resolvedImageUrl = _api.resolveImageUrl(
      place.imageUrl,
      placeId: place.id,
    );
    final previousItem = itemIndex > 0 ? day.items[itemIndex - 1] : null;
    final nextItem = itemIndex < day.items.length - 1
        ? day.items[itemIndex + 1]
        : null;
    final durationMinutes = _rangeDurationMinutes(range);
    final explanationFuture = _fetchStopExplanation(
      day: day,
      itemIndex: itemIndex,
      item: item,
      range: range,
      previousItem: previousItem,
      nextItem: nextItem,
      durationMinutes: durationMinutes,
    );

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: resolvedImageUrl.isNotEmpty
                      ? Image.network(
                          resolvedImageUrl,
                          width: double.infinity,
                          height: 180,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            height: 180,
                            color: const Color(0xFFF1ECE6),
                          ),
                        )
                      : Container(
                          height: 180,
                          color: const Color(0xFFF1ECE6),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.landscape,
                            color: Colors.black38,
                            size: 28,
                          ),
                        ),
                ),
                const SizedBox(height: 12),
                Text(
                  place.name,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  place.address.isNotEmpty ? place.address : place.city,
                  style: const TextStyle(fontSize: 14, color: Colors.black54),
                ),
                if (place.tags.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: place.tags
                        .take(6)
                        .map(
                          (tag) => Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEDE7F6),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              tag,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
                const SizedBox(height: 10),
                Text(
                  place.description.isNotEmpty ? place.description : '暫無景點介紹',
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: Colors.black87),
                ),
                const SizedBox(height: 12),
                FutureBuilder<Map<String, dynamic>>(
                  future: explanationFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return _buildStopExplanationCard(
                        title: '行程安排說明',
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  '正在生成這個景點的安排說明...',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    if (snapshot.hasError || !snapshot.hasData) {
                      return _buildStopExplanationCard(
                        title: '行程安排說明',
                        child: const Text(
                          '暫時無法取得此景點安排說明。',
                          style: TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                      );
                    }
                    final data = snapshot.data!;
                    final tips =
                        (data['tips'] as List?)
                            ?.map((e) => e.toString())
                            .where((e) => e.trim().isNotEmpty)
                            .toList() ??
                        const <String>[];
                    return _buildStopExplanationCard(
                      title: '行程安排說明',
                      source: data['source']?.toString(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if ((data['summary']?.toString() ?? '')
                              .trim()
                              .isNotEmpty)
                            Text(
                              data['summary'].toString(),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF2F2B41),
                              ),
                            ),
                          const SizedBox(height: 8),
                          _explainRow(
                            '為什麼加入',
                            data['whyIncluded']?.toString() ?? '',
                          ),
                          const SizedBox(height: 6),
                          _explainRow(
                            '為什麼這時段',
                            data['whyTiming']?.toString() ?? '',
                          ),
                          const SizedBox(height: 6),
                          _explainRow(
                            '為什麼停留這麼久',
                            data['whyDuration']?.toString() ?? '',
                          ),
                          if (tips.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            for (final tip in tips.take(3))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: Text(
                                  '• $tip',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    color: Color(0xFF5A5670),
                                  ),
                                ),
                              ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('關閉'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  int _rangeDurationMinutes(_TimeRange range) {
    final start = _parseHm(range.start);
    final end = _parseHm(range.end);
    if (start == null || end == null) return 90;
    final startMin = start.$1 * 60 + start.$2;
    final endMin = end.$1 * 60 + end.$2;
    if (endMin <= startMin) return 90;
    return endMin - startMin;
  }

  Future<Map<String, dynamic>> _fetchStopExplanation({
    required _ItineraryDay day,
    required int itemIndex,
    required _ItineraryItem item,
    required _TimeRange range,
    required _ItineraryItem? previousItem,
    required _ItineraryItem? nextItem,
    required int durationMinutes,
  }) async {
    final meta = _planJson['meta'];
    final metaMap = meta is Map
        ? Map<String, dynamic>.from(meta)
        : <String, dynamic>{};

    String? weatherSummary;
    String? weatherTempRange;
    if (day.weather != null) {
      weatherSummary = day.weather!.summary;
      final min = day.weather!.temperatureMin;
      final max = day.weather!.temperatureMax;
      if (min != null && max != null) {
        weatherTempRange = '${min.round()}~${max.round()}°C';
      }
    }

    final payload = <String, dynamic>{
      'date': day.date?.toIso8601String().substring(0, 10),
      'day': day.day,
      'startTime': range.start,
      'endTime': range.end,
      'durationMinutes': durationMinutes,
      'location': metaMap['location'],
      'budget': metaMap['budget'],
      'people': metaMap['people'],
      'interests': metaMap['tags'] is List
          ? List<dynamic>.from(metaMap['tags'] as List)
          : const [],
      'weatherSummary': weatherSummary,
      'weatherTempRange': weatherTempRange,
      'prevPlaceName': previousItem?.place.name,
      'nextPlaceName': nextItem?.place.name,
      'transitFromPrev': previousItem?.transitToNext
          ?.toTransitInfo()
          .primaryLine,
      'transitToNext': item.transitToNext?.toTransitInfo().primaryLine,
      'place': {
        'id': item.place.id,
        'name': item.place.name,
        'city': item.place.city,
        'address': item.place.address,
        'description': item.place.description,
        'tags': item.place.tags,
        'rating': item.place.rating,
      },
    };
    try {
      return await _api.explainItineraryStop(payload: payload);
    } catch (_) {
      return _buildLocalStopExplanation(
        day: day,
        item: item,
        range: range,
        previousItem: previousItem,
        nextItem: nextItem,
        durationMinutes: durationMinutes,
      );
    }
  }

  Map<String, dynamic> _buildLocalStopExplanation({
    required _ItineraryDay day,
    required _ItineraryItem item,
    required _TimeRange range,
    required _ItineraryItem? previousItem,
    required _ItineraryItem? nextItem,
    required int durationMinutes,
  }) {
    final meta = _planJson['meta'];
    final interests = meta is Map && meta['tags'] is List
        ? (meta['tags'] as List)
              .map((e) => e.toString().toLowerCase())
              .where((e) => e.isNotEmpty)
              .toSet()
        : <String>{};

    final matchedTags = item.place.tags
        .where((tag) => interests.contains(tag.toLowerCase()))
        .take(3)
        .toList();

    final includeReasonParts = <String>[
      if (matchedTags.isNotEmpty) '符合你的偏好類型（${matchedTags.join('、')}）',
      if (item.place.rating != null)
        '評分表現不錯（${item.place.rating!.toStringAsFixed(1)}）',
      if (item.place.city.isNotEmpty) '位於${item.place.city}，符合本日區域動線',
    ];

    final timingParts = <String>[
      '安排在 ${range.start}-${range.end}，用來銜接整體路線節奏',
      if (previousItem != null) '前一站是「${previousItem.place.name}」',
      if (nextItem != null) '下一站接「${nextItem.place.name}」',
      if (day.weather != null) '並參考當日天氣（${day.weather!.summary}）',
    ];

    String durationReason;
    if (durationMinutes >= 150) {
      durationReason = '此站時間較長，通常代表含深度參觀、拍照、休息或用餐彈性。';
    } else if (durationMinutes >= 90) {
      durationReason = '停留時間設定為中等，兼顧參觀品質與後續移動效率。';
    } else {
      durationReason = '此站安排為快速走訪，避免壓縮後續重點景點時間。';
    }

    return {
      'summary': '${item.place.name} 是這一天動線中的重要節點，用來平衡順路與體驗。',
      'whyIncluded': includeReasonParts.isEmpty
          ? '此景點與本次行程主題及路線順序相容，因此被納入。'
          : '因為${includeReasonParts.join('，')}。',
      'whyTiming': '${timingParts.join('，')}。',
      'whyDuration': durationReason,
      'tips': <String>[
        if (day.weather != null) '天氣：${day.weather!.summary}',
        if (durationMinutes >= 120) '可保留一些彈性時間給拍照或排隊',
        '若實際延誤，可先縮短停留再銜接下一站',
      ],
      'source': 'rule',
    };
  }

  Widget _buildStopExplanationCard({
    required String title,
    String? source,
    required Widget child,
  }) {
    final sourceLabel = source == 'gpt'
        ? 'GPT'
        : (source == 'rule' ? '規則' : null);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F2FB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE8DFF3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.auto_awesome,
                size: 15,
                color: Color(0xFF61528A),
              ),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (sourceLabel != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    sourceLabel,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Widget _explainRow(String label, String content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            color: Color(0xFF4E4768),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          content.isEmpty ? '暫無說明' : content,
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFF3D394C),
            height: 1.35,
          ),
        ),
      ],
    );
  }

  _TimeRange _buildTimeRange(_ItineraryDay day, int index) {
    final item = day.items[index];
    if (!_manuallyEditedDayKeys.contains(_dayEditKey(day)) &&
        !_hasTransitOverrideAffectingIndex(day, index)) {
      final explicitStart = item.time?.trim();
      final explicitEnd = item.endTime?.trim();
      if ((explicitStart ?? '').isNotEmpty && (explicitEnd ?? '').isNotEmpty) {
        return _TimeRange(start: explicitStart!, end: explicitEnd!);
      }
    }
    final start = _resolvedTimelineStartTime(day, index);
    final end = start.add(
      Duration(minutes: _resolvedItemDurationMinutes(day, index)),
    );
    return _TimeRange(start: _toHm(start), end: _toHm(end));
  }

  bool _hasTransitOverrideAffectingIndex(_ItineraryDay day, int index) {
    for (var i = 0; i < index; i++) {
      if (_transitModeOverrides.containsKey(_transitSegmentKey(day, i))) {
        return true;
      }
    }
    return false;
  }

  DateTime _resolvedTimelineStartTime(_ItineraryDay day, int index) {
    var current = _preferredDayStartDateTime(day);
    for (var i = 0; i < index; i++) {
      current = current.add(
        Duration(minutes: _resolvedItemDurationMinutes(day, i)),
      );
      current = current.add(
        Duration(minutes: _resolvedTransitMinutes(day, i, i + 1)),
      );
    }
    return current;
  }

  int _resolvedItemDurationMinutes(_ItineraryDay day, int index) {
    final item = day.items[index];
    final explicit = item.durationMinutes;
    if (explicit != null && explicit > 0) {
      return explicit;
    }
    final start = _parseHm(item.time);
    final end = _parseHm(item.endTime);
    if (start != null && end != null) {
      final startMinute = start.$1 * 60 + start.$2;
      final endMinute = end.$1 * 60 + end.$2;
      if (endMinute > startMinute) {
        return endMinute - startMinute;
      }
    }
    return item.place.isMealBreak ? 60 : 90;
  }

  int _resolvedTransitMinutes(
    _ItineraryDay day,
    int fromIndex,
    int nextItemIndex,
  ) {
    if (fromIndex < 0 || nextItemIndex >= day.items.length) {
      return 0;
    }
    final from = day.items[fromIndex];
    final to = day.items[nextItemIndex];
    if (!_canEstimateTransitBetween(from, to)) {
      return 0;
    }
    final options = _transitComparisonOptions(
      day,
      fromIndex,
      nextItemIndex,
      from,
      to,
    );
    final selectedModeKey = _normalizeTransitMode(
      _transitModeOverrides[_transitSegmentKey(day, fromIndex)],
    );
    return (options[selectedModeKey] ?? options['car']!).minutes;
  }

  _TransitInfo? _resolvedTransitInfoForTimeline(
    _ItineraryDay day,
    int fromIndex,
    int nextItemIndex,
    _ItineraryItem from,
    _ItineraryItem to,
  ) {
    if (!_canEstimateTransitBetween(from, to)) {
      return null;
    }
    final options = _transitComparisonOptions(
      day,
      fromIndex,
      nextItemIndex,
      from,
      to,
    );
    final selectedModeKey = _normalizeTransitMode(
      _transitModeOverrides[_transitSegmentKey(day, fromIndex)],
    );
    return options[selectedModeKey] ?? options['car'];
  }

  bool _canEstimateTransitBetween(_ItineraryItem from, _ItineraryItem to) {
    return _hasValidPlaceCoordinate(from.place) &&
        _hasValidPlaceCoordinate(to.place);
  }

  bool _hasValidPlaceCoordinate(_ItineraryPlace place) {
    final lat = place.lat;
    final lng = place.lng;
    if (lat == null || lng == null) {
      return false;
    }
    if (lat == 0 && lng == 0) {
      return false;
    }
    return true;
  }

  DateTime _preferredDayStartDateTime(_ItineraryDay day) {
    final base = day.date ?? DateTime.now();
    return DateTime(
      base.year,
      base.month,
      base.day,
      _preferredStartTime.hour,
      _preferredStartTime.minute,
    );
  }

  (int, int)? _parseHm(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    final parts = raw.split(':');
    if (parts.length != 2) {
      return null;
    }
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) {
      return null;
    }
    return (h.clamp(0, 23), m.clamp(0, 59));
  }

  String _toHm(DateTime value) {
    final h = value.hour.toString().padLeft(2, '0');
    final m = value.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Map<String, _TransitInfo> _transitComparisonOptions(
    _ItineraryDay day,
    int segmentIndex,
    int nextItemIndex,
    _ItineraryItem from,
    _ItineraryItem to,
  ) {
    final resolvedTransit = _resolveSegmentTransit(
      day,
      segmentIndex,
      nextItemIndex,
    );
    final transit =
        resolvedTransit?.toTransitInfo() ??
        _estimateTransitByMode(from.place, to.place, 'transit');
    return {
      'transit': transit,
      'car': _estimateTransitByMode(from.place, to.place, 'car'),
      'walk': _estimateTransitByMode(from.place, to.place, 'walk'),
    };
  }

  _ItineraryTransit? _resolveSegmentTransit(
    _ItineraryDay day,
    int fromItemIndex,
    int toItemIndex,
  ) {
    final upper = toItemIndex.clamp(fromItemIndex + 1, day.items.length);
    for (var i = fromItemIndex; i < upper; i++) {
      final transit = day.items[i].transitToNext;
      if (transit != null) return transit;
    }
    return null;
  }

  String _transitSegmentKey(_ItineraryDay day, int segmentIndex) {
    final dateKey = day.date?.toIso8601String() ?? 'day-${day.day}';
    return '$dateKey#$segmentIndex';
  }

  Widget _buildTransitModeMenu({
    required _ItineraryDay day,
    required int segmentIndex,
    required String selected,
  }) {
    const modeLabels = {'transit': '大眾', 'car': '開車', 'walk': '步行'};
    return Container(
      height: 24,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: const Color(0xFFD7CEE6).withValues(alpha: 0.7),
          width: 0.8,
        ),
      ),
      child: PopupMenuButton<String>(
        tooltip: '比較交通方式',
        padding: EdgeInsets.zero,
        initialValue: selected,
        onSelected: (value) {
          setState(() {
            _transitModeOverrides[_transitSegmentKey(day, segmentIndex)] =
                value;
          });
        },
        color: Colors.white.withValues(alpha: 0.97),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'transit', child: Text('大眾運輸')),
          PopupMenuItem(value: 'car', child: Text('開車/計程車')),
          PopupMenuItem(value: 'walk', child: Text('步行')),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                modeLabels[_normalizeTransitMode(selected)] ?? '開車',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF5B5779),
                ),
              ),
              const SizedBox(width: 2),
              const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 14,
                color: Color(0xFF5B5779),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _TransitInfo _estimateTransitByMode(
    _ItineraryPlace from,
    _ItineraryPlace to,
    String mode,
  ) {
    mode = _normalizeTransitMode(mode);
    final km = _haversineKm(
      from.lat ?? 0,
      from.lng ?? 0,
      to.lat ?? 0,
      to.lng ?? 0,
    );
    final safeKm = km.isFinite ? km : 0.0;
    if (mode == 'walk') {
      final mins = math.max(5, (safeKm / 4.5 * 60).round());
      return _TransitInfo(
        primaryLine: '步行  約 $mins 分鐘 · ${safeKm.toStringAsFixed(1)} km',
        secondaryLine: safeKm > 3.0 ? '步行距離較長，僅供比較' : '',
        minutes: mins,
        icon: Icons.directions_walk,
      );
    }
    if (mode == 'car') {
      final speed = safeKm < 10 ? 28 : 40;
      final mins = math.max(8, (safeKm / speed * 60).round());
      return _TransitInfo(
        primaryLine: '開車/計程車  約 $mins 分鐘 · ${safeKm.toStringAsFixed(1)} km',
        secondaryLine: '依市區路況估算',
        minutes: mins,
        icon: Icons.directions_car_filled,
      );
    }
    if (mode == 'transit') {
      final mins = safeKm < 8
          ? math.max(15, (safeKm / 18 * 60).round())
          : math.max(20, (safeKm / 35 * 60).round() + 8);
      return _TransitInfo(
        primaryLine: '大眾運輸  約 $mins 分鐘 · ${safeKm.toStringAsFixed(1)} km',
        secondaryLine: '含候車/轉乘時間估算',
        minutes: mins,
        icon: Icons.directions_transit,
      );
    }

    return _estimateTransitByMode(from, to, 'car');
  }

  String _normalizeTransitMode(String? mode) {
    return switch (mode) {
      'transit' => 'transit',
      'car' => 'car',
      'walk' => 'walk',
      'best' || null => 'car',
      _ => 'car',
    };
  }

  double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    final dLat = _toRad(lat2 - lat1);
    final dLon = _toRad(lon2 - lon1);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRad(lat1)) *
            math.cos(_toRad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  double _toRad(double degree) => degree * math.pi / 180;

  String _formatDateLabel(DateTime? date) {
    if (date == null) return '未提供日期';
    return '${date.month}月${date.day}日';
  }

  String _weatherHint(DateTime? date) {
    if (date == null) return '天氣資料整理中';
    final month = date.month;
    if (month >= 6 && month <= 9) {
      return '天氣偏熱，建議補水';
    }
    if (month >= 11 || month <= 2) {
      return '天氣偏涼，建議外套';
    }
    return '舒適天氣，適合走訪';
  }

  String _weatherPrimaryText(_ItineraryDay day) {
    final weather = day.weather;
    if (weather == null) {
      return _weatherHint(day.date);
    }
    final min = weather.temperatureMin;
    final max = weather.temperatureMax;
    if (min != null && max != null) {
      return '${weather.summary}  ${min.round()}~${max.round()}°C';
    }
    return weather.summary;
  }

  String _weatherSecondaryText(_ItineraryDay day) {
    final weather = day.weather;
    if (weather == null) {
      return '';
    }
    if (weather.precipitationProbability != null) {
      return '降雨機率 ${weather.precipitationProbability}%';
    }
    if (weather.source.isNotEmpty) {
      return '資料來源 ${weather.source}';
    }
    return '';
  }

  IconData _weatherIcon(int? code) {
    if (code == null) return Icons.wb_sunny_rounded;
    if (code == 0) return Icons.wb_sunny_rounded;
    if (code >= 1 && code <= 3) return Icons.cloud_rounded;
    if (code >= 45 && code <= 48) return Icons.cloud_rounded;
    if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) {
      return Icons.grain_rounded;
    }
    if (code >= 71 && code <= 77) return Icons.ac_unit_rounded;
    if (code >= 95) return Icons.thunderstorm_rounded;
    return Icons.cloud_rounded;
  }
}

class _TransitInfo {
  const _TransitInfo({
    required this.primaryLine,
    required this.secondaryLine,
    required this.minutes,
    required this.icon,
  });

  final String primaryLine;
  final String secondaryLine;
  final int minutes;
  final IconData icon;
}

class _DayRouteStop {
  const _DayRouteStop({
    required this.order,
    required this.itemIndex,
    required this.item,
    required this.position,
  });

  final int order;
  final int itemIndex;
  final _ItineraryItem item;
  final LatLng position;
}

class _DayRouteSegment {
  const _DayRouteSegment({
    required this.from,
    required this.to,
    required this.selectedMode,
    required this.transit,
  });

  final _DayRouteStop from;
  final _DayRouteStop to;
  final String selectedMode;
  final _TransitInfo transit;
}

class _DayRouteMapSheet extends StatefulWidget {
  const _DayRouteMapSheet({
    required this.day,
    required this.stops,
    required this.segments,
    required this.dateLabel,
  });

  final _ItineraryDay day;
  final List<_DayRouteStop> stops;
  final List<_DayRouteSegment> segments;
  final String dateLabel;

  @override
  State<_DayRouteMapSheet> createState() => _DayRouteMapSheetState();
}

class _DayRouteMapSheetState extends State<_DayRouteMapSheet> {
  static const _googleMapsApiKey = String.fromEnvironment(
    'GOOGLE_MAPS_API_KEY',
  );

  GoogleMapController? _mapController;
  bool _didFitBounds = false;
  bool _loadingRoadRoute = false;
  String _roadRouteHint = '';
  final Map<int, List<LatLng>> _segmentRoadPaths = {};

  @override
  void initState() {
    super.initState();
    unawaited(_loadRoadPolylines());
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final markers = widget.stops
        .map(
          (stop) => Marker(
            markerId: MarkerId('stop-${stop.order}-${stop.item.place.id}'),
            position: stop.position,
            infoWindow: InfoWindow(
              title: '${stop.order}. ${stop.item.place.name}',
              snippet: [
                if ((stop.item.time ?? '').trim().isNotEmpty) stop.item.time!,
                if (stop.item.place.address.trim().isNotEmpty)
                  stop.item.place.address,
              ].join(' · '),
            ),
          ),
        )
        .toSet();

    final polylines = <Polyline>{
      for (var i = 0; i < widget.segments.length; i++)
        Polyline(
          polylineId: PolylineId('seg-$i'),
          points:
              _segmentRoadPaths[i] ??
              [
                widget.segments[i].from.position,
                widget.segments[i].to.position,
              ],
          color: _segmentColor(widget.segments[i].selectedMode),
          width: 5,
          geodesic: true,
        ),
    };

    final center = _averageLatLng(widget.stops.map((e) => e.position).toList());

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF4EFE8),
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${widget.dateLabel} · 第${widget.day.day}天路線地圖',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF241F2D),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '標記 ${widget.stops.length} 個景點${widget.segments.isNotEmpty ? '，含 ${widget.segments.length} 段交通' : ''}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF6A6478),
                          ),
                        ),
                        if (_loadingRoadRoute)
                          const Text(
                            '正在載入 Google Directions 道路路線...',
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFF6A6478),
                            ),
                          )
                        else if (_roadRouteHint.isNotEmpty)
                          Text(
                            _roadRouteHint,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF8A7A64),
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '關閉',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: SizedBox(
                  height: 280,
                  child: GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: center,
                      zoom: 11,
                    ),
                    markers: markers,
                    polylines: polylines,
                    myLocationButtonEnabled: false,
                    zoomControlsEnabled: false,
                    mapToolbarEnabled: false,
                    onMapCreated: (controller) {
                      _mapController = controller;
                      _fitBoundsIfNeeded();
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
                children: [
                  _buildLegend(),
                  const SizedBox(height: 10),
                  ..._buildRouteRows(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadRoadPolylines() async {
    if (_googleMapsApiKey.trim().isEmpty || widget.segments.isEmpty) return;
    setState(() {
      _loadingRoadRoute = true;
    });

    final resolved = <int, List<LatLng>>{};
    var fallbackUsed = false;
    var deniedCount = 0;
    var zeroResultCount = 0;
    for (var i = 0; i < widget.segments.length; i++) {
      final segment = widget.segments[i];
      final modes = _directionsModesToTry(segment);
      final result = await _fetchDirectionsPolyline(
        origin: segment.from.position,
        destination: segment.to.position,
        modes: modes,
      );
      if (result.points != null && result.points!.length > 1) {
        resolved[i] = result.points!;
        if (result.usedMode != null && result.usedMode != modes.first) {
          fallbackUsed = true;
        }
      } else {
        if (result.lastStatus == 'REQUEST_DENIED' ||
            result.lastStatus == 'OVER_DAILY_LIMIT' ||
            result.lastStatus == 'OVER_QUERY_LIMIT') {
          deniedCount++;
        } else if (result.lastStatus == 'ZERO_RESULTS') {
          zeroResultCount++;
        }
      }
    }

    if (!mounted) return;
    var hint = '';
    if (resolved.isNotEmpty) {
      if (fallbackUsed) {
        hint = '部分路段已自動改用開車/步行模式顯示道路路線。';
      }
    } else if (widget.segments.isNotEmpty) {
      if (deniedCount > 0) {
        hint = 'Directions 請求被拒絕，請確認 API 金鑰已啟用 Directions API。';
      } else if (zeroResultCount > 0) {
        hint = 'Directions 沒有回傳可用路線，暫以直線顯示。';
      } else {
        hint = '目前顯示估算直線路徑（Directions 未回傳道路折線）';
      }
    }
    setState(() {
      _segmentRoadPaths
        ..clear()
        ..addAll(resolved);
      _loadingRoadRoute = false;
      _roadRouteHint = hint;
    });
  }

  List<String> _directionsModesToTry(_DayRouteSegment segment) {
    switch (_normalizeTransitMode(segment.selectedMode)) {
      case 'car':
        return const ['driving'];
      case 'walk':
        return const ['walking', 'driving'];
      case 'transit':
        return const ['transit', 'driving'];
      default:
        return const ['driving'];
    }
  }

  String _normalizeTransitMode(String? mode) {
    return switch (mode) {
      'transit' => 'transit',
      'car' => 'car',
      'walk' => 'walk',
      'best' || null => 'car',
      _ => 'car',
    };
  }

  Future<_DirectionsFetchResult> _fetchDirectionsPolyline({
    required LatLng origin,
    required LatLng destination,
    required List<String> modes,
  }) async {
    String? lastStatus;
    for (final mode in modes) {
      final uri =
          Uri.https('maps.googleapis.com', '/maps/api/directions/json', {
            'origin': '${origin.latitude},${origin.longitude}',
            'destination': '${destination.latitude},${destination.longitude}',
            'mode': mode,
            'language': 'zh-TW',
            'key': _googleMapsApiKey,
          });
      try {
        final response = await http
            .get(uri)
            .timeout(const Duration(seconds: 8));
        if (response.statusCode >= 400) {
          lastStatus = 'HTTP_${response.statusCode}';
          continue;
        }
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final status = body['status']?.toString() ?? '';
        lastStatus = status;
        if (status != 'OK') {
          continue;
        }
        final routes = body['routes'];
        if (routes is! List || routes.isEmpty) continue;
        final route0 = routes.first;
        if (route0 is! Map) continue;
        final overview = route0['overview_polyline'];
        if (overview is! Map) continue;
        final encoded = overview['points']?.toString() ?? '';
        if (encoded.isEmpty) continue;
        final decoded = _decodePolyline(encoded);
        if (decoded.length < 2) continue;
        return _DirectionsFetchResult(
          points: decoded,
          usedMode: mode,
          lastStatus: status,
        );
      } catch (_) {
        lastStatus = 'EXCEPTION';
      }
    }
    return _DirectionsFetchResult(lastStatus: lastStatus);
  }

  List<LatLng> _decodePolyline(String encoded) {
    final points = <LatLng>[];
    var index = 0;
    var lat = 0;
    var lng = 0;

    while (index < encoded.length) {
      var result = 0;
      var shift = 0;
      int byte;
      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20 && index < encoded.length);
      final dLat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lat += dLat;

      result = 0;
      shift = 0;
      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20 && index < encoded.length);
      final dLng = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lng += dLng;

      points.add(LatLng(lat / 1e5, lng / 1e5));
    }

    return points;
  }

  Widget _buildLegend() {
    final legend = const [('transit', '大眾'), ('car', '開車'), ('walk', '步行')];
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: legend
          .map(
            (entry) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0xFFE4DACC)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _segmentColor(entry.$1),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    entry.$2,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF4C465A),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }

  List<Widget> _buildRouteRows() {
    final rows = <Widget>[];
    for (var i = 0; i < widget.stops.length; i++) {
      final stop = widget.stops[i];
      rows.add(_buildStopCard(stop));
      if (i < widget.segments.length) {
        rows.add(const SizedBox(height: 8));
        rows.add(_buildTransitCard(widget.segments[i], i + 1));
      }
      if (i != widget.stops.length - 1) {
        rows.add(const SizedBox(height: 10));
      }
    }
    return rows;
  }

  Widget _buildStopCard(_DayRouteStop stop) {
    final place = stop.item.place;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE6DDCF)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFF6E8BD8),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '${stop.order}',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if ((stop.item.time ?? '').trim().isNotEmpty)
                  Text(
                    stop.item.time!,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF6A6478),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                Text(
                  place.name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF231E2D),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  place.address.isNotEmpty ? place.address : place.city,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF6A6478),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransitCard(_DayRouteSegment segment, int segmentNo) {
    return Container(
      margin: const EdgeInsets.only(left: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE4DACC)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            segment.transit.icon,
            size: 16,
            color: _segmentColor(segment.selectedMode),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '第 $segmentNo 段交通 · ${_modeLabel(segment.selectedMode)}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF5E5875),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  segment.transit.primaryLine,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF2A2435),
                  ),
                ),
                if (segment.transit.secondaryLine.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    segment.transit.secondaryLine,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF6A6478),
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  '${segment.from.item.place.name} -> ${segment.to.item.place.name}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF7A7488),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _modeLabel(String mode) => switch (mode) {
    'transit' => '大眾',
    'car' => '開車',
    'walk' => '步行',
    _ => '開車',
  };

  Color _segmentColor(String mode) => switch (mode) {
    'transit' => const Color(0xFF6B5FCF),
    'car' => const Color(0xFF4A8FDF),
    'walk' => const Color(0xFF46A36C),
    _ => const Color(0xFFE08A5A),
  };

  LatLng _averageLatLng(List<LatLng> points) {
    if (points.isEmpty) return const LatLng(23.6978, 120.9605);
    var lat = 0.0;
    var lng = 0.0;
    for (final p in points) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / points.length, lng / points.length);
  }

  Future<void> _fitBoundsIfNeeded() async {
    if (_didFitBounds || _mapController == null || widget.stops.isEmpty) return;
    _didFitBounds = true;
    if (widget.stops.length == 1) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted || _mapController == null) return;
      await _mapController!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: widget.stops.first.position, zoom: 14.5),
        ),
      );
      return;
    }

    final lats = widget.stops.map((e) => e.position.latitude).toList();
    final lngs = widget.stops.map((e) => e.position.longitude).toList();
    final sw = LatLng(lats.reduce(math.min), lngs.reduce(math.min));
    final ne = LatLng(lats.reduce(math.max), lngs.reduce(math.max));

    await Future<void>.delayed(const Duration(milliseconds: 280));
    if (!mounted || _mapController == null) return;
    try {
      await _mapController!.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(southwest: sw, northeast: ne),
          60,
        ),
      );
    } catch (_) {
      await _mapController!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: _averageLatLng(
              widget.stops.map((e) => e.position).toList(),
            ),
            zoom: 11,
          ),
        ),
      );
    }
  }
}

class _DirectionsFetchResult {
  const _DirectionsFetchResult({this.points, this.usedMode, this.lastStatus});

  final List<LatLng>? points;
  final String? usedMode;
  final String? lastStatus;
}

class _TimeRange {
  const _TimeRange({required this.start, required this.end});

  final String start;
  final String end;
}

class _ItineraryPlan {
  const _ItineraryPlan({required this.days, this.insight});

  final List<_ItineraryDay> days;
  final _ItineraryInsight? insight;

  factory _ItineraryPlan.fromJson(Map<String, dynamic> json) {
    final rawDays = json['days'];
    if (rawDays is! List) {
      return const _ItineraryPlan(days: []);
    }
    final rawInsight = json['insight'];
    return _ItineraryPlan(
      days: rawDays
          .whereType<Map>()
          .map(
            (item) => _ItineraryDay.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(),
      insight: rawInsight is Map
          ? _ItineraryInsight.fromJson(Map<String, dynamic>.from(rawInsight))
          : null,
    );
  }
}

class _ItineraryInsight {
  const _ItineraryInsight({
    required this.summary,
    required this.planningFocus,
    required this.alternativePlan,
    required this.routeReason,
    required this.userLikeReason,
    required this.tips,
    required this.warnings,
    required this.improvements,
    required this.pacing,
    required this.mealPlan,
    required this.source,
  });

  final String summary;
  final String planningFocus;
  final String alternativePlan;
  final String routeReason;
  final String userLikeReason;
  final List<String> tips;
  final List<String> warnings;
  final List<String> improvements;
  final String pacing;
  final String mealPlan;
  final String source;

  factory _ItineraryInsight.fromJson(Map<String, dynamic> json) {
    return _ItineraryInsight(
      summary: json['summary']?.toString() ?? '',
      planningFocus: json['planningFocus']?.toString() ?? '',
      alternativePlan: json['alternativePlan']?.toString() ?? '',
      routeReason: json['routeReason']?.toString() ?? '',
      userLikeReason: json['userLikeReason']?.toString() ?? '',
      tips:
          (json['tips'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      warnings:
          (json['warnings'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      improvements:
          (json['improvements'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      pacing: json['pacing']?.toString() ?? '',
      mealPlan: json['mealPlan']?.toString() ?? '',
      source: json['source']?.toString() ?? 'rule',
    );
  }
}

class _ItineraryDay {
  const _ItineraryDay({
    required this.day,
    required this.date,
    required this.weather,
    required this.originTransit,
    required this.items,
  });

  final int day;
  final DateTime? date;
  final _ItineraryWeather? weather;
  final _ItineraryTransit? originTransit;
  final List<_ItineraryItem> items;

  factory _ItineraryDay.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final rawWeather = json['weather'];
    final rawOriginTransit = json['originTransit'];
    return _ItineraryDay(
      day: (json['day'] as num?)?.toInt() ?? 1,
      date: DateTime.tryParse(json['date']?.toString() ?? ''),
      weather: rawWeather is Map
          ? _ItineraryWeather.fromJson(Map<String, dynamic>.from(rawWeather))
          : null,
      originTransit: rawOriginTransit is Map
          ? _ItineraryTransit.fromJson(
              Map<String, dynamic>.from(rawOriginTransit),
            )
          : null,
      items: rawItems is List
          ? rawItems
                .whereType<Map>()
                .map(
                  (item) =>
                      _ItineraryItem.fromJson(Map<String, dynamic>.from(item)),
                )
                .toList()
          : const [],
    );
  }
}

class _ItineraryWeather {
  const _ItineraryWeather({
    required this.summary,
    required this.code,
    required this.temperatureMin,
    required this.temperatureMax,
    required this.precipitationProbability,
    required this.source,
  });

  final String summary;
  final int? code;
  final double? temperatureMin;
  final double? temperatureMax;
  final int? precipitationProbability;
  final String source;

  factory _ItineraryWeather.fromJson(Map<String, dynamic> json) {
    return _ItineraryWeather(
      summary: json['summary']?.toString() ?? '天氣資料整理中',
      code: (json['code'] as num?)?.toInt(),
      temperatureMin: (json['temperatureMin'] as num?)?.toDouble(),
      temperatureMax: (json['temperatureMax'] as num?)?.toDouble(),
      precipitationProbability: (json['precipitationProbability'] as num?)
          ?.toInt(),
      source: json['source']?.toString() ?? '',
    );
  }
}

class _ItineraryItem {
  const _ItineraryItem({
    required this.time,
    required this.endTime,
    required this.durationMinutes,
    required this.place,
    required this.transitToNext,
  });

  final String? time;
  final String? endTime;
  final int? durationMinutes;
  final _ItineraryPlace place;
  final _ItineraryTransit? transitToNext;

  factory _ItineraryItem.fromJson(Map<String, dynamic> json) {
    final rawTransit = json['transitToNext'];
    return _ItineraryItem(
      time: json['time']?.toString(),
      endTime: json['endTime']?.toString(),
      durationMinutes: (json['durationMinutes'] as num?)?.toInt(),
      place: _ItineraryPlace.fromJson(
        Map<String, dynamic>.from(json['place'] as Map? ?? const {}),
      ),
      transitToNext: rawTransit is Map
          ? _ItineraryTransit.fromJson(Map<String, dynamic>.from(rawTransit))
          : null,
    );
  }
}

class _ItineraryTransit {
  const _ItineraryTransit({
    required this.mode,
    required this.label,
    required this.minutes,
    required this.distanceText,
    required this.lines,
    required this.departureTime,
    required this.arrivalTime,
    required this.detail,
    required this.fromLabel,
    required this.toLabel,
  });

  final String mode;
  final String label;
  final int minutes;
  final String distanceText;
  final List<String> lines;
  final String? departureTime;
  final String? arrivalTime;
  final String detail;
  final String? fromLabel;
  final String? toLabel;

  factory _ItineraryTransit.fromJson(Map<String, dynamic> json) {
    return _ItineraryTransit(
      mode: json['mode']?.toString() ?? 'transit',
      label: json['label']?.toString() ?? '大眾運輸',
      minutes: (json['minutes'] as num?)?.toInt() ?? 0,
      distanceText: json['distanceText']?.toString() ?? '',
      lines:
          (json['lines'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      departureTime: json['departureTime']?.toString(),
      arrivalTime: json['arrivalTime']?.toString(),
      detail: json['detail']?.toString() ?? '',
      fromLabel: json['fromLabel']?.toString(),
      toLabel: json['toLabel']?.toString(),
    );
  }

  _TransitInfo toTransitInfo() {
    final icon = switch (mode) {
      'walk' => Icons.directions_walk,
      'car' => Icons.directions_car_filled,
      'bus' => Icons.directions_bus_filled,
      'rail' => Icons.train,
      _ => Icons.directions_transit,
    };
    final distancePart = distanceText.isNotEmpty ? ' · $distanceText' : '';
    final primary = '$label  約 $minutes 分鐘$distancePart';

    final timePart = (departureTime != null && arrivalTime != null)
        ? '$departureTime -> $arrivalTime'
        : '';
    final linePart = lines.isEmpty ? '' : '路線 ${lines.join(' / ')}';
    final detailPart = detail.trim();
    final extra = [
      timePart,
      linePart,
      detailPart,
    ].where((part) => part.trim().isNotEmpty).join(' · ');

    return _TransitInfo(
      primaryLine: primary,
      secondaryLine: extra,
      minutes: minutes,
      icon: icon,
    );
  }
}

class _MealCandidateOption {
  const _MealCandidateOption({
    required this.raw,
    required this.place,
    required this.fromPrevMinutes,
    required this.toNextMinutes,
    required this.fitScore,
  });

  final Map<String, dynamic> raw;
  final _ItineraryPlace place;
  final int fromPrevMinutes;
  final int toNextMinutes;
  final double fitScore;
}

class _ItineraryPlace {
  const _ItineraryPlace({
    required this.id,
    required this.name,
    required this.kind,
    required this.city,
    required this.address,
    required this.description,
    required this.imageUrl,
    required this.tags,
    required this.rating,
    required this.lat,
    required this.lng,
  });

  final String id;
  final String name;
  final String kind;
  final String city;
  final String address;
  final String description;
  final String imageUrl;
  final List<String> tags;
  final double? rating;
  final double? lat;
  final double? lng;

  bool get isMealBreak => kind == 'meal_break';

  factory _ItineraryPlace.fromJson(Map<String, dynamic> json) {
    return _ItineraryPlace(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      kind: json['kind']?.toString() ?? 'place',
      city: json['city']?.toString() ?? '',
      address: json['address']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      imageUrl: BackendApi.instance.resolveImageUrl(
        json['imageUrl']?.toString() ?? '',
        placeId: json['id']?.toString(),
      ),
      tags: (json['tags'] as List?)?.whereType<String>().toList() ?? const [],
      rating: (json['rating'] as num?)?.toDouble(),
      lat: (json['lat'] as num?)?.toDouble(),
      lng: (json['lng'] as num?)?.toDouble(),
    );
  }
}
