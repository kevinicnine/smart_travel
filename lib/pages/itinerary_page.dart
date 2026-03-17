import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../services/backend_api.dart';
import '../state/user_state.dart';

class ItineraryPage extends StatefulWidget {
  const ItineraryPage({super.key, required this.plan});

  final Map<String, dynamic> plan;

  @override
  State<ItineraryPage> createState() => _ItineraryPageState();
}

class _ItineraryPageState extends State<ItineraryPage> {
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

  @override
  void initState() {
    super.initState();
    _planJson = Map<String, dynamic>.from(widget.plan);
    _plan = _ItineraryPlan.fromJson(_planJson);
    _dayPageController = PageController();
    _hydrateArrangementPreferencesFromPlanMeta();
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
                  child: Column(
                    children: [
                      _buildDaySelector(days),
                      if (_hasArrangementPreferences) ...[
                        const SizedBox(height: 8),
                        _buildArrangementPreferenceCard(),
                      ],
                      if (_plan.insight != null) ...[
                        const SizedBox(height: 8),
                        _buildInsightCard(_plan.insight!),
                      ],
                      const SizedBox(height: 10),
                      Expanded(child: _buildTimeline(days[_selectedDayIndex])),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('這一天的景點沒有座標，無法顯示路線地圖。')),
      );
      return;
    }

    final segments = <_DayRouteSegment>[];
    for (var i = 0; i < stops.length - 1; i++) {
      final fromStop = stops[i];
      final toStop = stops[i + 1];
      final options = _transitComparisonOptions(
        day,
        fromStop.itemIndex,
        fromStop.item,
        toStop.item,
      );
      final selectedMode =
          _transitModeOverrides[_transitSegmentKey(day, fromStop.itemIndex)] ??
          'best';
      segments.add(
        _DayRouteSegment(
          from: fromStop,
          to: toStop,
          selectedMode: selectedMode,
          transit: options[selectedMode] ?? options['best']!,
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

  Widget _buildInsightCard(_ItineraryInsight insight) {
    final tips = insight.tips.take(3).toList();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE0D8CE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(
                Icons.auto_awesome_rounded,
                size: 16,
                color: Color(0xFF625A8A),
              ),
              const SizedBox(width: 6),
              Text(
                insight.source == 'gpt' ? 'GPT 行程解釋' : '行程解釋',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2F2B3F),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (insight.summary.isNotEmpty)
            Text(
              insight.summary,
              style: const TextStyle(
                fontSize: 13,
                height: 1.35,
                fontWeight: FontWeight.w700,
                color: Color(0xFF292533),
              ),
            ),
          if (insight.routeReason.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '順路原因：${insight.routeReason}',
              style: const TextStyle(
                fontSize: 12,
                height: 1.35,
                color: Color(0xFF4C4760),
              ),
            ),
          ],
          if (insight.userLikeReason.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              '喜好匹配：${insight.userLikeReason}',
              style: const TextStyle(
                fontSize: 12,
                height: 1.35,
                color: Color(0xFF4C4760),
              ),
            ),
          ],
          if (tips.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final tip in tips)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '• $tip',
                  style: const TextStyle(
                    fontSize: 11.5,
                    height: 1.3,
                    color: Color(0xFF5A5670),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  void _animateToDay(int index) {
    if (index < 0 || index >= _plan.days.length) return;
    _dayPageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Widget _buildTimeline(_ItineraryDay day) {
    if (day.items.isEmpty) {
      return const Center(
        child: Text(
          '這一天沒有安排景點',
          style: TextStyle(fontSize: 16, color: Colors.black54),
        ),
      );
    }

    return ListView.builder(
      controller: _timelineScrollController,
      physics: const BouncingScrollPhysics(),
      itemCount: day.items.length * 2 - 1,
      itemBuilder: (context, index) {
        if (index.isOdd) {
          final fromIndex = (index - 1) ~/ 2;
          final from = day.items[fromIndex];
          final to = day.items[(index + 1) ~/ 2];
          final options = _transitComparisonOptions(day, fromIndex, from, to);
          final selectedModeKey =
              _transitModeOverrides[_transitSegmentKey(day, fromIndex)] ??
              'best';
          final transit = options[selectedModeKey] ?? options['best']!;
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(width: 20),
                Container(width: 2, height: 24, color: const Color(0xFFE2D7EA)),
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
          );
        }

        final stopIndex = index ~/ 2;
        final item = day.items[stopIndex];
        final range = _buildTimeRange(day, stopIndex);
        return Padding(
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
                    decoration: const BoxDecoration(
                      color: Color(0xFF6E8BD8),
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
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _showPlaceDetail(
                    day: day,
                    itemIndex: stopIndex,
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
                              Text(
                                item.place.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                item.place.address.isNotEmpty
                                    ? item.place.address
                                    : item.place.city,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.black54,
                                ),
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
                                      color: Colors.black.withValues(
                                        alpha: 0.6,
                                      ),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: item.place.imageUrl.isNotEmpty
                              ? Image.network(
                                  item.place.imageUrl,
                                  width: 68,
                                  height: 68,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) =>
                                      _imagePlaceholder(),
                                )
                              : _imagePlaceholder(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
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

  void _showPlaceDetail({
    required _ItineraryDay day,
    required int itemIndex,
    required _ItineraryItem item,
    required _TimeRange range,
  }) {
    final place = item.place;
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
                  child: place.imageUrl.isNotEmpty
                      ? Image.network(
                          place.imageUrl,
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
    final start = _resolveDisplayStartTime(day, index, item.time);
    DateTime end;
    if (index < day.items.length - 1) {
      final next = day.items[index + 1];
      final nextStart = _resolveDisplayStartTime(day, index + 1, next.time);
      end = nextStart.isAfter(start)
          ? nextStart
          : start.add(const Duration(minutes: 90));
    } else {
      end = _preferredDayEndDateTime(day);
      if (!end.isAfter(start)) {
        end = start.add(const Duration(minutes: 90));
      }
    }
    return _TimeRange(start: _toHm(start), end: _toHm(end));
  }

  DateTime _resolveDisplayStartTime(
    _ItineraryDay day,
    int index,
    String? rawTime,
  ) {
    final raw = _resolveRawStartTime(day, index, rawTime);
    if (day.items.isEmpty) return raw;
    final rawDayStart = _resolveRawStartTime(day, 0, day.items.first.time);
    final rawDayEnd = _estimateRawDayEndTime(day);
    final targetStart = _preferredDayStartDateTime(day);
    final targetEnd = _preferredDayEndDateTime(day);

    final rawSpan = rawDayEnd.difference(rawDayStart).inMinutes;
    final targetSpan = targetEnd.difference(targetStart).inMinutes;
    if (rawSpan <= 0 || targetSpan <= 0) {
      return raw;
    }

    final rawOffset = raw.difference(rawDayStart).inMinutes.clamp(0, rawSpan);
    final mappedMinutes = (rawOffset * targetSpan / rawSpan).round();
    return targetStart.add(Duration(minutes: mappedMinutes));
  }

  DateTime _resolveRawStartTime(_ItineraryDay day, int index, String? rawTime) {
    final base = day.date ?? DateTime.now();
    final parsed = _parseHm(rawTime);
    if (parsed != null) {
      return DateTime(base.year, base.month, base.day, parsed.$1, parsed.$2);
    }
    return DateTime(base.year, base.month, base.day, 9 + index * 2);
  }

  DateTime _estimateRawDayEndTime(_ItineraryDay day) {
    if (day.items.isEmpty) {
      return _preferredDayEndDateTime(day);
    }
    final lastIndex = day.items.length - 1;
    final lastStart = _resolveRawStartTime(
      day,
      lastIndex,
      day.items[lastIndex].time,
    );
    return lastStart.add(const Duration(minutes: 90));
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

  DateTime _preferredDayEndDateTime(_ItineraryDay day) {
    final base = day.date ?? DateTime.now();
    final start = _preferredDayStartDateTime(day);
    var end = DateTime(
      base.year,
      base.month,
      base.day,
      _preferredEndTime.hour,
      _preferredEndTime.minute,
    );
    if (!end.isAfter(start)) {
      end = start.add(const Duration(hours: 8));
    }
    return end;
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

  _TransitInfo _estimateTransit(_ItineraryPlace from, _ItineraryPlace to) {
    return _estimateTransitByMode(from, to, 'best');
  }

  Map<String, _TransitInfo> _transitComparisonOptions(
    _ItineraryDay day,
    int segmentIndex,
    _ItineraryItem from,
    _ItineraryItem to,
  ) {
    final best =
        from.transitToNext?.toTransitInfo() ??
        _estimateTransit(from.place, to.place);
    final transit =
        from.transitToNext?.toTransitInfo() ??
        _estimateTransitByMode(from.place, to.place, 'transit');
    return {
      'best': best,
      'transit': transit,
      'car': _estimateTransitByMode(from.place, to.place, 'car'),
      'walk': _estimateTransitByMode(from.place, to.place, 'walk'),
    };
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
    const modeLabels = {
      'best': '最佳',
      'transit': '大眾',
      'car': '開車',
      'walk': '步行',
    };
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
          PopupMenuItem(value: 'best', child: Text('最佳（預設）')),
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
                modeLabels[selected] ?? '最佳',
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

    if (safeKm < 1.5) return _estimateTransitByMode(from, to, 'walk');
    if (safeKm < 20) return _estimateTransitByMode(from, to, 'car');
    return _estimateTransitByMode(from, to, 'transit');
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
  static const _googleMapsApiKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');

  GoogleMapController? _mapController;
  bool _didFitBounds = false;
  bool _loadingRoadRoute = false;
  bool _hasRoadRoute = false;
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
              [widget.segments[i].from.position, widget.segments[i].to.position],
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
                    initialCameraPosition: CameraPosition(target: center, zoom: 11),
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
      _hasRoadRoute = resolved.isNotEmpty;
      _loadingRoadRoute = false;
      _roadRouteHint = hint;
    });
  }

  List<String> _directionsModesToTry(_DayRouteSegment segment) {
    switch (segment.selectedMode) {
      case 'car':
        return const ['driving'];
      case 'walk':
        return const ['walking', 'driving'];
      case 'transit':
        return const ['transit', 'driving'];
      case 'best':
      default:
        if (segment.transit.icon == Icons.directions_walk) {
          return const ['walking', 'driving'];
        }
        if (segment.transit.icon == Icons.directions_car_filled) {
          return const ['driving'];
        }
        return const ['transit', 'driving', 'walking'];
    }
  }

  Future<_DirectionsFetchResult> _fetchDirectionsPolyline({
    required LatLng origin,
    required LatLng destination,
    required List<String> modes,
  }) async {
    String? lastStatus;
    for (final mode in modes) {
      final uri = Uri.https('maps.googleapis.com', '/maps/api/directions/json', {
        'origin': '${origin.latitude},${origin.longitude}',
        'destination': '${destination.latitude},${destination.longitude}',
        'mode': mode,
        'language': 'zh-TW',
        'key': _googleMapsApiKey,
      });
      try {
        final response = await http.get(uri).timeout(const Duration(seconds: 8));
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
    final legend = const [
      ('best', '最佳'),
      ('transit', '大眾'),
      ('car', '開車'),
      ('walk', '步行'),
    ];
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
          Icon(segment.transit.icon, size: 16, color: _segmentColor(segment.selectedMode)),
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
                  style: const TextStyle(fontSize: 11, color: Color(0xFF7A7488)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _modeLabel(String mode) => switch (mode) {
    'best' => '最佳',
    'transit' => '大眾',
    'car' => '開車',
    'walk' => '步行',
    _ => mode,
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
    final sw = LatLng(
      lats.reduce(math.min),
      lngs.reduce(math.min),
    );
    final ne = LatLng(
      lats.reduce(math.max),
      lngs.reduce(math.max),
    );

    await Future<void>.delayed(const Duration(milliseconds: 280));
    if (!mounted || _mapController == null) return;
    try {
      await _mapController!.animateCamera(
        CameraUpdate.newLatLngBounds(LatLngBounds(southwest: sw, northeast: ne), 60),
      );
    } catch (_) {
      await _mapController!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: _averageLatLng(widget.stops.map((e) => e.position).toList()), zoom: 11),
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
    required this.routeReason,
    required this.userLikeReason,
    required this.tips,
    required this.source,
  });

  final String summary;
  final String routeReason;
  final String userLikeReason;
  final List<String> tips;
  final String source;

  factory _ItineraryInsight.fromJson(Map<String, dynamic> json) {
    return _ItineraryInsight(
      summary: json['summary']?.toString() ?? '',
      routeReason: json['routeReason']?.toString() ?? '',
      userLikeReason: json['userLikeReason']?.toString() ?? '',
      tips:
          (json['tips'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      source: json['source']?.toString() ?? 'rule',
    );
  }
}

class _ItineraryDay {
  const _ItineraryDay({
    required this.day,
    required this.date,
    required this.weather,
    required this.items,
  });

  final int day;
  final DateTime? date;
  final _ItineraryWeather? weather;
  final List<_ItineraryItem> items;

  factory _ItineraryDay.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final rawWeather = json['weather'];
    return _ItineraryDay(
      day: (json['day'] as num?)?.toInt() ?? 1,
      date: DateTime.tryParse(json['date']?.toString() ?? ''),
      weather: rawWeather is Map
          ? _ItineraryWeather.fromJson(Map<String, dynamic>.from(rawWeather))
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
    required this.place,
    required this.transitToNext,
  });

  final String? time;
  final _ItineraryPlace place;
  final _ItineraryTransit? transitToNext;

  factory _ItineraryItem.fromJson(Map<String, dynamic> json) {
    final rawTransit = json['transitToNext'];
    return _ItineraryItem(
      time: json['time']?.toString(),
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
  });

  final String mode;
  final String label;
  final int minutes;
  final String distanceText;
  final List<String> lines;
  final String? departureTime;
  final String? arrivalTime;
  final String detail;

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

class _ItineraryPlace {
  const _ItineraryPlace({
    required this.id,
    required this.name,
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
  final String city;
  final String address;
  final String description;
  final String imageUrl;
  final List<String> tags;
  final double? rating;
  final double? lat;
  final double? lng;

  factory _ItineraryPlace.fromJson(Map<String, dynamic> json) {
    return _ItineraryPlace(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      city: json['city']?.toString() ?? '',
      address: json['address']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      imageUrl: json['imageUrl']?.toString() ?? '',
      tags: (json['tags'] as List?)?.whereType<String>().toList() ?? const [],
      rating: (json['rating'] as num?)?.toDouble(),
      lat: (json['lat'] as num?)?.toDouble(),
      lng: (json['lng'] as num?)?.toDouble(),
    );
  }
}
