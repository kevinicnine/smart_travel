import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../data/interest_data.dart';
import '../services/backend_api.dart';
import '../state/user_state.dart';
import 'account_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.selectedInterestIds,
    this.displayName,
  });

  final List<String> selectedInterestIds;
  final String? displayName;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _googleMapsApiKey = String.fromEnvironment(
    'GOOGLE_MAPS_API_KEY',
  );

  late final TextEditingController _startController;
  late final TextEditingController _endController;
  late final TextEditingController _locationController;
  late final TextEditingController _peopleController;
  late final TextEditingController _budgetController;

  DateTime? _startDate;
  DateTime? _endDate;
  late final List<InterestItem> _recommended;
  int _currentNavIndex = 0;
  bool _generatingPlan = false;
  final BackendApi _api = BackendApi.instance;
  final TextEditingController _mapSearchController = TextEditingController();
  late List<_Place> _places;
  late LatLng _mapCenter;
  _Place? _selectedPlace;
  GoogleMapController? _googleMapController;
  Set<Marker> _mapMarkers = <Marker>{};
  bool _isSearching = false;
  final List<_Place> _favorites = [];
  static const _favoritesStorageKey = 'favorites_places';

  @override
  void initState() {
    super.initState();
    _startController = TextEditingController();
    _endController = TextEditingController();
    _locationController = TextEditingController();
    _peopleController = TextEditingController();
    _budgetController = TextEditingController();
    _recommended = _buildRecommendations();
    _places = List<_Place>.from(_buildPlaces());
    _mapCenter = _places.first.position;
    _rebuildMarkers();
    _loadFavorites();
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    _locationController.dispose();
    _peopleController.dispose();
    _budgetController.dispose();
    _mapSearchController.dispose();
    super.dispose();
  }

  List<_Place> _buildPlaces() {
    return const [
      _Place('台北 101', LatLng(25.033968, 121.564468), '地標 / 觀景台'),
      _Place('中正紀念堂', LatLng(25.034201, 121.521777), '文化地標'),
      _Place('士林夜市', LatLng(25.08806, 121.525), '美食夜市'),
      _Place('西門町', LatLng(25.042233, 121.508802), '逛街 / 美食'),
    ];
  }

  void _rebuildMarkers() {
    _mapMarkers = _places
        .map(
          (p) => Marker(
            markerId: MarkerId(p.name),
            position: p.position,
            infoWindow: InfoWindow(title: p.name, snippet: p.description),
            onTap: () => _selectPlace(p),
          ),
        )
        .toSet();
  }

  void _addOrReplacePlace(_Place place) {
    setState(() {
      _places.removeWhere((p) => p.name == place.name);
      _places = [place, ..._places];
      _rebuildMarkers();
    });
  }

  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_favoritesStorageKey) ?? [];
    final decoded = saved
        .map((e) => jsonDecode(e) as Map<String, dynamic>)
        .map(_Place.fromJson)
        .toList();
    setState(() {
      _favorites
        ..clear()
        ..addAll(decoded);
    });
  }

  Future<void> _persistFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final data = _favorites.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(_favoritesStorageKey, data);
  }

  List<InterestItem> _buildRecommendations() {
    final unique = <InterestItem>[];
    final seen = <String>{};

    for (final id in widget.selectedInterestIds) {
      final item = interestItemsById[id];
      if (item != null && seen.add(item.id)) {
        unique.add(item);
      }
    }

    if (unique.isNotEmpty) {
      return unique;
    }

    // 沒有選擇 → 用預設前幾個
    final fallback = <InterestItem>[];
    for (final category in interestCategories) {
      fallback.addAll(category.items);
    }
    return fallback.take(6).toList();
  }

  Future<void> _pickDate({required bool isStart}) async {
    final initial = isStart
        ? (_startDate ?? DateTime.now())
        : (_endDate ?? _startDate ?? DateTime.now());

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 730)),
    );

    if (picked == null) return;

    setState(() {
      if (isStart) {
        _startDate = picked;
        _startController.text = _formatDate(picked);
        if (_endDate != null && _endDate!.isBefore(_startDate!)) {
          _endDate = null;
          _endController.clear();
        }
      } else {
        _endDate = picked;
        _endController.text = _formatDate(picked);
      }
    });
  }

  String _formatDate(DateTime date) {
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    return '${date.year}-$mm-$dd';
  }

  Future<void> _startDesign() async {
    if (_generatingPlan) return;

    if (_startDate == null || _endDate == null) {
      _showMessage('請先選擇開始與結束日期');
      return;
    }
    if (_endDate!.isBefore(_startDate!)) {
      _showMessage('結束日期必須在開始日期之後');
      return;
    }

    setState(() {
      _generatingPlan = true;
    });

    try {
      final plan = await _api.generateItinerary(
        interestIds: widget.selectedInterestIds,
        startDate: _startDate,
        endDate: _endDate,
        location: _locationController.text.trim().isEmpty
            ? null
            : _locationController.text.trim(),
        people: int.tryParse(_peopleController.text),
        budget: int.tryParse(_budgetController.text),
      );
      if (!mounted) return;
      _showPlanDialog(plan);
    } on ApiClientException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) {
        setState(() {
          _generatingPlan = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hiName = widget.displayName ?? UserState.displayName ?? '旅人';
    return Scaffold(
      backgroundColor: const Color(0xFFE2D6C9),
      body: _currentNavIndex == 1
          ? _buildMapPage()
          : _currentNavIndex == 2
          ? SafeArea(child: _buildFavoritesPage())
          : SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final fullWidth = constraints.maxWidth;

                  // 首頁內容
                  Widget content = Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 16,
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Hi! $hiName',
                            style: TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w800,
                              color: Colors.black.withOpacity(0.9),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _buildPlannerCard(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '猜你喜歡',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: Colors.black.withOpacity(0.85),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildRecommendationStrip(fullWidth),
                      const SizedBox(height: 10),
                    ],
                  );

                  if (constraints.maxHeight < 640) {
                    return SingleChildScrollView(child: content);
                  }

                  return SizedBox(
                    height: constraints.maxHeight,
                    child: content,
                  );
                },
              ),
            ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentNavIndex,
        onTap: (value) {
          if (value == 4) {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AccountPage()),
            ).then((_) {
              setState(() {});
            });
            return;
          }
          setState(() {
            _currentNavIndex = value;
          });
        },
        selectedItemColor: const Color(0xFF7A91C9),
        unselectedItemColor: Colors.black54,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home_filled), label: '首頁'),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: '地圖'),
          BottomNavigationBarItem(icon: Icon(Icons.favorite), label: '收藏'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: '歷史'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: '帳戶'),
        ],
      ),
    );
  }

  Widget _buildMapPage() {
    return Stack(
      children: [
        Positioned.fill(child: _buildMapView()),
        Positioned(
          top: 48,
          left: 16,
          right: 16,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.38),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white.withOpacity(0.6)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.08),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: TextField(
                  controller: _mapSearchController,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search, color: Colors.black87),
                    suffixIcon: _isSearching
                        ? const Padding(
                            padding: EdgeInsets.all(10),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : null,
                    hintText: '搜尋地點或景點',
                    hintStyle: TextStyle(color: Colors.black.withOpacity(0.55)),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                  ),
                  onSubmitted: _onMapSearch,
                ),
              ),
            ),
          ),
        ),
        if (_selectedPlace != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 20,
            child: _buildPlaceCard(_selectedPlace!),
          ),
      ],
    );
  }

  Widget _buildFavoritesPage() {
    if (_favorites.isEmpty) {
      return Center(
        child: Text(
          '目前沒有收藏的景點，先去地圖頁搜尋並按愛心吧！',
          style: TextStyle(color: Colors.black.withOpacity(0.65)),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      itemBuilder: (context, index) {
        final place = _favorites[index];
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
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
                      place.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      place.description,
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.favorite, color: Color(0xFFE57373)),
                tooltip: '取消收藏',
                onPressed: () => _toggleFavorite(place),
              ),
              IconButton(
                icon: const Icon(Icons.map, color: Color(0xFF7A91C9)),
                tooltip: '在地圖上查看',
                onPressed: () => _openPlaceOnMap(place),
              ),
            ],
          ),
        );
      },
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemCount: _favorites.length,
    );
  }

  Widget _buildPlannerCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          colors: [Color(0xFFFFC369), Color(0xFFF7A7AF), Color(0xFF7EAFFF)],
          stops: [0.05, 0.45, 0.95],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '準備好設計\n專屬於你的旅程了嗎？',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _buildInputField(
                  hint: '開始日期',
                  controller: _startController,
                  onTap: () => _pickDate(isStart: true),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildInputField(
                  hint: '結束日期',
                  controller: _endController,
                  onTap: () => _pickDate(isStart: false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildInputField(
            hint: '地點',
            controller: _locationController,
            prefixIcon: Icons.search,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildInputField(
                  hint: '人數',
                  controller: _peopleController,
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildInputField(
                  hint: '預算',
                  controller: _budgetController,
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: _generatingPlan ? null : () => _startDesign(),
              style: ElevatedButton.styleFrom(
                elevation: 0,
                backgroundColor: Colors.white.withOpacity(0.9),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                ),
              ),
              child: _generatingPlan
                  ? const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    )
                  : Text(
                      '開始設計！',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: Colors.black.withOpacity(0.8),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputField({
    required String hint,
    required TextEditingController controller,
    TextInputType? keyboardType,
    IconData? prefixIcon,
    VoidCallback? onTap,
  }) {
    return TextField(
      controller: controller,
      readOnly: onTap != null,
      onTap: onTap,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        filled: true,
        fillColor: Colors.white,
        hintText: hint,
        prefixIcon: prefixIcon == null
            ? null
            : Icon(prefixIcon, color: Colors.black.withOpacity(0.6)),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildRecommendationStrip(double width) {
    if (_recommended.isEmpty) {
      return const Text('目前沒有推薦，先去選擇一些興趣吧！');
    }

    return SizedBox(
      width: width,
      height: 155,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: _recommended.length * 10,
        itemBuilder: (context, index) {
          final item = _recommended[index % _recommended.length];
          return Container(
            width: 118,
            margin: EdgeInsets.only(
              right: index == _recommended.length * 10 - 1 ? 0 : 14,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ClipOval(
                  child: Image.asset(
                    item.imagePath,
                    width: 84,
                    height: 84,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  item.label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showPlanDialog(Map<String, dynamic> plan) {
    final encoder = const JsonEncoder.withIndent('  ');
    final prettyPlan = plan.isEmpty ? '尚未取得建議內容' : encoder.convert(plan);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        final maxHeight = MediaQuery.of(context).size.height * 0.6;
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 34),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AI 行程建議',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Colors.black.withOpacity(0.85),
                ),
              ),
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: SingleChildScrollView(
                  child: SelectableText(
                    prettyPlan,
                    style: const TextStyle(fontSize: 14, height: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('關閉'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Widget _buildMapView() {
    final center = _selectedPlace?.position ?? _mapCenter;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: GoogleMap(
        initialCameraPosition: CameraPosition(target: center, zoom: 14),
        markers: _mapMarkers,
        myLocationButtonEnabled: false,
        zoomControlsEnabled: false,
        onMapCreated: (controller) {
          _googleMapController = controller;
        },
        onTap: (_) => FocusScope.of(context).unfocus(),
      ),
    );
  }

  Future<void> _onMapSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    if (_googleMapsApiKey.isEmpty) {
      _showMessage(
        '缺少 Google Maps API 金鑰，請先在 dart-define 設定 GOOGLE_MAPS_API_KEY',
      );
      return;
    }

    setState(() {
      _isSearching = true;
    });

    try {
      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/place/findplacefromtext/json',
        {
          'input': trimmed,
          'inputtype': 'textquery',
          'fields': 'name,geometry,formatted_address',
          'language': 'zh-TW',
          'region': 'tw',
          'key': _googleMapsApiKey,
        },
      );
      final response = await http.get(uri);
      if (response.statusCode != 200) {
        _showMessage('搜尋失敗 (${response.statusCode})');
        return;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final status = data['status'] as String? ?? '';
      final errMsg = data['error_message'] as String?;
      if (status != 'OK') {
        _showMessage(
          errMsg == null ? '搜尋失敗（$status）' : '搜尋失敗：$errMsg（$status）',
        );
        debugPrint('Places API response: $data');
        return;
      }
      final candidates = (data['candidates'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      if (candidates.isEmpty) {
        _showMessage('找不到相關地點（status: $status）');
        return;
      }
      final candidate = candidates.first;
      final location = (candidate['geometry'] as Map?)?['location'] as Map?;
      if (location == null ||
          location['lat'] == null ||
          location['lng'] == null) {
        _showMessage('取得座標失敗');
        return;
      }
      final place = _Place(
        candidate['name'] as String? ?? trimmed,
        LatLng(
          (location['lat'] as num).toDouble(),
          (location['lng'] as num).toDouble(),
        ),
        candidate['formatted_address'] as String? ?? 'Google Maps',
      );
      _addOrReplacePlace(place);
      _selectPlace(place, moveCamera: true);
    } catch (error) {
      final msg = '搜尋失敗：$error';
      _showMessage(msg);
      debugPrint('Places API error: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  void _selectPlace(_Place place, {bool moveCamera = false}) {
    setState(() {
      _selectedPlace = place;
      _mapCenter = place.position;
      _rebuildMarkers();
    });
    if (moveCamera) {
      _googleMapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: place.position, zoom: 15),
        ),
      );
    }
  }

  bool _isFavorite(_Place place) {
    return _favorites.any(
      (p) => p.name == place.name && p.position == place.position,
    );
  }

  void _toggleFavorite(_Place place) {
    var removed = false;
    _favorites.removeWhere((p) {
      final hit = p.name == place.name && p.position == place.position;
      if (hit) removed = true;
      return hit;
    });
    if (!removed) {
      _favorites.add(place);
      _showMessage('已加入收藏');
    } else {
      _showMessage('已從收藏移除');
    }
    setState(() {});
    _persistFavorites();
  }

  void _openPlaceOnMap(_Place place) {
    _selectPlace(place, moveCamera: false);
    setState(() {
      _currentNavIndex = 1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectPlace(place, moveCamera: true);
    });
  }

  Widget _buildPlaceCard(_Place place) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  place.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => _toggleFavorite(place),
                icon: Icon(
                  _isFavorite(place) ? Icons.favorite : Icons.favorite_border,
                  color: _isFavorite(place)
                      ? const Color(0xFFE57373)
                      : Colors.black54,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            place.description,
            style: const TextStyle(color: Colors.black54),
          ),
        ],
      ),
    );
  }
}

class _Place {
  final String name;
  final LatLng position;
  final String description;
  const _Place(this.name, this.position, this.description);

  Map<String, dynamic> toJson() => {
    'name': name,
    'lat': position.latitude,
    'lng': position.longitude,
    'description': description,
  };

  factory _Place.fromJson(Map<String, dynamic> json) {
    return _Place(
      json['name'] as String? ?? '',
      LatLng((json['lat'] as num).toDouble(), (json['lng'] as num).toDouble()),
      json['description'] as String? ?? '',
    );
  }
}
