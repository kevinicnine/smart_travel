import 'dart:async';

import 'package:flutter/material.dart';

import '../services/backend_api.dart';
import '../state/user_state.dart';

class PlannerChatPage extends StatefulWidget {
  const PlannerChatPage({
    super.key,
    required this.startDate,
    required this.endDate,
    required this.originCity,
    required this.destinationCities,
    required this.interestIds,
  });

  final DateTime startDate;
  final DateTime endDate;
  final String originCity;
  final List<String> destinationCities;
  final List<String> interestIds;

  @override
  State<PlannerChatPage> createState() => _PlannerChatPageState();
}

class _PlannerChatPageState extends State<PlannerChatPage> {
  final BackendApi _api = BackendApi.instance;
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_PlannerChatMessage> _messages = <_PlannerChatMessage>[];
  List<String> _suggestedQuickReplies = const <String>[];
  _PlannerGuidanceStage _guidanceStage = _PlannerGuidanceStage.companion;
  bool _generating = false;
  String? _requirementsText;
  List<String> _requiredPlaces = const <String>[];
  String? _conversationId;
  Map<String, dynamic>? _draftPlan;
  bool _draftNeedsRefresh = false;

  @override
  void initState() {
    super.initState();
    _seedConversation();
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _seedConversation() {
    final dayCount = widget.endDate.difference(widget.startDate).inDays + 1;
    final destinationLabel = widget.destinationCities.join('、');
    _suggestedQuickReplies = _guidanceOptions(_guidanceStage);
    _messages.add(
      _PlannerChatMessage.assistant(
        '我先收到你的基本條件：${_formatDate(widget.startDate)} 到 ${_formatDate(widget.endDate)}，'
        '從 ${widget.originCity} 出發，目的地 $destinationLabel，共 $dayCount 天。'
        '\n\n我會用幾個簡短問題協助你整理需求。\n${_guidanceQuestion(_guidanceStage)}',
      ),
    );
  }

  String _formatDate(DateTime date) {
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    return '${date.year}-$mm-$dd';
  }

  Future<void> _sendUserMessage(
    String text, {
    bool skipUserBubble = false,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _generating) return;
    final previousRequirements = (_requirementsText ?? '').trim();
    final answeredStage = _guidanceStage;
    final shouldRefreshDraft = _draftPlan != null;
    setState(() {
      if (!skipUserBubble) {
        _messages.add(_PlannerChatMessage.user(trimmed));
      }
      _inputController.clear();
      _generating = true;
      if (_draftPlan != null) {
        _draftNeedsRefresh = true;
      }
    });
    _scrollToBottom();
    try {
      final result = await _api.plannerChat(
        conversationId: _conversationId,
        userId: UserState.userId,
        startDate: widget.startDate,
        endDate: widget.endDate,
        originCity: widget.originCity,
        destinationCities: widget.destinationCities,
        userMessage: trimmed,
        requirementsText: previousRequirements,
      );
      if (!mounted) return;
      setState(() {
        _conversationId = result['conversationId']?.toString();
        _requirementsText = result['requirementsText']?.toString().trim();
        final hardConstraints = result['hardConstraints'] is Map
            ? Map<String, dynamic>.from(result['hardConstraints'] as Map)
            : const <String, dynamic>{};
        _requiredPlaces = _stringList(hardConstraints['requiredPlaces']);
        final quickReplies =
            (result['suggestedQuickReplies'] as List?)
                ?.map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
                .toList() ??
            const <String>[];
        final reply =
            result['assistantReply']?.toString().trim() ?? '收到，我會把這些需求一起納入。';
        _appendGuidedAssistantReply(
          answeredStage: answeredStage,
          aiReply: reply,
          aiQuickReplies: quickReplies,
        );
      });
    } on ApiClientException catch (error) {
      if (!mounted) return;
      final combinedText = [
        if (previousRequirements.isNotEmpty) previousRequirements,
        trimmed,
      ].join('；');
      setState(() {
        _requirementsText = combinedText;
        _requiredPlaces = _extractRequiredPlaces(combinedText);
        _appendGuidedAssistantReply(
          answeredStage: answeredStage,
          aiReply:
              '${_buildAssistantReply(latestInput: trimmed, combinedText: combinedText)}\n（後端對話暫時不可用，先用本地摘要模式）',
          aiQuickReplies: _buildFallbackQuickReplies(combinedText),
        );
      });
      _scrollToBottom();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) {
        setState(() {
          _generating = false;
        });
      }
      _scrollToBottom();
    }
    if (shouldRefreshDraft && mounted) {
      await _generatePlan();
    }
  }

  void _appendGuidedAssistantReply({
    required _PlannerGuidanceStage answeredStage,
    required String aiReply,
    required List<String> aiQuickReplies,
  }) {
    if (answeredStage != _PlannerGuidanceStage.open) {
      _guidanceStage = _nextGuidanceStage(answeredStage);
      _suggestedQuickReplies = _guidanceOptions(_guidanceStage);
      final nextQuestion = _guidanceQuestion(_guidanceStage);
      final reply = _guidanceStage == _PlannerGuidanceStage.open
          ? '$aiReply\n\n基本偏好已整理完成。你可以繼續補充需求，或直接按「照這個安排」。'
          : '收到。\n$nextQuestion';
      _messages.add(_PlannerChatMessage.assistant(reply));
      return;
    }

    _suggestedQuickReplies = aiQuickReplies.isEmpty
        ? _buildFallbackQuickReplies(_requirementsText ?? '')
        : aiQuickReplies;
    final adjustmentHint = _draftPlan != null ? '\n\n我已記下這次調整，正在更新行程草稿。' : '';
    _messages.add(_PlannerChatMessage.assistant('$aiReply$adjustmentHint'));
  }

  _PlannerGuidanceStage _nextGuidanceStage(_PlannerGuidanceStage stage) {
    return switch (stage) {
      _PlannerGuidanceStage.companion => _PlannerGuidanceStage.transport,
      _PlannerGuidanceStage.transport => _PlannerGuidanceStage.style,
      _PlannerGuidanceStage.style => _PlannerGuidanceStage.pacing,
      _PlannerGuidanceStage.pacing => _PlannerGuidanceStage.open,
      _PlannerGuidanceStage.open => _PlannerGuidanceStage.open,
    };
  }

  String _guidanceQuestion(_PlannerGuidanceStage stage) {
    return switch (stage) {
      _PlannerGuidanceStage.companion => '這次會和誰一起旅行？',
      _PlannerGuidanceStage.transport => '旅途中主要想使用哪種交通方式？',
      _PlannerGuidanceStage.style => '你最想要哪一種旅遊風格？',
      _PlannerGuidanceStage.pacing => '最後，希望整體行程是什麼節奏？',
      _PlannerGuidanceStage.open => '',
    };
  }

  List<String> _guidanceOptions(_PlannerGuidanceStage stage) {
    return switch (stage) {
      _PlannerGuidanceStage.companion => const [
        '獨自旅行',
        '伴侶／情侶',
        '朋友同行',
        '親子家庭',
        '帶爸媽長輩',
      ],
      _PlannerGuidanceStage.transport => const [
        '自駕',
        '大眾運輸',
        '機車',
        '步行為主',
        '交通方式不限',
      ],
      _PlannerGuidanceStage.style => const [
        '戶外自然',
        '文化歷史',
        '美食小吃',
        '拍照打卡',
        '親子體驗',
      ],
      _PlannerGuidanceStage.pacing => const [
        '輕鬆慢遊',
        '充實踩點',
        '短距離優先',
        '少走路',
        '節奏不限',
      ],
      _PlannerGuidanceStage.open => const [],
    };
  }

  String _buildAssistantReply({
    required String latestInput,
    required String combinedText,
  }) {
    final latestTraits = <String>[];
    final planTraits = <String>[];
    final followUps = <String>[];
    final prefersIndoor = _containsAny(combinedText, const [
      '室內',
      '百貨',
      '商場',
      '購物中心',
      '逛街',
      '展覽',
    ]);

    if (_containsAny(latestInput, const ['獨旅', '一個人', '自己', '單人'])) {
      latestTraits.add('改成比較適合獨旅的節奏');
    }
    if (_containsAny(latestInput, const [
      '家庭',
      '親子',
      '小朋友',
      '小孩',
      '爸媽',
      '長輩',
    ])) {
      latestTraits.add('會偏向家庭友善');
    }
    if (_containsAny(latestInput, const [
          '戶外',
          '走走',
          '散步',
          '步道',
          '海景',
          '山景',
          '自然',
        ]) &&
        !prefersIndoor) {
      latestTraits.add('保留戶外走走的安排');
    }
    if (_containsAny(latestInput, const [
      '室內',
      '百貨',
      '商場',
      '購物中心',
      '逛街',
      '展覽',
    ])) {
      latestTraits.add('提高室內景點與逛街行程比例');
    }
    if (_containsAny(latestInput, const ['拍照', '打卡', '網美', '美景', '取景'])) {
      latestTraits.add('多放進適合拍照打卡的點');
    }
    if (_containsAny(latestInput, const [
      '不要太遠',
      '距離不要太遠',
      '順路',
      '不要拉車',
      '近一點',
    ])) {
      latestTraits.add('盡量縮短點跟點距離');
    }
    if (_containsAny(latestInput, const ['不要走太多', '少走路', '不要太累'])) {
      latestTraits.add('會壓低步行負擔');
    }
    if (_containsAny(latestInput, const ['夜市', '晚上想去夜市', '晚上市集'])) {
      latestTraits.add('晚間會優先保留夜市或熱鬧商圈時段');
    }
    if (_containsAny(latestInput, const [
      '晚餐',
      '吃飯',
      '小吃',
      '美食',
      '餐廳',
      '下午茶',
      '咖啡',
    ])) {
      latestTraits.add('會兼顧美食安排');
    }
    if (_containsAny(latestInput, const ['不要太趕', '放鬆', '悠閒', '慢慢'])) {
      latestTraits.add('整體節奏會放鬆一點');
    }
    if (_containsAny(latestInput, const ['不要夜市', '不要逛街', '避開夜間'])) {
      latestTraits.add('晚間活動會保守安排');
    }

    if (_containsAny(combinedText, const ['獨旅', '一個人', '自己', '單人'])) {
      planTraits.add('獨旅');
    }
    if (_containsAny(combinedText, const [
      '家庭',
      '親子',
      '小朋友',
      '小孩',
      '爸媽',
      '長輩',
    ])) {
      planTraits.add('家庭友善');
    }
    if (_containsAny(combinedText, const [
          '戶外',
          '走走',
          '散步',
          '步道',
          '海景',
          '山景',
          '自然',
        ]) &&
        !prefersIndoor) {
      planTraits.add('戶外');
    }
    if (prefersIndoor) {
      planTraits.add('室內逛街');
    }
    if (_containsAny(combinedText, const ['拍照', '打卡', '網美', '美景', '取景'])) {
      planTraits.add('拍照打卡');
    }
    if (_containsAny(combinedText, const [
      '不要太遠',
      '距離不要太遠',
      '順路',
      '不要拉車',
      '近一點',
    ])) {
      planTraits.add('順路不拉車');
    }
    if (_containsAny(combinedText, const ['夜市', '晚上想去夜市', '晚上市集'])) {
      planTraits.add('晚間夜市');
    }
    if (_containsAny(combinedText, const [
      '晚餐',
      '吃飯',
      '小吃',
      '美食',
      '餐廳',
      '下午茶',
      '咖啡',
    ])) {
      planTraits.add('美食');
    }
    if (_containsAny(combinedText, const ['不要太趕', '放鬆', '悠閒', '慢慢'])) {
      planTraits.add('放鬆節奏');
    }
    if (_containsAny(combinedText, const ['不要走太多', '少走路', '不要太累'])) {
      planTraits.add('低步行負擔');
    }

    if (!_containsAny(combinedText, const [
      '午餐',
      '晚餐',
      '小吃',
      '美食',
      '餐廳',
      '下午茶',
      '咖啡',
    ])) {
      followUps.add('如果要指定午晚餐風格，也可以再補一句');
    }
    if (!_containsAny(combinedText, const [
      '不要太遠',
      '距離不要太遠',
      '順路',
      '不要拉車',
      '近一點',
    ])) {
      followUps.add('如果你在意拉車時間，可以直接說「點跟點不要太遠」');
    }
    if (!_containsAny(combinedText, const ['不要走太多', '少走路', '不要太累'])) {
      followUps.add('如果有長輩或不想走太多，也可以直接說');
    }

    final latestLine = latestTraits.isEmpty
        ? '收到，我會把這句需求一起納入。'
        : '收到，${latestTraits.join('、')}。';
    final planLine = planTraits.isEmpty
        ? '目前先按你提供的條件排。'
        : '目前這版會偏向 ${planTraits.join('、')} 的路線。';
    final followUpLine = followUps.isEmpty
        ? '你也可以直接按「照這個安排」開始生成。'
        : '${followUps.first}。';
    return '$latestLine\n$planLine\n$followUpLine';
  }

  List<String> _buildFallbackQuickReplies(String combinedText) {
    final quickReplies = <String>[];
    if (!_containsAny(combinedText, const ['不要走太多', '少走路', '不要太累'])) {
      quickReplies.add('帶爸媽，不要走太多路');
    }
    if (!_containsAny(combinedText, const ['拍照', '打卡', '網美', '取景'])) {
      quickReplies.add('想沿途拍照打卡');
    }
    if (!_containsAny(combinedText, const [
      '不要太遠',
      '距離不要太遠',
      '順路',
      '不要拉車',
      '近一點',
    ])) {
      quickReplies.add('希望景點之間不要太遠');
    }
    if (!_containsAny(combinedText, const [
      '午餐',
      '晚餐',
      '小吃',
      '美食',
      '餐廳',
      '下午茶',
      '咖啡',
    ])) {
      quickReplies.add('中午安排在地小吃');
    }
    return quickReplies;
  }

  bool _containsAny(String source, List<String> keywords) {
    return keywords.any(source.contains);
  }

  Future<void> _generatePlan() async {
    if (_generating) return;
    final requirementsText = (_requirementsText ?? '').trim();
    final isUpdatingDraft = _draftPlan != null;
    setState(() {
      _generating = true;
      _messages.add(
        _PlannerChatMessage.assistant(
          isUpdatingDraft ? '正在依照最新調整更新行程草稿。' : '正在根據目前條件建立第一版行程草稿。',
        ),
      );
    });
    _scrollToBottom();
    try {
      final destinationLabel = widget.destinationCities.join('、');
      final plan = await _api.generateItinerary(
        interestIds: widget.interestIds,
        userId: UserState.userId,
        startDate: widget.startDate,
        endDate: widget.endDate,
        originCity: widget.originCity,
        destinationCities: widget.destinationCities,
        requirementsText: requirementsText,
        tripPurpose: _inferTripPurpose(requirementsText),
        travelBehavior: _inferTravelBehavior(requirementsText),
        location: destinationLabel,
        budget: _inferBudgetValue(requirementsText),
        wishlistPlaces: _requiredPlaces,
        currentTime: DateTime.now(),
      );
      if (!mounted) return;
      setState(() {
        _draftPlan = plan;
        _draftNeedsRefresh = false;
        _guidanceStage = _PlannerGuidanceStage.open;
        _suggestedQuickReplies = const [
          '減少一個景點，行程輕鬆一點',
          '想增加戶外景點',
          '午餐安排在地小吃',
          '景點之間不要太遠',
        ];
        _messages.add(
          _PlannerChatMessage.assistant(
            '${isUpdatingDraft ? '已更新行程草稿：' : '先提供第一版行程草稿：'}\n\n'
            '${_formatDraftPlan(plan)}\n\n'
            '你可以直接告訴我要刪除、替換或增加什麼；確認沒問題後，再進入正式行程頁。',
          ),
        );
      });
      _scrollToBottom();
    } on ApiClientException catch (error) {
      if (!mounted) return;
      setState(() {
        _messages.add(_PlannerChatMessage.assistant('生成失敗：${error.message}'));
      });
      _scrollToBottom();
    } finally {
      if (mounted) {
        setState(() {
          _generating = false;
        });
      }
    }
  }

  List<String> _stringList(dynamic value) {
    return (value as List?)
            ?.map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toSet()
            .toList() ??
        const <String>[];
  }

  List<String> _extractRequiredPlaces(String input) {
    final places = <String>{..._requiredPlaces};
    final pattern = RegExp(r'(?:想去|我要去|要去|必去|一定要去|希望去|排入|加入|保留)([^，。；、,\n]+)');
    for (final match in pattern.allMatches(input)) {
      var place = (match.group(1) ?? '').trim();
      place = place.split(RegExp(r'(?:然後|之後|接著|再去|晚上|白天|早上|下午)')).first.trim();
      if (place.length >= 2 && place.length <= 32) {
        places.add(place);
      }
    }
    return places.toList();
  }

  String _formatDraftPlan(Map<String, dynamic> plan) {
    final rawDays = plan['days'];
    if (rawDays is! List || rawDays.isEmpty) {
      return '目前沒有可預覽的行程內容。';
    }

    final sections = <String>[];
    for (final rawDay in rawDays.whereType<Map>()) {
      final day = Map<String, dynamic>.from(rawDay);
      final dayNumber = (day['day'] as num?)?.toInt() ?? sections.length + 1;
      final date = day['date']?.toString().split('T').first ?? '';
      final lines = <String>['第 $dayNumber 天${date.isEmpty ? '' : '｜$date'}'];
      final rawItems = day['items'];
      if (rawItems is List) {
        for (final rawItem in rawItems.whereType<Map>()) {
          final item = Map<String, dynamic>.from(rawItem);
          final place = item['place'] is Map
              ? Map<String, dynamic>.from(item['place'] as Map)
              : const <String, dynamic>{};
          final name = place['name']?.toString().trim() ?? '';
          if (name.isEmpty) continue;
          final start = item['time']?.toString().trim() ?? '';
          final end = item['endTime']?.toString().trim() ?? '';
          final highlight = item['travelHighlight']?.toString().trim() ?? '';
          final icon = item['icon']?.toString().trim() ?? '';
          final time = start.isEmpty
              ? ''
              : end.isEmpty
              ? start
              : '$start-$end';
          lines.add(
            '• ${time.isEmpty ? '' : '$time｜'}$name'
            '${icon.isEmpty ? '' : ' $icon'}'
            '${highlight.isEmpty ? '' : '\n  $highlight'}',
          );
        }
      }
      sections.add(lines.join('\n'));
    }
    final meta = plan['meta'] is Map
        ? Map<String, dynamic>.from(plan['meta'] as Map)
        : const <String, dynamic>{};
    final missingRequiredPlaces = _stringList(meta['missingRequiredPlaces']);
    if (missingRequiredPlaces.isNotEmpty) {
      sections.add(
        '⚠️ 尚未找到必排景點：${missingRequiredPlaces.join('、')}\n'
        '請確認名稱或稍後再試，系統不會把它當成已排入。',
      );
    }
    return sections.join('\n\n');
  }

  Future<void> _confirmDraftPlan() async {
    final plan = _draftPlan;
    if (plan == null || _generating || _draftNeedsRefresh) return;
    Navigator.of(context).pop(plan);
  }

  String? _inferTripPurpose(String text) {
    if (text.isEmpty) return null;
    if (_containsAny(text, const ['情侶', '約會', '紀念日', '浪漫'])) return 'couple';
    if (_containsAny(text, const [
      '爸媽',
      '父母',
      '長輩',
      '家人',
      '親子',
      '小朋友',
      '小孩',
      '家庭',
    ])) {
      return 'family';
    }
    if (_containsAny(text, const ['放鬆', '泡湯', '慢慢玩', '不要太趕', '悠閒', '耍廢'])) {
      return 'relax';
    }
    if (_containsAny(text, const ['探索', '踩點', '拍照', '景點', '走走'])) {
      return 'explore';
    }
    return null;
  }

  String? _inferTravelBehavior(String text) {
    if (text.isEmpty) return null;
    if (_containsAny(text, const ['情侶', '約會', '兩個人', '二人'])) return 'couple';
    if (_containsAny(text, const [
      '爸媽',
      '父母',
      '長輩',
      '家人',
      '親子',
      '小朋友',
      '小孩',
      '家庭',
    ])) {
      return 'family';
    }
    if (_containsAny(text, const ['一個人', '自己', '獨旅', '單人'])) return 'solo';
    return null;
  }

  int? _inferBudgetValue(String text) {
    if (text.isEmpty) return null;
    if (_containsAny(text, const ['高預算', '奢華', '高級', '貴一點沒關係'])) return 5000;
    if (_containsAny(text, const ['中等預算', '適中', '不要太貴'])) return 2500;
    if (_containsAny(text, const ['便宜', '省錢', '小資', '低預算'])) return 1000;
    return null;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 120,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE2D6C9),
      appBar: AppBar(
        backgroundColor: const Color(0xFFE2D6C9),
        elevation: 0,
        title: const Text(
          'AI 行程規劃',
          style: TextStyle(
            color: Color(0xFF1F1F23),
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                children: [
                  _buildContextCard(),
                  const SizedBox(height: 14),
                  ..._messages.map(_buildMessageBubble),
                  const SizedBox(height: 12),
                  _buildQuickPromptRow(),
                  const SizedBox(height: 12),
                  _buildActionCard(),
                ],
              ),
            ),
            _buildComposer(),
          ],
        ),
      ),
    );
  }

  Widget _buildContextCard() {
    final destinationLabel = widget.destinationCities.join('、');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '本次規劃條件',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            '日期：${_formatDate(widget.startDate)} - ${_formatDate(widget.endDate)}',
          ),
          Text('出發地：${widget.originCity}'),
          Text('目的地：$destinationLabel'),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(_PlannerChatMessage message) {
    final isUser = message.role == _PlannerChatRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        constraints: const BoxConstraints(maxWidth: 320),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xFFE567A6) : Colors.white,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Text(
          message.text,
          style: TextStyle(
            fontSize: 16,
            height: 1.4,
            color: isUser ? Colors.white : const Color(0xFF1F1F23),
            fontWeight: isUser ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildQuickPromptRow() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _suggestedQuickReplies
          .map(
            (prompt) => ActionChip(
              label: Text(prompt),
              onPressed: _generating ? null : () => _sendUserMessage(prompt),
            ),
          )
          .toList(),
    );
  }

  Widget _buildActionCard() {
    final hasRequirements = (_requirementsText ?? '').trim().isNotEmpty;
    final guidanceCompleted = _guidanceStage == _PlannerGuidanceStage.open;
    final hasDraft = _draftPlan != null;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            hasDraft && _draftNeedsRefresh
                ? '已收到新的調整需求，AI 正在更新行程草稿。'
                : hasDraft
                ? '目前顯示的是行程草稿，確認後才會建立正式行程。'
                : guidanceCompleted
                ? '基本偏好已完成，可繼續補充或直接生成。'
                : '回答幾個簡單問題會讓安排更符合需求，也可以直接開始。',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (hasDraft)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _generating || _draftNeedsRefresh
                    ? null
                    : _confirmDraftPlan,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE567A6),
                  foregroundColor: Colors.white,
                ),
                child: _generating || _draftNeedsRefresh
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: Colors.white,
                        ),
                      )
                    : const Text('確認正式行程'),
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _generating ? null : _generatePlan,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE567A6),
                  foregroundColor: Colors.white,
                ),
                child: _generating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        guidanceCompleted || hasRequirements
                            ? '產生行程草稿'
                            : '快速產生草稿',
                      ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildComposer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: _guidanceStage == _PlannerGuidanceStage.open
                    ? '還有其他需求可以繼續告訴我'
                    : '可點選上方選項，或直接輸入你的回答',
                filled: true,
                fillColor: const Color(0xFFF6F2EC),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
              ),
              onSubmitted: _generating ? null : _sendUserMessage,
            ),
          ),
          const SizedBox(width: 10),
          IconButton.filled(
            onPressed: _generating
                ? null
                : () => _sendUserMessage(_inputController.text),
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFFE567A6),
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.send_rounded),
          ),
        ],
      ),
    );
  }
}

enum _PlannerGuidanceStage { companion, transport, style, pacing, open }

enum _PlannerChatRole { assistant, user }

class _PlannerChatMessage {
  const _PlannerChatMessage({required this.role, required this.text});

  const _PlannerChatMessage.assistant(this.text)
    : role = _PlannerChatRole.assistant;

  const _PlannerChatMessage.user(this.text) : role = _PlannerChatRole.user;

  final _PlannerChatRole role;
  final String text;
}
