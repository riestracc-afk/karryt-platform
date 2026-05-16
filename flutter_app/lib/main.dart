import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart'
  show
    Clipboard,
    ClipboardData,
    HapticFeedback,
    LogicalKeyboardKey,
    SystemSound,
    SystemSoundType,
    rootBundle;

import 'core/api_base.dart';
import 'core/app_theme.dart';
import 'core/csv_download.dart';
import 'data/address_store.dart';
import 'data/api_client.dart';
import 'data/geocoding_client.dart';
import 'data/google_routes_client.dart';
import 'data/realtime_client.dart';
import 'domain/models.dart';
import 'state/ride_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _runtimeEnv
    ..clear()
    ..addAll(await _loadRuntimeEnv());
  runApp(const KarrytFlutterApp());
}

final Map<String, String> _runtimeEnv = <String, String>{};

Future<Map<String, String>> _loadRuntimeEnv() async {
  for (final fileName in const ['.env', 'assets/.env']) {
    try {
      final content = await rootBundle.loadString(fileName);
      final env = <String, String>{};

      for (final rawLine in const LineSplitter().convert(content)) {
        final line = rawLine.trim();
        if (line.isEmpty || line.startsWith('#')) {
          continue;
        }

        final separatorIndex = line.indexOf('=');
        if (separatorIndex <= 0) {
          continue;
        }

        final key = line.substring(0, separatorIndex).trim();
        final value = line.substring(separatorIndex + 1).trim();
        env[key] = value;
      }

      if (env.isNotEmpty) {
        return env;
      }
    } catch (_) {
      // Si el asset no existe en esta ruta, se intenta la siguiente.
    }
  }

  return const <String, String>{};
}

const List<String> _monthShortLabels = [
  'ene',
  'feb',
  'mar',
  'abr',
  'may',
  'jun',
  'jul',
  'ago',
  'sep',
  'oct',
  'nov',
  'dic',
];

String formatLocalDateTime(DateTime value) {
  final local = value.toLocal();
  final month = _monthShortLabels[local.month - 1];
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$day $month ${local.year}, $hour:$minute';
}

String formatScheduledAtLocal(String? isoValue) {
  if (isoValue == null || isoValue.trim().isEmpty) {
    return 'No programado';
  }

  final parsed = DateTime.tryParse(isoValue);
  if (parsed == null) {
    return isoValue;
  }

  return formatLocalDateTime(parsed);
}

String _readEnvValue(String key) {
  return _runtimeEnv[key]?.trim() ?? '';
}

String get _mapboxAccessToken {
  final fromEnvFile = _readEnvValue('MAPBOX_ACCESS_TOKEN');
  if (fromEnvFile.isNotEmpty) {
    return fromEnvFile;
  }
  return const String.fromEnvironment('MAPBOX_ACCESS_TOKEN');
}

String get _googleRoutesApiKey {
  final fromEnvFile = _readEnvValue('GOOGLE_ROUTES_API_KEY');
  if (fromEnvFile.isNotEmpty) {
    return fromEnvFile;
  }
  return const String.fromEnvironment('GOOGLE_ROUTES_API_KEY');
}

String get _firebaseWebVapidKey {
  final fromEnvFile = _readEnvValue('FIREBASE_WEB_VAPID_KEY');
  if (fromEnvFile.isNotEmpty) {
    return fromEnvFile;
  }
  return const String.fromEnvironment('FIREBASE_WEB_VAPID_KEY');
}

class _RouteSnapshot {
  const _RouteSnapshot({
    required this.points,
    required this.distanceKm,
    required this.etaMinutes,
    required this.hasLiveTraffic,
  });

  final List<LatLng> points;
  final double distanceKm;
  final int etaMinutes;
  final bool hasLiveTraffic;
}

class _RankedSuggestion {
  const _RankedSuggestion({
    required this.suggestion,
    required this.score,
    required this.distanceKm,
    required this.queryTokenMatches,
    required this.localityTokenMatches,
    required this.addressNumberMatches,
  });

  final GeocodeSuggestion suggestion;
  final double score;
  final double distanceKm;
  final int queryTokenMatches;
  final int localityTokenMatches;
  final int addressNumberMatches;
}

class KarrytFlutterApp extends StatelessWidget {
  const KarrytFlutterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Karryt Mueve',
      theme: buildKarrytTheme(KarrytRoleTheme.user),
      home: const RideScreen(),
    );
  }
}

/// Widget premium para estados vacíos (sin datos/resultados)
class KarrytEmptyState extends StatelessWidget {
  const KarrytEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
    this.actionLabel,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? action;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(
                icon,
                size: 56,
                color: theme.colorScheme.primary.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (action != null && actionLabel != null) ...[
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: action,
                icon: const Icon(Icons.add_rounded),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _KarrytShortcutIntent extends Intent {
  const _KarrytShortcutIntent(this.command);
  final String command;
}

/// Premium skeleton loader con shimmer effect (sin dependencias extras)
class KarrytSkeletonLoader extends StatefulWidget {
  const KarrytSkeletonLoader({
    super.key,
    required this.child,
    this.isLoading = true,
    this.duration = const Duration(milliseconds: 1500),
  });

  final Widget child;
  final bool isLoading;
  final Duration duration;

  @override
  State<KarrytSkeletonLoader> createState() => _KarrytSkeletonLoaderState();
}

class _KarrytSkeletonLoaderState extends State<KarrytSkeletonLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isLoading) {
      return widget.child;
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: 0.6 + (0.4 * (math.sin(_controller.value * math.pi * 2) + 1) / 2),
          child: ShaderMask(
            shaderCallback: (bounds) {
              return LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Colors.grey.shade300,
                  Colors.grey.shade100,
                  Colors.grey.shade300,
                ],
                stops: [
                  (_controller.value - 0.3).clamp(0, 1),
                  _controller.value.clamp(0, 1),
                  (_controller.value + 0.3).clamp(0, 1),
                ],
              ).createShader(bounds);
            },
            child: widget.child,
          ),
        );
      },
    );
  }
}

/// Skeleton para tarjetas de viaje (fare cards)
class RideCardSkeleton extends StatelessWidget {
  const RideCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 16,
              width: 100,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              height: 12,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              height: 12,
              width: 200,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 12,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  height: 12,
                  width: 80,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class WorkspaceShell extends StatefulWidget {
  const WorkspaceShell({super.key});

  @override
  State<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<WorkspaceShell> {
  int _index = 0;

  static const _tabs = [
    RideScreen(),
    AdminScreen(),
    DriverScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Usuario',
          ),
          NavigationDestination(
            icon: Icon(Icons.admin_panel_settings_outlined),
            selectedIcon: Icon(Icons.admin_panel_settings),
            label: 'Admin',
          ),
          NavigationDestination(
            icon: Icon(Icons.local_shipping_outlined),
            selectedIcon: Icon(Icons.local_shipping),
            label: 'Chofer',
          ),
        ],
      ),
    );
  }
}

class RideScreen extends StatefulWidget {
  const RideScreen({super.key});

  @override
  State<RideScreen> createState() => _RideScreenState();
}

enum MapPickMode { pickup, dropoff }

class _RideScreenState extends State<RideScreen> {
  late final TextEditingController _pickupController;
  late final TextEditingController _dropoffController;
  late final TextEditingController _distanceController;
  late final FocusNode _pickupFocusNode;
  late final FocusNode _dropoffFocusNode;
  late final ScrollController _pageScrollController;

  late final ApiClient _apiClient;
  late final RideController _controller;
  late final GoogleRoutesClient _googleRoutesClient;
  late final AddressStore _addressStore;
  late final MapController _mapController;

  final GlobalKey _requestSectionKey = GlobalKey();
  final GlobalKey _pricingSectionKey = GlobalKey();
  final GlobalKey _routePreviewKey = GlobalKey();

  static const _defaultCenter = LatLng(25.6866, -100.3161);
  MapPickMode _mapPickMode = MapPickMode.pickup;
  LatLng? _pickupPoint;
  LatLng? _dropoffPoint;
  bool _locating = false;
  bool _resolvingAddress = false;
  bool _searchingPickup = false;
  bool _searchingDropoff = false;
  DateTime? _scheduledAt;
  String _rideRequestType = 'urgent';
  bool _notifyOfflineByWhatsApp = true;
  bool _notifyOfflineBySms = false;
  String? _locationStatus;
  String? _routeStatus;
  bool _routeLoading = false;
  double? _routeDistanceKm;
  int? _etaMinutes;
  List<LatLng> _routePoints = const [];
  LatLng? _currentDevicePoint;
  String? _currentLocationLabel;
  List<GeocodeSuggestion> _recentAddresses = const [];
  List<GeocodeSuggestion> _favoriteAddresses = const [];
  List<GeocodeSuggestion> _pickupAutocompleteSuggestions = const [];
  List<GeocodeSuggestion> _dropoffAutocompleteSuggestions = const [];
  int _currentNavIndex = 0;
  Timer? _pickupGeocodeDebounce;
  Timer? _dropoffGeocodeDebounce;
  int _pickupAutocompleteRequestId = 0;
  int _dropoffAutocompleteRequestId = 0;
  bool _loadingPickupAutocomplete = false;
  bool _loadingDropoffAutocomplete = false;
  String? _lastPickupResolvedQuery;
  String? _lastDropoffResolvedQuery;
  String? _lastPickupDisambiguationQuery;
  String? _lastDropoffDisambiguationQuery;
  String? _pickupAddressValidationMessage;
  String? _dropoffAddressValidationMessage;
  bool _pickupAddressConfirmed = false;
  bool _dropoffAddressConfirmed = false;
  bool _pickupAddressApproximate = false;
  bool _dropoffAddressApproximate = false;
  bool _submittingRideRating = false;

  static const _lastPickupAddressKey = 'Karryt_last_pickup_address';
  static const _lastDropoffAddressKey = 'Karryt_last_dropoff_address';
  static const _includedLoadMinutes = 25;
  static const _includedUnloadMinutes = 25;
  static const Set<String> _addressSearchStopWords = {
    'a',
    'al',
    'av',
    'avenida',
    'calle',
    'camino',
    'carretera',
    'col',
    'colonia',
    'cp',
    'de',
    'del',
    'destino',
    'direccion',
    'el',
    'en',
    'fracc',
    'fraccionamiento',
    'int',
    'interior',
    'la',
    'las',
    'localidad',
    'los',
    'mexico',
    'mi',
    'municipio',
    'no',
    'numero',
    'origen',
    'ubicacion',
    'y',
  };

  @override
  void initState() {
    super.initState();

    final baseUrl = resolveApiBaseUrl();
    _apiClient = ApiClient(baseUrl);
    _controller = RideController(
      apiClient: _apiClient,
      realtimeClient: RealtimeClient(baseUrl),
    )..init();
    _googleRoutesClient = GoogleRoutesClient(apiKey: _googleRoutesApiKey);
    _addressStore = AddressStore(baseUrl: baseUrl);
    _mapController = MapController();
    _pageScrollController = ScrollController();
    _pickupFocusNode = FocusNode()
      ..addListener(() {
        _handleAddressFieldFocusChange(isPickup: true);
      });
    _dropoffFocusNode = FocusNode()
      ..addListener(() {
        _handleAddressFieldFocusChange(isPickup: false);
      });

    _pickupController =
        TextEditingController(text: _controller.pickupText.value)
          ..addListener(() {
            _controller.pickupText.value = _pickupController.text;
            _onAddressInputChanged(isPickup: true);
          });

    _dropoffController =
        TextEditingController(text: _controller.dropoffText.value)
          ..addListener(() {
            _controller.dropoffText.value = _dropoffController.text;
            _onAddressInputChanged(isPickup: false);
          });

    _distanceController =
        TextEditingController(text: _controller.distanceText.value)
          ..addListener(() {
            _controller.distanceText.value = _distanceController.text;
          });

    unawaited(_loadSavedAddresses());
    unawaited(_loadLastUsedAddresses());
  }

  Future<void> _scrollToSection(GlobalKey key, int index) async {
    setState(() {
      _currentNavIndex = index;
    });

    final context = key.currentContext;
    if (context == null) {
      return;
    }

    await Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
      alignment: 0.08,
    );
  }

  void _syncNavIndexFromScroll() {
    int nextIndex = _currentNavIndex;

    bool isSectionAboveThreshold(GlobalKey key) {
      final context = key.currentContext;
      if (context == null) {
        return false;
      }

      final renderObject = context.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.attached) {
        return false;
      }

      final dy = renderObject.localToGlobal(Offset.zero).dy;
      return dy <= 180;
    }

    if (isSectionAboveThreshold(_pricingSectionKey)) {
      nextIndex = 1;
    } else {
      nextIndex = 0;
    }

    if (nextIndex != _currentNavIndex && mounted) {
      setState(() {
        _currentNavIndex = nextIndex;
      });
    }
  }

  Future<void> _loadSavedAddresses() async {
    final recents = await _addressStore.loadRecent();
    final favorites = await _addressStore.loadFavorites();
    if (!mounted) {
      return;
    }

    setState(() {
      _recentAddresses = recents;
      _favoriteAddresses = favorites;
    });
  }

  Future<void> _loadLastUsedAddresses() async {
    final prefs = await SharedPreferences.getInstance();
    final pickupRaw = prefs.getString(_lastPickupAddressKey);
    final dropoffRaw = prefs.getString(_lastDropoffAddressKey);

    GeocodeSuggestion? parseValue(String? raw) {
      if (raw == null || raw.isEmpty) {
        return null;
      }
      try {
        final data = jsonDecode(raw);
        if (data is! Map) {
          return null;
        }
        return GeocodeSuggestion.fromJson(data.cast<String, dynamic>());
      } catch (_) {
        return null;
      }
    }

    final pickup = parseValue(pickupRaw);
    final dropoff = parseValue(dropoffRaw);
    if (!mounted) {
      return;
    }

    if (pickup == null && dropoff == null) {
      return;
    }

    setState(() {
      if (pickup != null) {
        final point = LatLng(pickup.lat, pickup.lng);
        _pickupPoint = point;
        _lastPickupResolvedQuery = pickup.displayName;
        _setAddressValidationFeedbackValues(
          isPickup: true,
          message: 'Origen confirmado.',
          confirmed: true,
        );
        _pickupController.text = pickup.displayName;
        _controller.setPickupPoint(point.latitude, point.longitude);
      }
      if (dropoff != null) {
        final point = LatLng(dropoff.lat, dropoff.lng);
        _dropoffPoint = point;
        _lastDropoffResolvedQuery = dropoff.displayName;
        _setAddressValidationFeedbackValues(
          isPickup: false,
          message: 'Destino confirmado.',
          confirmed: true,
        );
        _dropoffController.text = dropoff.displayName;
        _controller.setDropoffPoint(point.latitude, point.longitude);
      }
    });

    final center = _pickupPoint ?? _dropoffPoint;
    if (center != null) {
      _moveMapWhenReady(center, 13.5);
    }
    _syncDistanceFromMap();
  }

  void _moveMapWhenReady(LatLng point, double zoom) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      try {
        _mapController.move(point, zoom);
      } catch (_) {
        // Si el mapa aun no se renderiza, se conserva el resto del flujo.
      }
    });
  }

  Future<void> _focusAcceptedAddressOnMap({required bool isPickup}) async {
    final point = isPickup ? _pickupPoint : _dropoffPoint;
    if (point == null) {
      return;
    }

    if (mounted) {
      setState(() {
        _mapPickMode = isPickup ? MapPickMode.pickup : MapPickMode.dropoff;
      });
    }

    await _scrollToSection(_routePreviewKey, 0);
    _moveMapWhenReady(point, 16.5);
  }

  Future<void> _openManualMapSelection({required bool isPickup}) async {
    if (mounted) {
      setState(() {
        _mapPickMode = isPickup ? MapPickMode.pickup : MapPickMode.dropoff;
        _locationStatus = isPickup
            ? 'Toca el mapa para fijar el origen exacto.'
            : 'Toca el mapa para fijar el destino exacto.';
      });
    }

    await _scrollToSection(_routePreviewKey, 0);
    final center = isPickup
        ? (_pickupPoint ?? _currentDevicePoint ?? _dropoffPoint ?? _defaultCenter)
        : (_dropoffPoint ?? _pickupPoint ?? _currentDevicePoint ?? _defaultCenter);
    _moveMapWhenReady(center, 16);
  }

  Future<void> _saveLastAddress(
    GeocodeSuggestion value, {
    required bool isPickup,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = isPickup ? _lastPickupAddressKey : _lastDropoffAddressKey;
    final payload = jsonEncode({
      'display_name': value.displayName,
      'lat': value.lat.toString(),
      'lon': value.lng.toString(),
    });
    await prefs.setString(key, payload);
  }

  void _selectAllAddressText(TextEditingController controller) {
    if (controller.text.isEmpty) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || controller.text.isEmpty) {
        return;
      }

      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: controller.text.length,
      );
    });
  }

  void _handleAddressFieldFocusChange({required bool isPickup}) {
    final focusNode = isPickup ? _pickupFocusNode : _dropoffFocusNode;
    final controller = isPickup ? _pickupController : _dropoffController;

    if (!focusNode.hasFocus) {
      if (!mounted) {
        return;
      }

      setState(() {
        _clearAutocompleteSuggestionsValues(isPickup: isPickup);
      });
      return;
    }

    _selectAllAddressText(controller);

    if (mounted) {
      setState(() {
        _clearAutocompleteSuggestionsValues(isPickup: !isPickup);
      });
    }

    final query = controller.text.trim();
    if (query.length >= 3) {
      _loadAutocompleteSuggestions(isPickup: isPickup, query: query);
    }
  }

  void _clearAddressInput({required bool isPickup}) {
    final controller = isPickup ? _pickupController : _dropoffController;
    controller.clear();

    if (!mounted) {
      return;
    }

    setState(() {
      _locationStatus = null;
    });

    FocusScope.of(context).requestFocus(
      isPickup ? _pickupFocusNode : _dropoffFocusNode,
    );
  }

  Widget _buildAddressFieldSuffix({required bool isPickup}) {
    final controller = isPickup ? _pickupController : _dropoffController;
    final query = controller.text.trim();
    final loading = isPickup
        ? (_loadingPickupAutocomplete || _searchingPickup)
        : (_loadingDropoffAutocomplete || _searchingDropoff);
    final showSecondaryAction = loading || query.isNotEmpty;

    return SizedBox(
      width: showSecondaryAction ? 88 : 48,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (query.isNotEmpty)
            IconButton(
              tooltip: 'Limpiar direccion',
              onPressed: () => _clearAddressInput(isPickup: isPickup),
              icon: const Icon(Icons.close_rounded, size: 20),
            ),
          IconButton(
            tooltip: 'Elegir en mapa',
            onPressed: () => _openManualMapSelection(isPickup: isPickup),
            icon: const Icon(Icons.map_outlined, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildAddressInput({required bool isPickup}) {
    return TextField(
      controller: isPickup ? _pickupController : _dropoffController,
      focusNode: isPickup ? _pickupFocusNode : _dropoffFocusNode,
      keyboardType: TextInputType.streetAddress,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        labelText: isPickup ? 'Punto de recoleccion' : 'Destino',
        hintText: 'Calle, numero, colonia, municipio',
        prefixIcon: Icon(
          isPickup ? Icons.my_location : Icons.location_on_outlined,
        ),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 48,
          maxWidth: 96,
          minHeight: 48,
        ),
        suffixIcon: _buildAddressFieldSuffix(isPickup: isPickup),
      ),
      onTap: () => _selectAllAddressText(
        isPickup ? _pickupController : _dropoffController,
      ),
      onSubmitted: (_) => _searchAddress(isPickup: isPickup),
    );
  }

  void _clearAddressSelectionValues({required bool isPickup}) {
    if (isPickup) {
      _pickupPoint = null;
      _lastPickupResolvedQuery = null;
      _lastPickupDisambiguationQuery = null;
    } else {
      _dropoffPoint = null;
      _lastDropoffResolvedQuery = null;
      _lastDropoffDisambiguationQuery = null;
    }
  }

  void _setAddressValidationFeedbackValues({
    required bool isPickup,
    required String? message,
    required bool confirmed,
    bool approximate = false,
  }) {
    if (isPickup) {
      _pickupAddressValidationMessage = message;
      _pickupAddressConfirmed = confirmed;
      _pickupAddressApproximate = approximate;
    } else {
      _dropoffAddressValidationMessage = message;
      _dropoffAddressConfirmed = confirmed;
      _dropoffAddressApproximate = approximate;
    }
  }

  void _setAutocompleteSuggestionValues({
    required bool isPickup,
    List<GeocodeSuggestion>? suggestions,
    bool? loading,
  }) {
    if (isPickup) {
      if (suggestions != null) {
        _pickupAutocompleteSuggestions = suggestions;
      }
      if (loading != null) {
        _loadingPickupAutocomplete = loading;
      }
    } else {
      if (suggestions != null) {
        _dropoffAutocompleteSuggestions = suggestions;
      }
      if (loading != null) {
        _loadingDropoffAutocomplete = loading;
      }
    }
  }

  void _clearAutocompleteSuggestionsValues({required bool isPickup}) {
    _setAutocompleteSuggestionValues(
      isPickup: isPickup,
      suggestions: const <GeocodeSuggestion>[],
      loading: false,
    );
  }

  Future<void> _loadAutocompleteSuggestions({
    required bool isPickup,
    required String query,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.length < 3) {
      if (mounted) {
        setState(() {
          _clearAutocompleteSuggestionsValues(isPickup: isPickup);
        });
      }
      return;
    }

    final requestId = isPickup
        ? ++_pickupAutocompleteRequestId
        : ++_dropoffAutocompleteRequestId;

    if (mounted) {
      setState(() {
        _setAutocompleteSuggestionValues(isPickup: isPickup, loading: true);
      });
    }

    try {
      final suggestions = await _fetchAddressSuggestions(
        query: normalizedQuery,
        isPickup: isPickup,
      );

      if (!mounted) {
        return;
      }

      final latestRequestId = isPickup
          ? _pickupAutocompleteRequestId
          : _dropoffAutocompleteRequestId;
      final currentQuery =
          (isPickup ? _pickupController.text : _dropoffController.text).trim();

      if (requestId != latestRequestId ||
          _normalizeAddressText(currentQuery) !=
              _normalizeAddressText(normalizedQuery)) {
        return;
      }

      setState(() {
        _setAutocompleteSuggestionValues(
          isPickup: isPickup,
          suggestions: suggestions,
          loading: false,
        );
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      final latestRequestId =
          isPickup ? _pickupAutocompleteRequestId : _dropoffAutocompleteRequestId;
      if (requestId != latestRequestId) {
        return;
      }

      setState(() {
        _clearAutocompleteSuggestionsValues(isPickup: isPickup);
        _setAddressValidationFeedbackValues(
          isPickup: isPickup,
          message: isPickup
              ? 'No se pudieron cargar sugerencias para el origen.'
              : 'No se pudieron cargar sugerencias para el destino.',
          confirmed: false,
        );
      });
    }
  }

  void _onAddressInputChanged({required bool isPickup}) {
    final query =
        (isPickup ? _pickupController.text : _dropoffController.text).trim();

    if (isPickup) {
      _pickupGeocodeDebounce?.cancel();
    } else {
      _dropoffGeocodeDebounce?.cancel();
    }

    final sameAsLast = isPickup
        ? query == _lastPickupResolvedQuery
        : query == _lastDropoffResolvedQuery;
    if (sameAsLast) {
      setState(() {
        _clearAutocompleteSuggestionsValues(isPickup: isPickup);
      });
      return;
    }

    final hadResolvedSelection = isPickup
        ? _pickupPoint != null || _lastPickupResolvedQuery != null
        : _dropoffPoint != null || _lastDropoffResolvedQuery != null;

    if (hadResolvedSelection) {
      if (isPickup) {
        _controller.clearPickupPoint();
      } else {
        _controller.clearDropoffPoint();
      }
    }

    if (query.isEmpty) {
      setState(() {
        _clearAddressSelectionValues(isPickup: isPickup);
        _clearAutocompleteSuggestionsValues(isPickup: isPickup);
        _setAddressValidationFeedbackValues(
          isPickup: isPickup,
          message: null,
          confirmed: false,
        );
      });
      _syncDistanceFromMap();
      return;
    }

    setState(() {
      if (hadResolvedSelection) {
        _clearAddressSelectionValues(isPickup: isPickup);
      } else if (isPickup) {
        _lastPickupDisambiguationQuery = null;
      } else {
        _lastDropoffDisambiguationQuery = null;
      }

      _setAddressValidationFeedbackValues(
        isPickup: isPickup,
        message: query.length < 3
            ? (isPickup
                ? 'Sigue escribiendo el origen para validarlo.'
                : 'Sigue escribiendo el destino para validarlo.')
            : (isPickup
                ? 'Elige una opcion de la lista o ajusta el punto en el mapa.'
                : 'Elige una opcion de la lista o ajusta el punto en el mapa.'),
        confirmed: false,
      );
    });

    if (hadResolvedSelection) {
      _syncDistanceFromMap();
    }

    if (query.length < 3) {
      return;
    }

    if (isPickup) {
      _pickupGeocodeDebounce = Timer(const Duration(milliseconds: 320), () {
        _loadAutocompleteSuggestions(isPickup: true, query: query);
      });
    } else {
      _dropoffGeocodeDebounce = Timer(const Duration(milliseconds: 320), () {
        _loadAutocompleteSuggestions(isPickup: false, query: query);
      });
    }
  }

  Future<void> _resolveTypedAddressToPoint({
    required bool isPickup,
    required String query,
    bool allowDisambiguationPrompt = true,
  }) async {
    if (!mounted) {
      return;
    }

    try {
      final addressNumberTokens = _extractAddressNumberTokens(query);
      final finalSuggestions = await _fetchAddressSuggestions(
        query: query,
        isPickup: isPickup,
      );

      final liveQuery =
          (isPickup ? _pickupController.text : _dropoffController.text).trim();
      if (_normalizeAddressText(liveQuery) != _normalizeAddressText(query)) {
        return;
      }

      if (!mounted || finalSuggestions.isEmpty) {
        if (mounted) {
          setState(() {
            _clearAutocompleteSuggestionsValues(isPickup: isPickup);
            _setAddressValidationFeedbackValues(
              isPickup: isPickup,
              message: addressNumberTokens.isNotEmpty
                  ? 'No se pudo confirmar el numero exterior. Ajusta calle y numero.'
                  : 'No se pudo confirmar esta direccion. Ajusta calle y numero.',
              confirmed: false,
            );
          });
        }
        return;
      }

      final shortlist = finalSuggestions
          .take(6)
          .toList(growable: false)
          .cast<GeocodeSuggestion>();
      GeocodeSuggestion? selected;

      if (shortlist.length == 1) {
        final topDisplay =
            _normalizeAddressText(shortlist.first.displayName);
        final topAddressNumberMatches =
            _countExactTokenMatches(topDisplay, addressNumberTokens);
        final requiresExactAddressNumber = addressNumberTokens.isNotEmpty;

        if (requiresExactAddressNumber &&
            topAddressNumberMatches < addressNumberTokens.length) {
          setState(() {
            _setAddressValidationFeedbackValues(
              isPickup: isPickup,
              message:
                  'La coincidencia no confirma el numero exterior. Elige otra opcion o ajusta el punto en el mapa.',
              confirmed: false,
            );
          });
          return;
        }

        selected = shortlist.first;
      } else {
        final normalizedQuery = _normalizeAddressText(query);
        final queryTokens = _extractMeaningfulAddressTokens([query]);
        final top = _normalizeAddressText(shortlist.first.displayName);
        final second = _normalizeAddressText(shortlist[1].displayName);
        final topTokenMatches = _countTokenMatches(top, queryTokens);
        final secondTokenMatches = _countTokenMatches(second, queryTokens);
        final topAddressNumberMatches =
            _countExactTokenMatches(top, addressNumberTokens);
        final secondAddressNumberMatches =
            _countExactTokenMatches(second, addressNumberTokens);
        final clearBestNumber = addressNumberTokens.isEmpty ||
            (topAddressNumberMatches == addressNumberTokens.length &&
                secondAddressNumberMatches < topAddressNumberMatches);

        final clearBestText = top == normalizedQuery ||
            (normalizedQuery.isNotEmpty &&
                top.startsWith(normalizedQuery) &&
                !second.startsWith(normalizedQuery)) ||
            (queryTokens.isNotEmpty &&
                topTokenMatches == queryTokens.length &&
                secondTokenMatches < topTokenMatches);

        final clearBest = clearBestText && clearBestNumber;

        if (clearBest) {
          selected = shortlist.first;
        } else if (!allowDisambiguationPrompt) {
          setState(() {
            _setAddressValidationFeedbackValues(
              isPickup: isPickup,
              message: addressNumberTokens.isNotEmpty
                  ? 'No se confirmo el numero exterior. Elige una opcion de la lista o ajusta el punto en el mapa.'
                  : 'Hay varias coincidencias. Elige una opcion de la lista o ajusta el punto en el mapa.',
              confirmed: false,
            );
          });
          return;
        } else {
          final lastPrompted = isPickup
              ? _lastPickupDisambiguationQuery
              : _lastDropoffDisambiguationQuery;
          if (lastPrompted == query) {
            return;
          }

          if (isPickup) {
            _lastPickupDisambiguationQuery = query;
          } else {
            _lastDropoffDisambiguationQuery = query;
          }

          selected = await _pickSuggestionForTypedQuery(
            isPickup: isPickup,
            query: query,
            options: shortlist,
          );
          if (selected == null || !mounted) {
            return;
          }
        }
      }

      await _applySuggestion(selected, isPickup: isPickup);
    } catch (_) {
      // Si falla geocodificación, mantenemos el texto sin bloquear al usuario.
    }
  }

  String _normalizeAddressText(String value) {
    var normalized = value.toLowerCase();

    const replacements = {
      'á': 'a',
      'é': 'e',
      'í': 'i',
      'ó': 'o',
      'ú': 'u',
      'ü': 'u',
      'ñ': 'n',
    };

    replacements.forEach((source, target) {
      normalized = normalized.replaceAll(source, target);
    });

    normalized = normalized.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    return normalized.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Future<List<GeocodeSuggestion>> _fetchAddressSuggestions({
    required String query,
    required bool isPickup,
  }) async {
    final biasPoint = _resolveSearchBiasPoint(isPickup: isPickup);
    final suggestions = await _apiClient.searchAddressSuggestions(
      query: query,
      biasLat: biasPoint?.latitude,
      biasLng: biasPoint?.longitude,
    );

    if (suggestions.isEmpty) {
      return const [];
    }

    final hasServerResolvedCoordinates =
        suggestions.any((item) => item.provider == 'nominatim');
    if (!hasServerResolvedCoordinates) {
      return suggestions;
    }

    return _rankAddressSuggestions(
      query: query,
      suggestions: suggestions,
      isPickup: isPickup,
    );
  }

  LatLng? _resolveSearchBiasPoint({required bool isPickup}) {
    if (!isPickup) {
      return _pickupPoint ?? _currentDevicePoint ?? _dropoffPoint;
    }

    return _currentDevicePoint ?? _pickupPoint ?? _dropoffPoint;
  }

  Iterable<String> _searchContextTexts({required bool isPickup}) sync* {
    final currentLocation = _currentLocationLabel?.trim();
    if (currentLocation != null && currentLocation.isNotEmpty) {
      yield currentLocation;
    }

    if (!isPickup) {
      final pickupText = _pickupController.text.trim();
      if (pickupText.isNotEmpty) {
        yield pickupText;
      }
      return;
    }

    if (_dropoffPoint != null) {
      final dropoffText = _dropoffController.text.trim();
      if (dropoffText.isNotEmpty) {
        yield dropoffText;
      }
    }
  }

  List<GeocodeSuggestion> _rankAddressSuggestions({
    required String query,
    required List<GeocodeSuggestion> suggestions,
    required bool isPickup,
  }) {
    if (suggestions.isEmpty) {
      return const [];
    }

    final normalizedQuery = _normalizeAddressText(query);
    final queryTokens = _extractMeaningfulAddressTokens([query]);
    final addressNumberTokens = _extractAddressNumberTokens(query);
    final localityTokens = _extractMeaningfulAddressTokens(
      _searchContextTexts(isPickup: isPickup),
    );
    final biasPoint = _resolveSearchBiasPoint(isPickup: isPickup);

    final ranked = suggestions.map((suggestion) {
      final normalizedDisplay = _normalizeAddressText(suggestion.displayName);
      final queryTokenMatches =
          _countTokenMatches(normalizedDisplay, queryTokens);
        final addressNumberMatches =
          _countExactTokenMatches(normalizedDisplay, addressNumberTokens);
      final localityTokenMatches =
          _countTokenMatches(normalizedDisplay, localityTokens);
      final distanceKm = biasPoint == null
          ? double.infinity
          : _distanceKm(biasPoint, LatLng(suggestion.lat, suggestion.lng));

      var score = 0.0;
      if (normalizedDisplay == normalizedQuery) {
        score += 220;
      } else if (
          normalizedQuery.isNotEmpty && normalizedDisplay.startsWith(normalizedQuery)) {
        score += 140;
      } else if (
          normalizedQuery.isNotEmpty && normalizedDisplay.contains(normalizedQuery)) {
        score += 90;
      }

      score += queryTokenMatches * 18;
      score += addressNumberMatches * 115;
      score += localityTokenMatches * 26;

      if (addressNumberTokens.isNotEmpty && addressNumberMatches == 0) {
        score -= 85;
      }

      if (distanceKm.isFinite) {
        score += _distancePriorityScore(distanceKm);
      }

      return _RankedSuggestion(
        suggestion: suggestion,
        score: score,
        distanceKm: distanceKm,
        queryTokenMatches: queryTokenMatches,
        localityTokenMatches: localityTokenMatches,
        addressNumberMatches: addressNumberMatches,
      );
    }).toList(growable: false);

    ranked.sort((left, right) {
      final byScore = right.score.compareTo(left.score);
      if (byScore != 0) {
        return byScore;
      }

      final byAddressNumber =
          right.addressNumberMatches.compareTo(left.addressNumberMatches);
      if (byAddressNumber != 0) {
        return byAddressNumber;
      }

      final byLocality =
          right.localityTokenMatches.compareTo(left.localityTokenMatches);
      if (byLocality != 0) {
        return byLocality;
      }

      final byQuery =
          right.queryTokenMatches.compareTo(left.queryTokenMatches);
      if (byQuery != 0) {
        return byQuery;
      }

      return left.distanceKm.compareTo(right.distanceKm);
    });

    final deduped = <GeocodeSuggestion>[];
    final seenKeys = <String>{};
    for (final item in ranked) {
      final key =
          '${_normalizeAddressText(item.suggestion.displayName)}|${item.suggestion.lat.toStringAsFixed(4)}|${item.suggestion.lng.toStringAsFixed(4)}';
      if (seenKeys.add(key)) {
        deduped.add(item.suggestion);
      }
    }

    return deduped.take(8).toList(growable: false);
  }

  Set<String> _extractMeaningfulAddressTokens(Iterable<String?> values) {
    final tokens = <String>{};

    for (final value in values) {
      final normalized = _normalizeAddressText(value ?? '');
      if (normalized.isEmpty) {
        continue;
      }

      for (final token in normalized.split(' ')) {
        if (token.length < 3 ||
            _addressSearchStopWords.contains(token) ||
            double.tryParse(token) != null) {
          continue;
        }
        tokens.add(token);
      }
    }

    return tokens;
  }

  Set<String> _extractAddressNumberTokens(String value) {
    final normalized = _normalizeAddressText(value);
    if (normalized.isEmpty) {
      return const <String>{};
    }

    return normalized
        .split(' ')
        .where((token) => RegExp(r'^\d+[a-z]?$').hasMatch(token))
        .toSet();
  }

  int _countTokenMatches(String text, Set<String> tokens) {
    if (text.isEmpty || tokens.isEmpty) {
      return 0;
    }

    var matches = 0;
    for (final token in tokens) {
      if (text.contains(token)) {
        matches += 1;
      }
    }
    return matches;
  }

  int _countExactTokenMatches(String text, Set<String> tokens) {
    if (text.isEmpty || tokens.isEmpty) {
      return 0;
    }

    final textTokens = _normalizeAddressText(text).split(' ').toSet();
    var matches = 0;
    for (final token in tokens) {
      if (textTokens.contains(token)) {
        matches += 1;
      }
    }
    return matches;
  }

  ({String? label, Color? color}) _buildNumberMatchHint({
    required String query,
    required GeocodeSuggestion suggestion,
  }) {
    final addressNumberTokens = _extractAddressNumberTokens(query);
    if (addressNumberTokens.isEmpty) {
      return (label: null, color: null);
    }

    final normalizedDisplay = _normalizeAddressText(suggestion.displayName);
    final matchedAddressNumbers =
        _countExactTokenMatches(normalizedDisplay, addressNumberTokens);

    if (matchedAddressNumbers == addressNumberTokens.length) {
      return (
        label: 'Numero exterior confirmado',
        color: Colors.green.shade700,
      );
    }

    if (matchedAddressNumbers > 0) {
      return (
        label: 'Numero exterior parcial (verifica en mapa)',
        color: Colors.orange.shade800,
      );
    }

    return (
      label: 'Numero exterior no confirmado',
      color: Colors.orange.shade800,
    );
  }

  double _distancePriorityScore(double distanceKm) {
    if (distanceKm <= 1) {
      return 120;
    }
    if (distanceKm <= 3) {
      return 90;
    }
    if (distanceKm <= 8) {
      return 72;
    }
    if (distanceKm <= 20) {
      return 50;
    }
    if (distanceKm <= 40) {
      return 28;
    }
    if (distanceKm <= 80) {
      return 12;
    }

    return -math.min(35.0, (distanceKm - 80) / 8);
  }

  String? _buildSuggestionSubtitle(
    GeocodeSuggestion suggestion, {
    required bool isPickup,
  }) {
    final secondaryText = suggestion.secondaryText?.trim();
    if (secondaryText != null && secondaryText.isNotEmpty) {
      return secondaryText;
    }

    if (!suggestion.hasCoordinates) {
      return null;
    }

    final biasPoint = _resolveSearchBiasPoint(isPickup: isPickup);
    if (biasPoint == null) {
      return '${suggestion.lat.toStringAsFixed(5)}, ${suggestion.lng.toStringAsFixed(5)}';
    }

    final distanceKm =
        _distanceKm(biasPoint, LatLng(suggestion.lat, suggestion.lng));
    final referenceLabel = _suggestionReferenceLabel(isPickup: isPickup);
    if (distanceKm < 1) {
      return 'A ${(distanceKm * 1000).round()} m $referenceLabel';
    }

    final value = distanceKm < 10
        ? distanceKm.toStringAsFixed(1)
        : distanceKm.toStringAsFixed(0);
    return 'A $value km $referenceLabel';
  }

  String _suggestionReferenceLabel({required bool isPickup}) {
    if (!isPickup && _pickupPoint != null) {
      return 'de tu origen actual';
    }
    if (_currentDevicePoint != null) {
      return 'de tu ubicacion actual';
    }
    if (isPickup && _dropoffPoint != null) {
      return 'de tu destino actual';
    }
    return 'de tu referencia actual';
  }

  Future<GeocodeSuggestion?> _pickSuggestionForTypedQuery({
    required bool isPickup,
    required String query,
    required List<GeocodeSuggestion> options,
  }) async {
    final hasBias = _resolveSearchBiasPoint(isPickup: isPickup) != null;

    return showModalBottomSheet<GeocodeSuggestion>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isPickup
                      ? 'Elige el origen correcto'
                      : 'Elige el destino correcto',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Busqueda: "$query"',
                  style:
                      const TextStyle(color: Color(0xFF475569), fontSize: 12),
                ),
                if (hasBias) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Se priorizan coincidencias cercanas a ${_suggestionReferenceLabel(isPickup: isPickup)}.',
                    style: const TextStyle(
                      color: Color(0xFF1D4ED8),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                ...options.map((item) {
                  final subtitle =
                      _buildSuggestionSubtitle(item, isPickup: isPickup);
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: Icon(
                      isPickup ? Icons.my_location : Icons.location_on_outlined,
                    ),
                    title: Text(
                      item.primaryText ?? item.displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: subtitle == null ? null : Text(subtitle),
                    onTap: () => Navigator.of(context).pop(item),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  bool _isFavoriteAddress(GeocodeSuggestion value) {
    return _favoriteAddresses
        .any((item) => item.displayName == value.displayName);
  }

  Future<void> _rememberRecentAddress(GeocodeSuggestion value) async {
    final deduped = [
      value,
      ..._recentAddresses
          .where((item) => item.displayName != value.displayName),
    ].take(12).toList();

    setState(() {
      _recentAddresses = deduped;
    });

    await _addressStore.saveRecent(deduped);
  }

  Future<void> _toggleFavoriteAddress(GeocodeSuggestion value) async {
    final exists = _isFavoriteAddress(value);
    final updated = exists
        ? _favoriteAddresses
            .where((item) => item.displayName != value.displayName)
            .toList()
        : [value, ..._favoriteAddresses].take(20).toList();

    setState(() {
      _favoriteAddresses = updated;
      _locationStatus = exists
          ? 'Direccion eliminada de favoritos.'
          : 'Direccion agregada a favoritos.';
    });

    await _addressStore.saveFavorites(updated);
  }

  Future<void> _removeFavoriteAddress(GeocodeSuggestion value) async {
    final updated = _favoriteAddresses
        .where((item) => item.displayName != value.displayName)
        .toList();

    setState(() {
      _favoriteAddresses = updated;
      _locationStatus = 'Favorito eliminado.';
    });

    await _addressStore.saveFavorites(updated);
  }

  Future<void> _applySuggestion(GeocodeSuggestion selected,
      {required bool isPickup, String? typedQuery}) async {
    final resolved = selected.isGooglePrediction && !selected.hasCoordinates
        ? await _apiClient.resolveAddressSuggestion(selected)
        : selected;

    if (!mounted || resolved == null || !resolved.hasCoordinates) {
      if (mounted) {
        setState(() {
          _setAddressValidationFeedbackValues(
            isPickup: isPickup,
            message:
                'No se pudo confirmar esa direccion. Prueba otra sugerencia.',
            confirmed: false,
          );
        });
      }
      return;
    }

    final point = LatLng(resolved.lat, resolved.lng);
    final capturedQuery = typedQuery?.trim();
    final normalizedResolved = _normalizeAddressText(resolved.displayName);
    final queryTokens = capturedQuery == null || capturedQuery.isEmpty
      ? const <String>{}
      : _extractMeaningfulAddressTokens([capturedQuery]);
    final addressNumberTokens = capturedQuery == null || capturedQuery.isEmpty
      ? const <String>{}
      : _extractAddressNumberTokens(capturedQuery);
    final matchedQueryTokens =
      _countTokenMatches(normalizedResolved, queryTokens);
    final matchedAddressNumbers =
      _countExactTokenMatches(normalizedResolved, addressNumberTokens);
    final addressNumberConfirmed = addressNumberTokens.isNotEmpty &&
        matchedAddressNumbers == addressNumberTokens.length;
    final approximate = capturedQuery != null &&
      capturedQuery.isNotEmpty &&
      ((queryTokens.isNotEmpty && matchedQueryTokens < queryTokens.length) ||
        (addressNumberTokens.isNotEmpty &&
          matchedAddressNumbers < addressNumberTokens.length));
    final displayText = capturedQuery != null && capturedQuery.isNotEmpty
      ? capturedQuery
      : resolved.displayName;
    final storedSuggestion = GeocodeSuggestion(
      displayName: displayText,
      lat: resolved.lat,
      lng: resolved.lng,
      placeId: resolved.placeId,
      primaryText: resolved.primaryText,
      secondaryText: resolved.secondaryText,
      provider: resolved.provider,
    );

    setState(() {
      if (isPickup) {
        _pickupPoint = point;
      _lastPickupResolvedQuery = displayText;
        _lastPickupDisambiguationQuery = null;
      _pickupController.text = displayText;
        _controller.setPickupPoint(point.latitude, point.longitude);
        _clearAutocompleteSuggestionsValues(isPickup: true);
      _locationStatus = approximate
        ? 'Origen aproximado confirmado. Ajusta el pin en mapa si hace falta.'
        : (addressNumberConfirmed
            ? 'Origen confirmado con numero exterior.'
            : 'Origen confirmado con sugerencia de direccion.');
      } else {
        _dropoffPoint = point;
      _lastDropoffResolvedQuery = displayText;
        _lastDropoffDisambiguationQuery = null;
      _dropoffController.text = displayText;
        _controller.setDropoffPoint(point.latitude, point.longitude);
        _clearAutocompleteSuggestionsValues(isPickup: false);
      _locationStatus = approximate
        ? 'Destino aproximado confirmado. Ajusta el pin en mapa si hace falta.'
        : (addressNumberConfirmed
            ? 'Destino confirmado con numero exterior.'
            : 'Destino confirmado con sugerencia de direccion.');
      }
      _setAddressValidationFeedbackValues(
        isPickup: isPickup,
      message: approximate
        ? (isPickup
          ? 'Origen aproximado confirmado. Conservamos tu captura y puedes ajustar el pin en mapa.'
          : 'Destino aproximado confirmado. Conservamos tu captura y puedes ajustar el pin en mapa.')
        : (addressNumberConfirmed
            ? (isPickup
                ? 'Origen confirmado con numero exterior.'
                : 'Destino confirmado con numero exterior.')
            : (isPickup ? 'Origen confirmado.' : 'Destino confirmado.')),
        confirmed: true,
      approximate: approximate,
      );
    });

    if (mounted) {
      FocusScope.of(context).unfocus();
    }

    _moveMapWhenReady(point, 14);
    _syncDistanceFromMap();
    await _rememberRecentAddress(storedSuggestion);
    await _saveLastAddress(storedSuggestion, isPickup: isPickup);
  }

  Future<void> _pickFromSaved(
      {required bool favorites, required bool isPickup}) async {
    final source = favorites ? _favoriteAddresses : _recentAddresses;
    if (source.isEmpty) {
      setState(() {
        _locationStatus = favorites
            ? 'No hay direcciones favoritas guardadas.'
            : 'No hay direcciones recientes guardadas.';
      });
      return;
    }

    final selected = await showModalBottomSheet<GeocodeSuggestion>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView.separated(
            itemCount: source.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final item = source[index];
              return ListTile(
                leading: Icon(isPickup ? Icons.location_on : Icons.flag),
                title: Text(
                  item.displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                    '${item.lat.toStringAsFixed(5)}, ${item.lng.toStringAsFixed(5)}'),
                onTap: () => Navigator.of(context).pop(item),
              );
            },
          ),
        );
      },
    );

    if (selected == null) {
      return;
    }

    await _applySuggestion(selected, isPickup: isPickup);
  }

  String _compactAddress(String value, {int maxLength = 34}) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= maxLength) {
      return normalized;
    }

    return '${normalized.substring(0, maxLength - 1).trimRight()}…';
  }

  Widget _buildSavedAddressChips({required bool isPickup}) {
    final recents = _recentAddresses.take(4).toList();
    final favorites = _favoriteAddresses.take(4).toList();

    if (recents.isEmpty && favorites.isEmpty) {
      return const SizedBox.shrink();
    }

    final label = isPickup ? 'Origen' : 'Destino';

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (favorites.isNotEmpty) ...[
            const Text('Favoritos',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: favorites.map((item) {
                return InputChip(
                  avatar: const Icon(Icons.star, size: 16),
                  label: Text(
                    _compactAddress(item.displayName, maxLength: 28),
                    style: const TextStyle(fontSize: 12),
                  ),
                  labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onPressed: () => _applySuggestion(item, isPickup: isPickup),
                  onDeleted: () => _removeFavoriteAddress(item),
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
          ],
          if (recents.isNotEmpty) ...[
            Text('Recientes $label',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: recents.map((item) {
                return ActionChip(
                  avatar: const Icon(Icons.history, size: 16),
                  label: Text(
                    _compactAddress(item.displayName, maxLength: 28),
                    style: const TextStyle(fontSize: 12),
                  ),
                  labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onPressed: () => _applySuggestion(item, isPickup: isPickup),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  String _formatCoordsLabel(String label, LatLng point) {
    return '$label: ${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}';
  }

  double _distanceKm(LatLng a, LatLng b) {
    const earthRadiusKm = 6371.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180.0;
    final dLon = (b.longitude - a.longitude) * math.pi / 180.0;
    final lat1 = a.latitude * math.pi / 180.0;
    final lat2 = b.latitude * math.pi / 180.0;

    final x = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(x), math.sqrt(1 - x));
    return earthRadiusKm * c;
  }

  void _syncDistanceFromMap() {
    if (_pickupPoint == null || _dropoffPoint == null) {
      setState(() {
        _etaMinutes = null;
        _routeDistanceKm = null;
        _routeStatus = null;
        _routePoints = const [];
      });
      _distanceController.text = '';
      _controller.distanceText.value = '';
      return;
    }

    final pickup = _pickupPoint!;
    final dropoff = _dropoffPoint!;
    final straightDistance = _distanceKm(pickup, dropoff);
    final etaMinutes = math.max(1, (straightDistance / 35 * 60).round());
    final distanceValue = straightDistance.toStringAsFixed(1);

    setState(() {
      _routeDistanceKm = straightDistance;
      _etaMinutes = etaMinutes;
      _routeLoading = false;
      _routePoints = [pickup, dropoff];
      _routeStatus = _googleRoutesApiKey.isNotEmpty
          ? 'Estimacion preliminar. Recalcula tarifa para confirmar ruta real.'
          : 'Estimacion preliminar sin Routes API activa.';
    });

    _distanceController.text = distanceValue;
    _controller.distanceText.value = distanceValue;
  }

  Future<bool> _refreshRouteData({
    required bool useRoutesApi,
    bool quoteAfterUpdate = false,
  }) async {
    if (_pickupPoint == null || _dropoffPoint == null) {
      return false;
    }

    final pickup = _pickupPoint!;
    final dropoff = _dropoffPoint!;

    if (mounted) {
      setState(() {
        _routeLoading = true;
        _routeStatus = null;
      });
    }

    try {
      _RouteSnapshot? route;
      var routeProvider = 'osrm';

      if (useRoutesApi && _googleRoutesApiKey.isNotEmpty) {
        final googleRoute = await _fetchGoogleRoute(pickup, dropoff);
        if (googleRoute != null) {
          route = googleRoute;
          routeProvider = 'google_routes';
        }
      }

      if (route == null && _mapboxAccessToken.isNotEmpty) {
        route = await _fetchMapboxTrafficRoute(pickup, dropoff);
        if (route != null) {
          routeProvider = 'mapbox';
        }
      }

      if (route == null) {
        route = await _fetchOsrmRoute(pickup, dropoff);
        routeProvider = 'osrm';
      }

      if (route == null) {
        throw Exception('Ruta vial no disponible');
      }

      if (!mounted) {
        return false;
      }

      setState(() {
        _routeLoading = false;
        _routeDistanceKm = route!.distanceKm;
        _etaMinutes = route.etaMinutes;
        _routePoints = route.points;
        _routeStatus = routeProvider == 'google_routes'
            ? 'Ruta confirmada con Google Routes para tarifa y viaje.'
            : (route.hasLiveTraffic
                ? 'ETA calculado con trafico en vivo.'
                : 'ETA estimado por ruta vial con ajuste horario (sin proveedor de trafico en vivo).');
      });

      final distanceValue = route.distanceKm.toStringAsFixed(1);
      _distanceController.text = distanceValue;
      _controller.distanceText.value = distanceValue;
      if (quoteAfterUpdate) {
        await _controller.quote();
      }
      return true;
    } catch (_) {
      if (!mounted) {
        return false;
      }

      setState(() {
        _routeLoading = false;
        _routeStatus =
            'No se pudo calcular ruta vial confiable. Verifica origen/destino o intenta de nuevo.';
        _routeDistanceKm = null;
        _etaMinutes = null;
        _routePoints = const [];
      });
      _distanceController.text = '';
      _controller.distanceText.value = '';
      return false;
    }
  }

  Future<_RouteSnapshot?> _fetchGoogleRoute(
    LatLng pickup,
    LatLng dropoff,
  ) async {
    try {
      final route = await _googleRoutesClient.getRoute(pickup, dropoff);
      if (route == null) {
        return null;
      }

      return _RouteSnapshot(
        points: route.points,
        distanceKm: route.distanceMeters / 1000,
        etaMinutes: math.max(1, (route.durationSeconds / 60).round()),
        hasLiveTraffic: true,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _recalculateFareWithConfirmedRoute() async {
    final refreshed = await _refreshRouteData(
      useRoutesApi: true,
      quoteAfterUpdate: true,
    );
    if (!refreshed) {
      setState(() {
        _locationStatus =
            'No se pudo confirmar la ruta para tarifa. Revisa origen y destino.';
      });
    }
  }

  Future<void> _requestRideWithConfirmedRoute() async {
    if (_rideRequestType == 'scheduled' && _scheduledAt == null) {
      setState(() {
        _locationStatus = 'Para programar, elige dia y hora del viaje.';
      });
      return;
    }
    if (_rideRequestType != 'scheduled' && _scheduledAt != null) {
      setState(() {
        _scheduledAt = null;
      });
    }

    final refreshed = await _refreshRouteData(
      useRoutesApi: true,
      quoteAfterUpdate: true,
    );
    if (!refreshed) {
      setState(() {
        _locationStatus =
            'No se pudo confirmar ruta para solicitar. Intenta nuevamente.';
      });
      return;
    }

    await _controller.createRide(
      scheduledAt: _rideRequestType == 'scheduled' ? _scheduledAt : null,
      requestType: _rideRequestType,
      notifyWhatsApp: _notifyOfflineByWhatsApp,
      notifySms: _notifyOfflineBySms,
    );
  }

  Future<_RouteSnapshot?> _fetchMapboxTrafficRoute(
    LatLng pickup,
    LatLng dropoff,
  ) async {
    try {
      final coordinates =
          '${pickup.longitude},${pickup.latitude};${dropoff.longitude},${dropoff.latitude}';
      final uri = Uri.https(
        'api.mapbox.com',
        '/directions/v5/mapbox/driving-traffic/$coordinates',
        {
          'alternatives': 'false',
          'geometries': 'geojson',
          'overview': 'full',
          'steps': 'false',
          'language': 'es',
          'access_token': _mapboxAccessToken,
        },
      );

      final response = await http.get(uri);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      final data = jsonDecode(response.body);
      if (data is! Map) {
        return null;
      }

      final routes = data['routes'];
      if (routes is! List || routes.isEmpty) {
        return null;
      }

      final route = routes.first;
      if (route is! Map) {
        return null;
      }

      final durationSeconds = (route['duration'] as num?)?.toDouble();
      final distanceMeters = (route['distance'] as num?)?.toDouble();
      final geometry = route['geometry'];
      final coordinatesRaw =
          geometry is Map ? geometry['coordinates'] as List? : null;
      final points = _parseGeoJsonCoordinates(coordinatesRaw);

      if (durationSeconds == null ||
          distanceMeters == null ||
          points.length < 2) {
        return null;
      }

      return _RouteSnapshot(
        points: points,
        distanceKm: distanceMeters / 1000,
        etaMinutes: math.max(1, (durationSeconds / 60).round()),
        hasLiveTraffic: true,
      );
    } catch (_) {
      return null;
    }
  }

  Future<_RouteSnapshot?> _fetchOsrmRoute(
    LatLng pickup,
    LatLng dropoff,
  ) async {
    try {
      final uri = Uri.https(
        'router.project-osrm.org',
        '/route/v1/driving/${pickup.longitude},${pickup.latitude};${dropoff.longitude},${dropoff.latitude}',
        {
          'overview': 'full',
          'geometries': 'geojson',
          'steps': 'false',
          'alternatives': 'false',
        },
      );

      final response = await http.get(uri);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      final data = jsonDecode(response.body);
      if (data is! Map) {
        return null;
      }

      final routes = data['routes'];
      if (routes is! List || routes.isEmpty) {
        return null;
      }

      final route = routes.first;
      if (route is! Map) {
        return null;
      }

      final durationSeconds = (route['duration'] as num?)?.toDouble();
      final distanceMeters = (route['distance'] as num?)?.toDouble();
      final geometry = route['geometry'];
      final coordinatesRaw =
          geometry is Map ? geometry['coordinates'] as List? : null;
      final points = _parseGeoJsonCoordinates(coordinatesRaw);

      if (durationSeconds == null ||
          distanceMeters == null ||
          points.length < 2) {
        return null;
      }

      final baseMinutes = durationSeconds / 60;
      final etaWithTrafficModel = math.max(
          1, (baseMinutes * _trafficMultiplier(DateTime.now())).round());

      return _RouteSnapshot(
        points: points,
        distanceKm: distanceMeters / 1000,
        etaMinutes: etaWithTrafficModel,
        hasLiveTraffic: false,
      );
    } catch (_) {
      return null;
    }
  }

  List<LatLng> _parseGeoJsonCoordinates(List<dynamic>? coordinates) {
    if (coordinates == null) {
      return const [];
    }
    final points = <LatLng>[];
    for (final item in coordinates) {
      if (item is List && item.length >= 2) {
        final lon = (item[0] as num?)?.toDouble();
        final lat = (item[1] as num?)?.toDouble();
        if (lat != null && lon != null) {
          points.add(LatLng(lat, lon));
        }
      }
    }
    return points;
  }

  double _trafficMultiplier(DateTime now) {
    final isWeekday =
        now.weekday >= DateTime.monday && now.weekday <= DateTime.friday;
    final hour = now.hour;

    if (isWeekday && ((hour >= 7 && hour < 10) || (hour >= 17 && hour < 21))) {
      return 1.45;
    }
    if ((hour >= 12 && hour < 15) || (hour >= 21 && hour < 23)) {
      return 1.2;
    }
    return 1.0;
  }

  void _onMapTap(TapPosition _, LatLng point) {
    final isPickup = _mapPickMode == MapPickMode.pickup;
    setState(() {
      if (isPickup) {
        _pickupPoint = point;
        _pickupController.text = _formatCoordsLabel('Ubicacion', point);
        _controller.setPickupPoint(point.latitude, point.longitude);
      } else {
        _dropoffPoint = point;
        _dropoffController.text = _formatCoordsLabel('Destino', point);
        _controller.setDropoffPoint(point.latitude, point.longitude);
      }
    });

    _syncDistanceFromMap();
    _resolveAddress(point: point, isPickup: isPickup);
  }

  Future<void> _resolveAddress(
      {required LatLng point, required bool isPickup}) async {
    if (_resolvingAddress) {
      return;
    }

    setState(() {
      _resolvingAddress = true;
    });

    try {
      final address = await _apiClient.reverseGeocode(
        point.latitude,
        point.longitude,
      );

      if (!mounted || address == null || address.isEmpty) {
        return;
      }

      setState(() {
        if (isPickup) {
          _lastPickupResolvedQuery = address;
          _lastPickupDisambiguationQuery = null;
          _pickupController.text = address;
          _locationStatus = 'Origen actualizado con direccion real.';
        } else {
          _lastDropoffResolvedQuery = address;
          _lastDropoffDisambiguationQuery = null;
          _dropoffController.text = address;
          _locationStatus = 'Destino actualizado con direccion real.';
        }
        _setAddressValidationFeedbackValues(
          isPickup: isPickup,
          message: isPickup ? 'Origen confirmado.' : 'Destino confirmado.',
          confirmed: true,
        );
      });

      await _rememberRecentAddress(
        GeocodeSuggestion(
            displayName: address, lat: point.latitude, lng: point.longitude),
      );
      await _saveLastAddress(
        GeocodeSuggestion(
            displayName: address, lat: point.latitude, lng: point.longitude),
        isPickup: isPickup,
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _locationStatus =
            'No se pudo resolver direccion, se mantienen coordenadas.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _resolvingAddress = false;
        });
      }
    }
  }

  Future<void> _searchAddress({required bool isPickup}) async {
    final query = isPickup
        ? _pickupController.text.trim()
        : _dropoffController.text.trim();
    if (query.length < 3) {
      setState(() {
        _locationStatus =
            'Escribe al menos 3 caracteres para buscar direcciones.';
      });
      return;
    }

    setState(() {
      if (isPickup) {
        _searchingPickup = true;
      } else {
        _searchingDropoff = true;
      }
      _locationStatus = null;
    });

    try {
      await _resolveTypedAddressToPoint(
        isPickup: isPickup,
        query: query,
        allowDisambiguationPrompt: true,
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _locationStatus = 'No se pudo buscar direcciones en este momento.';
        _setAddressValidationFeedbackValues(
          isPickup: isPickup,
          message: 'No se pudo validar la direccion en este momento.',
          confirmed: false,
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          if (isPickup) {
            _searchingPickup = false;
          } else {
            _searchingDropoff = false;
          }
        });
      }
    }
  }

  Future<void> _useDeviceLocation() async {
    setState(() {
      _locating = true;
      _locationStatus = null;
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          _locationStatus =
              'Activa el GPS del dispositivo para usar tu ubicacion.';
        });
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        setState(() {
          _locationStatus = 'Permiso de ubicacion denegado.';
        });
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      final point = LatLng(position.latitude, position.longitude);

      if (!mounted) {
        return;
      }

      setState(() {
        _pickupPoint = point;
        _currentDevicePoint = point;
        _pickupController.text = _formatCoordsLabel('Mi ubicacion', point);
        _controller.setPickupPoint(point.latitude, point.longitude);
        _locationStatus = 'Ubicacion detectada correctamente.';
      });

      _moveMapWhenReady(point, 14);
      _syncDistanceFromMap();
      await _resolveAddress(point: point, isPickup: true);
      final resolvedAddress = _pickupController.text.trim();
      if (mounted &&
          resolvedAddress.isNotEmpty &&
          !resolvedAddress.toLowerCase().startsWith('mi ubicacion')) {
        setState(() {
          _currentLocationLabel = resolvedAddress;
        });
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _locationStatus = 'No se pudo obtener tu ubicacion en este momento.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _locating = false;
        });
      }
    }
  }

  String _formatScheduledAt(DateTime value) {
    return formatLocalDateTime(value);
  }

  Future<void> _pickScheduledAt() async {
    final now = DateTime.now();
    final initial = _scheduledAt?.isAfter(now) == true
        ? _scheduledAt!
        : now.add(const Duration(minutes: 30));
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: now,
      lastDate: now.add(const Duration(days: 30)),
    );
    if (pickedDate == null || !mounted) {
      return;
    }

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (pickedTime == null || !mounted) {
      return;
    }

    final scheduled = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );

    if (scheduled.isBefore(now)) {
      setState(() {
        _locationStatus = 'Selecciona una hora futura para programar el viaje.';
      });
      return;
    }

    setState(() {
      _scheduledAt = scheduled;
      _locationStatus =
          'Viaje programado para ${_formatScheduledAt(scheduled)}.';
    });
  }

  Future<void> _setScheduledTimeManually() async {
    final now = DateTime.now();
    final base = _scheduledAt ?? now.add(const Duration(minutes: 30));
    final controller = TextEditingController(
      text:
          '${base.hour.toString().padLeft(2, '0')}:${base.minute.toString().padLeft(2, '0')}',
    );
    String? errorText;

    final result = await showDialog<DateTime>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              title: const Text('Asignar hora manual'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                      'Formato HH:mm. Se conserva la fecha elegida o la de hoy.'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    keyboardType: TextInputType.datetime,
                    decoration: InputDecoration(
                      labelText: 'Hora',
                      hintText: '18:30',
                      errorText: errorText,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () {
                    final match = RegExp(r'^(\d{1,2}):(\d{2})$')
                        .firstMatch(controller.text.trim());
                    if (match == null) {
                      setModalState(() {
                        errorText = 'Usa el formato HH:mm';
                      });
                      return;
                    }

                    final hour = int.parse(match.group(1)!);
                    final minute = int.parse(match.group(2)!);
                    if (hour > 23 || minute > 59) {
                      setModalState(() {
                        errorText = 'Ingresa una hora valida';
                      });
                      return;
                    }

                    final selected =
                        DateTime(base.year, base.month, base.day, hour, minute);
                    if (selected.isBefore(now)) {
                      setModalState(() {
                        errorText = 'La hora debe ser futura';
                      });
                      return;
                    }

                    Navigator.of(context).pop(selected);
                  },
                  child: const Text('Aplicar'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null || !mounted) {
      return;
    }

    setState(() {
      _scheduledAt = result;
      _locationStatus = 'Viaje programado para ${_formatScheduledAt(result)}.';
    });
  }

  Future<void> _showRideCommandMenu() async {
    if (!mounted) {
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Recalcular tarifa (Ctrl+R)'),
                onTap: () {
                  Navigator.of(context).pop();
                  _recalculateFareWithConfirmedRoute();
                },
              ),
              ListTile(
                leading: const Icon(Icons.my_location),
                title: const Text('Usar mi ubicacion (Ctrl+L)'),
                onTap: () {
                  Navigator.of(context).pop();
                  _useDeviceLocation();
                },
              ),
              ListTile(
                leading: const Icon(Icons.schedule),
                title: const Text('Programar viaje (Ctrl+Shift+S)'),
                onTap: () {
                  Navigator.of(context).pop();
                  _pickScheduledAt();
                },
              ),
              ListTile(
                leading: const Icon(Icons.send),
                title: const Text('Solicitar viaje (Ctrl+Enter)'),
                onTap: () {
                  Navigator.of(context).pop();
                  _requestRideWithConfirmedRoute();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _pickupGeocodeDebounce?.cancel();
    _dropoffGeocodeDebounce?.cancel();
    _pickupFocusNode.dispose();
    _dropoffFocusNode.dispose();
    _pickupController.dispose();
    _dropoffController.dispose();
    _distanceController.dispose();
    _pageScrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.enter, control: true):
                _KarrytShortcutIntent('requestRide'),
            SingleActivator(LogicalKeyboardKey.keyR, control: true):
                _KarrytShortcutIntent('recalculateFare'),
            SingleActivator(LogicalKeyboardKey.keyL, control: true):
                _KarrytShortcutIntent('useLocation'),
            SingleActivator(LogicalKeyboardKey.keyS,
                control: true, shift: true): _KarrytShortcutIntent('scheduleRide'),
            SingleActivator(LogicalKeyboardKey.slash, shift: true):
                _KarrytShortcutIntent('openCommands'),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              _KarrytShortcutIntent: CallbackAction<_KarrytShortcutIntent>(
                onInvoke: (intent) {
                  switch (intent.command) {
                    case 'requestRide':
                      _requestRideWithConfirmedRoute();
                      break;
                    case 'recalculateFare':
                      _recalculateFareWithConfirmedRoute();
                      break;
                    case 'useLocation':
                      _useDeviceLocation();
                      break;
                    case 'scheduleRide':
                      _pickScheduledAt();
                      break;
                    case 'openCommands':
                      _showRideCommandMenu();
                      break;
                  }
                  return null;
                },
              ),
            },
            child: Focus(
              autofocus: true,
              child: Scaffold(
          appBar: AppBar(
            elevation: 4,
            shadowColor: Colors.black.withValues(alpha: 0.2),
            toolbarHeight: 74,
            flexibleSpace: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xFF0F4CFF),
                    const Color(0xFF0F4CFF).withValues(alpha: 0.85),
                  ],
                ),
              ),
            ),
            titleSpacing: 12,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'Karryt',
                  style: TextStyle(
                    fontSize: 38,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 18),
                  child: Transform.translate(
                    offset: const Offset(0, -8),
                    child: const Text(
                      'Mueve',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        height: 0.95,
                        color: Colors.white70,
                      ),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Comandos y atajos',
                onPressed: _showRideCommandMenu,
                icon: const Icon(Icons.keyboard_command_key),
              ),
            ],
          ),
          body: _controller.loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _controller.init,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification.metrics.axis == Axis.vertical &&
                          notification.depth == 0) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) {
                            _syncNavIndexFromScroll();
                          }
                        });
                      }
                      return false;
                    },
                    child: ListView(
                      controller: _pageScrollController,
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (_controller.error != null) ...[
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.red.shade50,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.red.shade200),
                            ),
                            child: Text(_controller.error!,
                                style: TextStyle(color: Colors.red.shade700)),
                          ),
                          const SizedBox(height: 12),
                        ],
                        KeyedSubtree(
                            key: _requestSectionKey,
                            child: _buildRequestCard()),
                        const SizedBox(height: 16),
                        _buildRideCard(),
                        const SizedBox(height: 16),
                        KeyedSubtree(
                            key: _pricingSectionKey,
                            child: _buildPricingCard()),
                        const SizedBox(height: 96),
                      ],
                    ),
                  ),
                ),
          bottomNavigationBar: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.22)),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withValues(alpha: 0.88),
                        const Color(0xFFF4F8FF).withValues(alpha: 0.84),
                      ],
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x220F1A2E),
                        blurRadius: 24,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  child: NavigationBarTheme(
                    data: NavigationBarThemeData(
                      backgroundColor: Colors.transparent,
                      indicatorColor:
                          const Color(0xFF0F4CFF).withValues(alpha: 0.16),
                      labelTextStyle: WidgetStateProperty.resolveWith((states) {
                        final selected = states.contains(WidgetState.selected);
                        return TextStyle(
                          fontSize: 12,
                          fontWeight:
                              selected ? FontWeight.w800 : FontWeight.w700,
                          color: selected
                              ? const Color(0xFF0F4CFF)
                              : const Color(0xFF5F6C80),
                        );
                      }),
                      iconTheme: WidgetStateProperty.resolveWith((states) {
                        final selected = states.contains(WidgetState.selected);
                        return IconThemeData(
                          color: selected
                              ? const Color(0xFF0F4CFF)
                              : const Color(0xFF5F6C80),
                          size: selected ? 26 : 24,
                        );
                      }),
                    ),
                    child: NavigationBar(
                      selectedIndex: _currentNavIndex,
                      elevation: 0,
                      height: 72,
                      labelBehavior:
                          NavigationDestinationLabelBehavior.alwaysShow,
                      onDestinationSelected: (index) {
                        if (index == 0) {
                          _scrollToSection(_requestSectionKey, 0);
                        } else {
                          _scrollToSection(_pricingSectionKey, 1);
                        }
                      },
                      destinations: const [
                        NavigationDestination(
                          icon: Icon(Icons.local_shipping_outlined),
                          selectedIcon: Icon(Icons.local_shipping),
                          label: 'Solicitar',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.receipt_long_outlined),
                          selectedIcon: Icon(Icons.receipt_long),
                          label: 'Tarifas',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRequestCard() {
    final availableDrivers =
        _controller.drivers.where((d) => d.available).length;

    return Card(
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.white, Colors.blue.shade50],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Solicitar viaje de carga',
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF172033)),
              ),
              const SizedBox(height: 4),
              Text(
                'Conductores disponibles ahora: $availableDrivers',
                style: TextStyle(
                    color: Colors.blueGrey.shade700,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              _buildCategorySketchSelector(),
              const SizedBox(height: 10),
              _buildServiceSelector(),
              const SizedBox(height: 10),
              _buildAddressInput(isPickup: true),
              _buildAutocompleteSuggestions(isPickup: true),
              _buildAddressValidationHint(isPickup: true),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _locating ? null : _useDeviceLocation,
                    icon: const Icon(Icons.my_location),
                    label: Text(
                      _locating ? 'Ubicando...' : 'Usar mi ubicacion',
                    ),
                  ),
                  if (_currentLocationLabel != null &&
                      _currentLocationLabel!.trim().isNotEmpty)
                    Chip(
                      avatar: const Icon(Icons.place, size: 16),
                      label: Text(
                        _compactAddress(
                          _currentLocationLabel!,
                          maxLength: 38,
                        ),
                      ),
                    ),
                ],
              ),
              if (_locationStatus != null) ...[
                const SizedBox(height: 8),
                Text(
                  _locationStatus!,
                  style: TextStyle(
                    color: (_locationStatus!.contains('correctamente') ||
                            _locationStatus!.contains('actualizado'))
                        ? Colors.green.shade700
                        : Colors.orange.shade800,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
              _buildSavedAddressChips(isPickup: true),
              const SizedBox(height: 10),
              _buildAddressInput(isPickup: false),
              _buildAutocompleteSuggestions(isPickup: false),
              _buildAddressValidationHint(isPickup: false),
              _buildSavedAddressChips(isPickup: false),
              const SizedBox(height: 10),
              KeyedSubtree(
                key: _routePreviewKey,
                child: _buildRoutePreviewCard(),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () =>
                        _pickFromSaved(favorites: false, isPickup: true),
                    icon: const Icon(Icons.history),
                    label: const Text('Reciente origen'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        _pickFromSaved(favorites: true, isPickup: true),
                    icon: const Icon(Icons.star),
                    label: const Text('Favorito origen'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        _pickFromSaved(favorites: false, isPickup: false),
                    icon: const Icon(Icons.history),
                    label: const Text('Reciente destino'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        _pickFromSaved(favorites: true, isPickup: false),
                    icon: const Icon(Icons.star),
                    label: const Text('Favorito destino'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _distanceController,
                readOnly: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Distancia por ruta vial (km)',
                  hintText: 'Se completa al trazar la ruta vial',
                  prefixIcon: Icon(Icons.straighten),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Urgente'),
                    selected: _rideRequestType == 'urgent',
                    onSelected: (_) {
                      setState(() {
                        _rideRequestType = 'urgent';
                        _scheduledAt = null;
                      });
                    },
                  ),
                  ChoiceChip(
                    label: const Text('Transcurso del dia'),
                    selected: _rideRequestType == 'same_day',
                    onSelected: (_) {
                      setState(() {
                        _rideRequestType = 'same_day';
                        _scheduledAt = null;
                      });
                    },
                  ),
                  ChoiceChip(
                    label: const Text('Programar dia y hora'),
                    selected: _rideRequestType == 'scheduled',
                    onSelected: (_) {
                      setState(() {
                        _rideRequestType = 'scheduled';
                      });
                    },
                  ),
                ],
              ),
              if (_rideRequestType == 'scheduled') ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _pickScheduledAt,
                        icon: const Icon(Icons.calendar_month),
                        label: Text(
                          _scheduledAt == null
                              ? 'Elegir fecha'
                              : '${_scheduledAt!.day.toString().padLeft(2, '0')}/${_scheduledAt!.month.toString().padLeft(2, '0')}',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _setScheduledTimeManually,
                        icon: const Icon(Icons.access_time),
                        label: Text(
                          _scheduledAt == null
                              ? 'Hora manual'
                              : '${_scheduledAt!.hour.toString().padLeft(2, '0')}:${_scheduledAt!.minute.toString().padLeft(2, '0')}',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (_scheduledAt != null && _rideRequestType == 'scheduled') ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Programado: ${_formatScheduledAt(_scheduledAt!)}',
                        style: TextStyle(
                            color: Colors.blue.shade800,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _scheduledAt = null;
                        });
                      },
                      icon: const Icon(Icons.close),
                      label: const Text('Limpiar'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 6),
              CheckboxListTile(
                value: _notifyOfflineByWhatsApp,
                onChanged: (value) {
                  setState(() {
                    _notifyOfflineByWhatsApp = value == true;
                  });
                },
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Notificar choferes fuera de linea por WhatsApp'),
              ),
              CheckboxListTile(
                value: _notifyOfflineBySms,
                onChanged: (value) {
                  setState(() {
                    _notifyOfflineBySms = value == true;
                  });
                },
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Notificar choferes fuera de linea por SMS'),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.blue.shade100),
                ),
                child: Row(
                  children: [
                    Icon(Icons.payments_outlined, color: Colors.blue.shade700),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Tarifa estimada: ${_controller.fareLabel}',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: Colors.blue.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: _controller.quoting ||
                              _routeLoading ||
                              _routeDistanceKm == null
                          ? null
                          : _recalculateFareWithConfirmedRoute,
                      child: Text(_controller.quoting
                          ? 'Calculando...'
                          : 'Recalcular tarifa'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: _controller.requestingRide ||
                              _routeLoading ||
                              _routeDistanceKm == null
                          ? null
                        : _requestRideWithConfirmedRoute,
                      child: Text(_controller.requestingRide
                          ? 'Solicitando...'
                          : _rideRequestType == 'scheduled'
                              ? 'Programar'
                              : 'Solicitar'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRoutePreviewCard() {
    final hasPoints = _pickupPoint != null || _dropoffPoint != null;
    final routeForDraw = _routePoints.length >= 2
        ? _routePoints
        : (_pickupPoint != null && _dropoffPoint != null)
            ? [_pickupPoint!, _dropoffPoint!]
            : const <LatLng>[];

    final markers = <Marker>[
      if (_pickupPoint != null)
        Marker(
          point: _pickupPoint!,
          width: 34,
          height: 34,
          child: const Icon(Icons.location_on, color: Colors.blue, size: 34),
        ),
      if (_dropoffPoint != null)
        Marker(
          point: _dropoffPoint!,
          width: 34,
          height: 34,
          child: const Icon(Icons.flag, color: Colors.red, size: 28),
        ),
    ];

    final eta = _etaMinutes;
    final etaWithLoad = eta != null ? eta + _includedLoadMinutes : null;
    final etaWithLoadAndUnload = eta != null
        ? eta + _includedLoadMinutes + _includedUnloadMinutes
        : null;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.blue.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Ruta sugerida',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 230,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: hasPoints
                  ? FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter:
                            _pickupPoint ?? _dropoffPoint ?? _defaultCenter,
                        initialZoom: 12,
                        onTap: _onMapTap,
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'Karryt.flutter',
                        ),
                        if (routeForDraw.length >= 2)
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: routeForDraw,
                                color: Colors.white,
                                strokeWidth: 7,
                              ),
                              Polyline(
                                points: routeForDraw,
                                color: const Color(0xFF0F4CFF),
                                strokeWidth: 4.2,
                              )
                            ],
                          ),
                        MarkerLayer(markers: markers),
                      ],
                    )
                  : Container(
                      color: const Color(0xFFF1F5F9),
                      alignment: Alignment.center,
                      child: const Text(
                        'Origen y destino vacios\n(Aparece al ingresar direcciones)',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Editar origen en mapa'),
                selected: _mapPickMode == MapPickMode.pickup,
                onSelected: (_) =>
                    setState(() => _mapPickMode = MapPickMode.pickup),
              ),
              ChoiceChip(
                label: const Text('Editar destino en mapa'),
                selected: _mapPickMode == MapPickMode.dropoff,
                onSelected: (_) =>
                    setState(() => _mapPickMode = MapPickMode.dropoff),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_routeLoading) const LinearProgressIndicator(minHeight: 3),
          if (_routeDistanceKm != null)
            Text(
              'Distancia por ruta: ${_routeDistanceKm!.toStringAsFixed(1)} km',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          if (eta != null)
            Text(
              'Tiempo aproximado de llegada al destino (ajustado por trafico): $eta min',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          Text(
            etaWithLoad != null
                ? 'Tiempo de carga incluido 25 min a partir de haber llegado al punto de recoleccion.\nTotal estimado tras carga: $etaWithLoad min'
                : 'Tiempo de carga incluido 25 min a partir de haber llegado al punto de recoleccion.',
            style: const TextStyle(color: Color(0xFF1E3A8A), fontSize: 12),
          ),
          Text(
            etaWithLoadAndUnload != null
                ? 'Tiempo de descarga incluido 25 min a partir de haber llegado al destino.\nTotal estimado con descarga: $etaWithLoadAndUnload min'
                : 'Tiempo de descarga incluido 25 min a partir de haber llegado al destino.',
            style: const TextStyle(color: Color(0xFF1E3A8A), fontSize: 12),
          ),
          if (_routeStatus != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _routeStatus!,
                style: TextStyle(
                  color: Colors.orange.shade800,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCategorySketchSelector() {
    final categoryEntries =
        _controller.categories.entries.toList(growable: false);
    final selectedCategoryKey = _controller.selectedCategory;
    final selectedCategory = selectedCategoryKey == null
        ? null
        : _controller.categories[selectedCategoryKey];
    if (categoryEntries.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Categorias',
          style:
              TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF1F2937)),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFD9E2F2)),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: categoryEntries.map((entry) {
                final isSelected = selectedCategoryKey == entry.key;
                final palette = _categorySketchPalette(entry.key);

                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => _controller.selectCategory(entry.key),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOut,
                        width: 128,
                        padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: isSelected ? Colors.white : Colors.transparent,
                          border: Border.all(
                            color: isSelected
                                ? palette.strokeColor
                                : Colors.transparent,
                            width: 1.6,
                          ),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.06),
                                    blurRadius: 10,
                                    offset: const Offset(0, 4),
                                  ),
                                ]
                              : const [],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 58,
                              height: 34,
                              child: CustomPaint(
                                painter: _VehicleSketchPainter(
                                  kind: palette.kind,
                                  strokeColor: palette.strokeColor,
                                  accentColor: palette.accentColor,
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              entry.value.label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: isSelected
                                    ? const Color(0xFF0F172A)
                                    : const Color(0xFF334155),
                              ),
                            ),
                            const SizedBox(height: 6),
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOut,
                              width: 36,
                              height: 3,
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? palette.strokeColor
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(growable: false),
            ),
          ),
        ),
        if (selectedCategory != null) ...[
          const SizedBox(height: 10),
          Builder(
            builder: (context) {
              final palette = _categorySketchPalette(selectedCategoryKey!);
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 64,
                    height: 40,
                    child: CustomPaint(
                      painter: _VehicleSketchPainter(
                        kind: palette.kind,
                        strokeColor: palette.strokeColor,
                        accentColor: palette.accentColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          selectedCategory.label,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          selectedCategory.capacity,
                          style: TextStyle(
                            fontSize: 12,
                            color: palette.strokeColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (selectedCategory.description.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            selectedCategory.description,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF64748B),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        _buildCategoryInformationButton(
                          category: selectedCategory,
                          palette: palette,
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ],
    );
  }

  Widget _buildCategoryInformationButton({
    required VehicleCategory category,
    required _CategorySketchPalette palette,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showCategoryInformation(category, palette),
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                palette.strokeColor,
                Color.lerp(palette.strokeColor, palette.accentColor, 0.45) ??
                    palette.strokeColor,
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: palette.strokeColor.withValues(alpha: 0.22),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.info_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Informacion',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Capacidad y caja estandar',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: Colors.white,
                  size: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showCategoryInformation(
    VehicleCategory category,
    _CategorySketchPalette palette,
  ) async {
    final boxSize = category.boxSize.trim().isEmpty
        ? 'Medida estandar por confirmar.'
        : category.boxSize;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(28),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x220F172A),
                    blurRadius: 28,
                    offset: Offset(0, 14),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: palette.strokeColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            Icons.inventory_2_rounded,
                            color: palette.strokeColor,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Informacion de la categoria',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF64748B),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                category.label,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    if (category.description.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        category.description,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF475569),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    _buildCategoryInfoMetric(
                      label: 'Capacidad de carga',
                      value: category.capacity,
                      highlight: palette.strokeColor,
                    ),
                    const SizedBox(height: 10),
                    _buildCategoryInfoMetric(
                      label: 'Caja estandar',
                      value: boxSize,
                      highlight: palette.strokeColor,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Medidas referenciales sujetas a la unidad disponible.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blueGrey.shade600,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCategoryInfoMetric({
    required String label,
    required String value,
    required Color highlight,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: highlight.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: highlight.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: highlight,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildServiceSelector() {
    final serviceEntries = _controller.services.entries.toList(growable: false);
    final selectedCategoryKey = _controller.selectedCategory;
    final selectedCategory = selectedCategoryKey == null
        ? null
        : _controller.categories[selectedCategoryKey];

    if (serviceEntries.isEmpty || selectedCategory == null) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Tipos de servicio',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: Color(0xFF1F2937),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Disponibles para ${selectedCategory.label}',
          style: const TextStyle(
            color: Color(0xFF64748B),
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: serviceEntries.map((entry) {
            final selected = _controller.selectedService == entry.key;
            return ChoiceChip(
              label: Text(entry.value.label),
              selected: selected,
              onSelected: (_) => _controller.selectService(entry.key),
            );
          }).toList(growable: false),
        ),
      ],
    );
  }

  _CategorySketchPalette _categorySketchPalette(String categoryKey) {
    switch (categoryKey) {
      case 'pickup_mini':
        return const _CategorySketchPalette(
          kind: _VehicleSketchKind.pickupMini,
          strokeColor: Color(0xFF1D4ED8),
          accentColor: Color(0xFF93C5FD),
        );
      case 'specialized_1t':
        return const _CategorySketchPalette(
          kind: _VehicleSketchKind.oneTonVan,
          strokeColor: Color(0xFF0F766E),
          accentColor: Color(0xFF5EEAD4),
        );
      case 'truck_3t':
        return const _CategorySketchPalette(
          kind: _VehicleSketchKind.threeTonTruck,
          strokeColor: Color(0xFFB45309),
          accentColor: Color(0xFFFCD34D),
        );
      case 'dump_truck':
        return const _CategorySketchPalette(
          kind: _VehicleSketchKind.dumpTruck,
          strokeColor: Color(0xFF7C2D12),
          accentColor: Color(0xFFFDA4AF),
        );
      default:
        return const _CategorySketchPalette(
          kind: _VehicleSketchKind.generic,
          strokeColor: Color(0xFF334155),
          accentColor: Color(0xFFCBD5E1),
        );
    }
  }

  Widget _buildRideCard() {
    final ride = _controller.currentRide;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Seguimiento de Viaje',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            if (ride == null)
              const Text('Aun no has solicitado una carga.')
            else ...[
              _infoLine('ID', ride.id),
              _infoLine('Estado', statusToLabel(ride.status)),
              _infoLine('Solicitud', requestTypeToLabel(ride.requestType)),
              if (ride.scheduledAt != null)
                _infoLine(
                    'Programado', formatScheduledAtLocal(ride.scheduledAt)),
              _infoLine(
                  'ETA', ride.etaMin != null ? '${ride.etaMin} min' : '--'),
              if (ride.driver != null)
                _infoLine('Conductor', ride.driver!.name),
              const SizedBox(height: 10),
              LinearProgressIndicator(value: ride.progress.clamp(0, 1)),
              if (ride.status == 'pending_driver')
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'No hay chofer disponible por ahora. En cuanto uno se conecte, se asignara tu viaje automaticamente.',
                    style: TextStyle(
                      color: Colors.orange.shade900,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              const SizedBox(height: 6),
              const SizedBox(height: 12),
              const Text('Linea de tiempo',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              ...ride.timeline.reversed.take(6).map((e) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('• ${e.label}'),
                );
              }),
              if (ride.status == 'completed') ...[
                const SizedBox(height: 12),
                const Text('Calificacion del conductor',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                if (ride.riderRating != null)
                  Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.shade100),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Enviada: ${ride.riderRating!.score}/5',
                          style: TextStyle(
                            color: Colors.green.shade800,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (ride.riderRating!.comment.trim().isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            ride.riderRating!.comment,
                            style: TextStyle(color: Colors.green.shade900),
                          ),
                        ],
                      ],
                    ),
                  )
                else
                  FilledButton.icon(
                    onPressed: !_controller.canRateCurrentRide || _submittingRideRating
                        ? null
                        : () => _openRideRatingDialog(ride),
                    icon: _submittingRideRating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.star_outline),
                    label: Text(_submittingRideRating
                        ? 'Enviando...'
                        : 'Calificar conductor'),
                  ),
              ],
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed:
                    _controller.canCancel ? _controller.cancelRide : null,
                child: const Text('Cancelar viaje'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openRideRatingDialog(RideData ride) async {
    var score = 5;
    final commentController = TextEditingController();
    final result = await showDialog<(int, String)?>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Widget starButton(int value) {
              final selected = value <= score;
              return IconButton(
                onPressed: () {
                  setDialogState(() {
                    score = value;
                  });
                },
                icon: Icon(
                  selected ? Icons.star : Icons.star_border,
                  color: selected ? const Color(0xFFF59E0B) : Colors.grey,
                ),
              );
            }

            return AlertDialog(
              title: Text('Califica a ${ride.driver?.name ?? 'tu conductor'}'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Selecciona de 1 a 5 estrellas'),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List<Widget>.generate(5, (index) {
                      return starButton(index + 1);
                    }),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: commentController,
                    maxLines: 3,
                    maxLength: 250,
                    decoration: const InputDecoration(
                      labelText: 'Comentario (opcional)',
                      hintText: 'Comparte tu experiencia con el servicio',
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context)
                      .pop((score, commentController.text.trim())),
                  child: const Text('Enviar'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null || !mounted) {
      return;
    }

    final selectedScore = result.$1;
    final comment = result.$2;
    if (selectedScore < 1 || selectedScore > 5) {
      return;
    }

    setState(() {
      _submittingRideRating = true;
    });

    try {
      await _controller.submitRideRating(score: selectedScore, comment: comment);
      if (!mounted) {
        return;
      }
      setState(() {
        _locationStatus = 'Gracias. Tu calificacion fue registrada.';
      });
    } catch (_) {
      // El controlador publica el error para UI.
    } finally {
      if (mounted) {
        setState(() {
          _submittingRideRating = false;
        });
      }
    }
  }

  Widget _buildAddressValidationHint({required bool isPickup}) {
    final message = isPickup
        ? _pickupAddressValidationMessage
        : _dropoffAddressValidationMessage;
    final confirmed =
        isPickup ? _pickupAddressConfirmed : _dropoffAddressConfirmed;
    final approximate =
      isPickup ? _pickupAddressApproximate : _dropoffAddressApproximate;
    final hasAcceptedPoint = isPickup ? _pickupPoint != null : _dropoffPoint != null;
    final query =
      (isPickup ? _pickupController.text : _dropoffController.text).trim();

    if (message == null || message.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final color = approximate
      ? Colors.orange.shade900
      : (confirmed ? Colors.green.shade700 : Colors.orange.shade800);
    final background = approximate
      ? Colors.orange.shade50
      : (confirmed ? Colors.green.shade50 : Colors.orange.shade50);
    final border = approximate
      ? Colors.orange.shade100
      : (confirmed ? Colors.green.shade100 : Colors.orange.shade100);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              approximate
                  ? Icons.near_me_outlined
                  : (confirmed
                      ? Icons.verified_rounded
                      : Icons.info_outline_rounded),
              size: 18,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message,
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (hasAcceptedPoint) ...[
                    const SizedBox(height: 6),
                    TextButton.icon(
                      onPressed: () => approximate
                          ? _openManualMapSelection(isPickup: isPickup)
                          : _focusAcceptedAddressOnMap(isPickup: isPickup),
                      style: TextButton.styleFrom(
                        foregroundColor: color,
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        alignment: Alignment.centerLeft,
                      ),
                      icon: const Icon(Icons.map_outlined, size: 18),
                      label: Text(approximate
                          ? 'Ajustar punto exacto en mapa'
                          : 'Ver ubicacion aceptada en el mapa'),
                    ),
                  ] else if (query.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    TextButton.icon(
                      onPressed: () => _openManualMapSelection(
                        isPickup: isPickup,
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: color,
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        alignment: Alignment.centerLeft,
                      ),
                      icon: const Icon(Icons.place_outlined, size: 18),
                      label: const Text('Elegir punto manual en mapa'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAutocompleteSuggestions({required bool isPickup}) {
    final suggestions =
        isPickup ? _pickupAutocompleteSuggestions : _dropoffAutocompleteSuggestions;
    final loading =
        isPickup ? _loadingPickupAutocomplete : _loadingDropoffAutocomplete;
    final hasFocus =
      isPickup ? _pickupFocusNode.hasFocus : _dropoffFocusNode.hasFocus;
    final query =
        (isPickup ? _pickupController.text : _dropoffController.text).trim();

    if (!hasFocus || query.length < 3) {
      return const SizedBox.shrink();
    }

    if (loading) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(
              'Buscando direcciones...',
              style: TextStyle(
                color: Colors.blueGrey.shade700,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    if (suggestions.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.blue.shade100),
          boxShadow: const [
            BoxShadow(
              color: Color(0x120F172A),
              blurRadius: 16,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          children: suggestions
              .take(5)
              .map((item) {
                final subtitle =
                    _buildSuggestionSubtitle(item, isPickup: isPickup);
                final numberHint =
                    _buildNumberMatchHint(query: query, suggestion: item);
                final numberShort = numberHint.label == null
                    ? null
                    : (numberHint.label!.contains('confirmado') &&
                            !numberHint.label!.contains('no confirmado')
                        ? 'N° OK'
                        : (numberHint.label!.contains('parcial')
                            ? 'N° ?'
                            : 'N° X'));
                final titleText = numberShort == null
                    ? (item.primaryText ?? item.displayName)
                    : '$numberShort  ${item.primaryText ?? item.displayName}';

                final subtitleParts = <String>[];
                if (subtitle != null && subtitle.isNotEmpty) {
                  subtitleParts.add(subtitle);
                }
                if (numberHint.label != null) {
                  subtitleParts.add(numberHint.label!);
                }

                return Column(
                  children: [
                    ListTile(
                      leading: const Icon(
                        Icons.search_rounded,
                        color: Color(0xFF0F4CFF),
                      ),
                      title: Text(
                        titleText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1F2937),
                        ),
                      ),
                      subtitle: subtitleParts.isEmpty
                          ? null
                          : Text(
                              subtitleParts.join(' • '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                      trailing: IconButton(
                        onPressed: () => _toggleFavoriteAddress(item),
                        icon: Icon(
                          _isFavoriteAddress(item)
                              ? Icons.star
                              : Icons.star_border,
                          size: 20,
                          color: _isFavoriteAddress(item)
                              ? const Color(0xFFF59E0B)
                              : Colors.blueGrey.shade400,
                        ),
                        tooltip: 'Guardar favorita',
                      ),
                      onTap: () => _applySuggestion(
                        item,
                        isPickup: isPickup,
                        typedQuery: query,
                      ),
                    ),
                    if (item != suggestions.take(5).last)
                      const Divider(height: 1, indent: 16, endIndent: 16),
                  ],
                );
              })
              .toList(growable: false),
        ),
      ),
    );
  }

  Widget _buildPricingCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Tarifas por Categoria',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Categoria')),
                  DataColumn(label: Text('Arranque')),
                  DataColumn(label: Text('Por km')),
                  DataColumn(label: Text('Espera/min')),
                ],
                rows: _controller.pricing
                    .map(
                      (row) => DataRow(
                        cells: [
                          DataCell(Text(row.categoryLabel)),
                          DataCell(
                              Text('MXN ${row.startFare.toStringAsFixed(0)}')),
                          DataCell(
                              Text('MXN ${row.perKmRate.toStringAsFixed(0)}')),
                          DataCell(Text(
                              'MXN ${row.waitPerMinRate.toStringAsFixed(0)}')),
                        ],
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

enum _VehicleSketchKind {
  pickupMini,
  oneTonVan,
  threeTonTruck,
  dumpTruck,
  generic,
}

class _CategorySketchPalette {
  const _CategorySketchPalette({
    required this.kind,
    required this.strokeColor,
    required this.accentColor,
  });

  final _VehicleSketchKind kind;
  final Color strokeColor;
  final Color accentColor;

}

class _VehicleSketchPainter extends CustomPainter {
  const _VehicleSketchPainter({
    required this.kind,
    required this.strokeColor,
    required this.accentColor,
  });

  final _VehicleSketchKind kind;
  final Color strokeColor;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final accentStroke = Paint()
      ..color = accentColor.withValues(alpha: 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final wheelFill = Paint()
      ..color = strokeColor.withValues(alpha: 0.2)
      ..style = PaintingStyle.fill;

    switch (kind) {
      case _VehicleSketchKind.pickupMini:
        _drawPickup(canvas, size, stroke, accentStroke, wheelFill);
        break;
      case _VehicleSketchKind.oneTonVan:
        _drawVan(canvas, size, stroke, accentStroke, wheelFill);
        break;
      case _VehicleSketchKind.threeTonTruck:
        _drawTruck(canvas, size, stroke, accentStroke, wheelFill);
        break;
      case _VehicleSketchKind.dumpTruck:
        _drawDumpTruck(canvas, size, stroke, accentStroke, wheelFill);
        break;
      case _VehicleSketchKind.generic:
        _drawGeneric(canvas, size, stroke, accentStroke, wheelFill);
        break;
    }
  }

  void _drawPickup(
      Canvas canvas, Size size, Paint stroke, Paint accent, Paint wheelFill) {
    final body = ui.Path()
      ..moveTo(size.width * 0.08, size.height * 0.66)
      ..lineTo(size.width * 0.42, size.height * 0.66)
      ..lineTo(size.width * 0.54, size.height * 0.52)
      ..lineTo(size.width * 0.72, size.height * 0.52)
      ..lineTo(size.width * 0.84, size.height * 0.66)
      ..lineTo(size.width * 0.93, size.height * 0.66);

    final bedLine = ui.Path()
      ..moveTo(size.width * 0.16, size.height * 0.52)
      ..lineTo(size.width * 0.44, size.height * 0.52);

    _sketchPath(canvas, body, stroke);
    _sketchPath(canvas, bedLine, accent);
    _drawWheel(canvas, Offset(size.width * 0.28, size.height * 0.72), 7, stroke,
        wheelFill);
    _drawWheel(canvas, Offset(size.width * 0.74, size.height * 0.72), 7, stroke,
        wheelFill);
    _drawGround(canvas, size, accent);
  }

  void _drawVan(
      Canvas canvas, Size size, Paint stroke, Paint accent, Paint wheelFill) {
    final shell = ui.Path()
      ..moveTo(size.width * 0.08, size.height * 0.68)
      ..lineTo(size.width * 0.1, size.height * 0.5)
      ..quadraticBezierTo(
        size.width * 0.24,
        size.height * 0.34,
        size.width * 0.48,
        size.height * 0.34,
      )
      ..lineTo(size.width * 0.78, size.height * 0.34)
      ..lineTo(size.width * 0.9, size.height * 0.54)
      ..lineTo(size.width * 0.92, size.height * 0.68);

    final door = ui.Path()
      ..moveTo(size.width * 0.57, size.height * 0.4)
      ..lineTo(size.width * 0.57, size.height * 0.64)
      ..lineTo(size.width * 0.74, size.height * 0.64)
      ..lineTo(size.width * 0.74, size.height * 0.42);

    _sketchPath(canvas, shell, stroke);
    _sketchPath(canvas, door, accent);
    _drawWheel(canvas, Offset(size.width * 0.27, size.height * 0.72), 7, stroke,
        wheelFill);
    _drawWheel(canvas, Offset(size.width * 0.74, size.height * 0.72), 7, stroke,
        wheelFill);
    _drawGround(canvas, size, accent);
  }

  void _drawTruck(
      Canvas canvas, Size size, Paint stroke, Paint accent, Paint wheelFill) {
    final cargo = ui.Path()
      ..moveTo(size.width * 0.08, size.height * 0.67)
      ..lineTo(size.width * 0.08, size.height * 0.4)
      ..lineTo(size.width * 0.6, size.height * 0.4)
      ..lineTo(size.width * 0.6, size.height * 0.67);

    final cabin = ui.Path()
      ..moveTo(size.width * 0.62, size.height * 0.67)
      ..lineTo(size.width * 0.62, size.height * 0.5)
      ..lineTo(size.width * 0.74, size.height * 0.5)
      ..lineTo(size.width * 0.82, size.height * 0.44)
      ..lineTo(size.width * 0.9, size.height * 0.44)
      ..lineTo(size.width * 0.92, size.height * 0.67);

    final slats = ui.Path()
      ..moveTo(size.width * 0.18, size.height * 0.46)
      ..lineTo(size.width * 0.18, size.height * 0.64)
      ..moveTo(size.width * 0.3, size.height * 0.46)
      ..lineTo(size.width * 0.3, size.height * 0.64)
      ..moveTo(size.width * 0.42, size.height * 0.46)
      ..lineTo(size.width * 0.42, size.height * 0.64);

    _sketchPath(canvas, cargo, stroke);
    _sketchPath(canvas, cabin, stroke);
    _sketchPath(canvas, slats, accent);
    _drawWheel(canvas, Offset(size.width * 0.24, size.height * 0.73), 7, stroke,
        wheelFill);
    _drawWheel(canvas, Offset(size.width * 0.5, size.height * 0.73), 7, stroke,
        wheelFill);
    _drawWheel(canvas, Offset(size.width * 0.79, size.height * 0.73), 7, stroke,
        wheelFill);
    _drawGround(canvas, size, accent);
  }

  void _drawDumpTruck(
      Canvas canvas, Size size, Paint stroke, Paint accent, Paint wheelFill) {
    final base = ui.Path()
      ..moveTo(size.width * 0.08, size.height * 0.68)
      ..lineTo(size.width * 0.57, size.height * 0.68)
      ..lineTo(size.width * 0.57, size.height * 0.52)
      ..lineTo(size.width * 0.72, size.height * 0.52)
      ..lineTo(size.width * 0.84, size.height * 0.42)
      ..lineTo(size.width * 0.92, size.height * 0.42)
      ..lineTo(size.width * 0.92, size.height * 0.68);

    final bucket = ui.Path()
      ..moveTo(size.width * 0.14, size.height * 0.56)
      ..lineTo(size.width * 0.5, size.height * 0.46)
      ..lineTo(size.width * 0.54, size.height * 0.58)
      ..lineTo(size.width * 0.18, size.height * 0.66);

    _sketchPath(canvas, base, stroke);
    _sketchPath(canvas, bucket, accent);
    _drawWheel(canvas, Offset(size.width * 0.26, size.height * 0.74), 7, stroke,
        wheelFill);
    _drawWheel(canvas, Offset(size.width * 0.72, size.height * 0.74), 7, stroke,
        wheelFill);
    _drawGround(canvas, size, accent);
  }

  void _drawGeneric(
      Canvas canvas, Size size, Paint stroke, Paint accent, Paint wheelFill) {
    final body = ui.Path()
      ..moveTo(size.width * 0.1, size.height * 0.66)
      ..lineTo(size.width * 0.34, size.height * 0.66)
      ..lineTo(size.width * 0.46, size.height * 0.48)
      ..lineTo(size.width * 0.76, size.height * 0.48)
      ..lineTo(size.width * 0.88, size.height * 0.66)
      ..lineTo(size.width * 0.93, size.height * 0.66);

    _sketchPath(canvas, body, stroke);
    _drawWheel(canvas, Offset(size.width * 0.28, size.height * 0.73), 7, stroke,
        wheelFill);
    _drawWheel(canvas, Offset(size.width * 0.77, size.height * 0.73), 7, stroke,
        wheelFill);
    _drawGround(canvas, size, accent);
  }

  void _sketchPath(Canvas canvas, ui.Path path, Paint paint) {
    canvas.drawPath(path, paint);
    final offsetPaint = Paint()
      ..color = paint.color.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, paint.strokeWidth - 0.7)
      ..strokeCap = paint.strokeCap
      ..strokeJoin = paint.strokeJoin;
    canvas.save();
    canvas.translate(0.9, -0.8);
    canvas.drawPath(path, offsetPaint);
    canvas.restore();
  }

  void _drawWheel(
    Canvas canvas,
    Offset center,
    double radius,
    Paint stroke,
    Paint fill,
  ) {
    canvas.drawCircle(center, radius, fill);
    canvas.drawCircle(center, radius, stroke);
    canvas.drawCircle(
      center.translate(0.8, -0.4),
      radius * 0.58,
      stroke,
    );
  }

  void _drawGround(Canvas canvas, Size size, Paint accent) {
    final path = ui.Path()
      ..moveTo(size.width * 0.06, size.height * 0.82)
      ..quadraticBezierTo(
        size.width * 0.48,
        size.height * 0.87,
        size.width * 0.95,
        size.height * 0.8,
      );
    _sketchPath(canvas, path, accent);
  }

  @override
  bool shouldRepaint(covariant _VehicleSketchPainter oldDelegate) {
    return oldDelegate.kind != kind ||
        oldDelegate.strokeColor != strokeColor ||
        oldDelegate.accentColor != accentColor;
  }
}

String statusToLabel(String status) {
  switch (status) {
    case 'searching':
      return 'Buscando conductor';
    case 'accepted':
      return 'Conductor asignado';
    case 'driver_arriving':
      return 'Conductor en camino';
    case 'in_progress':
      return 'Carga en curso';
    case 'completed':
      return 'Completado';
    case 'cancelled':
      return 'Cancelado';
    case 'no_drivers':
      return 'Sin conductores';
    case 'pending_driver':
      return 'En espera de chofer disponible';
    default:
      return status;
  }
}

String requestTypeToLabel(String requestType) {
  switch (requestType) {
    case 'scheduled':
      return 'Programado';
    case 'same_day':
      return 'Transcurso del dia';
    case 'urgent':
      return 'Urgente';
    default:
      return requestType;
  }
}

/// Tarjeta métrica animada para Admin con hover effect y micro-animaciones
class _AdminMetricCard extends StatefulWidget {
  const _AdminMetricCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  State<_AdminMetricCard> createState() => _AdminMetricCardState();
}

class _AdminMetricCardState extends State<_AdminMetricCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _hoverController;

  @override
  void initState() {
    super.initState();
    _hoverController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _hoverController.dispose();
    super.dispose();
  }

  void _onHoverChange(bool isHovered) {
    _hoverController.animateTo(isHovered ? 1 : 0);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _onHoverChange(true),
      onExit: (_) => _onHoverChange(false),
      child: AnimatedBuilder(
        animation: _hoverController,
        builder: (context, child) {
          final scale = 1 + (_hoverController.value * 0.02);
          final shadowOpacity = 0.05 + (_hoverController.value * 0.1);

          return Transform.scale(
            scale: scale,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: shadowOpacity),
                    blurRadius: 10 + (_hoverController.value * 5),
                    offset: Offset(0, 3 + (_hoverController.value * 2)),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: widget.color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(widget.icon, color: widget.color, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.label,
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade600,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text(widget.value,
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w800)),
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
}

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

enum _AdminModule {
  overview,
  operations,
  finance,
  apiCosts,
  vehicles,
  drivers,
  settings,
}

class _AdminScreenState extends State<AdminScreen> {
  late final ApiClient _apiClient;
  static const List<int> _adminStatementWindowOptions = [7, 15, 30, 60, 90];
  static const List<int> _adminStatementLimitOptions = [100, 300, 500, 1000];
  static const List<int> _adminStatementCsvLimitOptions = [500, 1000, 3000, 5000];
  static const String _adminStatementWindowPrefsKey =
    'admin.driverStatement.windowDays';
  static const String _adminStatementQueryLimitPrefsKey =
    'admin.driverStatement.queryLimit';
  static const String _adminStatementCsvLimitPrefsKey =
    'admin.driverStatement.csvLimit';
  static const String _adminStatementDriverIdPrefsKey =
    'admin.driverStatement.driverId';
  static const String _adminSelectedModulePrefsKey =
    'admin.selectedModule';

  final Map<String, TextEditingController> _fields = {
    'foraneoThresholdKm': TextEditingController(),
    'includedKmInStartFare': TextEditingController(),
    'foraneoMultiplier': TextEditingController(),
    'defaultLoadingMinutes': TextEditingController(),
    'defaultTransferMinutes': TextEditingController(),
    'defaultUnloadingMinutes': TextEditingController(),
    'loadPersonnelUnitCost': TextEditingController(),
    'unloadPersonnelUnitCost': TextEditingController(),
    'municipalities': TextEditingController(),
  };

  final Map<String, String> _categoryLabels = {
    'pickup_mini': 'Pick-up Mini',
    'specialized_1t': 'Especializada 1 tonelada',
    'truck_3t': 'Especializada 3 toneladas',
    'dump_truck': 'Camion de Volteo',
  };

  final Map<String, Map<String, TextEditingController>> _categoryFields = {};
  List<RideData> _rides = [];
  List<AdminVehicle> _adminVehicles = [];
  List<AdminDriver> _adminDrivers = [];
  List<AdminDriverAuditEvent> _driverAudit = [];
  List<String> _vehicleAccessoriesCatalog = [];
  List<String> _driverSkillsCatalog = [];
  Map<String, List<String>> _adminCatalogItems = {
    'vehicle_accessories': const <String>[],
    'driver_documents': const <String>[],
    'driver_skills': const <String>[],
  };
  final Map<String, String> _catalogLabels = const {
    'vehicle_accessories': 'Accesorios de Vehiculo',
    'driver_documents': 'Documentos de Chofer',
    'driver_skills': 'Habilidades de Carga',
  };
  _AdminModule _selectedModule = _AdminModule.overview;
  DateTime? _filterStartDate;
  DateTime? _filterEndDate;
  String _filterMunicipality = 'all';
  String _filterCategory = 'all';
  AdminRatingsDistribution? _ratingsDistribution;
  List<AdminCustomer> _adminCustomers = [];
  List<AdminIncident> _adminIncidents = [];
  List<AdminSanction> _adminSanctions = [];
  DriverAccountStatement? _adminDriverAccountStatement;
  String? _selectedDriverStatementId;
  Map<String, List<String>> _incidentCatalog = const {};
  String _incidentFilterStatus = 'all';
  String _incidentFilterSeverity = 'all';
  String _incidentFilterSubjectType = 'all';
  String _sanctionFilterSubjectType = 'all';
  bool _loadingGovernance = false;
  bool _loadingDriverStatement = false;
  int _adminStatementWindowDays = 30;
  int _adminStatementQueryLimit = 300;
  int _adminStatementCsvLimit = 3000;
  bool _loadingRatingsDistribution = false;
  bool _operationsTopRatedOnly = true;
  double _operationsMinRating = 4.5;
  int _operationsMinRatingCount = 3;

  final TextEditingController _apiMonthlyConfirmedRidesController =
      TextEditingController(text: '300');
  final TextEditingController _apiPlacesCallsPerRideController =
      TextEditingController(text: '2.2');
  final TextEditingController _apiGeocodingCallsPerRideController =
      TextEditingController(text: '1.2');
  final TextEditingController _apiValidationCallsPerRideController =
      TextEditingController(text: '1.0');
  final TextEditingController _apiRoutesCallsPerRideController =
      TextEditingController(text: '1.0');
  final TextEditingController _apiRoutesPricePerThousandController =
      TextEditingController(text: '0');

    final TextEditingController _vehiclePlateController = TextEditingController();
    final TextEditingController _vehicleUnitNumberController =
      TextEditingController();
    final TextEditingController _vehicleBodyTypeController =
      TextEditingController();
    final TextEditingController _vehicleBrandController = TextEditingController();
    final TextEditingController _vehicleModelController = TextEditingController();
    final TextEditingController _vehicleYearController = TextEditingController();
    final TextEditingController _vehicleColorController = TextEditingController();
    final TextEditingController _vehicleCapacityKgController =
      TextEditingController();
    final TextEditingController _vehicleVolumeM3Controller =
      TextEditingController();
    final TextEditingController _vehicleOwnerController = TextEditingController();
    final TextEditingController _vehicleOperatorController =
      TextEditingController();
    final TextEditingController _vehiclePhoneController = TextEditingController();
    final TextEditingController _vehicleInsurancePolicyController =
      TextEditingController();
    final TextEditingController _vehicleInsuranceExpiryController =
      TextEditingController();
    final TextEditingController _vehicleCirculationExpiryController =
      TextEditingController();
    final TextEditingController _vehicleVerificationExpiryController =
      TextEditingController();
    final TextEditingController _vehicleNotesController = TextEditingController();
    final TextEditingController _vehicleSearchController = TextEditingController();

    final TextEditingController _driverFirstNameController = TextEditingController();
    final TextEditingController _driverLastNameController = TextEditingController();
    final TextEditingController _driverPhoneController = TextEditingController();
    final TextEditingController _driverEmailController = TextEditingController();
    final TextEditingController _driverCurpController = TextEditingController();
    final TextEditingController _driverRfcController = TextEditingController();
    final TextEditingController _driverBirthDateController = TextEditingController();
    final TextEditingController _driverAddressController = TextEditingController();
    final TextEditingController _driverMunicipalityController = TextEditingController();
    final TextEditingController _driverEmergencyNameController = TextEditingController();
    final TextEditingController _driverEmergencyPhoneController = TextEditingController();
    final TextEditingController _driverLicenseNumberController = TextEditingController();
    final TextEditingController _driverLicenseTypeController = TextEditingController();
    final TextEditingController _driverLicenseExpiryController = TextEditingController();
    final TextEditingController _driverBloodTypeController = TextEditingController();
    final TextEditingController _driverNotesController = TextEditingController();
    final TextEditingController _driverSearchController = TextEditingController();
    final TextEditingController _catalogEntryController = TextEditingController();
    final TextEditingController _driverPayoutAmountController = TextEditingController();
    final TextEditingController _driverPayoutNoteController = TextEditingController();
    final TextEditingController _driverAdjustmentAmountController = TextEditingController();
    final TextEditingController _driverAdjustmentNoteController = TextEditingController();

    String _vehicleCategory = 'pickup_mini';
    String _vehicleFilterCategory = 'all';
    String _vehicleFilterStatus = 'all';
    String _vehicleSortBy = 'updated_desc';
    int _vehiclePage = 0;
    bool _vehicleActive = true;
    bool _loadingVehicles = false;
    bool _savingVehicle = false;
    String? _editingVehicleId;
    Set<String> _selectedVehicleAccessories = <String>{};

    String _driverCategory = 'pickup_mini';
    String _driverFilterCategory = 'all';
    String _driverFilterStatus = 'all';
    String _driverSortBy = 'updated_desc';
    int _driverPage = 0;
    bool _driverActive = true;
    bool _driverAvailable = false;
    bool _loadingDrivers = false;
    bool _loadingDriverAudit = false;
    bool _savingDriver = false;
    String? _editingDriverId;
    Set<String> _selectedDriverVehicleIds = <String>{};
    Set<String> _selectedDriverSkills = <String>{};
    Map<String, bool> _driverDocuments = {
      'ine': false,
      'licencia_vigente': false,
      'comprobante_domicilio': false,
      'carta_antecedentes': false,
      'contrato_firmado': false,
      'capacitacion_aprobada': false,
      'seguro_vigente': false,
      'examen_medico': false,
    };
    String _selectedCatalogKey = 'driver_skills';
    bool _savingCatalogEntry = false;
    String? _recentlyReorderedCatalogItem;
    String _driverAdjustmentKind = 'credit';

  bool _loading = true;
  bool _loadingRides = false;
  bool _saving = false;
  bool _adminDensityCompact = false;
  String? _error;
  String? _success;

  @override
  void initState() {
    super.initState();
    _apiClient = ApiClient(resolveApiBaseUrl());
    unawaited(_initializeAdminScreen());
  }

  Future<void> _initializeAdminScreen() async {
    await _restoreAdminStatementPreferences();
    await _restoreAdminDensityPreference();
    await _load();
  }

  Future<void> _restoreAdminDensityPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final density = prefs.getBool('admin.densityCompact') ?? false;
      if (!mounted) return;
      setState(() => _adminDensityCompact = density);
    } catch (_) {}
  }

  Future<void> _saveAdminDensityPreference(bool compact) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('admin.densityCompact', compact);
    } catch (_) {}
  }

  Future<void> _restoreAdminStatementPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedWindow = prefs.getInt(_adminStatementWindowPrefsKey);
      final storedQueryLimit = prefs.getInt(_adminStatementQueryLimitPrefsKey);
      final storedCsvLimit = prefs.getInt(_adminStatementCsvLimitPrefsKey);
      final storedDriverId = prefs.getString(_adminStatementDriverIdPrefsKey);
      final storedModuleName = prefs.getString(_adminSelectedModulePrefsKey);

      if (!mounted) {
        return;
      }

      setState(() {
        if (storedWindow != null &&
            _adminStatementWindowOptions.contains(storedWindow)) {
          _adminStatementWindowDays = storedWindow;
        }
        if (storedQueryLimit != null &&
            _adminStatementLimitOptions.contains(storedQueryLimit)) {
          _adminStatementQueryLimit = storedQueryLimit;
        }
        if (storedCsvLimit != null &&
            _adminStatementCsvLimitOptions.contains(storedCsvLimit)) {
          _adminStatementCsvLimit = storedCsvLimit;
        }
        if (storedDriverId != null && storedDriverId.trim().isNotEmpty) {
          _selectedDriverStatementId = storedDriverId.trim();
        }
        if (storedModuleName != null && storedModuleName.trim().isNotEmpty) {
          _selectedModule = _AdminModule.values.firstWhere(
            (module) => module.name == storedModuleName.trim(),
            orElse: () => _AdminModule.overview,
          );
        }
      });
    } catch (_) {
      // Ignora errores de preferencias locales.
    }
  }

  Future<void> _saveAdminStatementPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_adminStatementWindowPrefsKey, _adminStatementWindowDays);
      await prefs.setInt(
          _adminStatementQueryLimitPrefsKey, _adminStatementQueryLimit);
      await prefs.setInt(_adminStatementCsvLimitPrefsKey, _adminStatementCsvLimit);
      final selectedDriverId = _selectedDriverStatementId?.trim();
      if (selectedDriverId != null && selectedDriverId.isNotEmpty) {
        await prefs.setString(_adminStatementDriverIdPrefsKey, selectedDriverId);
      } else {
        await prefs.remove(_adminStatementDriverIdPrefsKey);
      }
      await prefs.setString(_adminSelectedModulePrefsKey, _selectedModule.name);
    } catch (_) {
      // Ignora errores de preferencias locales.
    }
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    for (final controls in _categoryFields.values) {
      for (final controller in controls.values) {
        controller.dispose();
      }
    }
    _apiMonthlyConfirmedRidesController.dispose();
    _apiPlacesCallsPerRideController.dispose();
    _apiGeocodingCallsPerRideController.dispose();
    _apiValidationCallsPerRideController.dispose();
    _apiRoutesCallsPerRideController.dispose();
    _apiRoutesPricePerThousandController.dispose();
    _vehiclePlateController.dispose();
    _vehicleUnitNumberController.dispose();
    _vehicleBodyTypeController.dispose();
    _vehicleBrandController.dispose();
    _vehicleModelController.dispose();
    _vehicleYearController.dispose();
    _vehicleColorController.dispose();
    _vehicleCapacityKgController.dispose();
    _vehicleVolumeM3Controller.dispose();
    _vehicleOwnerController.dispose();
    _vehicleOperatorController.dispose();
    _vehiclePhoneController.dispose();
    _vehicleInsurancePolicyController.dispose();
    _vehicleInsuranceExpiryController.dispose();
    _vehicleCirculationExpiryController.dispose();
    _vehicleVerificationExpiryController.dispose();
    _vehicleNotesController.dispose();
    _vehicleSearchController.dispose();
    _driverFirstNameController.dispose();
    _driverLastNameController.dispose();
    _driverPhoneController.dispose();
    _driverEmailController.dispose();
    _driverCurpController.dispose();
    _driverRfcController.dispose();
    _driverBirthDateController.dispose();
    _driverAddressController.dispose();
    _driverMunicipalityController.dispose();
    _driverEmergencyNameController.dispose();
    _driverEmergencyPhoneController.dispose();
    _driverLicenseNumberController.dispose();
    _driverLicenseTypeController.dispose();
    _driverLicenseExpiryController.dispose();
    _driverBloodTypeController.dispose();
    _driverNotesController.dispose();
    _driverSearchController.dispose();
    _catalogEntryController.dispose();
    _driverPayoutAmountController.dispose();
    _driverPayoutNoteController.dispose();
    _driverAdjustmentAmountController.dispose();
    _driverAdjustmentNoteController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _success = null;
    });

    try {
      final config = await _apiClient.getAdminPricingConfig();
      _fields['foraneoThresholdKm']!.text =
          config.foraneoThresholdKm.toStringAsFixed(2);
      _fields['includedKmInStartFare']!.text =
          config.includedKmInStartFare.toStringAsFixed(2);
      _fields['foraneoMultiplier']!.text =
          config.foraneoMultiplier.toStringAsFixed(2);
      _fields['defaultLoadingMinutes']!.text =
          config.defaultLoadingMinutes.toStringAsFixed(2);
      _fields['defaultTransferMinutes']!.text =
          config.defaultTransferMinutes.toStringAsFixed(2);
      _fields['defaultUnloadingMinutes']!.text =
          config.defaultUnloadingMinutes.toStringAsFixed(2);
      _fields['loadPersonnelUnitCost']!.text =
          config.loadPersonnelUnitCost.toStringAsFixed(2);
      _fields['unloadPersonnelUnitCost']!.text =
          config.unloadPersonnelUnitCost.toStringAsFixed(2);
      _fields['municipalities']!.text = config.municipalities.join(', ');

      for (final entry in config.categories.entries) {
        final map = _categoryFields.putIfAbsent(entry.key, () {
          return {
            'startFare': TextEditingController(),
            'extraKmRate': TextEditingController(),
            'operationalPerMinRate': TextEditingController(),
          };
        });

        map['startFare']!.text = entry.value.startFare.toStringAsFixed(2);
        map['extraKmRate']!.text = entry.value.extraKmRate.toStringAsFixed(2);
        map['operationalPerMinRate']!.text =
            entry.value.operationalPerMinRate.toStringAsFixed(2);
      }

      await _loadRides();
      await _loadAdminCatalogs();
      await _loadVehicles();
      await _loadDrivers();
      await _loadRatingsDistribution();
      await _loadGovernanceData();
    } catch (e) {
      _error = 'No se pudo cargar configuracion: $e';
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadRides() async {
    setState(() {
      _loadingRides = true;
    });

    try {
      final rides = await _apiClient.getDriverRides(activeOnly: false);
      if (!mounted) {
        return;
      }

      setState(() {
        _rides = rides;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo cargar monitoreo de viajes: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingRides = false;
        });
      }
    }
  }

  Future<void> _loadRatingsDistribution() async {
    setState(() {
      _loadingRatingsDistribution = true;
    });

    try {
      final distribution = await _apiClient.getAdminRatingsDistribution();
      if (!mounted) {
        return;
      }
      setState(() {
        _ratingsDistribution = distribution;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo cargar distribucion de calificaciones: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingRatingsDistribution = false;
        });
      }
    }
  }

  Future<void> _loadGovernanceData() async {
    setState(() {
      _loadingGovernance = true;
    });

    try {
      final customers = await _apiClient.getAdminCustomers();
      final incidents = await _apiClient.getAdminIncidents(
        subjectType:
            _incidentFilterSubjectType == 'all' ? null : _incidentFilterSubjectType,
        severity: _incidentFilterSeverity == 'all' ? null : _incidentFilterSeverity,
        status: _incidentFilterStatus == 'all' ? null : _incidentFilterStatus,
        limit: 150,
      );
      final catalog = await _apiClient.getAdminIncidentsCatalog();
      final sanctions = await _apiClient.getAdminSanctions(
        subjectType:
            _sanctionFilterSubjectType == 'all' ? null : _sanctionFilterSubjectType,
        limit: 200,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _adminCustomers = customers;
        _adminIncidents = incidents;
        _incidentCatalog = catalog;
        _adminSanctions = sanctions;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo cargar clientes/incidencias: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingGovernance = false;
        });
      }
    }
  }

  List<AdminDriver> _topRatedAdminDrivers() {
    final source = _adminDrivers.where((driver) {
      final rating = double.tryParse(driver.rating) ?? 0;
      if (_operationsTopRatedOnly && rating < _operationsMinRating) {
        return false;
      }
      if (_operationsTopRatedOnly && driver.ratingCount < _operationsMinRatingCount) {
        return false;
      }
      return true;
    }).toList();

    source.sort((left, right) {
      final byRating =
          (double.tryParse(right.rating) ?? 0).compareTo(double.tryParse(left.rating) ?? 0);
      if (byRating != 0) {
        return byRating;
      }
      return right.ratingCount.compareTo(left.ratingCount);
    });
    return source;
  }

  double _numField(String key, {double fallback = 0}) {
    return double.tryParse(_fields[key]!.text.trim()) ?? fallback;
  }

  double _categoryNumField(String category, String field) {
    return double.tryParse(_categoryFields[category]![field]!.text.trim()) ?? 0;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
      _success = null;
    });

    final categories = <String, AdminCategoryConfig>{};
    for (final category in _categoryFields.keys) {
      categories[category] = AdminCategoryConfig(
        startFare: _categoryNumField(category, 'startFare'),
        extraKmRate: _categoryNumField(category, 'extraKmRate'),
        operationalPerMinRate:
            _categoryNumField(category, 'operationalPerMinRate'),
      );
    }

    final municipalities = _fields['municipalities']!
        .text
        .split(',')
        .map((item) => item.trim().toLowerCase())
        .where((item) => item.isNotEmpty)
        .toList();

    final payload = AdminPricingConfig(
      foraneoThresholdKm: _numField('foraneoThresholdKm'),
      includedKmInStartFare: _numField('includedKmInStartFare'),
      foraneoMultiplier: _numField('foraneoMultiplier', fallback: 1),
      defaultLoadingMinutes: _numField('defaultLoadingMinutes'),
      defaultTransferMinutes: _numField('defaultTransferMinutes'),
      defaultUnloadingMinutes: _numField('defaultUnloadingMinutes'),
      loadPersonnelUnitCost: _numField('loadPersonnelUnitCost'),
      unloadPersonnelUnitCost: _numField('unloadPersonnelUnitCost'),
      categories: categories,
      municipalities: municipalities,
    );

    try {
      await _apiClient.saveAdminPricingConfig(payload);
      _success = 'Configuracion guardada correctamente.';
      await _load();
    } catch (e) {
      setState(() {
        _error = 'No se pudo guardar configuracion: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  int _countRidesByStatus(Set<String> statuses, {List<RideData>? rides}) {
    final source = rides ?? _rides;
    return source.where((ride) => statuses.contains(ride.status)).length;
  }

  Widget _buildAdminMetric({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return _AdminMetricCard(
      icon: icon,
      label: label,
      value: value,
      color: color,
    );
  }

  double _controllerNumber(TextEditingController controller,
      {double fallback = 0}) {
    return double.tryParse(controller.text.trim()) ?? fallback;
  }

  String _money(double value) => 'MXN ${value.toStringAsFixed(2)}';

  int _confirmedRideCount({List<RideData>? rides}) {
    final source = rides ?? _rides;
    return source
        .where((ride) => {
              'accepted',
              'driver_arriving',
              'in_progress',
              'completed'
            }.contains(ride.status))
        .length;
  }

  double _totalRevenue({List<RideData>? rides}) {
    final source = rides ?? _rides;
    return source
        .where((ride) => ride.status == 'completed')
        .fold<double>(0, (sum, ride) => sum + ride.fareEstimate);
  }

  double _avgTicket({List<RideData>? rides}) {
    final source = rides ?? _rides;
    final completed = source.where((ride) => ride.status == 'completed').toList();
    if (completed.isEmpty) {
      return 0;
    }
    return _totalRevenue(rides: source) / completed.length;
  }

  Map<String, int> _ridesByCategory({List<RideData>? rides}) {
    final source = rides ?? _rides;
    final map = <String, int>{};
    for (final ride in source) {
      map.update(ride.category, (value) => value + 1, ifAbsent: () => 1);
    }
    return map;
  }

  DateTime? _rideReferenceDate(RideData ride) {
    final raw = (ride.scheduledAt ?? ride.requestedAt).trim();
    if (raw.isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw)?.toLocal();
  }

  String _extractMunicipality(String address) {
    final parts = address
        .split(',')
        .map((part) => part.trim().toLowerCase())
        .where((part) => part.isNotEmpty)
        .toList();

    if (parts.isEmpty) {
      return 'sin dato';
    }

    if (parts.length >= 2) {
      return parts[parts.length - 2];
    }

    return parts.first;
  }

  Set<String> _availableMunicipalities() {
    final values = _rides
        .map((ride) => _extractMunicipality(ride.dropoff.isNotEmpty ? ride.dropoff : ride.pickup))
        .where((item) => item != 'sin dato')
        .toSet();
    return values;
  }

  List<RideData> _filteredRides() {
    return _rides.where((ride) {
      if (_filterCategory != 'all' && ride.category != _filterCategory) {
        return false;
      }

      if (_filterMunicipality != 'all') {
        final municipality =
            _extractMunicipality(ride.dropoff.isNotEmpty ? ride.dropoff : ride.pickup);
        if (municipality != _filterMunicipality) {
          return false;
        }
      }

      final rideDate = _rideReferenceDate(ride);
      if (_filterStartDate != null) {
        if (rideDate == null ||
            rideDate.isBefore(DateTime(
                _filterStartDate!.year, _filterStartDate!.month, _filterStartDate!.day))) {
          return false;
        }
      }

      if (_filterEndDate != null) {
        final endBoundary =
            DateTime(_filterEndDate!.year, _filterEndDate!.month, _filterEndDate!.day)
                .add(const Duration(days: 1));
        if (rideDate == null || !rideDate.isBefore(endBoundary)) {
          return false;
        }
      }

      return true;
    }).toList();
  }

  IconData _moduleIcon(_AdminModule module) {
    switch (module) {
      case _AdminModule.overview:
        return Icons.space_dashboard_outlined;
      case _AdminModule.operations:
        return Icons.local_shipping_outlined;
      case _AdminModule.finance:
        return Icons.attach_money_outlined;
      case _AdminModule.apiCosts:
        return Icons.query_stats_outlined;
      case _AdminModule.vehicles:
        return Icons.local_shipping;
      case _AdminModule.drivers:
        return Icons.badge_outlined;
      case _AdminModule.settings:
        return Icons.settings_outlined;
    }
  }

  String _moduleLabel(_AdminModule module) {
    switch (module) {
      case _AdminModule.overview:
        return 'Resumen';
      case _AdminModule.operations:
        return 'Operaciones';
      case _AdminModule.finance:
        return 'Finanzas';
      case _AdminModule.apiCosts:
        return 'API y Costos';
      case _AdminModule.vehicles:
        return 'Vehiculos';
      case _AdminModule.drivers:
        return 'Choferes';
      case _AdminModule.settings:
        return 'Configuracion';
    }
  }

  Widget _buildAdminModuleMenu() {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _AdminModule.values.map((module) {
            return ChoiceChip(
              selected: _selectedModule == module,
              onSelected: (_) => setState(() {
                _selectedModule = module;
                unawaited(_saveAdminStatementPreferences());
              }),
              avatar: Icon(_moduleIcon(module), size: 16),
              label: Text(_moduleLabel(module)),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildOverviewSection() {
    final active = _countRidesByStatus(
      {'searching', 'scheduled', 'pending_driver', 'accepted', 'driver_arriving', 'in_progress'});
    final completed = _countRidesByStatus({'completed'});
    final incidents = _countRidesByStatus({'cancelled', 'no_drivers'});

    return Column(
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            SizedBox(
              width: 240,
              child: _buildAdminMetric(
                icon: Icons.local_shipping_outlined,
                label: 'Viajes activos',
                value: '$active',
                color: const Color(0xFF1D4ED8),
              ),
            ),
            SizedBox(
              width: 240,
              child: _buildAdminMetric(
                icon: Icons.check_circle_outline,
                label: 'Completados',
                value: '$completed',
                color: const Color(0xFF15803D),
              ),
            ),
            SizedBox(
              width: 240,
              child: _buildAdminMetric(
                icon: Icons.warning_amber_rounded,
                label: 'Incidencias',
                value: '$incidents',
                color: const Color(0xFFB45309),
              ),
            ),
            SizedBox(
              width: 240,
              child: _buildAdminMetric(
                icon: Icons.payments_outlined,
                label: 'Facturacion cerrada',
                value: _money(_totalRevenue()),
                color: const Color(0xFF7C3AED),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildMonitoringCard(rides: _rides),
      ],
    );
  }

  Widget _buildOperationsSection() {
    final rides = _filteredRides();
    final topDrivers = _topRatedAdminDrivers();
    return Column(
      children: [
        _buildAdvancedFiltersCard(),
        const SizedBox(height: 12),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Calificaciones de choferes',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                if (_loadingRatingsDistribution)
                  const LinearProgressIndicator()
                else if (_ratingsDistribution == null)
                  const Text('No hay datos de calificaciones por ahora.')
                else
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      SizedBox(
                        width: 220,
                        child: _buildAdminMetric(
                          icon: Icons.star_rounded,
                          label: 'Promedio global',
                          value: _ratingsDistribution!.average.toStringAsFixed(2),
                          color: const Color(0xFFD97706),
                        ),
                      ),
                      SizedBox(
                        width: 220,
                        child: _buildAdminMetric(
                          icon: Icons.rate_review_outlined,
                          label: 'Total calificaciones',
                          value: '${_ratingsDistribution!.total}',
                          color: const Color(0xFF0F766E),
                        ),
                      ),
                      SizedBox(
                        width: 220,
                        child: _buildAdminMetric(
                          icon: Icons.reply_outlined,
                          label: 'Sin respuesta chofer',
                          value: '${_ratingsDistribution!.withoutReply}',
                          color: const Color(0xFFB45309),
                        ),
                      ),
                      ...[5, 4, 3, 2, 1].map((star) {
                        final count = _ratingsDistribution!.countByStar[star] ?? 0;
                        return Chip(label: Text('$star estrellas: $count'));
                      }),
                    ],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Estado de cuenta de chofer',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 320,
                      child: DropdownButtonFormField<String>(
                        initialValue: _selectedDriverStatementId,
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'Chofer para estado de cuenta',
                        ),
                        items: _adminDrivers
                            .map((driver) => DropdownMenuItem(
                                  value: driver.id,
                                  child: Text(driver.fullName),
                                ))
                            .toList(growable: false),
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _selectedDriverStatementId = value;
                          });
                          unawaited(_saveAdminStatementPreferences());
                          _loadDriverStatementForAdmin(driverId: value);
                        },
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _loadingDriverStatement
                          ? null
                          : _loadDriverStatementForAdmin,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Actualizar'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _loadingDriverStatement
                          ? null
                          : _exportDriverStatementCsvFromAdmin,
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Exportar CSV'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _adminStatementWindowOptions
                      .map(
                        (days) => ChoiceChip(
                          label: Text('EC ${days}d'),
                          selected: _adminStatementWindowDays == days,
                          onSelected: (_) {
                            setState(() {
                              _adminStatementWindowDays = days;
                            });
                            unawaited(_saveAdminStatementPreferences());
                            _loadDriverStatementForAdmin();
                          },
                        ),
                      )
                      .toList(growable: false),
                ),
                const SizedBox(height: 10),
                if (_loadingDriverStatement)
                  const LinearProgressIndicator()
                else if (_adminDriverAccountStatement == null)
                  const Text('Selecciona un chofer para ver su estado de cuenta.')
                else ...[
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      SizedBox(
                        width: 220,
                        child: _buildAdminMetric(
                          icon: Icons.payments_outlined,
                          label: 'Ingresos brutos',
                          value:
                              'MXN ${_adminDriverAccountStatement!.summary.grossEarnings.toStringAsFixed(2)}',
                          color: const Color(0xFF15803D),
                        ),
                      ),
                      SizedBox(
                        width: 220,
                        child: _buildAdminMetric(
                          icon: Icons.percent_outlined,
                          label: 'Comisiones',
                          value:
                              'MXN ${_adminDriverAccountStatement!.summary.commissions.toStringAsFixed(2)}',
                          color: const Color(0xFFB45309),
                        ),
                      ),
                      SizedBox(
                        width: 220,
                        child: _buildAdminMetric(
                          icon: Icons.account_balance_wallet_outlined,
                          label: 'Neto',
                          value:
                              'MXN ${_adminDriverAccountStatement!.summary.netEarnings.toStringAsFixed(2)}',
                          color: const Color(0xFF0F766E),
                        ),
                      ),
                      SizedBox(
                        width: 220,
                        child: _buildAdminMetric(
                          icon: Icons.savings_outlined,
                          label: 'Saldo actual',
                          value:
                              'MXN ${_adminDriverAccountStatement!.summary.balance.toStringAsFixed(2)}',
                          color: const Color(0xFF1D4ED8),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      SizedBox(
                        width: 190,
                        child: TextField(
                          controller: _driverPayoutAmountController,
                          keyboardType:
                              const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(
                            labelText: 'Monto liquidacion',
                            isDense: true,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 320,
                        child: TextField(
                          controller: _driverPayoutNoteController,
                          decoration: const InputDecoration(
                            labelText: 'Nota de liquidacion',
                            isDense: true,
                          ),
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: _registerDriverPayoutFromAdmin,
                        child: const Text('Registrar pago'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      SizedBox(
                        width: 180,
                        child: DropdownButtonFormField<String>(
                          initialValue: _driverAdjustmentKind,
                          decoration: const InputDecoration(
                            isDense: true,
                            labelText: 'Tipo ajuste',
                          ),
                          items: const [
                            DropdownMenuItem(value: 'credit', child: Text('A favor')),
                            DropdownMenuItem(value: 'debit', child: Text('A cargo')),
                          ],
                          onChanged: (value) {
                            if (value == null) {
                              return;
                            }
                            setState(() {
                              _driverAdjustmentKind = value;
                            });
                          },
                        ),
                      ),
                      SizedBox(
                        width: 190,
                        child: TextField(
                          controller: _driverAdjustmentAmountController,
                          keyboardType:
                              const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(
                            labelText: 'Monto ajuste',
                            isDense: true,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 320,
                        child: TextField(
                          controller: _driverAdjustmentNoteController,
                          decoration: const InputDecoration(
                            labelText: 'Nota ajuste',
                            isDense: true,
                          ),
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: _registerDriverAdjustmentFromAdmin,
                        child: const Text('Registrar ajuste'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_adminDriverAccountStatement!.entries.isEmpty)
                    const Text('Sin movimientos en el periodo actual.')
                  else
                    ..._adminDriverAccountStatement!.entries.take(16).map((entry) {
                      final isCredit = entry.amount >= 0;
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          isCredit
                              ? Icons.arrow_downward_rounded
                              : Icons.arrow_upward_rounded,
                          color:
                              isCredit ? Colors.green.shade700 : Colors.red.shade700,
                        ),
                        title: Text(_ledgerTypeLabelForAdmin(entry.type)),
                        subtitle: Text(
                          '${entry.description.isEmpty ? 'Sin descripcion' : entry.description} · ${entry.createdAt}',
                        ),
                        trailing: Text(
                          '${entry.amount >= 0 ? '+' : '-'} MXN ${entry.amount.abs().toStringAsFixed(2)}',
                          style: TextStyle(
                            color: isCredit
                                ? Colors.green.shade700
                                : Colors.red.shade700,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      );
                    }),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Choferes mejor calificados',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilterChip(
                      label: const Text('Solo top calificados'),
                      selected: _operationsTopRatedOnly,
                      onSelected: (value) {
                        setState(() {
                          _operationsTopRatedOnly = value;
                        });
                      },
                    ),
                    ChoiceChip(
                      label: const Text('>= 4.5'),
                      selected: _operationsMinRating == 4.5,
                      onSelected: (_) {
                        setState(() {
                          _operationsMinRating = 4.5;
                        });
                      },
                    ),
                    ChoiceChip(
                      label: const Text('>= 4.7'),
                      selected: _operationsMinRating == 4.7,
                      onSelected: (_) {
                        setState(() {
                          _operationsMinRating = 4.7;
                        });
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Min 3 calificaciones'),
                      selected: _operationsMinRatingCount == 3,
                      onSelected: (_) {
                        setState(() {
                          _operationsMinRatingCount = 3;
                        });
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Min 10 calificaciones'),
                      selected: _operationsMinRatingCount == 10,
                      onSelected: (_) {
                        setState(() {
                          _operationsMinRatingCount = 10;
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (topDrivers.isEmpty)
                  KarrytEmptyState(
                    icon: Icons.filter_alt_off_outlined,
                    title: 'Sin resultados',
                    subtitle: 'Ajusta los filtros para ver más choferes.',
                  )
                else
                  ...topDrivers.take(8).map((driver) {
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.emoji_events_outlined),
                      title: Text(driver.fullName),
                      subtitle: Text(
                          '${_categoryLabels[driver.category] ?? driver.category} · ${driver.phone}'),
                      trailing: Text(
                        '${driver.rating} (${driver.ratingCount})',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('Clientes y riesgo',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                    ),
                    IconButton(
                      onPressed: _loadingGovernance ? null : _loadGovernanceData,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                if (_loadingGovernance)
                  const LinearProgressIndicator()
                else if (_adminCustomers.isEmpty)
                  const Text('No hay clientes registrados aun.')
                else
                  ..._adminCustomers.take(8).map((customer) {
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        customer.suspended ? Icons.block : Icons.person_outline,
                        color: customer.suspended
                            ? Colors.red.shade700
                            : Colors.blueGrey.shade700,
                      ),
                      title: Text(customer.fullName),
                      subtitle: Text(
                        '${customer.phone} · Rating ${customer.rating} (${customer.ratingCount})',
                      ),
                      trailing: FilledButton.tonal(
                        onPressed: () => _toggleCustomerSuspension(
                            customer, !customer.suspended),
                        child: Text(customer.suspended ? 'Reactivar' : 'Suspender'),
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Incidencias operativas',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    SizedBox(
                      width: 190,
                      child: DropdownButtonFormField<String>(
                        initialValue: _incidentFilterSubjectType,
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'Tipo',
                        ),
                        items: const [
                          DropdownMenuItem(value: 'all', child: Text('Todos')),
                          DropdownMenuItem(value: 'customer', child: Text('Cliente')),
                          DropdownMenuItem(value: 'driver', child: Text('Chofer')),
                          DropdownMenuItem(value: 'vehicle', child: Text('Vehiculo')),
                          DropdownMenuItem(value: 'trip', child: Text('Viaje')),
                        ],
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _incidentFilterSubjectType = value;
                          });
                        },
                      ),
                    ),
                    SizedBox(
                      width: 190,
                      child: DropdownButtonFormField<String>(
                        initialValue: _incidentFilterSeverity,
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'Severidad',
                        ),
                        items: const [
                          DropdownMenuItem(value: 'all', child: Text('Todas')),
                          DropdownMenuItem(value: 'baja', child: Text('Baja')),
                          DropdownMenuItem(value: 'media', child: Text('Media')),
                          DropdownMenuItem(value: 'alta', child: Text('Alta')),
                          DropdownMenuItem(value: 'critica', child: Text('Critica')),
                        ],
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _incidentFilterSeverity = value;
                          });
                        },
                      ),
                    ),
                    SizedBox(
                      width: 190,
                      child: DropdownButtonFormField<String>(
                        initialValue: _incidentFilterStatus,
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'Estado',
                        ),
                        items: const [
                          DropdownMenuItem(value: 'all', child: Text('Todos')),
                          DropdownMenuItem(value: 'open', child: Text('Abierta')),
                          DropdownMenuItem(value: 'in_review', child: Text('En revision')),
                          DropdownMenuItem(value: 'resolved', child: Text('Resuelta')),
                          DropdownMenuItem(value: 'dismissed', child: Text('Descartada')),
                        ],
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _incidentFilterStatus = value;
                          });
                        },
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _loadingGovernance ? null : _loadGovernanceData,
                      icon: const Icon(Icons.filter_alt_outlined),
                      label: const Text('Aplicar filtros'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _loadingGovernance ? null : _exportIncidentsCsv,
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Exportar CSV'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_incidentCatalog.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _incidentCatalog.entries
                        .map((entry) => Chip(label: Text('${entry.key}: ${entry.value.length}')))
                        .toList(growable: false),
                  ),
                const SizedBox(height: 8),
                if (_loadingGovernance)
                  const LinearProgressIndicator()
                else if (_adminIncidents.isEmpty)
                  const Text('Sin incidencias reportadas.')
                else
                  ..._adminIncidents.take(12).map((incident) {
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${incident.subjectType}:${incident.subjectId} · ${incident.category}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Text(incident.title),
                          if (incident.details.trim().isNotEmpty)
                            Text(incident.details,
                                style: TextStyle(color: Colors.grey.shade700)),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            children: [
                              Chip(label: Text('Severidad: ${incident.severity}')),
                              Chip(label: Text('Estado: ${incident.status}')),
                              FilledButton.tonal(
                                onPressed: incident.status == 'resolved'
                                    ? null
                                    : () => _setIncidentStatus(incident, 'resolved'),
                                child: const Text('Resolver'),
                              ),
                              FilledButton.tonal(
                                onPressed: incident.status == 'dismissed'
                                    ? null
                                    : () => _setIncidentStatus(incident, 'dismissed'),
                                child: const Text('Descartar'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Historial de sanciones',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 190,
                      child: DropdownButtonFormField<String>(
                        initialValue: _sanctionFilterSubjectType,
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'Entidad',
                        ),
                        items: const [
                          DropdownMenuItem(value: 'all', child: Text('Todas')),
                          DropdownMenuItem(value: 'customer', child: Text('Cliente')),
                          DropdownMenuItem(value: 'driver', child: Text('Chofer')),
                          DropdownMenuItem(value: 'vehicle', child: Text('Vehiculo')),
                        ],
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _sanctionFilterSubjectType = value;
                          });
                        },
                      ),
                    ),
                    FilledButton.tonal(
                      onPressed: _loadingGovernance ? null : _loadGovernanceData,
                      child: const Text('Filtrar'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _loadingGovernance ? null : _exportSanctionsCsv,
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Exportar CSV'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_loadingGovernance)
                  const LinearProgressIndicator()
                else if (_adminSanctions.isEmpty)
                  const Text('Sin sanciones registradas.')
                else
                  ..._adminSanctions.take(14).map((entry) {
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.gavel_outlined),
                      title: Text(
                        '${entry.subjectType}:${entry.subjectId} · ${entry.action}',
                      ),
                      subtitle: Text(
                        '${entry.reason.isEmpty ? 'Sin motivo capturado' : entry.reason} · ${entry.createdAt}',
                      ),
                      trailing: Text(entry.actor),
                    );
                  }),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildMonitoringCard(rides: rides),
      ],
    );
  }

  Widget _buildFinanceSection() {
    final rides = _filteredRides();
    final byCategory = _ridesByCategory(rides: rides);
    return Column(
      children: [
        _buildAdvancedFiltersCard(),
        const SizedBox(height: 12),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Finanzas y desempeño',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    SizedBox(
                      width: 280,
                      child: _buildAdminMetric(
                        icon: Icons.receipt_long_outlined,
                        label: 'Ticket promedio',
                        value: _money(_avgTicket(rides: rides)),
                        color: const Color(0xFF0369A1),
                      ),
                    ),
                    SizedBox(
                      width: 280,
                      child: _buildAdminMetric(
                        icon: Icons.trending_up,
                        label: 'Ingresos completados',
                        value: _money(_totalRevenue(rides: rides)),
                        color: const Color(0xFF15803D),
                      ),
                    ),
                    SizedBox(
                      width: 280,
                      child: _buildAdminMetric(
                        icon: Icons.fact_check_outlined,
                        label: 'Viajes confirmados',
                        value: '${_confirmedRideCount(rides: rides)}',
                        color: const Color(0xFF7C2D12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Text('Volumen por categoria',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: byCategory.entries
                      .map((entry) => Chip(
                            label: Text(
                                '${_categoryLabels[entry.key] ?? entry.key}: ${entry.value}'),
                          ))
                      .toList(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildApiCostsSection() {
    const placesPerThousand = 296.3457;
    const geocodingPerThousand = 87.1605;
    const validationPerThousand = 435.8025;

    final monthlyRides =
        _controllerNumber(_apiMonthlyConfirmedRidesController, fallback: 0);
    final placesCalls = _controllerNumber(_apiPlacesCallsPerRideController);
    final geocodingCalls =
        _controllerNumber(_apiGeocodingCallsPerRideController);
    final validationCalls =
        _controllerNumber(_apiValidationCallsPerRideController);
    final routesCalls = _controllerNumber(_apiRoutesCallsPerRideController);
    final routesPerThousand =
        _controllerNumber(_apiRoutesPricePerThousandController);

    final placesCost = (monthlyRides * placesCalls / 1000) * placesPerThousand;
    final geocodingCost =
        (monthlyRides * geocodingCalls / 1000) * geocodingPerThousand;
    final validationCost =
        (monthlyRides * validationCalls / 1000) * validationPerThousand;
    final routesCost = (monthlyRides * routesCalls / 1000) * routesPerThousand;
    final total = placesCost + geocodingCost + validationCost + routesCost;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Control de costos API',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
              'Estimacion para viajes confirmados. Routes se usa solo en recalculo y solicitud.',
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 10),
            _compactNumberField(_apiMonthlyConfirmedRidesController,
                'Viajes confirmados / mes'),
            _compactNumberField(
                _apiPlacesCallsPerRideController, 'Llamadas Places por viaje'),
            _compactNumberField(_apiGeocodingCallsPerRideController,
                'Llamadas Geocoding por viaje'),
            _compactNumberField(_apiValidationCallsPerRideController,
                'Llamadas Address Validation por viaje'),
            _compactNumberField(
                _apiRoutesCallsPerRideController, 'Llamadas Routes por viaje'),
            _compactNumberField(_apiRoutesPricePerThousandController,
                'Precio Routes por 1000 (MXN)'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                SizedBox(
                  width: 260,
                  child: _buildAdminMetric(
                    icon: Icons.pin_drop_outlined,
                    label: 'Places estimado',
                    value: _money(placesCost),
                    color: const Color(0xFF2563EB),
                  ),
                ),
                SizedBox(
                  width: 260,
                  child: _buildAdminMetric(
                    icon: Icons.map_outlined,
                    label: 'Geocoding estimado',
                    value: _money(geocodingCost),
                    color: const Color(0xFF0F766E),
                  ),
                ),
                SizedBox(
                  width: 260,
                  child: _buildAdminMetric(
                    icon: Icons.verified_user_outlined,
                    label: 'Validation estimado',
                    value: _money(validationCost),
                    color: const Color(0xFF7C2D12),
                  ),
                ),
                SizedBox(
                  width: 260,
                  child: _buildAdminMetric(
                    icon: Icons.route_outlined,
                    label: 'Routes estimado',
                    value: _money(routesCost),
                    color: const Color(0xFF7C3AED),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Costo API mensual total estimado: ${_money(total)}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            if (routesPerThousand <= 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Define el precio de Routes por 1000 para una proyeccion completa.',
                  style: TextStyle(color: Colors.orange.shade800),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<String> _fallbackVehicleAccessories() {
    return const [
      'caballetes_marmol',
      'caballetes_vidrio',
      'estructura_acero_tramos',
      'redilas',
      'caja_seca',
      'caja_refrigerada',
      'estructura_cubierta_antilluvia',
      'lona',
      'cinchos',
      'tapetes',
      'hules',
      'carton',
      'plastico_emplaye',
      'tarimas',
      'esquineros_protectores',
      'mantas_aislantes',
      'cinta_seguridad',
      'rampas_carga',
    ];
  }

  String _vehicleAccessoryLabel(String value) {
    final words = value
        .split('_')
        .where((word) => word.trim().isNotEmpty)
        .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
        .toList();
    return words.join(' ');
  }

  Future<void> _loadVehicles() async {
    if (mounted) {
      setState(() {
        _loadingVehicles = true;
      });
    }

    try {
      final accessories = await _apiClient.getAdminVehicleAccessories();
      final vehicles = await _apiClient.getAdminVehicles();
      if (!mounted) {
        return;
      }

      setState(() {
        _vehicleAccessoriesCatalog = accessories.isEmpty
            ? _fallbackVehicleAccessories()
            : accessories;
        _adminVehicles = vehicles;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo cargar registro de vehiculos: $e';
        if (_vehicleAccessoriesCatalog.isEmpty) {
          _vehicleAccessoriesCatalog = _fallbackVehicleAccessories();
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingVehicles = false;
        });
      }
    }
  }

  AdminVehicle? _editingVehicle() {
    final id = _editingVehicleId;
    if (id == null) {
      return null;
    }

    for (final vehicle in _adminVehicles) {
      if (vehicle.id == id) {
        return vehicle;
      }
    }
    return null;
  }

  double? _tryDouble(String value) {
    final parsed = double.tryParse(value.trim());
    if (parsed == null || parsed < 0) {
      return null;
    }
    return parsed;
  }

  int? _tryYear(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null) {
      return null;
    }
    final current = DateTime.now().year;
    if (parsed < 1980 || parsed > current + 1) {
      return null;
    }
    return parsed;
  }

  String? _dateFieldValue(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  Future<void> _saveVehicleRecord() async {
    final plate = _vehiclePlateController.text.trim().toUpperCase();
    if (plate.isEmpty) {
      setState(() {
        _error = 'La placa es obligatoria para registrar el vehiculo.';
      });
      return;
    }

    final current = _editingVehicle();
    final nowIso = DateTime.now().toIso8601String();
    final payload = AdminVehicle(
      id: _editingVehicleId ?? '',
      plateNumber: plate,
      unitNumber: _vehicleUnitNumberController.text.trim(),
      category: _vehicleCategory,
      bodyType: _vehicleBodyTypeController.text.trim(),
      brand: _vehicleBrandController.text.trim(),
      model: _vehicleModelController.text.trim(),
      year: _tryYear(_vehicleYearController.text),
      color: _vehicleColorController.text.trim(),
      capacityKg: _tryDouble(_vehicleCapacityKgController.text),
      volumeM3: _tryDouble(_vehicleVolumeM3Controller.text),
      ownerName: _vehicleOwnerController.text.trim(),
      operatorName: _vehicleOperatorController.text.trim(),
      contactPhone: _vehiclePhoneController.text.trim(),
      insurancePolicy: _vehicleInsurancePolicyController.text.trim(),
      insuranceExpiry: _dateFieldValue(_vehicleInsuranceExpiryController.text),
      circulationCardExpiry:
          _dateFieldValue(_vehicleCirculationExpiryController.text),
      verificationExpiry:
          _dateFieldValue(_vehicleVerificationExpiryController.text),
      notes: _vehicleNotesController.text.trim(),
      accessories: _selectedVehicleAccessories.toList()..sort(),
      suspended: current?.suspended ?? false,
      suspensionReason: current?.suspensionReason ?? '',
      active: _vehicleActive,
      createdAt: current?.createdAt ?? nowIso,
      updatedAt: nowIso,
    );

    setState(() {
      _savingVehicle = true;
      _error = null;
      _success = null;
    });

    try {
      if (_editingVehicleId == null) {
        await _apiClient.createAdminVehicle(payload);
        if (mounted) {
          setState(() {
            _success = 'Vehiculo registrado correctamente.';
          });
        }
      } else {
        await _apiClient.updateAdminVehicle(payload);
        if (mounted) {
          setState(() {
            _success = 'Vehiculo actualizado correctamente.';
          });
        }
      }
      _clearVehicleForm();
      await _loadVehicles();
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo guardar el vehiculo: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _savingVehicle = false;
        });
      }
    }
  }

  void _clearVehicleForm() {
    setState(() {
      _editingVehicleId = null;
      _vehiclePlateController.clear();
      _vehicleUnitNumberController.clear();
      _vehicleBodyTypeController.clear();
      _vehicleBrandController.clear();
      _vehicleModelController.clear();
      _vehicleYearController.clear();
      _vehicleColorController.clear();
      _vehicleCapacityKgController.clear();
      _vehicleVolumeM3Controller.clear();
      _vehicleOwnerController.clear();
      _vehicleOperatorController.clear();
      _vehiclePhoneController.clear();
      _vehicleInsurancePolicyController.clear();
      _vehicleInsuranceExpiryController.clear();
      _vehicleCirculationExpiryController.clear();
      _vehicleVerificationExpiryController.clear();
      _vehicleNotesController.clear();
      _vehicleCategory = 'pickup_mini';
      _vehicleActive = true;
      _selectedVehicleAccessories = <String>{};
    });
  }

  void _loadVehicleToForm(AdminVehicle vehicle) {
    setState(() {
      _editingVehicleId = vehicle.id;
      _vehiclePlateController.text = vehicle.plateNumber;
      _vehicleUnitNumberController.text = vehicle.unitNumber;
      _vehicleBodyTypeController.text = vehicle.bodyType;
      _vehicleBrandController.text = vehicle.brand;
      _vehicleModelController.text = vehicle.model;
      _vehicleYearController.text = vehicle.year?.toString() ?? '';
      _vehicleColorController.text = vehicle.color;
      _vehicleCapacityKgController.text = vehicle.capacityKg?.toString() ?? '';
      _vehicleVolumeM3Controller.text = vehicle.volumeM3?.toString() ?? '';
      _vehicleOwnerController.text = vehicle.ownerName;
      _vehicleOperatorController.text = vehicle.operatorName;
      _vehiclePhoneController.text = vehicle.contactPhone;
      _vehicleInsurancePolicyController.text = vehicle.insurancePolicy;
      _vehicleInsuranceExpiryController.text = vehicle.insuranceExpiry ?? '';
      _vehicleCirculationExpiryController.text =
          vehicle.circulationCardExpiry ?? '';
      _vehicleVerificationExpiryController.text =
          vehicle.verificationExpiry ?? '';
      _vehicleNotesController.text = vehicle.notes;
      _vehicleCategory = vehicle.category;
      _vehicleActive = vehicle.active;
      _selectedVehicleAccessories = vehicle.accessories.toSet();
    });
  }

  Future<void> _toggleVehicleActive(AdminVehicle vehicle, bool active) async {
    try {
      final updated = await _apiClient.setAdminVehicleActive(vehicle.id, active);
      if (!mounted) {
        return;
      }
      setState(() {
        _adminVehicles = _adminVehicles
            .map((item) => item.id == updated.id ? updated : item)
            .toList();
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo actualizar estatus de vehiculo: $e';
      });
    }
  }

  Future<void> _toggleVehicleSuspension(AdminVehicle vehicle, bool suspended) async {
    try {
      final updated = await _apiClient.setAdminVehicleSuspension(
        id: vehicle.id,
        suspended: suspended,
        reason: suspended ? 'Suspension operativa desde panel admin' : 'Reactivado por admin',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _adminVehicles = _adminVehicles
            .map((item) => item.id == updated.id ? updated : item)
            .toList(growable: false);
      });
      await _loadGovernanceData();
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo actualizar suspension de vehiculo: $e';
      });
    }
  }

  Future<void> _deleteVehicle(AdminVehicle vehicle) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Eliminar vehiculo'),
          content: Text('Se eliminara ${vehicle.plateNumber}. Esta accion no se puede deshacer.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Eliminar'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    try {
      await _apiClient.deleteAdminVehicle(vehicle.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _adminVehicles = _adminVehicles.where((item) => item.id != vehicle.id).toList();
        if (_editingVehicleId == vehicle.id) {
          _clearVehicleForm();
        }
        _success = 'Vehiculo eliminado.';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo eliminar vehiculo: $e';
      });
    }
  }

  Widget _vehicleTextField(
    TextEditingController controller,
    String label, {
    TextInputType? keyboardType,
    String? hint,
    int maxLines = 1,
    double width = 250,
  }) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          isDense: true,
        ),
      ),
    );
  }

  List<AdminVehicle> _filteredVehicles() {
    final search = _vehicleSearchController.text.trim().toLowerCase();
    return _adminVehicles.where((vehicle) {
      if (_vehicleFilterCategory != 'all' && vehicle.category != _vehicleFilterCategory) {
        return false;
      }

      if (_vehicleFilterStatus == 'active' && !vehicle.active) {
        return false;
      }
      if (_vehicleFilterStatus == 'inactive' && vehicle.active) {
        return false;
      }

      if (search.isEmpty) {
        return true;
      }

      final haystack = [
        vehicle.plateNumber,
        vehicle.unitNumber,
        vehicle.brand,
        vehicle.model,
        vehicle.operatorName,
      ].join(' ').toLowerCase();

      return haystack.contains(search);
    }).toList();
  }

  int _vehicleUpdatedAtMs(AdminVehicle vehicle) {
    final parsed = DateTime.tryParse(vehicle.updatedAt);
    if (parsed == null) {
      return 0;
    }
    return parsed.millisecondsSinceEpoch;
  }

  List<AdminVehicle> _sortedFilteredVehicles() {
    final result = _filteredVehicles();
    result.sort((a, b) {
      switch (_vehicleSortBy) {
        case 'plate_asc':
          return a.plateNumber.compareTo(b.plateNumber);
        case 'plate_desc':
          return b.plateNumber.compareTo(a.plateNumber);
        case 'category_asc':
          return (_categoryLabels[a.category] ?? a.category)
              .compareTo(_categoryLabels[b.category] ?? b.category);
        case 'updated_asc':
          return _vehicleUpdatedAtMs(a).compareTo(_vehicleUpdatedAtMs(b));
        case 'updated_desc':
        default:
          return _vehicleUpdatedAtMs(b).compareTo(_vehicleUpdatedAtMs(a));
      }
    });
    return result;
  }

  Widget _buildVehiclesSection() {
    final categories = _categoryLabels.keys.toList();
    const pageSize = 8;
    final filteredVehicles = _sortedFilteredVehicles();
    final totalVehicles = filteredVehicles.length;
    final pageCount = totalVehicles == 0 ? 1 : (totalVehicles / pageSize).ceil();
    final currentPage = math.max(0, math.min(_vehiclePage, pageCount - 1));
    final startIndex = totalVehicles == 0 ? 0 : currentPage * pageSize;
    final endIndex = totalVehicles == 0
      ? 0
      : math.min(startIndex + pageSize, totalVehicles);
    final pageVehicles =
      totalVehicles == 0 ? const <AdminVehicle>[] : filteredVehicles.sublist(startIndex, endIndex);

    return Column(
      children: [
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _editingVehicleId == null
                            ? 'Registro de vehiculos'
                            : 'Editar vehiculo',
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w800),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _clearVehicleForm,
                      icon: const Icon(Icons.cleaning_services_outlined),
                      label: const Text('Limpiar'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _vehicleTextField(_vehiclePlateController, 'Placa *',
                        hint: 'ABC-123-D'),
                    _vehicleTextField(_vehicleUnitNumberController,
                        'Numero economico'),
                    SizedBox(
                      width: 250,
                      child: DropdownButtonFormField<String>(
                        initialValue: _vehicleCategory,
                        decoration: InputDecoration(
                          labelText: 'Categoria *',
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12)),
                          isDense: true,
                        ),
                        items: categories
                            .map(
                              (category) => DropdownMenuItem(
                                value: category,
                                child:
                                    Text(_categoryLabels[category] ?? category),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _vehicleCategory = value;
                          });
                        },
                      ),
                    ),
                    _vehicleTextField(_vehicleBodyTypeController,
                        'Tipo de carroceria',
                        hint: 'Plataforma, caja seca, redilas'),
                    _vehicleTextField(_vehicleBrandController, 'Marca'),
                    _vehicleTextField(_vehicleModelController, 'Modelo'),
                    _vehicleTextField(_vehicleYearController, 'Anio',
                        keyboardType: TextInputType.number),
                    _vehicleTextField(_vehicleColorController, 'Color'),
                    _vehicleTextField(_vehicleCapacityKgController,
                        'Capacidad (kg)',
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true)),
                    _vehicleTextField(_vehicleVolumeM3Controller, 'Volumen (m3)',
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true)),
                    _vehicleTextField(_vehicleOwnerController, 'Propietario'),
                    _vehicleTextField(
                        _vehicleOperatorController, 'Operador asignado'),
                    _vehicleTextField(_vehiclePhoneController, 'Telefono contacto',
                        keyboardType: TextInputType.phone),
                    _vehicleTextField(
                        _vehicleInsurancePolicyController, 'Poliza de seguro'),
                    _vehicleTextField(_vehicleInsuranceExpiryController,
                        'Vencimiento seguro',
                        hint: 'YYYY-MM-DD'),
                    _vehicleTextField(_vehicleCirculationExpiryController,
                        'Vencimiento tarjeta circulacion',
                        hint: 'YYYY-MM-DD'),
                    _vehicleTextField(_vehicleVerificationExpiryController,
                        'Vencimiento verificacion',
                        hint: 'YYYY-MM-DD'),
                    _vehicleTextField(_vehicleNotesController, 'Notas operativas',
                        maxLines: 2, width: 510),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Accesorios para transporte de carga',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _vehicleAccessoriesCatalog.map((item) {
                    final selected = _selectedVehicleAccessories.contains(item);
                    return FilterChip(
                      label: Text(_vehicleAccessoryLabel(item)),
                      selected: selected,
                      onSelected: (value) {
                        setState(() {
                          if (value) {
                            _selectedVehicleAccessories.add(item);
                          } else {
                            _selectedVehicleAccessories.remove(item);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 10),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _vehicleActive,
                  title: const Text('Vehiculo activo para asignacion'),
                  onChanged: (value) {
                    setState(() {
                      _vehicleActive = value ?? true;
                    });
                  },
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _savingVehicle ? null : _saveVehicleRecord,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(
                    _savingVehicle
                        ? 'Guardando...'
                        : (_editingVehicleId == null
                            ? 'Registrar vehiculo'
                            : 'Actualizar vehiculo'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Flota registrada',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      onPressed: _loadingVehicles ? null : _loadVehicles,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 300,
                      child: TextField(
                        controller: _vehicleSearchController,
                        onChanged: (_) => setState(() {
                          _vehiclePage = 0;
                        }),
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: 'Buscar placa, unidad o operador',
                          prefixIcon: const Icon(Icons.search),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 240,
                      child: DropdownButtonFormField<String>(
                        initialValue: _vehicleFilterCategory,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: 'Categoria',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: 'all',
                            child: Text('Todas las categorias'),
                          ),
                          ...categories.map(
                            (category) => DropdownMenuItem(
                              value: category,
                              child: Text(_categoryLabels[category] ?? category),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _vehicleFilterCategory = value;
                            _vehiclePage = 0;
                          });
                        },
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<String>(
                        initialValue: _vehicleFilterStatus,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: 'Estatus',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'all',
                            child: Text('Todos'),
                          ),
                          DropdownMenuItem(
                            value: 'active',
                            child: Text('Activos'),
                          ),
                          DropdownMenuItem(
                            value: 'inactive',
                            child: Text('Inactivos'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _vehicleFilterStatus = value;
                            _vehiclePage = 0;
                          });
                        },
                      ),
                    ),
                    SizedBox(
                      width: 240,
                      child: DropdownButtonFormField<String>(
                        initialValue: _vehicleSortBy,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: 'Ordenar por',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'updated_desc',
                            child: Text('Mas recientes'),
                          ),
                          DropdownMenuItem(
                            value: 'updated_asc',
                            child: Text('Mas antiguos'),
                          ),
                          DropdownMenuItem(
                            value: 'plate_asc',
                            child: Text('Placa A-Z'),
                          ),
                          DropdownMenuItem(
                            value: 'plate_desc',
                            child: Text('Placa Z-A'),
                          ),
                          DropdownMenuItem(
                            value: 'category_asc',
                            child: Text('Categoria A-Z'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _vehicleSortBy = value;
                            _vehiclePage = 0;
                          });
                        },
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () {
                        setState(() {
                          _vehicleSearchController.clear();
                          _vehicleFilterCategory = 'all';
                          _vehicleFilterStatus = 'all';
                          _vehicleSortBy = 'updated_desc';
                          _vehiclePage = 0;
                        });
                      },
                      icon: const Icon(Icons.filter_alt_off_outlined),
                      label: const Text('Limpiar'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Resultados: ${filteredVehicles.length} de ${_adminVehicles.length}',
                  style: TextStyle(
                    color: Colors.grey.shade700,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (totalVehicles > 0) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        'Mostrando ${startIndex + 1}-$endIndex de $totalVehicles',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Pagina anterior',
                        onPressed: currentPage <= 0
                            ? null
                            : () {
                                setState(() {
                                  _vehiclePage = currentPage - 1;
                                });
                              },
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text('${currentPage + 1}/$pageCount'),
                      IconButton(
                        tooltip: 'Pagina siguiente',
                        onPressed: currentPage >= pageCount - 1
                            ? null
                            : () {
                                setState(() {
                                  _vehiclePage = currentPage + 1;
                                });
                              },
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                if (_loadingVehicles)
                  const LinearProgressIndicator()
                else if (filteredVehicles.isEmpty)
                  const Text('No hay vehiculos registrados aun.')
                else
                  ...pageVehicles.map((vehicle) {
                    final categoryLabel =
                        _categoryLabels[vehicle.category] ?? vehicle.category;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFE3E8F2)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${vehicle.plateNumber} • $categoryLabel',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700),
                                  ),
                                ),
                                Switch(
                                  value: vehicle.active,
                                  onChanged: (value) =>
                                      _toggleVehicleActive(vehicle, value),
                                ),
                                IconButton(
                                  tooltip: vehicle.suspended
                                      ? 'Quitar suspension'
                                      : 'Suspender vehiculo',
                                  onPressed: () => _toggleVehicleSuspension(
                                      vehicle, !vehicle.suspended),
                                  icon: Icon(
                                    vehicle.suspended
                                        ? Icons.shield_outlined
                                        : Icons.gpp_bad_outlined,
                                    color: vehicle.suspended
                                        ? Colors.green.shade700
                                        : Colors.red.shade700,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Editar',
                                  onPressed: () => _loadVehicleToForm(vehicle),
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                                IconButton(
                                  tooltip: 'Eliminar',
                                  onPressed: () => _deleteVehicle(vehicle),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                                'Unidad: ${vehicle.unitNumber.isEmpty ? 'N/D' : vehicle.unitNumber} • Marca/Modelo: ${vehicle.brand.isEmpty ? 'N/D' : vehicle.brand} ${vehicle.model}'),
                            Text(
                                'Capacidad: ${vehicle.capacityKg?.toStringAsFixed(0) ?? 'N/D'} kg • Volumen: ${vehicle.volumeM3?.toStringAsFixed(2) ?? 'N/D'} m3'),
                            Text(
                                'Operador: ${vehicle.operatorName.isEmpty ? 'Sin asignar' : vehicle.operatorName}'),
                            if (vehicle.suspended)
                              Text(
                                'Suspendido: ${vehicle.suspensionReason.isEmpty ? 'sin motivo' : vehicle.suspensionReason}',
                                style: TextStyle(
                                  color: Colors.red.shade700,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            if (vehicle.accessories.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: vehicle.accessories
                                    .map((item) => Chip(
                                          visualDensity:
                                              VisualDensity.compact,
                                          label: Text(
                                            _vehicleAccessoryLabel(item),
                                            style: const TextStyle(fontSize: 12),
                                          ),
                                        ))
                                    .toList(),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _driverDocumentLabel(String key) {
    final words = key
        .split('_')
        .where((part) => part.trim().isNotEmpty)
        .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
        .toList();
    return words.join(' ');
  }

  String _driverSkillLabel(String key) {
    final words = key
        .split('_')
        .where((part) => part.trim().isNotEmpty)
        .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
        .toList();
    return words.join(' ');
  }

  List<String> _fallbackDriverSkills() {
    return const [
      'carga_marmol',
      'carga_vidrio',
      'manejo_acero_crudo_tubulares_vigas_ptr',
      'manejo_perfiles_y_estructuras_metalicas',
      'manejo_madera_tableros_triplay',
      'traslado_muebles_y_linea_blanca',
      'manejo_bultos_cemento_mortero_yeso',
      'manejo_material_encostalado',
      'manejo_residuos_peligrosos',
      'sitios_autorizados_escombro_basura',
      'manejo_escombro_y_residuos_de_obra',
      'manejo_minicargador',
      'maniobras_con_montacargas',
      'uso_rampas_patines_diablitos',
      'amarre_y_aseguramiento_carga',
      'habilidad_cargador_maniobrista',
      'solo_chofer_sin_maniobras_carga',
      'maniobras_con_caballetes',
      'estiba_y_desestiba_profesional',
      'proteccion_con_lona_hules_carton_emplaye',
      'uso_cinchos_cadenas_eslingas',
    ];
  }

  void _applyAdminCatalogs(Map<String, List<String>> catalogs) {
    final accessories = catalogs['vehicle_accessories'] ?? const <String>[];
    final documents = catalogs['driver_documents'] ?? const <String>[];
    final skills = catalogs['driver_skills'] ?? const <String>[];

    final nextDocuments = <String, bool>{};
    final documentKeys = documents.isEmpty ? _driverDocuments.keys.toList() : documents;
    for (final key in documentKeys) {
      nextDocuments[key] = _driverDocuments[key] ?? false;
    }

    _adminCatalogItems = {
      'vehicle_accessories': accessories,
      'driver_documents': documentKeys,
      'driver_skills': skills,
    };
    _vehicleAccessoriesCatalog =
        accessories.isEmpty ? _fallbackVehicleAccessories() : accessories;
    _driverSkillsCatalog = skills.isEmpty ? _fallbackDriverSkills() : skills;
    _driverDocuments = nextDocuments;
  }

  Future<void> _loadAdminCatalogs() async {
    try {
      final catalogs = await _apiClient.getAdminCatalogs();
      if (!mounted) {
        return;
      }
      setState(() {
        _applyAdminCatalogs(catalogs);
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _applyAdminCatalogs({
          'vehicle_accessories': _fallbackVehicleAccessories(),
          'driver_documents': _driverDocuments.keys.toList(),
          'driver_skills': _fallbackDriverSkills(),
        });
      });
    }
  }

  Future<void> _addCatalogEntryFromAdmin() async {
    final raw = _catalogEntryController.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _error = 'Escribe un campo/habilidad para agregar al catalogo.';
      });
      return;
    }

    setState(() {
      _savingCatalogEntry = true;
      _error = null;
      _success = null;
    });

    try {
      final catalogs = await _apiClient.addAdminCatalogEntry(
        catalogKey: _selectedCatalogKey,
        item: raw,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _applyAdminCatalogs(catalogs);
        _catalogEntryController.clear();
        _success = 'Catalogo actualizado correctamente.';
      });
      await _loadVehicles();
      await _loadDrivers();
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo agregar entrada al catalogo: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _savingCatalogEntry = false;
        });
      }
    }
  }

  Future<void> _renameCatalogEntryFromAdmin(String oldItem) async {
    final controller = TextEditingController(text: oldItem);
    final renamed = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Editar entrada de catalogo'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Nuevo nombre',
              hintText: 'ej: manejo_tablaroca_panel_yeso',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text.trim()),
              child: const Text('Guardar'),
            ),
          ],
        );
      },
    );

    if (renamed == null || renamed.isEmpty || renamed == oldItem) {
      return;
    }

    setState(() {
      _savingCatalogEntry = true;
      _error = null;
      _success = null;
    });

    try {
      final catalogs = await _apiClient.updateAdminCatalogEntry(
        catalogKey: _selectedCatalogKey,
        oldItem: oldItem,
        newItem: renamed,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _applyAdminCatalogs(catalogs);
        _success = 'Entrada de catalogo actualizada.';
      });
      await _loadVehicles();
      await _loadDrivers();
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo editar entrada de catalogo: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _savingCatalogEntry = false;
        });
      }
    }
  }

  Future<void> _deleteCatalogEntryFromAdmin(String item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Eliminar entrada de catalogo'),
          content: Text('Se eliminara "$item". Esta accion no se puede deshacer.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Eliminar'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    setState(() {
      _savingCatalogEntry = true;
      _error = null;
      _success = null;
    });

    try {
      final catalogs = await _apiClient.deleteAdminCatalogEntry(
        catalogKey: _selectedCatalogKey,
        item: item,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _applyAdminCatalogs(catalogs);
        _success = 'Entrada eliminada del catalogo.';
      });
      await _loadVehicles();
      await _loadDrivers();
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo eliminar entrada de catalogo: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _savingCatalogEntry = false;
        });
      }
    }
  }

  Future<void> _reorderCatalogEntryFromAdmin({
    required String item,
    required String direction,
  }) async {
    setState(() {
      _savingCatalogEntry = true;
      _error = null;
      _success = null;
    });

    try {
      final catalogs = await _apiClient.reorderAdminCatalogEntry(
        catalogKey: _selectedCatalogKey,
        item: item,
        direction: direction,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _applyAdminCatalogs(catalogs);
        _success = 'Orden de catalogo actualizado.';
      });
      await _loadVehicles();
      await _loadDrivers();
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo reordenar entrada: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _savingCatalogEntry = false;
        });
      }
    }
  }

  Future<void> _reorderCatalogByDragFromAdmin({
    required int oldIndex,
    required int newIndex,
    required List<String> catalogItems,
  }) async {
    if (_savingCatalogEntry) {
      return;
    }

    var targetIndex = newIndex;
    if (targetIndex > oldIndex) {
      targetIndex -= 1;
    }

    if (targetIndex == oldIndex ||
        oldIndex < 0 ||
        oldIndex >= catalogItems.length ||
        targetIndex < 0 ||
        targetIndex >= catalogItems.length) {
      return;
    }

    final reordered = List<String>.from(catalogItems);
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(targetIndex, moved);

    setState(() {
      _savingCatalogEntry = true;
      _error = null;
      _success = null;
    });

    try {
      final catalogs = await _apiClient.setAdminCatalogOrder(
        catalogKey: _selectedCatalogKey,
        items: reordered,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _applyAdminCatalogs(catalogs);
        _recentlyReorderedCatalogItem = moved;
        _success = 'Orden de catalogo actualizado.';
      });
      await _loadVehicles();
      await _loadDrivers();
      if (mounted) {
        unawaited(Future<void>.delayed(const Duration(milliseconds: 900), () {
          if (!mounted) {
            return;
          }
          setState(() {
            if (_recentlyReorderedCatalogItem == moved) {
              _recentlyReorderedCatalogItem = null;
            }
          });
        }));
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo reordenar entrada: $e';
        _recentlyReorderedCatalogItem = null;
      });
    } finally {
      if (mounted) {
        setState(() {
          _savingCatalogEntry = false;
        });
      }
    }
  }

  int _driversMissingDocumentsCount() {
    return _adminDrivers.where((driver) {
      if (driver.documents.isEmpty) {
        return true;
      }
      return driver.documents.values.any((ok) => ok != true);
    }).length;
  }

  int _driversWithoutVehicleCount() {
    return _adminDrivers.where((driver) => driver.assignedVehicleIds.isEmpty).length;
  }

  int _driversLicenseExpiringCount({int withinDays = 30}) {
    final threshold = DateTime.now().add(Duration(days: withinDays));
    return _adminDrivers.where((driver) {
      final raw = driver.licenseExpiry?.trim();
      if (raw == null || raw.isEmpty) {
        return false;
      }
      final parsed = DateTime.tryParse(raw);
      if (parsed == null) {
        return false;
      }
      return !parsed.isAfter(threshold);
    }).length;
  }

  String _driverAuditActionLabel(String action) {
    switch (action) {
      case 'create':
        return 'Alta';
      case 'update':
        return 'Edicion';
      case 'status':
        return 'Estatus';
      case 'availability':
        return 'Disponibilidad';
      case 'delete':
        return 'Baja';
      default:
        return action;
    }
  }

  Future<void> _loadDrivers() async {
    if (mounted) {
      setState(() {
        _loadingDrivers = true;
        _loadingDriverAudit = true;
      });
    }

    try {
      final drivers = await _apiClient.getAdminDrivers();
      final skills = await _apiClient.getAdminDriverSkills();
      final audit = await _apiClient.getAdminDriverAudit(limit: 120);
      final selectedStatementId = _selectedDriverStatementId;
      final resolvedStatementId = selectedStatementId != null &&
              drivers.any((driver) => driver.id == selectedStatementId)
          ? selectedStatementId
          : (drivers.isNotEmpty ? drivers.first.id : null);
      if (!mounted) {
        return;
      }
      setState(() {
        _adminDrivers = drivers;
        _driverSkillsCatalog = skills.isEmpty ? _fallbackDriverSkills() : skills;
        _driverAudit = audit;
        _selectedDriverStatementId = resolvedStatementId;
      });
      unawaited(_saveAdminStatementPreferences());
      if (resolvedStatementId != null) {
        await _loadDriverStatementForAdmin(driverId: resolvedStatementId);
      } else if (mounted) {
        setState(() {
          _adminDriverAccountStatement = null;
        });
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo cargar registro de choferes: $e';
        if (_driverSkillsCatalog.isEmpty) {
          _driverSkillsCatalog = _fallbackDriverSkills();
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingDrivers = false;
          _loadingDriverAudit = false;
        });
      }
    }
  }

  Future<void> _toggleDriverSuspension(AdminDriver driver, bool suspended) async {
    try {
      final updated = await _apiClient.setAdminDriverSuspension(
        id: driver.id,
        suspended: suspended,
        reason: suspended ? 'Suspension operativa desde panel admin' : 'Reactivado por admin',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _adminDrivers = _adminDrivers
            .map((item) => item.id == updated.id ? updated : item)
            .toList(growable: false);
      });
      await _loadGovernanceData();
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo actualizar suspension de chofer: $e';
      });
    }
  }

  Future<void> _toggleCustomerSuspension(AdminCustomer customer, bool suspended) async {
    try {
      final updated = await _apiClient.setAdminCustomerSuspension(
        id: customer.id,
        suspended: suspended,
        reason: suspended ? 'Suspendido por seguridad operativa' : 'Reactivado por admin',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _adminCustomers = _adminCustomers
            .map((item) => item.id == updated.id ? updated : item)
            .toList(growable: false);
      });
      await _loadGovernanceData();
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo actualizar suspension de cliente: $e';
      });
    }
  }

  Future<void> _setIncidentStatus(AdminIncident incident, String status) async {
    try {
      final updated = await _apiClient.setAdminIncidentStatus(
        id: incident.id,
        status: status,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _adminIncidents = _adminIncidents
            .map((item) => item.id == updated.id ? updated : item)
            .toList(growable: false);
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo actualizar incidencia: $e';
      });
    }
  }

  Future<void> _loadDriverStatementForAdmin({String? driverId}) async {
    final id = (driverId ?? _selectedDriverStatementId ?? '').trim();
    if (id.isEmpty) {
      return;
    }

    if (mounted) {
      setState(() {
        _loadingDriverStatement = true;
      });
    }

    try {
      final statement = await _apiClient.getAdminDriverAccountStatement(
        driverId: id,
        windowDays: _adminStatementWindowDays,
        limit: _adminStatementQueryLimit,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _adminDriverAccountStatement = statement;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo cargar estado de cuenta del chofer: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingDriverStatement = false;
        });
      }
    }
  }

  Future<void> _registerDriverPayoutFromAdmin() async {
    final driverId = (_selectedDriverStatementId ?? '').trim();
    final amount = double.tryParse(_driverPayoutAmountController.text.trim()) ?? 0;
    if (driverId.isEmpty || amount <= 0) {
      setState(() {
        _error = 'Selecciona chofer y captura monto de liquidacion mayor a 0.';
      });
      return;
    }

    try {
      await _apiClient.registerAdminDriverPayout(
        driverId: driverId,
        amount: amount,
        note: _driverPayoutNoteController.text.trim(),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _success = 'Liquidacion registrada correctamente.';
        _driverPayoutAmountController.clear();
        _driverPayoutNoteController.clear();
      });
      await _loadDriverStatementForAdmin(driverId: driverId);
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo registrar liquidacion: $e';
      });
    }
  }

  Future<void> _registerDriverAdjustmentFromAdmin() async {
    final driverId = (_selectedDriverStatementId ?? '').trim();
    final amount = double.tryParse(_driverAdjustmentAmountController.text.trim()) ?? 0;
    if (driverId.isEmpty || amount <= 0) {
      setState(() {
        _error = 'Selecciona chofer y captura monto de ajuste mayor a 0.';
      });
      return;
    }

    try {
      await _apiClient.registerAdminDriverAdjustment(
        driverId: driverId,
        kind: _driverAdjustmentKind,
        amount: amount,
        note: _driverAdjustmentNoteController.text.trim(),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _success = 'Ajuste registrado correctamente.';
        _driverAdjustmentAmountController.clear();
        _driverAdjustmentNoteController.clear();
      });
      await _loadDriverStatementForAdmin(driverId: driverId);
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo registrar ajuste: $e';
      });
    }
  }

  Future<void> _exportDriverStatementCsvFromAdmin() async {
    final driverId = (_selectedDriverStatementId ?? '').trim();
    if (driverId.isEmpty) {
      return;
    }

    try {
      final csv = await _apiClient.exportDriverAccountStatementCsv(
        driverId: driverId,
        windowDays: _adminStatementWindowDays,
        limit: _adminStatementCsvLimit,
      );
      final downloaded = await downloadCsvFile(
        fileName: 'admin-driver-account-$driverId.csv',
        csv: csv,
      );
      if (downloaded) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Descarga de estado de cuenta iniciada.')),
          );
        }
        return;
      }
      await _showCsvPreviewDialog(title: 'CSV estado de cuenta chofer', csv: csv);
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo exportar estado de cuenta del chofer: $e';
      });
    }
  }

  String _ledgerTypeLabelForAdmin(String type) {
    switch (type) {
      case 'earn':
        return 'Ingreso bruto';
      case 'commission':
        return 'Comision';
      case 'payout':
        return 'Liquidacion';
      case 'adjustment_credit':
        return 'Ajuste a favor';
      case 'adjustment_debit':
        return 'Ajuste a cargo';
      default:
        return type;
    }
  }

  Future<void> _showCsvPreviewDialog({
    required String title,
    required String csv,
  }) async {
    if (!mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: SelectableText(
                csv,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                unawaited(Clipboard.setData(ClipboardData(text: csv)));
                Navigator.of(context).pop();
                if (mounted) {
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    const SnackBar(content: Text('CSV copiado al portapapeles.')),
                  );
                }
              },
              child: const Text('Copiar CSV'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cerrar'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _exportIncidentsCsv() async {
    try {
      final csv = await _apiClient.exportAdminIncidentsCsv(
        subjectType:
            _incidentFilterSubjectType == 'all' ? null : _incidentFilterSubjectType,
        severity: _incidentFilterSeverity == 'all' ? null : _incidentFilterSeverity,
        status: _incidentFilterStatus == 'all' ? null : _incidentFilterStatus,
        limit: 3000,
      );
      final downloaded = await downloadCsvFile(
        fileName: 'admin-incidents.csv',
        csv: csv,
      );
      if (downloaded) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Descarga de incidencias iniciada.')),
          );
        }
        return;
      }
      await _showCsvPreviewDialog(title: 'CSV de incidencias', csv: csv);
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo exportar incidencias CSV: $e';
      });
    }
  }

  Future<void> _exportSanctionsCsv() async {
    try {
      final csv = await _apiClient.exportAdminSanctionsCsv(
        subjectType:
            _sanctionFilterSubjectType == 'all' ? null : _sanctionFilterSubjectType,
        limit: 3000,
      );
      final downloaded = await downloadCsvFile(
        fileName: 'admin-sanctions.csv',
        csv: csv,
      );
      if (downloaded) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Descarga de sanciones iniciada.')),
          );
        }
        return;
      }
      await _showCsvPreviewDialog(title: 'CSV de sanciones', csv: csv);
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo exportar sanciones CSV: $e';
      });
    }
  }

  AdminDriver? _editingDriver() {
    final id = _editingDriverId;
    if (id == null) {
      return null;
    }
    for (final driver in _adminDrivers) {
      if (driver.id == id) {
        return driver;
      }
    }
    return null;
  }

  Set<String> _activeVehicleIdsByCategory(String category) {
    return _adminVehicles
        .where((vehicle) => vehicle.active && vehicle.category == category)
        .map((vehicle) => vehicle.id)
        .toSet();
  }

  void _clearDriverForm() {
    setState(() {
      _editingDriverId = null;
      _driverFirstNameController.clear();
      _driverLastNameController.clear();
      _driverPhoneController.clear();
      _driverEmailController.clear();
      _driverCurpController.clear();
      _driverRfcController.clear();
      _driverBirthDateController.clear();
      _driverAddressController.clear();
      _driverMunicipalityController.clear();
      _driverEmergencyNameController.clear();
      _driverEmergencyPhoneController.clear();
      _driverLicenseNumberController.clear();
      _driverLicenseTypeController.clear();
      _driverLicenseExpiryController.clear();
      _driverBloodTypeController.clear();
      _driverNotesController.clear();
      _driverCategory = 'pickup_mini';
      _driverActive = true;
      _driverAvailable = false;
      _selectedDriverVehicleIds = <String>{};
      _selectedDriverSkills = <String>{};
      _driverDocuments = {
        'ine': false,
        'licencia_vigente': false,
        'comprobante_domicilio': false,
        'carta_antecedentes': false,
        'contrato_firmado': false,
        'capacitacion_aprobada': false,
        'seguro_vigente': false,
        'examen_medico': false,
      };
    });
  }

  void _loadDriverToForm(AdminDriver driver) {
    setState(() {
      _editingDriverId = driver.id;
      _driverFirstNameController.text = driver.firstName;
      _driverLastNameController.text = driver.lastName;
      _driverPhoneController.text = driver.phone;
      _driverEmailController.text = driver.email;
      _driverCurpController.text = driver.curp;
      _driverRfcController.text = driver.rfc;
      _driverBirthDateController.text = driver.birthDate ?? '';
      _driverAddressController.text = driver.address;
      _driverMunicipalityController.text = driver.municipality;
      _driverEmergencyNameController.text = driver.emergencyContactName;
      _driverEmergencyPhoneController.text = driver.emergencyContactPhone;
      _driverLicenseNumberController.text = driver.licenseNumber;
      _driverLicenseTypeController.text = driver.licenseType;
      _driverLicenseExpiryController.text = driver.licenseExpiry ?? '';
      _driverBloodTypeController.text = driver.bloodType;
      _driverNotesController.text = driver.notes;
      _driverCategory = driver.category;
      _driverActive = driver.active;
      _driverAvailable = driver.available;
      _selectedDriverVehicleIds = driver.assignedVehicleIds.toSet();
      _selectedDriverSkills = driver.cargoSkills.toSet();
      _driverDocuments = {
        'ine': driver.documents['ine'] == true,
        'licencia_vigente': driver.documents['licencia_vigente'] == true,
        'comprobante_domicilio': driver.documents['comprobante_domicilio'] == true,
        'carta_antecedentes': driver.documents['carta_antecedentes'] == true,
        'contrato_firmado': driver.documents['contrato_firmado'] == true,
        'capacitacion_aprobada': driver.documents['capacitacion_aprobada'] == true,
        'seguro_vigente': driver.documents['seguro_vigente'] == true,
        'examen_medico': driver.documents['examen_medico'] == true,
      };
    });
  }

  Future<void> _saveDriverRecord() async {
    final firstName = _driverFirstNameController.text.trim();
    final lastName = _driverLastNameController.text.trim();
    final phone = _driverPhoneController.text.trim();
    final license = _driverLicenseNumberController.text.trim();
    if (firstName.isEmpty || lastName.isEmpty || phone.isEmpty || license.isEmpty) {
      setState(() {
        _error =
            'Completa nombre, apellido, telefono y licencia para registrar chofer.';
      });
      return;
    }

    final current = _editingDriver();
    final nowIso = DateTime.now().toIso8601String();
    final allowedIds = _activeVehicleIdsByCategory(_driverCategory);
    final selectedIds = _selectedDriverVehicleIds
        .where((id) => allowedIds.contains(id))
        .toList()
      ..sort();

    final payload = AdminDriver(
      id: _editingDriverId ?? '',
      firstName: firstName,
      lastName: lastName,
      phone: phone,
      email: _driverEmailController.text.trim(),
      curp: _driverCurpController.text.trim(),
      rfc: _driverRfcController.text.trim(),
      birthDate: _dateFieldValue(_driverBirthDateController.text),
      address: _driverAddressController.text.trim(),
      municipality: _driverMunicipalityController.text.trim(),
      emergencyContactName: _driverEmergencyNameController.text.trim(),
      emergencyContactPhone: _driverEmergencyPhoneController.text.trim(),
      licenseNumber: license,
      licenseType: _driverLicenseTypeController.text.trim(),
      licenseExpiry: _dateFieldValue(_driverLicenseExpiryController.text),
      bloodType: _driverBloodTypeController.text.trim(),
      category: _driverCategory,
      available: _driverAvailable,
      suspended: current?.suspended ?? false,
      suspensionReason: current?.suspensionReason ?? '',
      active: _driverActive,
      notes: _driverNotesController.text.trim(),
      assignedVehicleIds: selectedIds,
      cargoSkills: _selectedDriverSkills.toList()..sort(),
      documents: Map<String, bool>.from(_driverDocuments),
      rating: current?.rating ?? '0.00',
      ratingCount: current?.ratingCount ?? 0,
      createdAt: current?.createdAt ?? nowIso,
      updatedAt: nowIso,
    );

    setState(() {
      _savingDriver = true;
      _error = null;
      _success = null;
    });

    try {
      if (_editingDriverId == null) {
        await _apiClient.createAdminDriver(payload);
        if (mounted) {
          setState(() {
            _success = 'Chofer registrado correctamente.';
          });
        }
      } else {
        await _apiClient.updateAdminDriver(payload);
        if (mounted) {
          setState(() {
            _success = 'Chofer actualizado correctamente.';
          });
        }
      }
      _clearDriverForm();
      await _loadDrivers();
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo guardar chofer: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _savingDriver = false;
        });
      }
    }
  }

  Future<void> _toggleDriverStatus(AdminDriver driver, bool active) async {
    try {
      final updated = await _apiClient.setAdminDriverStatus(driver.id, active);
      if (!mounted) {
        return;
      }
      setState(() {
        _adminDrivers = _adminDrivers
            .map((item) => item.id == updated.id ? updated : item)
            .toList();
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo actualizar estatus del chofer: $e';
      });
    }
  }

  Future<void> _toggleDriverAvailability(AdminDriver driver, bool available) async {
    try {
      final updated = await _apiClient.setAdminDriverAvailability(driver.id, available);
      if (!mounted) {
        return;
      }
      setState(() {
        _adminDrivers = _adminDrivers
            .map((item) => item.id == updated.id ? updated : item)
            .toList();
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo actualizar disponibilidad del chofer: $e';
      });
    }
  }

  Future<void> _deleteDriver(AdminDriver driver) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Eliminar chofer'),
          content: Text('Se eliminara a ${driver.fullName}. Esta accion no se puede deshacer.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Eliminar'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    try {
      await _apiClient.deleteAdminDriver(driver.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _adminDrivers = _adminDrivers.where((item) => item.id != driver.id).toList();
        if (_editingDriverId == driver.id) {
          _clearDriverForm();
        }
        _success = 'Chofer eliminado.';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo eliminar chofer: $e';
      });
    }
  }

  int _driverUpdatedAtMs(AdminDriver driver) {
    final parsed = DateTime.tryParse(driver.updatedAt);
    if (parsed == null) {
      return 0;
    }
    return parsed.millisecondsSinceEpoch;
  }

  List<AdminDriver> _filteredDrivers() {
    final search = _driverSearchController.text.trim().toLowerCase();
    return _adminDrivers.where((driver) {
      if (_driverFilterCategory != 'all' && driver.category != _driverFilterCategory) {
        return false;
      }

      if (_driverFilterStatus == 'active' && !driver.active) {
        return false;
      }
      if (_driverFilterStatus == 'inactive' && driver.active) {
        return false;
      }

      if (search.isEmpty) {
        return true;
      }

      final haystack = [
        driver.fullName,
        driver.phone,
        driver.licenseNumber,
        driver.email,
      ].join(' ').toLowerCase();
      return haystack.contains(search);
    }).toList();
  }

  List<AdminDriver> _sortedFilteredDrivers() {
    final result = _filteredDrivers();
    result.sort((a, b) {
      switch (_driverSortBy) {
        case 'name_asc':
          return a.fullName.compareTo(b.fullName);
        case 'name_desc':
          return b.fullName.compareTo(a.fullName);
        case 'category_asc':
          return (_categoryLabels[a.category] ?? a.category)
              .compareTo(_categoryLabels[b.category] ?? b.category);
        case 'updated_asc':
          return _driverUpdatedAtMs(a).compareTo(_driverUpdatedAtMs(b));
        case 'updated_desc':
        default:
          return _driverUpdatedAtMs(b).compareTo(_driverUpdatedAtMs(a));
      }
    });
    return result;
  }

  String _vehicleNameById(String vehicleId) {
    for (final vehicle in _adminVehicles) {
      if (vehicle.id == vehicleId) {
        final short = vehicle.unitNumber.isNotEmpty
            ? vehicle.unitNumber
            : vehicle.plateNumber;
        return '${vehicle.plateNumber} ($short)';
      }
    }
    return vehicleId;
  }

  Widget _buildDriversSection() {
    const pageSize = 8;
    final categories = _categoryLabels.keys.toList();
    final assignableVehicles = _adminVehicles
        .where((vehicle) => vehicle.active && vehicle.category == _driverCategory)
        .toList();
    final filteredDrivers = _sortedFilteredDrivers();
    final totalDrivers = filteredDrivers.length;
    final pageCount = totalDrivers == 0 ? 1 : (totalDrivers / pageSize).ceil();
    final currentPage = math.max(0, math.min(_driverPage, pageCount - 1));
    final startIndex = totalDrivers == 0 ? 0 : currentPage * pageSize;
    final endIndex = totalDrivers == 0
        ? 0
        : math.min(startIndex + pageSize, totalDrivers);
    final pageDrivers = totalDrivers == 0
        ? const <AdminDriver>[]
        : filteredDrivers.sublist(startIndex, endIndex);
    final activeDrivers = _adminDrivers.where((driver) => driver.active).length;
    final availableDrivers = _adminDrivers.where((driver) => driver.available).length;
    final missingDocs = _driversMissingDocumentsCount();
    final expiringLicenses = _driversLicenseExpiringCount();
    final withoutVehicle = _driversWithoutVehicleCount();

    return Column(
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            SizedBox(
              width: 220,
              child: _buildAdminMetric(
                icon: Icons.badge_outlined,
                label: 'Choferes activos',
                value: '$activeDrivers',
                color: const Color(0xFF1D4ED8),
              ),
            ),
            SizedBox(
              width: 220,
              child: _buildAdminMetric(
                icon: Icons.wifi_tethering,
                label: 'Disponibles',
                value: '$availableDrivers',
                color: const Color(0xFF15803D),
              ),
            ),
            SizedBox(
              width: 220,
              child: _buildAdminMetric(
                icon: Icons.assignment_late_outlined,
                label: 'Docs incompletos',
                value: '$missingDocs',
                color: const Color(0xFFB45309),
              ),
            ),
            SizedBox(
              width: 220,
              child: _buildAdminMetric(
                icon: Icons.event_busy_outlined,
                label: 'Licencias por vencer',
                value: '$expiringLicenses',
                color: const Color(0xFF7C2D12),
              ),
            ),
            SizedBox(
              width: 220,
              child: _buildAdminMetric(
                icon: Icons.link_off_outlined,
                label: 'Sin vehiculo',
                value: '$withoutVehicle',
                color: const Color(0xFF7C3AED),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _editingDriverId == null
                            ? 'Registro de choferes'
                            : 'Editar chofer',
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w800),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _clearDriverForm,
                      icon: const Icon(Icons.cleaning_services_outlined),
                      label: const Text('Limpiar'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _vehicleTextField(_driverFirstNameController, 'Nombre *'),
                    _vehicleTextField(_driverLastNameController, 'Apellidos *'),
                    _vehicleTextField(_driverPhoneController, 'Telefono *',
                        keyboardType: TextInputType.phone),
                    _vehicleTextField(_driverEmailController, 'Correo',
                        keyboardType: TextInputType.emailAddress),
                    _vehicleTextField(_driverCurpController, 'CURP'),
                    _vehicleTextField(_driverRfcController, 'RFC'),
                    _vehicleTextField(_driverBirthDateController,
                        'Fecha nacimiento',
                        hint: 'YYYY-MM-DD'),
                    _vehicleTextField(_driverAddressController, 'Direccion', width: 510),
                    _vehicleTextField(_driverMunicipalityController, 'Municipio'),
                    _vehicleTextField(
                        _driverEmergencyNameController, 'Contacto emergencia'),
                    _vehicleTextField(
                        _driverEmergencyPhoneController, 'Telefono emergencia',
                        keyboardType: TextInputType.phone),
                    _vehicleTextField(_driverLicenseNumberController,
                        'No. licencia *'),
                    _vehicleTextField(_driverLicenseTypeController,
                        'Tipo de licencia',
                        hint: 'B, C, E, Federal'),
                    _vehicleTextField(_driverLicenseExpiryController,
                        'Vigencia licencia',
                        hint: 'YYYY-MM-DD'),
                    _vehicleTextField(_driverBloodTypeController, 'Tipo sanguineo'),
                    SizedBox(
                      width: 250,
                      child: DropdownButtonFormField<String>(
                        initialValue: _driverCategory,
                        decoration: InputDecoration(
                          labelText: 'Categoria operativa *',
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12)),
                          isDense: true,
                        ),
                        items: categories
                            .map(
                              (category) => DropdownMenuItem(
                                value: category,
                                child: Text(_categoryLabels[category] ?? category),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _driverCategory = value;
                            final allowedIds = _activeVehicleIdsByCategory(value);
                            _selectedDriverVehicleIds = _selectedDriverVehicleIds
                                .where((id) => allowedIds.contains(id))
                                .toSet();
                          });
                        },
                      ),
                    ),
                    _vehicleTextField(_driverNotesController, 'Notas operativas',
                        width: 510, maxLines: 2),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Documentacion requerida',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _driverDocuments.entries.map((entry) {
                    return FilterChip(
                      label: Text(_driverDocumentLabel(entry.key)),
                      selected: entry.value,
                      onSelected: (selected) {
                        setState(() {
                          _driverDocuments[entry.key] = selected;
                        });
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Habilidades de carga',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                if (_driverSkillsCatalog.isEmpty)
                  const Text('No hay habilidades configuradas por el sistema.')
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _driverSkillsCatalog.map((skill) {
                      final selected = _selectedDriverSkills.contains(skill);
                      return FilterChip(
                        label: Text(_driverSkillLabel(skill)),
                        selected: selected,
                        onSelected: (value) {
                          setState(() {
                            if (value) {
                              _selectedDriverSkills.add(skill);
                            } else {
                              _selectedDriverSkills.remove(skill);
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
                const SizedBox(height: 12),
                const Text(
                  'Vehiculos asignados (uno o mas)',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                if (assignableVehicles.isEmpty)
                  const Text('No hay vehiculos activos disponibles en esta categoria.')
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: assignableVehicles.map((vehicle) {
                      final selected = _selectedDriverVehicleIds.contains(vehicle.id);
                      return FilterChip(
                        label: Text('${vehicle.plateNumber} · ${vehicle.unitNumber.isEmpty ? 'sin unidad' : vehicle.unitNumber}'),
                        selected: selected,
                        onSelected: (value) {
                          setState(() {
                            if (value) {
                              _selectedDriverVehicleIds.add(vehicle.id);
                            } else {
                              _selectedDriverVehicleIds.remove(vehicle.id);
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 18,
                  runSpacing: 8,
                  children: [
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _driverActive,
                      title: const Text('Chofer activo'),
                      onChanged: (value) {
                        setState(() {
                          _driverActive = value ?? true;
                        });
                      },
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      SizedBox(
                        width: 230,
                        child: DropdownButtonFormField<int>(
                          initialValue: _adminStatementQueryLimit,
                          decoration: const InputDecoration(
                            isDense: true,
                            labelText: 'Limite de consulta',
                          ),
                          items: _adminStatementLimitOptions
                              .map((value) => DropdownMenuItem<int>(
                                    value: value,
                                    child: Text('$value movimientos'),
                                  ))
                              .toList(growable: false),
                          onChanged: (value) {
                            if (value == null) {
                              return;
                            }
                            setState(() {
                              _adminStatementQueryLimit = value;
                            });
                            unawaited(_saveAdminStatementPreferences());
                            _loadDriverStatementForAdmin();
                          },
                        ),
                      ),
                      SizedBox(
                        width: 230,
                        child: DropdownButtonFormField<int>(
                          initialValue: _adminStatementCsvLimit,
                          decoration: const InputDecoration(
                            isDense: true,
                            labelText: 'Limite de exportacion CSV',
                          ),
                          items: _adminStatementCsvLimitOptions
                              .map((value) => DropdownMenuItem<int>(
                                    value: value,
                                    child: Text('$value movimientos'),
                                  ))
                              .toList(growable: false),
                          onChanged: (value) {
                            if (value == null) {
                              return;
                            }
                            setState(() {
                              _adminStatementCsvLimit = value;
                            });
                            unawaited(_saveAdminStatementPreferences());
                          },
                        ),
                      ),
                    ],
                  ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _driverAvailable,
                      title: const Text('Disponible para asignacion'),
                      onChanged: (value) {
                        setState(() {
                          _driverAvailable = value ?? false;
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _savingDriver ? null : _saveDriverRecord,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(
                    _savingDriver
                        ? 'Guardando...'
                        : (_editingDriverId == null
                            ? 'Registrar chofer'
                            : 'Actualizar chofer'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Choferes registrados',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      onPressed: _loadingDrivers ? null : _loadDrivers,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    SizedBox(
                      width: 300,
                      child: TextField(
                        controller: _driverSearchController,
                        onChanged: (_) => setState(() {
                          _driverPage = 0;
                        }),
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: 'Buscar nombre, telefono o licencia',
                          prefixIcon: const Icon(Icons.search),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 240,
                      child: DropdownButtonFormField<String>(
                        initialValue: _driverFilterCategory,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: 'Categoria',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: 'all',
                            child: Text('Todas las categorias'),
                          ),
                          ...categories.map(
                            (category) => DropdownMenuItem(
                              value: category,
                              child: Text(_categoryLabels[category] ?? category),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _driverFilterCategory = value;
                            _driverPage = 0;
                          });
                        },
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<String>(
                        initialValue: _driverFilterStatus,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: 'Estatus',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'all', child: Text('Todos')),
                          DropdownMenuItem(value: 'active', child: Text('Activos')),
                          DropdownMenuItem(value: 'inactive', child: Text('Inactivos')),
                        ],
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _driverFilterStatus = value;
                            _driverPage = 0;
                          });
                        },
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<String>(
                        initialValue: _driverSortBy,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: 'Ordenar por',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'updated_desc',
                            child: Text('Mas recientes'),
                          ),
                          DropdownMenuItem(
                            value: 'updated_asc',
                            child: Text('Mas antiguos'),
                          ),
                          DropdownMenuItem(value: 'name_asc', child: Text('Nombre A-Z')),
                          DropdownMenuItem(value: 'name_desc', child: Text('Nombre Z-A')),
                          DropdownMenuItem(
                            value: 'category_asc',
                            child: Text('Categoria A-Z'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _driverSortBy = value;
                            _driverPage = 0;
                          });
                        },
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () {
                        setState(() {
                          _driverSearchController.clear();
                          _driverFilterCategory = 'all';
                          _driverFilterStatus = 'all';
                          _driverSortBy = 'updated_desc';
                          _driverPage = 0;
                        });
                      },
                      icon: const Icon(Icons.filter_alt_off_outlined),
                      label: const Text('Limpiar'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Resultados: ${filteredDrivers.length} de ${_adminDrivers.length}',
                  style: TextStyle(
                    color: Colors.grey.shade700,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (totalDrivers > 0) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        'Mostrando ${startIndex + 1}-$endIndex de $totalDrivers',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Pagina anterior',
                        onPressed: currentPage <= 0
                            ? null
                            : () {
                                setState(() {
                                  _driverPage = currentPage - 1;
                                });
                              },
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text('${currentPage + 1}/$pageCount'),
                      IconButton(
                        tooltip: 'Pagina siguiente',
                        onPressed: currentPage >= pageCount - 1
                            ? null
                            : () {
                                setState(() {
                                  _driverPage = currentPage + 1;
                                });
                              },
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                if (_loadingDrivers)
                  const LinearProgressIndicator()
                else if (pageDrivers.isEmpty)
                  KarrytEmptyState(
                    icon: Icons.people_outline,
                    title: 'Sin choferes registrados',
                    subtitle: 'Agrega el primer chofer para comenzar.',
                    action: () => setState(() => _editingDriverId = null),
                    actionLabel: 'Registrar chofer',
                  )
                else
                  ...pageDrivers.map((driver) {
                    final categoryLabel =
                        _categoryLabels[driver.category] ?? driver.category;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFE3E8F2)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${driver.fullName} • $categoryLabel',
                                    style: const TextStyle(fontWeight: FontWeight.w700),
                                  ),
                                ),
                                Switch(
                                  value: driver.active,
                                  onChanged: (value) =>
                                      _toggleDriverStatus(driver, value),
                                ),
                                IconButton(
                                  tooltip: driver.suspended
                                      ? 'Quitar suspension'
                                      : 'Suspender chofer',
                                  onPressed: () => _toggleDriverSuspension(
                                      driver, !driver.suspended),
                                  icon: Icon(
                                    driver.suspended
                                        ? Icons.shield_outlined
                                        : Icons.gpp_bad_outlined,
                                    color: driver.suspended
                                        ? Colors.green.shade700
                                        : Colors.red.shade700,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Editar',
                                  onPressed: () => _loadDriverToForm(driver),
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                                IconButton(
                                  tooltip: 'Eliminar',
                                  onPressed: () => _deleteDriver(driver),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text('Telefono: ${driver.phone} • Licencia: ${driver.licenseNumber}'),
                            Text('Correo: ${driver.email.isEmpty ? 'N/D' : driver.email}'),
                            if (driver.suspended)
                              Text(
                                'Suspendido: ${driver.suspensionReason.isEmpty ? 'sin motivo' : driver.suspensionReason}',
                                style: TextStyle(
                                  color: Colors.red.shade700,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            Row(
                              children: [
                                const Text('Disponible:'),
                                Switch(
                                  value: driver.available,
                                  onChanged: (value) =>
                                      _toggleDriverAvailability(driver, value),
                                ),
                              ],
                            ),
                            if (driver.assignedVehicleIds.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: driver.assignedVehicleIds
                                    .map((id) => Chip(
                                          visualDensity: VisualDensity.compact,
                                          label: Text(
                                            _vehicleNameById(id),
                                            style: const TextStyle(fontSize: 12),
                                          ),
                                        ))
                                    .toList(),
                              ),
                            ],
                            if (driver.cargoSkills.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: driver.cargoSkills
                                    .map((skill) => Chip(
                                          visualDensity: VisualDensity.compact,
                                          label: Text(
                                            _driverSkillLabel(skill),
                                            style: const TextStyle(fontSize: 12),
                                          ),
                                        ))
                                    .toList(),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Bitacora de choferes',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                if (_loadingDriverAudit)
                  const LinearProgressIndicator()
                else if (_driverAudit.isEmpty)
                  const Text('Sin movimientos registrados aun.')
                else
                  ..._driverAudit.take(25).map(
                    (event) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.history, size: 18),
                      title: Text(
                        '${_driverAuditActionLabel(event.action)} · ${event.details.isEmpty ? 'Sin detalle' : event.details}',
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        '${formatScheduledAtLocal(event.createdAt)} · ${event.actor}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCatalogManagerCard() {
    final catalogItems = _adminCatalogItems[_selectedCatalogKey] ?? const <String>[];
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Catalogos Administrables',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
              'Agrega nuevos campos/habilidades que usara la plataforma sin modificar codigo.',
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 280,
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedCatalogKey,
                    decoration: InputDecoration(
                      labelText: 'Catalogo',
                      isDense: true,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    items: _catalogLabels.entries
                        .map(
                          (entry) => DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        _selectedCatalogKey = value;
                      });
                    },
                  ),
                ),
                SizedBox(
                  width: 340,
                  child: TextField(
                    controller: _catalogEntryController,
                    decoration: InputDecoration(
                      labelText: 'Nueva entrada',
                      hintText: 'ej: manejo_tablaroca_panel_yezo',
                      isDense: true,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _savingCatalogEntry ? null : _addCatalogEntryFromAdmin,
                  icon: const Icon(Icons.add),
                  label: Text(_savingCatalogEntry ? 'Guardando...' : 'Agregar'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Entradas actuales: ${catalogItems.length}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (catalogItems.isEmpty)
              const Text('Aun no hay entradas en este catalogo.')
            else
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                proxyDecorator: (child, index, animation) {
                  return AnimatedBuilder(
                    animation: animation,
                    child: child,
                    builder: (context, proxyChild) {
                      final eased = Curves.easeOutBack.transform(animation.value);
                      final scale = 1 + (0.035 * eased);
                      return Transform.scale(
                        scale: scale,
                        child: Material(
                          elevation: 8 + (12 * eased),
                          shadowColor: const Color(0x331F2937),
                          borderRadius: BorderRadius.circular(12),
                          color: Colors.white,
                          child: proxyChild,
                        ),
                      );
                    },
                  );
                },
                itemCount: catalogItems.length,
                onReorder: (oldIndex, newIndex) =>
                    _reorderCatalogByDragFromAdmin(
                  oldIndex: oldIndex,
                  newIndex: newIndex,
                  catalogItems: catalogItems,
                ),
                itemBuilder: (context, index) {
                  final item = catalogItems[index];
                  final canMoveUp = index > 0;
                  final canMoveDown = index < catalogItems.length - 1;
                  final isJustMoved = _recentlyReorderedCatalogItem == item;
                  return AnimatedContainer(
                    key: ValueKey('catalog-item-$item'),
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      color: isJustMoved
                          ? const Color(0x140F4CFF)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      title: Text(
                        _selectedCatalogKey == 'driver_skills'
                            ? _driverSkillLabel(item)
                            : (_selectedCatalogKey == 'driver_documents'
                                ? _driverDocumentLabel(item)
                                : _vehicleAccessoryLabel(item)),
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        item,
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                      trailing: Wrap(
                        spacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          IconButton(
                            tooltip: 'Subir',
                            onPressed: _savingCatalogEntry || !canMoveUp
                                ? null
                                : () => _reorderCatalogEntryFromAdmin(
                                      item: item,
                                      direction: 'up',
                                    ),
                            icon: const Icon(Icons.arrow_upward_outlined),
                          ),
                          IconButton(
                            tooltip: 'Bajar',
                            onPressed: _savingCatalogEntry || !canMoveDown
                                ? null
                                : () => _reorderCatalogEntryFromAdmin(
                                      item: item,
                                      direction: 'down',
                                    ),
                            icon: const Icon(Icons.arrow_downward_outlined),
                          ),
                          IconButton(
                            tooltip: 'Editar',
                            onPressed: _savingCatalogEntry
                                ? null
                                : () => _renameCatalogEntryFromAdmin(item),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            tooltip: 'Eliminar',
                            onPressed: _savingCatalogEntry
                                ? null
                                : () => _deleteCatalogEntryFromAdmin(item),
                            icon: const Icon(Icons.delete_outline),
                          ),
                          ReorderableDragStartListener(
                            index: index,
                            enabled: !_savingCatalogEntry,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              child: Icon(
                                Icons.drag_indicator,
                                color: _savingCatalogEntry
                                    ? Colors.grey.shade400
                                    : Colors.grey.shade700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsSection() {
    return Column(
      children: [
        _buildCatalogManagerCard(),
        const SizedBox(height: 12),
        _buildGeneralCard(),
        const SizedBox(height: 12),
        ..._categoryFields.keys.map(_buildCategoryCard),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.save),
          label: Text(_saving ? 'Guardando...' : 'Guardar configuracion'),
        ),
      ],
    );
  }

  Widget _buildModuleContent() {
    switch (_selectedModule) {
      case _AdminModule.overview:
        return _buildOverviewSection();
      case _AdminModule.operations:
        return _buildOperationsSection();
      case _AdminModule.finance:
        return _buildFinanceSection();
      case _AdminModule.apiCosts:
        return _buildApiCostsSection();
      case _AdminModule.vehicles:
        return _buildVehiclesSection();
      case _AdminModule.drivers:
        return _buildDriversSection();
      case _AdminModule.settings:
        return _buildSettingsSection();
    }
  }

  Widget _compactNumberField(TextEditingController controller, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }

  VisualDensity get _adminDensity =>
      _adminDensityCompact ? VisualDensity.compact : VisualDensity.standard;

  String _shortDateLabel(DateTime? value) {
    if (value == null) {
      return 'Sin filtro';
    }
    final day = value.day.toString().padLeft(2, '0');
    final month = value.month.toString().padLeft(2, '0');
    return '$day/$month/${value.year}';
  }

  Future<void> _pickStartDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _filterStartDate ?? _filterEndDate ?? now,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 2),
      helpText: 'Fecha inicial',
    );

    if (picked == null) {
      return;
    }

    setState(() {
      _filterStartDate = picked;
      if (_filterEndDate != null && _filterEndDate!.isBefore(picked)) {
        _filterEndDate = picked;
      }
    });
  }

  Future<void> _pickEndDate() async {
    final now = DateTime.now();
    final initial = _filterEndDate ?? _filterStartDate ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 2),
      helpText: 'Fecha final',
    );

    if (picked == null) {
      return;
    }

    setState(() {
      _filterEndDate = picked;
      if (_filterStartDate != null && _filterStartDate!.isAfter(picked)) {
        _filterStartDate = picked;
      }
    });
  }

  void _clearAdvancedFilters() {
    setState(() {
      _filterStartDate = null;
      _filterEndDate = null;
      _filterMunicipality = 'all';
      _filterCategory = 'all';
    });
  }

  String _csvField(String value) {
    final escaped = value.replaceAll('"', '""');
    return '"$escaped"';
  }

  String _buildFilteredRidesCsv(List<RideData> rides) {
    final rows = <List<String>>[
      [
        'id',
        'estado',
        'categoria',
        'programado_o_solicitado',
        'chofer',
        'origen',
        'destino',
        'distancia_km',
        'tarifa_mxn',
      ],
      ...rides.map((ride) {
        final date = _rideReferenceDate(ride);
        return [
          ride.id,
          statusToLabel(ride.status),
          _categoryLabels[ride.category] ?? ride.category,
          date != null ? formatLocalDateTime(date) : 'sin fecha',
          ride.driver?.name ?? 'sin asignar',
          ride.pickup,
          ride.dropoff,
          ride.tripDistanceKm.toStringAsFixed(2),
          ride.fareEstimate.toStringAsFixed(2),
        ];
      }),
    ];

    return rows
        .map((row) => row.map(_csvField).join(','))
        .join('\n');
  }

  String _buildFilteredSummary(List<RideData> rides) {
    final active = _countRidesByStatus({
      'searching',
      'scheduled',
      'accepted',
      'driver_arriving',
      'in_progress'
    }, rides: rides);
    final completed = _countRidesByStatus({'completed'}, rides: rides);
    final incidents = _countRidesByStatus({'cancelled', 'no_drivers'}, rides: rides);
    final revenue = _totalRevenue(rides: rides);
    final avgTicket = _avgTicket(rides: rides);
    final municipality = _filterMunicipality == 'all' ? 'todos' : _filterMunicipality;
    final category = _filterCategory == 'all'
        ? 'todas'
        : (_categoryLabels[_filterCategory] ?? _filterCategory);

    return [
      'Reporte Admin Karryt (filtros activos)',
      'Periodo: ${_shortDateLabel(_filterStartDate)} - ${_shortDateLabel(_filterEndDate)}',
      'Municipio: $municipality',
      'Categoria: $category',
      'Total viajes filtrados: ${rides.length}',
      'Activos: $active',
      'Completados: $completed',
      'Incidencias: $incidents',
      'Ingresos completados: ${_money(revenue)}',
      'Ticket promedio: ${_money(avgTicket)}',
    ].join('\n');
  }

  Future<void> _copyFilteredCsvToClipboard() async {
    final rides = _filteredRides();
    final csv = _buildFilteredRidesCsv(rides);
    await Clipboard.setData(ClipboardData(text: csv));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          rides.isEmpty
              ? 'CSV copiado con encabezados. No hay viajes con filtros actuales.'
              : 'CSV filtrado copiado (${rides.length} viajes). Puedes pegarlo en Excel.',
        ),
      ),
    );
  }

  Future<void> _copyFilteredSummaryToClipboard() async {
    final rides = _filteredRides();
    final summary = _buildFilteredSummary(rides);
    await Clipboard.setData(ClipboardData(text: summary));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Resumen ejecutivo copiado al portapapeles.'),
      ),
    );
  }

  Future<void> _showAdminCommandMenu() async {
    if (!mounted) {
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Actualizar consola (Ctrl+R)'),
                onTap: () {
                  Navigator.of(context).pop();
                  _load();
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings_suggest_outlined),
                title: const Text('Ir a Operaciones (Ctrl+2)'),
                onTap: () {
                  Navigator.of(context).pop();
                  setState(() {
                    _selectedModule = _AdminModule.operations;
                  });
                },
              ),
              ListTile(
                leading: const Icon(Icons.local_shipping_outlined),
                title: const Text('Ir a Choferes (Ctrl+3)'),
                onTap: () {
                  Navigator.of(context).pop();
                  setState(() {
                    _selectedModule = _AdminModule.drivers;
                  });
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAdvancedFiltersCard() {
    final municipalities = _availableMunicipalities().toList()..sort();
    final categoryOptions = _categoryFields.keys.toList()..sort();

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Filtros avanzados',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: _pickStartDate,
                  icon: const Icon(Icons.event_available_outlined),
                  label: Text('Desde: ${_shortDateLabel(_filterStartDate)}'),
                ),
                OutlinedButton.icon(
                  onPressed: _pickEndDate,
                  icon: const Icon(Icons.event_busy_outlined),
                  label: Text('Hasta: ${_shortDateLabel(_filterEndDate)}'),
                ),
                SizedBox(
                  width: 250,
                  child: DropdownButtonFormField<String>(
                    initialValue: _filterMunicipality,
                    decoration: const InputDecoration(
                      labelText: 'Municipio',
                      prefixIcon: Icon(Icons.location_city),
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: 'all',
                        child: Text('Todos los municipios'),
                      ),
                      ...municipalities.map(
                        (municipality) => DropdownMenuItem(
                          value: municipality,
                          child: Text(municipality),
                        ),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        _filterMunicipality = value;
                      });
                    },
                  ),
                ),
                SizedBox(
                  width: 250,
                  child: DropdownButtonFormField<String>(
                    initialValue: _filterCategory,
                    decoration: const InputDecoration(
                      labelText: 'Categoria',
                      prefixIcon: Icon(Icons.local_shipping_outlined),
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: 'all',
                        child: Text('Todas las categorias'),
                      ),
                      ...categoryOptions.map(
                        (category) => DropdownMenuItem(
                          value: category,
                          child: Text(_categoryLabels[category] ?? category),
                        ),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        _filterCategory = value;
                      });
                    },
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: _clearAdvancedFilters,
                  icon: const Icon(Icons.filter_alt_off_outlined),
                  label: const Text('Limpiar filtros'),
                ),
                FilledButton.icon(
                  onPressed: _copyFilteredCsvToClipboard,
                  icon: const Icon(Icons.table_chart_outlined),
                  label: const Text('Copiar CSV filtrado'),
                ),
                OutlinedButton.icon(
                  onPressed: _copyFilteredSummaryToClipboard,
                  icon: const Icon(Icons.summarize_outlined),
                  label: const Text('Copiar resumen'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyR, control: true):
            _KarrytShortcutIntent('adminRefresh'),
        SingleActivator(LogicalKeyboardKey.digit2, control: true):
            _KarrytShortcutIntent('adminOps'),
        SingleActivator(LogicalKeyboardKey.digit3, control: true):
            _KarrytShortcutIntent('adminDrivers'),
        SingleActivator(LogicalKeyboardKey.slash, shift: true):
            _KarrytShortcutIntent('adminCommands'),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _KarrytShortcutIntent: CallbackAction<_KarrytShortcutIntent>(
            onInvoke: (intent) {
              switch (intent.command) {
                case 'adminRefresh':
                  _load();
                  break;
                case 'adminOps':
                  setState(() {
                    _selectedModule = _AdminModule.operations;
                  });
                  break;
                case 'adminDrivers':
                  setState(() {
                    _selectedModule = _AdminModule.drivers;
                  });
                  break;
                case 'adminCommands':
                  _showAdminCommandMenu();
                  break;
              }
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
      backgroundColor: const Color(0xFFF4F6FB),
      appBar: AppBar(
        elevation: 4,
        shadowColor: Colors.black.withValues(alpha: 0.18),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF7C2D12), Color(0xFF9A3412)],
            ),
          ),
        ),
        title: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.admin_panel_settings,
                color: Colors.white,
                size: 26,
              ),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Consola Admin',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
                Text('Control operativo Karryt',
                    style: TextStyle(fontSize: 11, color: Colors.white70)),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: _adminDensityCompact ? 'Cómodo' : 'Compacto',
            onPressed: () {
              setState(() {
                _adminDensityCompact = !_adminDensityCompact;
              });
              unawaited(_saveAdminDensityPreference(_adminDensityCompact));
            },
            icon: Icon(_adminDensityCompact
                ? Icons.unfold_less_outlined
                : Icons.unfold_more_outlined),
          ),
          IconButton(
            tooltip: 'Comandos y atajos',
            onPressed: _showAdminCommandMenu,
            icon: const Icon(Icons.keyboard_command_key),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null) ...[
                    Text(_error!, style: TextStyle(color: Colors.red.shade700)),
                    const SizedBox(height: 8),
                  ],
                  if (_success != null) ...[
                    Text(_success!,
                        style: TextStyle(color: Colors.green.shade700)),
                    const SizedBox(height: 8),
                  ],
                  _buildAdminModuleMenu(),
                  const SizedBox(height: 12),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0.1, 0),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: _buildModuleContent(),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGeneralCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Parametros globales',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('Ajusta costos, tiempos y cobertura.',
                style: TextStyle(color: Colors.grey.shade600)),
            const SizedBox(height: 10),
            _numberField('foraneoThresholdKm', 'Umbral foraneo (km)'),
            _numberField('includedKmInStartFare', 'Km incluidos en arranque'),
            _numberField('foraneoMultiplier', 'Multiplicador foraneo'),
            _numberField('defaultLoadingMinutes', 'Minutos carga'),
            _numberField('defaultTransferMinutes', 'Minutos traslado'),
            _numberField('defaultUnloadingMinutes', 'Minutos descarga'),
            _numberField(
                'loadPersonnelUnitCost', 'Costo unitario personal carga'),
            _numberField(
                'unloadPersonnelUnitCost', 'Costo unitario personal descarga'),
            TextField(
              controller: _fields['municipalities'],
              decoration: const InputDecoration(
                labelText: 'Municipios (separados por coma)',
                prefixIcon: Icon(Icons.location_city),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMonitoringCard({required List<RideData> rides}) {
    final active = _countRidesByStatus({
      'searching',
      'scheduled',
      'accepted',
      'driver_arriving',
      'in_progress'
    }, rides: rides);
    final completed = _countRidesByStatus({'completed'}, rides: rides);
    final incidents = _countRidesByStatus({'cancelled', 'no_drivers'}, rides: rides);

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Monitoreo de viajes',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  onPressed: _loadingRides ? null : _loadRides,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Actualizar viajes',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                SizedBox(
                  width: 210,
                  child: _buildAdminMetric(
                    icon: Icons.local_shipping_outlined,
                    label: 'Activos',
                    value: '$active',
                    color: const Color(0xFF1D4ED8),
                  ),
                ),
                SizedBox(
                  width: 210,
                  child: _buildAdminMetric(
                    icon: Icons.check_circle_outline,
                    label: 'Completados',
                    value: '$completed',
                    color: const Color(0xFF15803D),
                  ),
                ),
                SizedBox(
                  width: 210,
                  child: _buildAdminMetric(
                    icon: Icons.warning_amber_rounded,
                    label: 'Incidencias',
                    value: '$incidents',
                    color: const Color(0xFFB45309),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loadingRides)
              KarrytSkeletonLoader(
                isLoading: true,
                child: Column(
                  children: [
                    const RideCardSkeleton(),
                    const SizedBox(height: 8),
                    const RideCardSkeleton(),
                    const SizedBox(height: 8),
                    const RideCardSkeleton(),
                  ],
                ),
              )
            else if (rides.isEmpty)
              KarrytEmptyState(
                icon: Icons.delivery_dining_outlined,
                title: 'Sin viajes aún',
                subtitle: 'Cuando aceptes un viaje, aparecerá aquí.',
              )
            else
              ...rides.take(20).map(
                    (ride) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFE3E8F2)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Viaje ${ride.id}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 4),
                            Text('Estado: ${statusToLabel(ride.status)}'),
                            if (ride.scheduledAt != null)
                              Text(
                                  'Programado: ${formatScheduledAtLocal(ride.scheduledAt)}'),
                            Text(
                                'Chofer: ${ride.driver?.name ?? 'Sin asignar'}'),
                            Text('Origen: ${ride.pickup}'),
                            Text('Destino: ${ride.dropoff}'),
                          ],
                        ),
                      ),
                    ),
                  ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryCard(String category) {
    final controls = _categoryFields[category]!;
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _categoryLabels[category] ?? category,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controls['startFare'],
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Tarifa arranque',
                  prefixIcon: Icon(Icons.local_offer_outlined)),
            ),
            TextField(
              controller: controls['extraKmRate'],
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Tarifa por km extra',
                  prefixIcon: Icon(Icons.straighten)),
            ),
            TextField(
              controller: controls['operationalPerMinRate'],
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Tarifa por minuto operacional',
                  prefixIcon: Icon(Icons.schedule)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _numberField(String key, String label) {
    return TextField(
      controller: _fields[key],
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label),
    );
  }
}

class DriverScreen extends StatefulWidget {
  const DriverScreen({super.key});

  @override
  State<DriverScreen> createState() => _DriverScreenState();
}

class _DriverScreenState extends State<DriverScreen> {
  late final ApiClient _apiClient;
  Timer? _autoRefresh;
  StreamSubscription<String>? _pushTokenRefreshSubscription;

  static const String _scheduledWindowPrefsKey = 'driver.scheduledWindowHours';
  static const String _driverPushTokenPrefsPrefix = 'driver.pushToken.registered';
  static const List<int> _windowOptions = [6, 12, 24, 48];
  static const List<int> _statementWindowOptions = [7, 15, 30, 60, 90];
  static const String _driverPushTokenFromEnv =
      String.fromEnvironment('DRIVER_PUSH_TOKEN', defaultValue: '');
  static const int _defaultScheduledWindowHours = int.fromEnvironment(
      'SCHEDULED_VISIBILITY_WINDOW_HOURS',
      defaultValue: 24);

  List<DriverDetail> _drivers = [];
  List<RideData> _rides = [];
  List<DriverRatingEntry> _ratings = [];
  DriverAccountStatement? _accountStatement;
  Map<String, List<String>> _incidentCatalog = const {};
  String? _selectedDriverId;
  late final TextEditingController _customWindowController;
  bool _activeOnly = true;
  bool _loading = true;
  bool _loadingRatings = false;
  bool _loadingAccountStatement = false;
  String? _replyingRatingId;
  String? _busyRideActionId;
  String? _error;
  final Set<String> _alertedRideIds = <String>{};
  int _scheduledWindowHours = _defaultScheduledWindowHours;
  int _statementWindowDays = 30;
  String? _cachedAutoPushToken;

  @override
  void initState() {
    super.initState();
    _apiClient = ApiClient(resolveApiBaseUrl());
    _customWindowController =
        TextEditingController(text: '$_scheduledWindowHours');
    _initializeDriverScreen();
    unawaited(_initializePushTokenAutoRefresh());
    _autoRefresh = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) {
        _loadRides();
      }
    });
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    _pushTokenRefreshSubscription?.cancel();
    _customWindowController.dispose();
    super.dispose();
  }

  Future<void> _initializePushTokenAutoRefresh() async {
    if (_driverPushTokenFromEnv.trim().isNotEmpty) {
      return;
    }

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }

      _pushTokenRefreshSubscription?.cancel();
      _pushTokenRefreshSubscription =
          FirebaseMessaging.instance.onTokenRefresh.listen((token) {
        final normalized = token.trim();
        if (normalized.isEmpty) {
          return;
        }
        _cachedAutoPushToken = normalized;
        unawaited(_registerDriverPushTokenIfAvailable());
      });
    } catch (_) {
      // Si Firebase no esta configurado, se omite registro automatico.
    }
  }

  Future<String?> _resolveDriverPushToken() async {
    final fromEnv = _driverPushTokenFromEnv.trim();
    if (fromEnv.isNotEmpty) {
      return fromEnv;
    }

    if (_cachedAutoPushToken != null && _cachedAutoPushToken!.isNotEmpty) {
      return _cachedAutoPushToken;
    }

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }

      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        return null;
      }

      final token = await FirebaseMessaging.instance.getToken(
        vapidKey: kIsWeb && _firebaseWebVapidKey.isNotEmpty
        ? _firebaseWebVapidKey
        : null,
      );
      final normalized = token?.trim();
      if (normalized == null || normalized.isEmpty) {
        return null;
      }
      _cachedAutoPushToken = normalized;
      return normalized;
    } catch (_) {
      return null;
    }
  }

  Future<void> _initializeDriverScreen() async {
    await _restoreScheduledWindowPreference();
    await _refreshAll();
  }

  Future<void> _restoreScheduledWindowPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getInt(_scheduledWindowPrefsKey);
      if (stored == null || stored <= 0 || stored > 168) {
        return;
      }
      _scheduledWindowHours = stored;
      _customWindowController.text = '$stored';
    } catch (_) {
      // Ignora errores de preferencias locales.
    }
  }

  Future<void> _saveScheduledWindowPreference(int hours) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_scheduledWindowPrefsKey, hours);
    } catch (_) {
      // Ignora errores de preferencias locales.
    }
  }

  void _applyCustomWindowHours() {
    final hours = int.tryParse(_customWindowController.text.trim());
    if (hours == null || hours < 1 || hours > 168) {
      setState(() {
        _error = 'Ingresa una ventana valida entre 1 y 168 horas.';
      });
      return;
    }

    setState(() {
      _scheduledWindowHours = hours;
      _error = null;
    });
    unawaited(_saveScheduledWindowPreference(hours));
    _loadRides();
  }

  Future<void> _refreshAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      _drivers = await _apiClient.getDrivers();
      _incidentCatalog = await _apiClient.getAdminIncidentsCatalog();
      _selectedDriverId ??= _drivers.isNotEmpty ? _drivers.first.id : null;
      unawaited(_registerDriverPushTokenIfAvailable());
      await _loadRides();
      await _loadRatings();
      await _loadAccountStatement();
    } catch (e) {
      _error = 'No se pudo cargar modulo chofer: $e';
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _registerDriverPushTokenIfAvailable() async {
    final driverId = (_selectedDriverId ?? '').trim();
    final token = (await _resolveDriverPushToken())?.trim() ?? '';
    if (driverId.isEmpty || token.isEmpty) {
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final tokenKey = '$_driverPushTokenPrefsPrefix.$driverId';
      final alreadyRegisteredToken = prefs.getString(tokenKey);
      if (alreadyRegisteredToken == token) {
        return;
      }

      await _apiClient.registerDriverDeviceToken(
        driverId: driverId,
        token: token,
        platform: 'flutter',
        appState: 'foreground',
      );

      await prefs.setString(tokenKey, token);
    } catch (_) {
      // Ignora errores de registro de token para no bloquear la operacion.
    }
  }

  Future<void> _loadRides() async {
    try {
      final rides = await _apiClient.getDriverRides(
        driverId: _selectedDriverId,
        activeOnly: _activeOnly,
        scheduledWindowHours: _scheduledWindowHours,
      );
      _notifyNewRideOffers(rides);
      if (mounted) {
        setState(() {
          _rides = rides;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'No se pudieron cargar viajes: $e';
        });
      }
    }
  }

  void _notifyNewRideOffers(List<RideData> rides) {
    final selectedDriverId = _selectedDriverId;
    if (!mounted || selectedDriverId == null || selectedDriverId.isEmpty) {
      return;
    }

    final offers = rides.where((ride) {
      if (ride.driver != null && ride.driver!.id.isNotEmpty) {
        return false;
      }
      return ride.status == 'searching' ||
          ride.status == 'pending_driver' ||
          ride.status == 'scheduled';
    }).toList(growable: false);

    RideData? newOffer;
    for (final ride in offers) {
      if (_alertedRideIds.contains(ride.id)) {
        continue;
      }
      newOffer = ride;
      break;
    }

    if (newOffer == null) {
      return;
    }

    final offer = newOffer;

    _alertedRideIds.add(offer.id);
    unawaited(SystemSound.play(SystemSoundType.alert));
    unawaited(HapticFeedback.heavyImpact());

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Nuevo viaje disponible: ${requestTypeToLabel(offer.requestType)} · MXN ${offer.fareEstimate.toStringAsFixed(2)}',
        ),
        action: SnackBarAction(
          label: 'Aceptar',
          onPressed: () => _setRideStatus(offer, 'accepted'),
        ),
      ),
    );
  }

  Future<void> _loadRatings() async {
    final driverId = _selectedDriverId;
    if (driverId == null || driverId.isEmpty) {
      if (mounted) {
        setState(() {
          _ratings = [];
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _loadingRatings = true;
      });
    }

    try {
      final ratings = await _apiClient.getDriverRatings(driverId: driverId);
      if (mounted) {
        setState(() {
          _ratings = ratings;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'No se pudieron cargar calificaciones: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loadingRatings = false;
        });
      }
    }
  }

  Future<void> _loadAccountStatement() async {
    final driverId = _selectedDriverId;
    if (driverId == null || driverId.isEmpty) {
      if (mounted) {
        setState(() {
          _accountStatement = null;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _loadingAccountStatement = true;
      });
    }

    try {
      final statement = await _apiClient.getDriverAccountStatement(
        driverId: driverId,
        windowDays: _statementWindowDays,
        limit: 400,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _accountStatement = statement;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo cargar estado de cuenta: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingAccountStatement = false;
        });
      }
    }
  }

  Future<void> _replyToRating(DriverRatingEntry entry) async {
    final driverId = _selectedDriverId;
    if (driverId == null || driverId.isEmpty) {
      return;
    }

    final controller = TextEditingController(text: entry.driverResponse);
    final responseText = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Responder calificacion'),
          content: TextField(
            controller: controller,
            maxLines: 4,
            maxLength: 250,
            decoration: const InputDecoration(
              labelText: 'Respuesta del chofer',
              hintText: 'Escribe una respuesta profesional',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text.trim()),
              child: const Text('Guardar respuesta'),
            ),
          ],
        );
      },
    );

    if (responseText == null || responseText.trim().isEmpty) {
      return;
    }

    setState(() {
      _replyingRatingId = entry.id;
    });

    try {
      final updated = await _apiClient.replyDriverRating(
        ratingId: entry.id,
        driverId: driverId,
        responseText: responseText,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _ratings = _ratings
            .map((item) => item.id == updated.id ? updated : item)
            .toList(growable: false);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'No se pudo responder calificacion: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _replyingRatingId = null;
        });
      }
    }
  }

  Future<void> _toggleAvailability(bool available) async {
    final driverId = _selectedDriverId;
    if (driverId == null) {
      return;
    }

    try {
      await _apiClient.updateDriverAvailability(driverId, available);
      await _refreshAll();
    } catch (e) {
      setState(() {
        _error = 'No se pudo actualizar disponibilidad: $e';
      });
    }
  }

  Future<void> _setRideStatus(RideData ride, String status) async {
    try {
      await _apiClient.updateRideStatus(ride.id, status,
          driverId: _selectedDriverId);
      await _loadRides();
      if (status == 'completed') {
        await _loadAccountStatement();
      }
    } catch (e) {
      setState(() {
        _error = 'No se pudo actualizar estado: $e';
      });
    }
  }

  String _moneySigned(double value) {
    final sign = value >= 0 ? '+' : '-';
    return '$sign MXN ${value.abs().toStringAsFixed(2)}';
  }

  String _ledgerTypeLabel(String type) {
    switch (type) {
      case 'earn':
        return 'Ingreso bruto';
      case 'commission':
        return 'Comision';
      case 'payout':
        return 'Liquidacion/pago';
      case 'adjustment_credit':
        return 'Ajuste a favor';
      case 'adjustment_debit':
        return 'Ajuste a cargo';
      default:
        return type;
    }
  }

  Future<void> _showDriverCsvPreviewDialog({
    required String title,
    required String csv,
  }) async {
    if (!mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: SelectableText(csv, style: const TextStyle(fontSize: 12)),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                unawaited(Clipboard.setData(ClipboardData(text: csv)));
                Navigator.of(context).pop();
                if (mounted) {
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    const SnackBar(content: Text('CSV copiado al portapapeles.')),
                  );
                }
              },
              child: const Text('Copiar CSV'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cerrar'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _exportDriverStatementCsv() async {
    final driverId = _selectedDriverId;
    if (driverId == null || driverId.isEmpty) {
      return;
    }

    try {
      final csv = await _apiClient.exportDriverAccountStatementCsv(
        driverId: driverId,
        windowDays: _statementWindowDays,
        limit: 3000,
      );

      final downloaded = await downloadCsvFile(
        fileName: 'driver-account-$driverId.csv',
        csv: csv,
      );

      if (downloaded) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Descarga de estado de cuenta iniciada.')),
          );
        }
        return;
      }

      await _showDriverCsvPreviewDialog(
        title: 'CSV estado de cuenta chofer',
        csv: csv,
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo exportar estado de cuenta: $e';
      });
    }
  }

  Widget _buildDriverMetric({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(value,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _rateCustomerForRide(RideData ride) async {
    final driverId = _selectedDriverId;
    if (driverId == null || ride.customer == null) {
      return;
    }

    final commentController = TextEditingController();
    final adminNotesController = TextEditingController();
    int score = 5;
    final selectedTags = <String>{};
    final complaintOptions = _incidentCatalog['customer'] ??
        const ['impuntualidad', 'maltrato', 'riesgo_seguridad', 'fraude'];

    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              title: const Text('Calificar cliente'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Cliente: ${ride.customer!.fullName}'),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      initialValue: score,
                      decoration: const InputDecoration(labelText: 'Estrellas'),
                      items: [5, 4, 3, 2, 1]
                          .map((value) =>
                              DropdownMenuItem(value: value, child: Text('$value')))
                          .toList(growable: false),
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setModalState(() {
                          score = value;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: commentController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Comentario visible en admin',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: complaintOptions.map((tag) {
                        return FilterChip(
                          label: Text(tag),
                          selected: selectedTags.contains(tag),
                          onSelected: (selected) {
                            setModalState(() {
                              if (selected) {
                                selectedTags.add(tag);
                              } else {
                                selectedTags.remove(tag);
                              }
                            });
                          },
                        );
                      }).toList(growable: false),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: adminNotesController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Queja interna (solo admin)',
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Guardar'),
                ),
              ],
            );
          },
        );
      },
    );

    if (accepted != true) {
      return;
    }

    setState(() {
      _busyRideActionId = ride.id;
    });

    try {
      final updated = await _apiClient.submitDriverCustomerRating(
        rideId: ride.id,
        driverId: driverId,
        score: score,
        comment: commentController.text,
        complaintTags: selectedTags.toList(growable: false),
        adminNotes: adminNotesController.text,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _rides = _rides
            .map((item) => item.id == updated.id ? updated : item)
            .toList(growable: false);
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo calificar al cliente: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busyRideActionId = null;
        });
      }
    }
  }

  Future<void> _reportIncidentForRide(RideData ride) async {
    final driverId = _selectedDriverId;
    if (driverId == null) {
      return;
    }

    String subjectType = 'trip';
    final titleController = TextEditingController();
    final detailsController = TextEditingController();
    final subjectIdController = TextEditingController(text: ride.id);
    String severity = 'media';
    String category = (_incidentCatalog['trip'] ?? const ['operacion'])
        .first;

    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final categories = _incidentCatalog[subjectType] ?? const ['operacion'];
            if (!categories.contains(category)) {
              category = categories.first;
            }
            return AlertDialog(
              title: const Text('Reportar incidencia'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: subjectType,
                      decoration: const InputDecoration(labelText: 'Tipo de caso'),
                      items: const [
                        DropdownMenuItem(value: 'trip', child: Text('Viaje')),
                        DropdownMenuItem(value: 'vehicle', child: Text('Vehiculo')),
                        DropdownMenuItem(value: 'customer', child: Text('Cliente')),
                        DropdownMenuItem(value: 'driver', child: Text('Chofer')),
                      ],
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setModalState(() {
                          subjectType = value;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: subjectIdController,
                      decoration: const InputDecoration(labelText: 'ID afectado'),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: category,
                      decoration: const InputDecoration(labelText: 'Categoria'),
                      items: categories
                          .map((item) => DropdownMenuItem(
                                value: item,
                                child: Text(item),
                              ))
                          .toList(growable: false),
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setModalState(() {
                          category = value;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: severity,
                      decoration: const InputDecoration(labelText: 'Severidad'),
                      items: const [
                        DropdownMenuItem(value: 'baja', child: Text('Baja')),
                        DropdownMenuItem(value: 'media', child: Text('Media')),
                        DropdownMenuItem(value: 'alta', child: Text('Alta')),
                        DropdownMenuItem(value: 'critica', child: Text('Critica')),
                      ],
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setModalState(() {
                          severity = value;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(labelText: 'Titulo'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: detailsController,
                      maxLines: 3,
                      decoration: const InputDecoration(labelText: 'Detalle'),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Reportar'),
                ),
              ],
            );
          },
        );
      },
    );

    if (accepted != true || titleController.text.trim().isEmpty) {
      return;
    }

    setState(() {
      _busyRideActionId = ride.id;
    });

    try {
      await _apiClient.reportDriverIncident(
        driverId: driverId,
        subjectType: subjectType,
        subjectId: subjectIdController.text.trim(),
        category: category,
        severity: severity,
        title: titleController.text.trim(),
        details: detailsController.text.trim(),
        rideId: ride.id,
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'No se pudo reportar incidencia: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busyRideActionId = null;
        });
      }
    }
  }

  Future<void> _showDriverCommandMenu() async {
    if (!mounted) {
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Actualizar modulo (Ctrl+R)'),
                onTap: () {
                  Navigator.of(context).pop();
                  _refreshAll();
                },
              ),
              ListTile(
                leading: const Icon(Icons.account_balance_wallet_outlined),
                title: const Text('Actualizar estado de cuenta (Ctrl+E)'),
                onTap: () {
                  Navigator.of(context).pop();
                  _loadAccountStatement();
                },
              ),
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text('Solo viajes activos'),
                onTap: () {
                  Navigator.of(context).pop();
                  setState(() {
                    _activeOnly = true;
                  });
                  _loadRides();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedDriver = _drivers
        .where((d) => d.id == _selectedDriverId)
        .cast<DriverDetail?>()
        .firstOrNull;

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyR, control: true):
            _KarrytShortcutIntent('driverRefresh'),
        SingleActivator(LogicalKeyboardKey.keyE, control: true):
            _KarrytShortcutIntent('driverStatement'),
        SingleActivator(LogicalKeyboardKey.slash, shift: true):
            _KarrytShortcutIntent('driverCommands'),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _KarrytShortcutIntent: CallbackAction<_KarrytShortcutIntent>(
            onInvoke: (intent) {
              switch (intent.command) {
                case 'driverRefresh':
                  _refreshAll();
                  break;
                case 'driverStatement':
                  _loadAccountStatement();
                  break;
                case 'driverCommands':
                  _showDriverCommandMenu();
                  break;
              }
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
      backgroundColor: const Color(0xFFF4F7FB),
      appBar: AppBar(
        elevation: 4,
        shadowColor: Colors.black.withValues(alpha: 0.18),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF0F766E), Color(0xFF059669)],
            ),
          ),
        ),
        title: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.local_shipping,
                color: Colors.white,
                size: 26,
              ),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Karryt Chofer',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
                Text('Aceptacion y seguimiento',
                    style: TextStyle(fontSize: 11, color: Colors.white70)),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _refreshAll,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Comandos y atajos',
            onPressed: _showDriverCommandMenu,
            icon: const Icon(Icons.keyboard_command_key),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refreshAll,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null) ...[
                    Text(_error!, style: TextStyle(color: Colors.red.shade700)),
                    const SizedBox(height: 8),
                  ],
                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18)),
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Perfil de chofer',
                              style: TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 10),
                          DropdownButtonFormField<String>(
                            initialValue: _selectedDriverId,
                            decoration:
                                const InputDecoration(labelText: 'Conductor'),
                            items: _drivers
                                .map((d) => DropdownMenuItem(
                                      value: d.id,
                                      child:
                                          Text('${d.name} (${d.vehicleName})'),
                                    ))
                                .toList(),
                            onChanged: (value) {
                              setState(() {
                                _selectedDriverId = value;
                                _alertedRideIds.clear();
                              });
                              unawaited(_registerDriverPushTokenIfAvailable());
                              _loadRides();
                              _loadRatings();
                              _loadAccountStatement();
                            },
                          ),
                          const SizedBox(height: 8),
                          if (selectedDriver != null) ...[
                            Text('Categoria: ${selectedDriver.category}'),
                            Text('Capacidad: ${selectedDriver.capacity}'),
                            Text(
                                'Rating: ${selectedDriver.rating} (${selectedDriver.ratingCount} calificaciones)'),
                            Text(
                                'Viajes completados: ${selectedDriver.completedRides}'),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: _windowOptions
                                  .map(
                                    (hours) => ChoiceChip(
                                      label: Text('${hours}h'),
                                      selected: _scheduledWindowHours == hours,
                                      onSelected: (_) {
                                        setState(() {
                                          _scheduledWindowHours = hours;
                                          _customWindowController.text =
                                              '$hours';
                                        });
                                        unawaited(
                                            _saveScheduledWindowPreference(
                                                hours));
                                        _loadRides();
                                      },
                                    ),
                                  )
                                  .toList(),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: _statementWindowOptions
                                  .map(
                                    (days) => ChoiceChip(
                                      label: Text('EC ${days}d'),
                                      selected: _statementWindowDays == days,
                                      onSelected: (_) {
                                        setState(() {
                                          _statementWindowDays = days;
                                        });
                                        _loadAccountStatement();
                                      },
                                    ),
                                  )
                                  .toList(),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _customWindowController,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: 'Ventana programada (horas)',
                                      prefixIcon: Icon(Icons.schedule_send),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                FilledButton.tonal(
                                  onPressed: _applyCustomWindowHours,
                                  child: const Text('Aplicar'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FilledButton.tonal(
                                  onPressed: () => _toggleAvailability(true),
                                  child: const Text('Disponible'),
                                ),
                                FilledButton.tonal(
                                  onPressed: () => _toggleAvailability(false),
                                  child: const Text('Fuera de servicio'),
                                ),
                                FilterChip(
                                  label: const Text('Solo activos'),
                                  selected: _activeOnly,
                                  onSelected: (value) {
                                    setState(() {
                                      _activeOnly = value;
                                    });
                                    _loadRides();
                                  },
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18)),
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Expanded(
                                child: Text('Estado de cuenta',
                                    style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700)),
                              ),
                              IconButton(
                                onPressed:
                                    _loadingAccountStatement ? null : _loadAccountStatement,
                                icon: const Icon(Icons.refresh),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: _loadingAccountStatement
                                    ? null
                                    : _exportDriverStatementCsv,
                                icon: const Icon(Icons.download_outlined),
                                label: const Text('Exportar CSV'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (_loadingAccountStatement)
                            const LinearProgressIndicator()
                          else if (_accountStatement == null)
                            const Text(
                                'Sin datos de estado de cuenta para el chofer seleccionado.')
                          else ...[
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                SizedBox(
                                  width: 220,
                                  child: _buildDriverMetric(
                                    icon: Icons.payments_outlined,
                                    label: 'Ingresos brutos',
                                    value:
                                        'MXN ${_accountStatement!.summary.grossEarnings.toStringAsFixed(2)}',
                                    color: const Color(0xFF15803D),
                                  ),
                                ),
                                SizedBox(
                                  width: 220,
                                  child: _buildDriverMetric(
                                    icon: Icons.percent_outlined,
                                    label: 'Comisiones',
                                    value:
                                        'MXN ${_accountStatement!.summary.commissions.toStringAsFixed(2)}',
                                    color: const Color(0xFFB45309),
                                  ),
                                ),
                                SizedBox(
                                  width: 220,
                                  child: _buildDriverMetric(
                                    icon: Icons.account_balance_wallet_outlined,
                                    label: 'Neto',
                                    value:
                                        'MXN ${_accountStatement!.summary.netEarnings.toStringAsFixed(2)}',
                                    color: const Color(0xFF0F766E),
                                  ),
                                ),
                                SizedBox(
                                  width: 220,
                                  child: _buildDriverMetric(
                                    icon: Icons.savings_outlined,
                                    label: 'Saldo disponible',
                                    value:
                                        'MXN ${_accountStatement!.summary.balance.toStringAsFixed(2)}',
                                    color: const Color(0xFF1D4ED8),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'Periodo: ${_accountStatement!.from} a ${_accountStatement!.to}',
                              style: TextStyle(
                                color: Colors.grey.shade700,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            if (_accountStatement!.entries.isEmpty)
                              const Text(
                                  'No hay movimientos en el periodo seleccionado.')
                            else
                              ..._accountStatement!.entries.take(20).map((entry) {
                                final isCredit = entry.amount >= 0;
                                return ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                    isCredit
                                        ? Icons.arrow_downward_rounded
                                        : Icons.arrow_upward_rounded,
                                    color: isCredit
                                        ? Colors.green.shade700
                                        : Colors.red.shade700,
                                  ),
                                  title: Text(_ledgerTypeLabel(entry.type)),
                                  subtitle: Text(
                                    '${entry.description.isEmpty ? 'Sin descripcion' : entry.description} · ${entry.createdAt}',
                                  ),
                                  trailing: Text(
                                    _moneySigned(entry.amount),
                                    style: TextStyle(
                                      color: isCredit
                                          ? Colors.green.shade700
                                          : Colors.red.shade700,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                );
                              }),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18)),
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Calificaciones recibidas',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          if (_loadingRatings)
                            const LinearProgressIndicator()
                          else if (_ratings.isEmpty)
                            const Text('Aun no hay calificaciones para este chofer.')
                          else
                            ..._ratings.take(8).map((entry) {
                              final hasReply = entry.driverResponse.trim().isNotEmpty;
                              return Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border:
                                      Border.all(color: const Color(0xFFE2E8F0)),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${entry.score}/5 estrellas · viaje ${entry.rideId.substring(0, math.min(8, entry.rideId.length))}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700),
                                    ),
                                    if (entry.comment.trim().isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(entry.comment),
                                    ],
                                    const SizedBox(height: 6),
                                    if (hasReply)
                                      Text(
                                        'Tu respuesta: ${entry.driverResponse}',
                                        style: TextStyle(
                                          color: Colors.teal.shade700,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      )
                                    else
                                      Text(
                                        'Sin respuesta del chofer',
                                        style: TextStyle(color: Colors.orange.shade800),
                                      ),
                                    const SizedBox(height: 6),
                                    FilledButton.tonalIcon(
                                      onPressed: _replyingRatingId == entry.id
                                          ? null
                                          : () => _replyToRating(entry),
                                      icon: _replyingRatingId == entry.id
                                          ? const SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2),
                                            )
                                          : const Icon(Icons.reply_outlined),
                                      label: Text(hasReply
                                          ? 'Editar respuesta'
                                          : 'Responder'),
                                    ),
                                  ],
                                ),
                              );
                            }),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ..._rides.map((ride) => _buildRideCard(ride)),
                  if (_rides.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: KarrytEmptyState(
                        icon: Icons.filter_alt_off_outlined,
                        title: 'Sin viajes',
                        subtitle: 'Ajusta los filtros para ver más resultados.',
                      ),
                    ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRideCard(RideData ride) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Viaje ${ride.id}',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('Estado: ${statusToLabel(ride.status)}'),
            Text('Solicitud: ${requestTypeToLabel(ride.requestType)}'),
            if (ride.scheduledAt != null)
              Text('Programado: ${formatScheduledAtLocal(ride.scheduledAt)}'),
            Text('Origen: ${ride.pickup}'),
            Text('Destino: ${ride.dropoff}'),
            Text('Distancia: ${ride.tripDistanceKm.toStringAsFixed(1)} km'),
            if (ride.customer != null)
              Text(
                  'Cliente: ${ride.customer!.fullName} · Rating ${ride.customer!.rating} (${ride.customer!.ratingCount})'),
            Text('Tarifa: MXN ${ride.fareEstimate.toStringAsFixed(2)}'),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: ride.progress.clamp(0, 1)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (ride.status == 'searching' ||
                    ride.status == 'scheduled' ||
                    ride.status == 'pending_driver')
                  FilledButton.tonal(
                    onPressed: () => _setRideStatus(ride, 'accepted'),
                    child: const Text('Aceptar viaje'),
                  ),
                OutlinedButton(
                  onPressed: () => _setRideStatus(ride, 'driver_arriving'),
                  child: const Text('En camino'),
                ),
                OutlinedButton(
                  onPressed: () => _setRideStatus(ride, 'in_progress'),
                  child: const Text('Iniciar carga'),
                ),
                FilledButton(
                  onPressed: () => _setRideStatus(ride, 'completed'),
                  child: const Text('Finalizar'),
                ),
                if (ride.status == 'completed' &&
                    ride.customer != null &&
                    !ride.driverRatedCustomer)
                  FilledButton.tonalIcon(
                    onPressed: _busyRideActionId == ride.id
                        ? null
                        : () => _rateCustomerForRide(ride),
                    icon: const Icon(Icons.star_outline),
                    label: const Text('Calificar cliente'),
                  ),
                FilledButton.tonalIcon(
                  onPressed: _busyRideActionId == ride.id
                      ? null
                      : () => _reportIncidentForRide(ride),
                  icon: const Icon(Icons.report_problem_outlined),
                  label: const Text('Reportar incidencia'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
