import 'package:flutter/foundation.dart';

import '../data/api_client.dart';
import '../data/realtime_client.dart';
import '../domain/models.dart';

final Map<String, VehicleCategory> _demoCategories = {
  'pickup_mini': VehicleCategory(
    id: 'pickup_mini',
    label: 'Pick-up Mini',
    capacity: 'Hasta 800 kg',
    description: 'Vehiculos compactos de carga ligera',
    boxSize: '1.80 x 1.50 x 0.45 m',
  ),
  'specialized_1t': VehicleCategory(
    id: 'specialized_1t',
    label: 'Especializada 1 tonelada',
    capacity: 'Hasta 1.1 tonelada',
    description: 'Camionetas especializadas para carga estructurada',
    boxSize: '2.60 x 1.80 x 0.40 m',
  ),
  'truck_3t': VehicleCategory(
    id: 'truck_3t',
    label: 'Especializada 3 tonelada',
    capacity: 'Hasta 3 toneladas',
    description: 'Camiones medianos para carga consolidada',
    boxSize: '4.20 x 2.10 x 2.10 m',
  ),
  'dump_truck': VehicleCategory(
    id: 'dump_truck',
    label: 'Camión de Volteo',
    capacity: 'Hasta 8 toneladas',
    description: 'Camiones especializados para carga a granel',
    boxSize: '3.40 x 2.20 x 0.80 m (6 m3 aprox.)',
  ),
};

final Map<String, Map<String, ServiceItem>> _demoServices = {
  'pickup_mini': {
    'local': ServiceItem(label: 'Recorrido Local'),
    'regional': ServiceItem(label: 'Recorrido Regional'),
  },
  'specialized_1t': {
    'structural': ServiceItem(label: 'Carga Estructural'),
  },
  'truck_3t': {
    'standard': ServiceItem(label: 'Carga Estándar'),
    'heavy': ServiceItem(label: 'Carga Pesada'),
  },
  'dump_truck': {
    'bulk': ServiceItem(label: 'Carga a Granel'),
    'specialized': ServiceItem(label: 'Carga Especializada'),
  },
};

final List<PricingRow> _demoPricing = [
  PricingRow(
    categoryLabel: 'Pick-up Mini',
    startFare: 150,
    perKmRate: 18,
    waitPerMinRate: 4,
  ),
  PricingRow(
    categoryLabel: 'Especializada 1 tonelada',
    startFare: 300,
    perKmRate: 30,
    waitPerMinRate: 6,
  ),
  PricingRow(
    categoryLabel: 'Especializada 3 tonelada',
    startFare: 700,
    perKmRate: 45,
    waitPerMinRate: 8,
  ),
  PricingRow(
    categoryLabel: 'Camión de Volteo',
    startFare: 1500,
    perKmRate: 75,
    waitPerMinRate: 12,
  ),
];

final Map<String, ({double startFare, double perKmRate})> _demoRateCard = {
  'pickup_mini': (startFare: 150, perKmRate: 18),
  'specialized_1t': (startFare: 300, perKmRate: 30),
  'truck_3t': (startFare: 700, perKmRate: 45),
  'dump_truck': (startFare: 1500, perKmRate: 75),
};

class RideController extends ChangeNotifier {
  RideController({
    required ApiClient apiClient,
    required RealtimeClient realtimeClient,
  })  : _apiClient = apiClient,
        _realtimeClient = realtimeClient;

  final ApiClient _apiClient;
  final RealtimeClient _realtimeClient;

  final pickupText = ValueNotifier<String>('');
  final dropoffText = ValueNotifier<String>('');
  final distanceText = ValueNotifier<String>('10');

  Map<String, VehicleCategory> categories = {};
  Map<String, ServiceItem> services = {};
  List<PricingRow> pricing = [];
  List<DriverPosition> drivers = [];

  String? selectedCategory;
  String? selectedService;

  RideData? currentRide;
  List<RideData> scheduledRides = [];
  double? pickupLat;
  double? pickupLng;
  double? dropoffLat;
  double? dropoffLng;

  bool loading = true;
  bool requestingRide = false;
  bool quoting = false;
  String fareLabel = 'MXN --.--';
  String? error;

  void _activateDemoMode(String message) {
    categories = _demoCategories.map(
      (key, value) => MapEntry(
        key,
        VehicleCategory(
          id: value.id,
          label: value.label,
          capacity: value.capacity,
          description: value.description,
          boxSize: value.boxSize,
        ),
      ),
    );

    pricing = _demoPricing
        .map(
          (row) => PricingRow(
            categoryLabel: row.categoryLabel,
            startFare: row.startFare,
            perKmRate: row.perKmRate,
            waitPerMinRate: row.waitPerMinRate,
          ),
        )
        .toList();

    selectedCategory ??= categories.keys.isNotEmpty ? categories.keys.first : null;
    services = _demoServices[selectedCategory] != null
        ? _demoServices[selectedCategory]!.map(
            (key, value) => MapEntry(key, ServiceItem(label: value.label)),
          )
        : {};
    selectedService = services.isNotEmpty ? services.keys.first : null;
    fareLabel = _estimateDemoFare();
    error = message;
  }

  String _estimateDemoFare() {
    final categoryKey = selectedCategory;
    if (categoryKey == null) {
      return 'MXN --.--';
    }

    final rate = _demoRateCard[categoryKey];
    if (rate == null) {
      return 'MXN --.--';
    }

    final distance = double.tryParse(distanceText.value.trim()) ?? 0;
    final total = rate.startFare + (distance * rate.perKmRate);
    return 'MXN ${total.toStringAsFixed(2)}';
  }

  Future<void> init() async {
    loading = true;
    error = null;
    notifyListeners();

    _realtimeClient.connect(
      onDriversUpdate: (data) {
        drivers = data;
        notifyListeners();
      },
      onRideUpdate: (ride) {
        final idx = scheduledRides.indexWhere((r) => r.id == ride.id);
        if (idx >= 0) {
          scheduledRides[idx] = ride;
          notifyListeners();
          return;
        }
        if (currentRide == null || currentRide!.id == ride.id) {
          currentRide = ride;
          notifyListeners();
        }
      },
      onError: (_) {
        // En tiempo real degradado, la app sigue operando por REST.
      },
    );

    try {
      categories = await _apiClient.getCategories();
      pricing = await _apiClient.getPricing();

      if (categories.isNotEmpty) {
        selectedCategory = categories.keys.first;
        await loadServices(selectedCategory!);
      }

      await quote();
    } catch (e) {
      _activateDemoMode(
        'Modo demo visual activo. Se muestran categorías, servicios y tarifas locales.',
      );
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> loadServices(String category) async {
    try {
      services = await _apiClient.getServices(category);
      selectedService = services.isNotEmpty ? services.keys.first : null;
      notifyListeners();
    } catch (e) {
      services = _demoServices[category] != null
          ? _demoServices[category]!.map(
              (key, value) => MapEntry(key, ServiceItem(label: value.label)),
            )
          : {};
      selectedService = services.isNotEmpty ? services.keys.first : null;
      error = 'Servicios demo activos para esta categoría.';
      notifyListeners();
    }
  }

  Future<void> selectCategory(String? category) async {
    if (category == null) {
      return;
    }

    selectedCategory = category;
    services = {};
    selectedService = null;
    notifyListeners();

    await loadServices(category);
    await quote();
  }

  Future<void> selectService(String? service) async {
    if (service == null || selectedService == service) {
      return;
    }

    selectedService = service;
    notifyListeners();
    await quote();
  }

  Future<void> quote() async {
    if (selectedCategory == null || selectedService == null) {
      return;
    }

    final distance = double.tryParse(distanceText.value.trim()) ?? 0;

    quoting = true;
    error = null;
    notifyListeners();

    try {
      final result = await _apiClient.getQuote(
        category: selectedCategory!,
        service: selectedService!,
        pickup: pickupText.value.trim(),
        dropoff: dropoffText.value.trim(),
        distance: distance,
      );
      fareLabel = result.currencyFormatted;
    } catch (e) {
      fareLabel = _estimateDemoFare();
      error = 'Estimación demo mostrada con tarifas locales.';
    } finally {
      quoting = false;
      notifyListeners();
    }
  }

  void setPickupPoint(double lat, double lng) {
    pickupLat = lat;
    pickupLng = lng;
    notifyListeners();
  }

  void clearPickupPoint() {
    pickupLat = null;
    pickupLng = null;
    notifyListeners();
  }

  void setDropoffPoint(double lat, double lng) {
    dropoffLat = lat;
    dropoffLng = lng;
    notifyListeners();
  }

  void clearDropoffPoint() {
    dropoffLat = null;
    dropoffLng = null;
    notifyListeners();
  }

  Future<void> createRide({
    DateTime? scheduledAt,
    String requestType = 'urgent',
    bool notifyWhatsApp = false,
    bool notifySms = false,
  }) async {
    if (selectedCategory == null || selectedService == null) {
      error = 'Selecciona categoria y servicio';
      notifyListeners();
      return;
    }

    final pickup = pickupText.value.trim();
    final dropoff = dropoffText.value.trim();
    final distance = double.tryParse(distanceText.value.trim()) ?? 0;

    if (pickup.isEmpty || dropoff.isEmpty) {
      error = 'Debes capturar origen y destino';
      notifyListeners();
      return;
    }

    requestingRide = true;
    error = null;
    notifyListeners();

    try {
      final ride = await _apiClient.createRide(
        pickup: pickup,
        dropoff: dropoff,
        category: selectedCategory!,
        service: selectedService!,
        distance: distance,
        pickupLat: pickupLat,
        pickupLng: pickupLng,
        scheduledAt: scheduledAt?.toUtc().toIso8601String(),
        requestType: requestType,
        customerId: 'app-user-demo',
        customerName: 'Cliente App',
        notifyWhatsApp: notifyWhatsApp,
        notifySms: notifySms,
      );

      if (requestType == 'scheduled') {
        scheduledRides.add(ride);
      } else {
        currentRide = ride;
      }
      _realtimeClient.watchRide(ride.id);
    } catch (e) {
      error = 'No se pudo crear viaje: $e';
    } finally {
      requestingRide = false;
      notifyListeners();
    }
  }

  Future<void> cancelScheduledRide(String id) async {
    try {
      final cancelled = await _apiClient.cancelRide(id);
      final idx = scheduledRides.indexWhere((r) => r.id == id);
      if (idx >= 0) {
        scheduledRides[idx] = cancelled;
      }
      notifyListeners();
    } catch (e) {
      error = 'No se pudo cancelar el viaje programado: $e';
      notifyListeners();
    }
  }

  Future<void> deleteScheduledRide(String id) async {
    try {
      await _apiClient.deleteRide(id);
      scheduledRides.removeWhere((r) => r.id == id);
      error = null;
      notifyListeners();
    } catch (e) {
      error = 'No se pudo eliminar el viaje programado: $e';
      notifyListeners();
    }
  }

  Future<void> cancelRide() async {
    if (currentRide == null) {
      return;
    }

    try {
      final cancelled = await _apiClient.cancelRide(currentRide!.id);
      currentRide = cancelled;
      notifyListeners();
    } catch (e) {
      error = 'No se pudo cancelar viaje: $e';
      notifyListeners();
    }
  }

  Future<void> deleteCurrentRide() async {
    if (currentRide == null) {
      return;
    }

    try {
      await _apiClient.deleteRide(currentRide!.id);
      currentRide = null;
      error = null;
      notifyListeners();
    } catch (e) {
      error = 'No se pudo eliminar la solicitud: $e';
      notifyListeners();
    }
  }

  Future<void> simulateDriverAccept() async {
    if (currentRide == null) {
      return;
    }

    try {
      await _apiClient.simulateDriverAccept(rideId: currentRide!.id);
    } catch (e) {
      error = 'Error en modo prueba: $e';
      notifyListeners();
    }
  }

  bool get canDeleteRide {
    final status = currentRide?.status;
    return status == 'cancelled' || status == 'completed';
  }

  bool get canSimulateDriver {
    final status = currentRide?.status;
    return status == 'searching' || status == 'pending_driver';
  }

  Future<void> submitRideRating({
    required int score,
    String? comment,
  }) async {
    if (currentRide == null) {
      return;
    }

    try {
      final updated = await _apiClient.submitRideRating(
        rideId: currentRide!.id,
        score: score,
        comment: comment,
      );
      currentRide = updated;
      notifyListeners();
    } catch (e) {
      error = 'No se pudo registrar la calificacion: $e';
      notifyListeners();
      rethrow;
    }
  }

  bool get canCancel {
    final status = currentRide?.status;
    return status != null &&
        status != 'completed' &&
        status != 'cancelled' &&
        status != 'no_drivers';
  }

  bool get canRateCurrentRide {
    final ride = currentRide;
    if (ride == null) {
      return false;
    }

    return ride.status == 'completed' &&
        ride.driver != null &&
        ride.riderRating == null;
  }

  @override
  void dispose() {
    _realtimeClient.disconnect();
    pickupText.dispose();
    dropoffText.dispose();
    distanceText.dispose();
    super.dispose();
  }
}
