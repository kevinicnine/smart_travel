import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../services/backend_api.dart';
import '../state/user_state.dart';
import 'account_page.dart';
import 'itinerary_page.dart';

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

  DateTime? _startDate;
  DateTime? _endDate;
  String? _selectedOriginCity;
  final List<String> _selectedDestinationCities = [];
  int? _selectedBudgetTier;
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
  bool _isLoadingPlaces = false;
  bool _showOnlySelectedMarker = false;
  final List<_Place> _favorites = [];
  final List<_SavedTrip> _savedTrips = [];
  static const _favoritesStorageKey = 'favorites_places';
  static const _tripsStorageKey = 'saved_itineraries_v1';

  @override
  void initState() {
    super.initState();
    _startController = TextEditingController();
    _endController = TextEditingController();
    _places = <_Place>[];
    _mapCenter = const LatLng(25.033968, 121.564468);
    _rebuildMarkers();
    _loadFavorites();
    _loadSavedTrips();
    _loadPlacesFromBackend();
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    _mapSearchController.dispose();
    super.dispose();
  }

  Future<void> _loadPlacesFromBackend() async {
    if (_isLoadingPlaces) return;
    setState(() {
      _isLoadingPlaces = true;
    });
    try {
      var raw = await _api.fetchPlaces(
        tags: widget.selectedInterestIds,
        sort: 'rating',
        limit: 200,
      );
      if (raw.isEmpty && widget.selectedInterestIds.isNotEmpty) {
        raw = await _api.fetchPlaces(sort: 'rating', limit: 200);
      }
      final places = raw.map(_Place.fromBackend).toList();
      if (places.isNotEmpty) {
        setState(() {
          _places = places;
          _syncPlannerSelections(places);
          _mapCenter = places.first.position;
          _rebuildMarkers();
        });
      }
    } on ApiClientException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingPlaces = false;
        });
      }
    }
  }

  void _rebuildMarkers() {
    final markerPlaces = _showOnlySelectedMarker && _selectedPlace != null
        ? <_Place>[_selectedPlace!]
        : _places;
    _mapMarkers = markerPlaces
        .map(
          (p) {
            final isSelected = _isSamePlace(_selectedPlace, p);
            return Marker(
            markerId: MarkerId(_markerIdForPlace(p)),
            position: p.position,
            infoWindow: InfoWindow(title: p.name, snippet: p.description),
            onTap: () => _selectPlace(p),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueRed,
            ),
            zIndexInt: isSelected ? 10 : 0,
          );
          },
        )
        .toSet();
  }

  String _markerIdForPlace(_Place place) {
    final id = place.id.trim();
    return id.isNotEmpty ? id : place.name;
  }

  bool _isSamePlace(_Place? a, _Place b) {
    if (a == null) return false;
    final aId = a.id.trim();
    final bId = b.id.trim();
    if (aId.isNotEmpty && bId.isNotEmpty) {
      return aId == bId;
    }
    return a.name == b.name;
  }

  void _addOrReplacePlace(_Place place) {
    setState(() {
      _places.removeWhere((p) => p.id == place.id || p.name == place.name);
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

  Future<void> _loadSavedTrips() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_tripsStorageKey) ?? [];
    final decoded =
        saved
            .map((e) => jsonDecode(e) as Map<String, dynamic>)
            .map(_SavedTrip.fromJson)
            .toList()
          ..sort(_compareTripsByDate);
    if (!mounted) return;
    setState(() {
      _savedTrips
        ..clear()
        ..addAll(decoded);
    });
  }

  Future<void> _persistSavedTrips() async {
    final prefs = await SharedPreferences.getInstance();
    final data = _savedTrips.map((t) => jsonEncode(t.toJson())).toList();
    await prefs.setStringList(_tripsStorageKey, data);
  }

  Future<void> _saveGeneratedTrip(Map<String, dynamic> plan) async {
    final trip = _SavedTrip.fromPlan(plan);
    setState(() {
      _savedTrips.removeWhere((t) => t.id == trip.id);
      _savedTrips.add(trip);
      _savedTrips.sort(_compareTripsByDate);
    });
    await _persistSavedTrips();
  }

  Future<void> _deleteSavedTrip(String tripId) async {
    setState(() {
      _savedTrips.removeWhere((trip) => trip.id == tripId);
    });
    await _persistSavedTrips();
    if (!mounted) return;
    _showMessage('已刪除旅程');
  }

  int _compareTripsByDate(_SavedTrip a, _SavedTrip b) {
    if (a.startDate != null && b.startDate != null) {
      final cmp = a.startDate!.compareTo(b.startDate!);
      if (cmp != 0) return cmp;
    } else if (a.startDate != null) {
      return -1;
    } else if (b.startDate != null) {
      return 1;
    }
    return b.savedAt.compareTo(a.savedAt);
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
    if (_selectedOriginCity == null || _selectedOriginCity!.isEmpty) {
      _showMessage('請先選擇出發地');
      return;
    }
    if (_selectedDestinationCities.isEmpty) {
      _showMessage('請至少選擇一個旅遊城市');
      return;
    }

    setState(() {
      _generatingPlan = true;
    });

    try {
      final destinationLabel = _selectedDestinationCities.join('、');
      final plan = await _api.generateItinerary(
        interestIds: widget.selectedInterestIds,
        userId: UserState.userId,
        startDate: _startDate,
        endDate: _endDate,
        originCity: _selectedOriginCity,
        destinationCities: _selectedDestinationCities,
        location: destinationLabel,
        budget: _budgetToValue(_selectedBudgetTier),
      );
      await _saveGeneratedTrip(plan);
      if (!mounted) return;
      _showMessage('行程已儲存到「旅程」');
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ItineraryPage(plan: plan)),
      );
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
          : _currentNavIndex == 3
          ? SafeArea(child: _buildTripsPage())
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
                          vertical: 12,
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Hi! $hiName',
                            style: TextStyle(
                              fontSize: 30,
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
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '推薦景點',
                            style: TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w700,
                              color: Colors.black.withOpacity(0.85),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      _buildRecommendationStrip(fullWidth),
                      const SizedBox(height: 10),
                    ],
                  );

                  return SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: content,
                    ),
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
            ).then((result) {
              if (!mounted) return;
              setState(() {
                if (result is int && result >= 0 && result <= 3) {
                  _currentNavIndex = result;
                }
              });
            });
            return;
          }
          setState(() {
            if (value == 1) {
              _showOnlySelectedMarker = false;
              _rebuildMarkers();
            }
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
          BottomNavigationBarItem(icon: Icon(Icons.route_rounded), label: '旅程'),
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
                        : _isLoadingPlaces
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
                    if (place.rating != null || place.userRatingsTotal != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            if (place.rating != null)
                              Text(
                                place.rating!.toStringAsFixed(1),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            if (place.rating != null)
                              const Padding(
                                padding: EdgeInsets.only(left: 4),
                                child: Icon(
                                  Icons.star,
                                  size: 14,
                                  color: Color(0xFF5A4E7C),
                                ),
                              ),
                            if (place.userRatingsTotal != null)
                              Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Text(
                                  '(${place.userRatingsTotal})',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      place.description.trim().isNotEmpty
                          ? place.description
                          : place.address,
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

  Widget _buildTripsPage() {
    if (_savedTrips.isEmpty) {
      return Center(
        child: Text(
          '目前沒有旅程，先到首頁設計一段行程吧！',
          style: TextStyle(color: Colors.black.withOpacity(0.65)),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      itemCount: _savedTrips.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final trip = _savedTrips[index];
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
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFF1EBFA),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.route_rounded,
                  color: Color(0xFF6C6296),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ItineraryPage(plan: trip.plan),
                      ),
                    );
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        trip.title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        trip.dateRangeText,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black54,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${trip.daysCount} 天 · ${trip.stopsCount} 個景點',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black54,
                        ),
                      ),
                      if (trip.tagsPreview.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: trip.tagsPreview
                              .map(
                                (tag) => Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFEDE7F6),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    tag,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: '刪除旅程',
                onPressed: () => _deleteSavedTrip(trip.id),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPlannerCard() {
    final cityOptions = _cityOptions();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFFFFC369), Color(0xFFF7A7AF), Color(0xFF7EAFFF)],
          stops: [0.05, 0.45, 0.95],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '準備好設計\n專屬於你的旅程了嗎？',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 12),
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
          const SizedBox(height: 8),
          _buildDropdownField(
            hint: '選擇出發地（必選）',
            value: _selectedOriginCity,
            options: cityOptions,
            onChanged: (value) {
              setState(() {
                _selectedOriginCity = value;
              });
            },
          ),
          const SizedBox(height: 10),
          _buildMultiSelectCityField(options: cityOptions),
          const SizedBox(height: 10),
          _buildBudgetSelector(),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _generatingPlan ? null : () => _startDesign(),
              style: ElevatedButton.styleFrom(
                elevation: 0,
                backgroundColor: Colors.white.withOpacity(0.9),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
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
                        fontSize: 19,
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
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(17),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildDropdownField({
    required String hint,
    required String? value,
    required List<String> options,
    required ValueChanged<String?> onChanged,
    bool enabled = true,
  }) {
    final hasValue = value != null && options.contains(value);
    return DropdownButtonFormField<String>(
      value: hasValue ? value : null,
      isExpanded: true,
      menuMaxHeight: 280,
      iconEnabledColor: Colors.black.withOpacity(0.7),
      decoration: InputDecoration(
        filled: true,
        fillColor: enabled ? Colors.white : Colors.white.withOpacity(0.65),
        hintText: hint,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(17),
          borderSide: BorderSide.none,
        ),
      ),
      items: options
          .map(
            (city) => DropdownMenuItem<String>(
              value: city,
              child: Text(city, overflow: TextOverflow.ellipsis),
            ),
          )
          .toList(),
      onChanged: enabled ? onChanged : null,
    );
  }

  Widget _buildMultiSelectCityField({required List<String> options}) {
    final hasSelection = _selectedDestinationCities.isNotEmpty;
    return InkWell(
      borderRadius: BorderRadius.circular(17),
      onTap: options.isEmpty ? null : () => _openDestinationCityPicker(options),
      child: InputDecorator(
        decoration: InputDecoration(
          filled: true,
          fillColor: Colors.white,
          hintText: '選擇旅遊城市（可複選）',
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(17),
            borderSide: BorderSide.none,
          ),
          suffixIcon: Icon(
            Icons.keyboard_arrow_down,
            color: Colors.black.withOpacity(0.7),
          ),
        ),
        child: hasSelection
            ? Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _selectedDestinationCities
                    .map(
                      (city) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.88),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.black.withOpacity(0.08),
                          ),
                        ),
                        child: Text(
                          city,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Colors.black.withOpacity(0.72),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              )
            : Text(
                '選擇旅遊城市（可複選）',
                style: TextStyle(
                  fontSize: 17,
                  color: Colors.black.withOpacity(0.48),
                ),
              ),
      ),
    );
  }

  Future<void> _openDestinationCityPicker(List<String> options) async {
    final tempSelected = _selectedDestinationCities.toSet();
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('選擇旅遊城市'),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: options
                      .map(
                        (city) => CheckboxListTile(
                          value: tempSelected.contains(city),
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(city),
                          onChanged: (checked) {
                            setStateDialog(() {
                              if (checked == true) {
                                tempSelected.add(city);
                              } else {
                                tempSelected.remove(city);
                              }
                            });
                          },
                        ),
                      )
                      .toList(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () {
                    tempSelected.clear();
                    setStateDialog(() {});
                  },
                  child: const Text('清空'),
                ),
                ElevatedButton(
                  onPressed: () =>
                      Navigator.pop(context, tempSelected.toList()..sort()),
                  child: const Text('完成'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null) return;
    setState(() {
      _selectedDestinationCities
        ..clear()
        ..addAll(result);
    });
  }

  Widget _buildBudgetSelector() {
    return Row(
      children: [
        Expanded(child: _buildBudgetButton(label: '\$', tier: 1)),
        const SizedBox(width: 8),
        Expanded(child: _buildBudgetButton(label: '\$\$', tier: 2)),
        const SizedBox(width: 8),
        Expanded(child: _buildBudgetButton(label: '\$\$\$', tier: 3)),
      ],
    );
  }

  Widget _buildBudgetButton({required String label, required int tier}) {
    final selected = _selectedBudgetTier == tier;
    return SizedBox(
      height: 44,
      child: ElevatedButton(
        onPressed: () {
          setState(() {
            _selectedBudgetTier = tier;
          });
        },
        style: ElevatedButton.styleFrom(
          elevation: 0,
          backgroundColor: selected
              ? const Color(0xFF5D73B9)
              : Colors.white.withOpacity(0.92),
          foregroundColor: selected
              ? Colors.white
              : Colors.black.withOpacity(0.75),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  List<String> _cityOptions() {
    final values =
        _places
            .map((p) => p.city.trim())
            .where((city) => city.isNotEmpty)
            .toSet()
            .map(_normalizeTaiwanAdminText)
            .toList()
          ..sort(_compareTaiwanCityOrder);
    return values;
  }

  void _syncPlannerSelections(List<_Place> places) {
    final cities = places
        .map((p) => p.city.trim())
        .where((city) => city.isNotEmpty)
        .toSet();
    if (_selectedOriginCity != null && !cities.contains(_selectedOriginCity)) {
      _selectedOriginCity = null;
    }
    _selectedDestinationCities.removeWhere((city) => !cities.contains(city));
  }

  int? _budgetToValue(int? tier) {
    switch (tier) {
      case 1:
        return 1000;
      case 2:
        return 2500;
      case 3:
        return 5000;
      default:
        return null;
    }
  }

  Widget _buildRecommendationStrip(double width) {
    if (_isLoadingPlaces && _places.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 24),
        child: Text('載入推薦景點中...'),
      );
    }
    final preferredTags = widget.selectedInterestIds.toSet();
    final base = preferredTags.isEmpty
        ? _places
        : _places.where((p) => p.tags.any(preferredTags.contains)).toList();
    final recommended = List<_Place>.from(base)
      ..sort((a, b) {
        final ar = a.rating ?? 0;
        final br = b.rating ?? 0;
        if (ar != br) return br.compareTo(ar);
        return a.name.compareTo(b.name);
      });

    if (recommended.isEmpty) {
      return const Text('目前沒有推薦景點，請先在後台匯入資料。');
    }

    final items = recommended.take(10).toList();

    return SizedBox(
      width: width,
      height: 182,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (context, index) {
          final place = items[index];
          return GestureDetector(
            onTap: () => _openPlaceFromRecommendation(place),
            child: Container(
              width: 174,
              padding: const EdgeInsets.all(10),
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: place.imageUrl.isNotEmpty
                        ? Image.network(
                            place.imageUrl,
                            height: 68,
                            width: double.infinity,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              height: 68,
                              color: const Color(0xFFF1ECE6),
                              alignment: Alignment.center,
                              child: const Icon(
                                Icons.landscape,
                                color: Colors.black38,
                                size: 18,
                              ),
                            ),
                          )
                        : Container(
                            height: 68,
                            color: const Color(0xFFF1ECE6),
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.landscape,
                              color: Colors.black38,
                              size: 18,
                            ),
                          ),
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          place.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            height: 1.1,
                          ),
                        ),
                        const SizedBox(height: 2),
                        if (place.rating != null ||
                            place.userRatingsTotal != null)
                          Row(
                            children: [
                              if (place.rating != null)
                                Text(
                                  place.rating!.toStringAsFixed(1),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                  ),
                                ),
                              if (place.rating != null)
                                const Padding(
                                  padding: EdgeInsets.only(left: 4),
                                  child: Icon(
                                    Icons.star,
                                    size: 12,
                                    color: Color(0xFF5A4E7C),
                                  ),
                                ),
                              if (place.userRatingsTotal != null)
                                Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: Text(
                                    '(${place.userRatingsTotal})',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.black54,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        const Spacer(),
                        Text(
                          place.city.isNotEmpty ? place.city : ' ',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openPlaceFromRecommendation(_Place place) {
    setState(() {
      _selectedPlace = place;
      _mapCenter = place.position;
      _showOnlySelectedMarker = true;
      _rebuildMarkers();
      _currentNavIndex = 1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectPlace(place, moveCamera: true);
    });
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

    final localHit = _places.firstWhere(
      (p) =>
          p.name.contains(trimmed) ||
          p.address.contains(trimmed) ||
          p.city.contains(trimmed),
      orElse: () => const _Place(
        id: '',
        name: '',
        position: LatLng(0, 0),
        description: '',
        address: '',
        imageUrl: '',
        city: '',
        tags: const [],
      ),
    );
    if (localHit.id.isNotEmpty) {
      _selectPlace(localHit, moveCamera: true);
      return;
    }
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
        id: 'google:${candidate['place_id'] ?? trimmed}',
        name: candidate['name'] as String? ?? trimmed,
        position: LatLng(
          (location['lat'] as num).toDouble(),
          (location['lng'] as num).toDouble(),
        ),
        description: candidate['formatted_address'] as String? ?? 'Google Maps',
        address: candidate['formatted_address'] as String? ?? '',
        imageUrl: '',
        city: '',
        tags: const [],
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
          CameraPosition(target: place.position, zoom: 16.8),
        ),
      );
    }
    _googleMapController?.showMarkerInfoWindow(
      MarkerId(_markerIdForPlace(place)),
    );
  }

  bool _isFavorite(_Place place) {
    return _favorites.any((p) => p.id == place.id);
  }

  void _toggleFavorite(_Place place) {
    var removed = false;
    _favorites.removeWhere((p) {
      final hit = p.id == place.id;
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
          if (place.rating != null || place.userRatingsTotal != null) ...[
            const SizedBox(height: 2),
            Row(
              children: [
                if (place.rating != null)
                  Text(
                    place.rating!.toStringAsFixed(1),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                if (place.rating != null) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.star, size: 16, color: Color(0xFF5A4E7C)),
                ],
                if (place.userRatingsTotal != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    '(${place.userRatingsTotal})',
                    style: const TextStyle(color: Colors.black54),
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 6),
          Text(
            place.description.trim().isNotEmpty
                ? place.description
                : place.address,
            style: const TextStyle(color: Colors.black54),
          ),
        ],
      ),
    );
  }
}

class _Place {
  final String id;
  final String name;
  final LatLng position;
  final String description;
  final String address;
  final String imageUrl;
  final String city;
  final List<String> tags;
  final double? rating;
  final int? userRatingsTotal;

  const _Place({
    required this.id,
    required this.name,
    required this.position,
    required this.description,
    required this.address,
    required this.imageUrl,
    required this.city,
    required this.tags,
    this.rating,
    this.userRatingsTotal,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'lat': position.latitude,
    'lng': position.longitude,
    'description': description,
    'address': address,
    'imageUrl': imageUrl,
    'city': city,
    'tags': tags,
    'rating': rating,
    'userRatingsTotal': userRatingsTotal,
  };

  factory _Place.fromJson(Map<String, dynamic> json) {
    return _Place(
      id: json['id'] as String? ?? (json['name'] as String? ?? ''),
      name: json['name'] as String? ?? '',
      position: LatLng(
        (json['lat'] as num).toDouble(),
        (json['lng'] as num).toDouble(),
      ),
      description: json['description'] as String? ?? '',
      address: json['address'] as String? ?? '',
      imageUrl: json['imageUrl'] as String? ?? '',
      city: _normalizeTaiwanAdminText(json['city'] as String? ?? ''),
      tags: (json['tags'] as List?)?.whereType<String>().toList() ?? const [],
      rating: (json['rating'] as num?)?.toDouble(),
      userRatingsTotal: (json['userRatingsTotal'] as num?)?.toInt(),
    );
  }

  factory _Place.fromBackend(Map<String, dynamic> json) {
    return _Place(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      position: LatLng(
        (json['lat'] as num?)?.toDouble() ?? 0,
        (json['lng'] as num?)?.toDouble() ?? 0,
      ),
      description: json['description'] as String? ?? '',
      address: json['address'] as String? ?? '',
      imageUrl: json['imageUrl'] as String? ?? '',
      city: _normalizeTaiwanAdminText(json['city'] as String? ?? ''),
      tags: (json['tags'] as List?)?.whereType<String>().toList() ?? const [],
      rating: (json['rating'] as num?)?.toDouble(),
      userRatingsTotal: (json['userRatingsTotal'] as num?)?.toInt(),
    );
  }
}

String _normalizeTaiwanAdminText(String input) {
  if (input.isEmpty) return input;
  const exactMap = <String, String>{
    '云林县': '雲林縣',
    '连江县': '連江縣',
    '台东县': '台東縣',
    '台东縣': '台東縣',
    '花莲县': '花蓮縣',
    '宜兰县': '宜蘭縣',
    '台中市': '臺中市',
    '台南市': '臺南市',
    '台北市': '臺北市',
    '台東縣': '臺東縣',
  };
  final trimmed = input.trim();
  if (exactMap.containsKey(trimmed)) {
    return exactMap[trimmed]!;
  }

  // Fallback: convert common simplified chars seen in Taiwan admin names.
  const charMap = <String, String>{
    '云': '雲',
    '县': '縣',
    '东': '東',
    '兰': '蘭',
    '连': '連',
    '台': '臺',
  };
  final sb = StringBuffer();
  for (final rune in trimmed.runes) {
    final ch = String.fromCharCode(rune);
    sb.write(charMap[ch] ?? ch);
  }
  return sb.toString();
}

const List<String> _taiwanCityNorthToSouth = <String>[
  '基隆市',
  '臺北市',
  '新北市',
  '桃園市',
  '新竹市',
  '新竹縣',
  '苗栗縣',
  '臺中市',
  '彰化縣',
  '南投縣',
  '雲林縣',
  '嘉義市',
  '嘉義縣',
  '臺南市',
  '高雄市',
  '屏東縣',
  '宜蘭縣',
  '花蓮縣',
  '臺東縣',
  '澎湖縣',
  '金門縣',
  '連江縣',
];

int _compareTaiwanCityOrder(String a, String b) {
  final normalizedA = _normalizeTaiwanAdminText(a);
  final normalizedB = _normalizeTaiwanAdminText(b);
  final indexA = _taiwanCityNorthToSouth.indexOf(normalizedA);
  final indexB = _taiwanCityNorthToSouth.indexOf(normalizedB);

  if (indexA != -1 && indexB != -1) {
    return indexA.compareTo(indexB);
  }
  if (indexA != -1) {
    return -1;
  }
  if (indexB != -1) {
    return 1;
  }
  return normalizedA.compareTo(normalizedB);
}

class _SavedTrip {
  const _SavedTrip({
    required this.id,
    required this.savedAt,
    required this.plan,
    required this.title,
    required this.startDate,
    required this.endDate,
    required this.daysCount,
    required this.stopsCount,
    required this.tagsPreview,
  });

  final String id;
  final DateTime savedAt;
  final Map<String, dynamic> plan;
  final String title;
  final DateTime? startDate;
  final DateTime? endDate;
  final int daysCount;
  final int stopsCount;
  final List<String> tagsPreview;

  String get dateRangeText {
    final start = startDate;
    final end = endDate;
    if (start == null && end == null) return '未提供日期';
    if (start != null && end != null) {
      return '${_fmtDate(start)} ~ ${_fmtDate(end)}';
    }
    return _fmtDate(start ?? end!);
  }

  factory _SavedTrip.fromPlan(Map<String, dynamic> plan) {
    final meta = plan['meta'] is Map<String, dynamic>
        ? plan['meta'] as Map<String, dynamic>
        : <String, dynamic>{};
    final days = (plan['days'] as List?)?.whereType<Map>().toList() ?? const [];

    DateTime? startDate;
    DateTime? endDate;
    var stopsCount = 0;
    for (final day in days) {
      final date = DateTime.tryParse(day['date']?.toString() ?? '');
      startDate ??= date;
      if (date != null) endDate = date;
      final items = day['items'];
      if (items is List) stopsCount += items.length;
    }

    final tagsPreview =
        (meta['tags'] as List?)
            ?.map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .take(4)
            .toList() ??
        const <String>[];
    final location = meta['location']?.toString().trim();
    final title = (location != null && location.isNotEmpty)
        ? location
        : '旅程 ${startDate != null ? _fmtDate(startDate) : ''}'.trim();

    final generatedAt = DateTime.tryParse(
      meta['generatedAt']?.toString() ?? '',
    );
    final keyBase =
        '${meta['generatedAt'] ?? DateTime.now().toIso8601String()}|${location ?? ''}|$stopsCount';
    return _SavedTrip(
      id: base64Url.encode(utf8.encode(keyBase)),
      savedAt: generatedAt ?? DateTime.now(),
      plan: jsonDecode(jsonEncode(plan)) as Map<String, dynamic>,
      title: title.isEmpty ? '未命名旅程' : title,
      startDate: startDate,
      endDate: endDate,
      daysCount: days.length,
      stopsCount: stopsCount,
      tagsPreview: tagsPreview,
    );
  }

  factory _SavedTrip.fromJson(Map<String, dynamic> json) {
    final rawPlan = json['plan'] as Map<String, dynamic>? ?? const {};
    return _SavedTrip(
      id: json['id']?.toString() ?? '',
      savedAt:
          DateTime.tryParse(json['savedAt']?.toString() ?? '') ??
          DateTime.now(),
      plan: Map<String, dynamic>.from(rawPlan),
      title: json['title']?.toString() ?? '未命名旅程',
      startDate: DateTime.tryParse(json['startDate']?.toString() ?? ''),
      endDate: DateTime.tryParse(json['endDate']?.toString() ?? ''),
      daysCount: (json['daysCount'] as num?)?.toInt() ?? 0,
      stopsCount: (json['stopsCount'] as num?)?.toInt() ?? 0,
      tagsPreview:
          (json['tagsPreview'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'savedAt': savedAt.toIso8601String(),
    'plan': plan,
    'title': title,
    'startDate': startDate?.toIso8601String(),
    'endDate': endDate?.toIso8601String(),
    'daysCount': daysCount,
    'stopsCount': stopsCount,
    'tagsPreview': tagsPreview,
  };

  static String _fmtDate(DateTime value) {
    final mm = value.month.toString().padLeft(2, '0');
    final dd = value.day.toString().padLeft(2, '0');
    return '${value.year}-$mm-$dd';
  }
}
