import 'dart:convert';

import 'package:http/http.dart' as http;

import 'geocoding_client.dart';
import '../domain/models.dart';

class ApiAuthContext {
  const ApiAuthContext({
    required this.role,
    required this.userId,
    this.bearerToken,
    this.devAuthKey,
  });

  const ApiAuthContext.admin({
    required String userId,
    String? bearerToken,
    String? devAuthKey,
  }) : this(
          role: 'admin',
          userId: userId,
          bearerToken: bearerToken,
          devAuthKey: devAuthKey,
        );

  const ApiAuthContext.driver({
    required String userId,
    String? bearerToken,
    String? devAuthKey,
  }) : this(
          role: 'driver',
          userId: userId,
          bearerToken: bearerToken,
          devAuthKey: devAuthKey,
        );

  const ApiAuthContext.customer({
    required String userId,
    String? bearerToken,
    String? devAuthKey,
  }) : this(
          role: 'customer',
          userId: userId,
          bearerToken: bearerToken,
          devAuthKey: devAuthKey,
        );

  final String role;
  final String userId;
  final String? bearerToken;
  final String? devAuthKey;
}

class _AuthHttpClient extends http.BaseClient {
  _AuthHttpClient({ApiAuthContext? authContext}) : _authContext = authContext;

  final http.Client _inner = http.Client();
  ApiAuthContext? _authContext;

  void setAuthContext(ApiAuthContext? value) {
    _authContext = value;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final auth = _authContext;
    if (auth != null) {
      final role = auth.role.trim();
      final userId = auth.userId.trim();
      final bearer = (auth.bearerToken ?? '').trim();
      final devKey = (auth.devAuthKey ?? '').trim();

      if (role.isNotEmpty) {
        request.headers.putIfAbsent('X-Karryt-Role', () => role);
      }
      if (userId.isNotEmpty) {
        request.headers.putIfAbsent('X-Karryt-User-Id', () => userId);
      }
      if (devKey.isNotEmpty) {
        request.headers.putIfAbsent('X-Karryt-Auth-Key', () => devKey);
      }
      if (bearer.isNotEmpty) {
        request.headers.putIfAbsent('Authorization', () => 'Bearer $bearer');
      }
    }

    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

class ApiClient {
  ApiClient(this.baseUrl, {ApiAuthContext? authContext})
      : _client = _AuthHttpClient(authContext: authContext);

  final String baseUrl;
  final _AuthHttpClient _client;

  void setAuthContext(ApiAuthContext? authContext) {
    _client.setAuthContext(authContext);
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(baseUrl);
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: path,
      queryParameters: query,
    );
  }

  Future<Map<String, VehicleCategory>> getCategories() async {
    final response = await _client.get(_uri('/api/categories'));
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data.map((k, v) =>
        MapEntry(k, VehicleCategory.fromJson(v as Map<String, dynamic>)));
  }

  Future<Map<String, ServiceItem>> getServices(String category) async {
    final response = await _client.get(_uri('/api/services/$category'));
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data.map(
        (k, v) => MapEntry(k, ServiceItem.fromJson(v as Map<String, dynamic>)));
  }

  Future<List<PricingRow>> getPricing() async {
    final response = await _client.get(_uri('/api/pricing'));
    _throwOnError(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((e) => PricingRow.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<GeocodeSuggestion>> searchAddressSuggestions({
    required String query,
    double? biasLat,
    double? biasLng,
  }) async {
    final response = await _client.get(
      _uri('/api/addresses/search', {
        'query': query,
        if (biasLat != null) 'biasLat': '$biasLat',
        if (biasLng != null) 'biasLng': '$biasLng',
      }),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final suggestions = data['suggestions'] as List<dynamic>? ?? const [];
    return suggestions
        .whereType<Map<String, dynamic>>()
        .map(GeocodeSuggestion.fromJson)
        .toList(growable: false);
  }

  Future<GeocodeSuggestion?> resolveAddressSuggestion(
    GeocodeSuggestion suggestion,
  ) async {
    if (!suggestion.isGooglePrediction) {
      return suggestion;
    }

    final placeId = suggestion.placeId?.trim();
    if (placeId == null || placeId.isEmpty) {
      return null;
    }

    final response = await _client.get(
      _uri('/api/addresses/resolve', {
        'placeId': placeId,
        if (suggestion.displayName.trim().isNotEmpty)
          'displayName': suggestion.displayName,
        if ((suggestion.primaryText ?? '').trim().isNotEmpty)
          'primaryText': suggestion.primaryText!.trim(),
        if ((suggestion.secondaryText ?? '').trim().isNotEmpty)
          'secondaryText': suggestion.secondaryText!.trim(),
      }),
    );

    if (response.statusCode == 404) {
      return null;
    }

    _throwOnError(response);
    return GeocodeSuggestion.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<String?> reverseGeocode(double lat, double lng) async {
    final response = await _client.get(
      _uri('/api/addresses/reverse', {
        'lat': '$lat',
        'lng': '$lng',
      }),
    );

    if (response.statusCode == 404) {
      return null;
    }

    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final displayName = data['displayName'];
    if (displayName is String && displayName.trim().isNotEmpty) {
      return displayName.trim();
    }

    return null;
  }

  Future<QuoteResult> getQuote({
    required String category,
    required String service,
    required String pickup,
    required String dropoff,
    required double distance,
  }) async {
    final response = await _client.get(
      _uri('/api/quote', {
        'category': category,
        'service': service,
        'pickup': pickup,
        'dropoff': dropoff,
        'distance': distance.toString(),
      }),
    );
    _throwOnError(response);
    return QuoteResult.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<RideData> createRide({
    required String pickup,
    required String dropoff,
    required String category,
    required String service,
    required double distance,
    double? pickupLat,
    double? pickupLng,
    String? scheduledAt,
    String? requestType,
    String? customerId,
    String? customerName,
    String? customerPhone,
    bool notifyWhatsApp = false,
    bool notifySms = false,
  }) async {
    final payload = {
      'pickup': pickup,
      'dropoff': dropoff,
      'category': category,
      'service': service,
      'distance': distance,
      if (scheduledAt != null && scheduledAt.trim().isNotEmpty)
        'scheduledAt': scheduledAt,
      if (requestType != null && requestType.trim().isNotEmpty)
        'requestType': requestType.trim(),
      if ((customerId != null && customerId.trim().isNotEmpty) ||
          (customerName != null && customerName.trim().isNotEmpty) ||
          (customerPhone != null && customerPhone.trim().isNotEmpty))
        'customer': {
          if (customerId != null && customerId.trim().isNotEmpty)
            'id': customerId.trim(),
          if (customerName != null && customerName.trim().isNotEmpty)
            'name': customerName.trim(),
          if (customerPhone != null && customerPhone.trim().isNotEmpty)
            'phone': customerPhone.trim(),
        },
      'notificationPreferences': {
        'whatsapp': notifyWhatsApp,
        'sms': notifySms,
      },
      'pickupPoint': {
        'lat': pickupLat ?? 40.4168,
        'lng': pickupLng ?? -3.7038,
      }
    };

    final response = await _client.post(
      _uri('/api/rides'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
    _throwOnError(response);
    return RideData.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<RideData> getRide(String id) async {
    final response = await _client.get(_uri('/api/rides/$id'));
    _throwOnError(response);
    return RideData.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<RideData> cancelRide(String id) async {
    final response = await _client.post(_uri('/api/rides/$id/cancel'));
    _throwOnError(response);
    return RideData.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> deleteRide(String id) async {
    final response = await _client.delete(_uri('/api/rides/$id'));
    _throwOnError(response);
  }

  Future<Map<String, dynamic>> simulateDriverAccept({String? rideId}) async {
    final response = await _client.post(
      _uri('/api/test/simulate-driver'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        if (rideId != null && rideId.trim().isNotEmpty) 'rideId': rideId.trim(),
      }),
    );
    _throwOnError(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<RideData> submitRideRating({
    required String rideId,
    required int score,
    String? comment,
  }) async {
    final response = await _client.post(
      _uri('/api/rides/$rideId/rating'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'score': score,
        if (comment != null && comment.trim().isNotEmpty)
          'comment': comment.trim(),
      }),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return RideData.fromJson(data['ride'] as Map<String, dynamic>);
  }

  Future<AdminPricingConfig> getAdminPricingConfig() async {
    final response = await _client.get(_uri('/api/admin/pricing-config'));
    _throwOnError(response);
    return AdminPricingConfig.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<AdminPricingConfig> saveAdminPricingConfig(
      AdminPricingConfig config) async {
    final response = await _client.put(
      _uri('/api/admin/pricing-config'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(config.toJson()),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return AdminPricingConfig.fromJson(data['config'] as Map<String, dynamic>);
  }

  Future<List<String>> getAdminVehicleAccessories() async {
    final response = await _client.get(_uri('/api/admin/vehicle-accessories'));
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final list = data['accessories'] as List<dynamic>? ?? const [];
    return list
        .map((entry) => entry.toString())
        .where((entry) => entry.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<Map<String, List<String>>> getAdminCatalogs() async {
    final response = await _client.get(_uri('/api/admin/catalogs'));
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final vehicleAccessories =
        data['vehicle_accessories'] as List<dynamic>? ?? const [];
    final driverDocuments =
        data['driver_documents'] as List<dynamic>? ?? const [];
    final driverSkills = data['driver_skills'] as List<dynamic>? ?? const [];
    return {
      'vehicle_accessories': vehicleAccessories
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
      'driver_documents': driverDocuments
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
      'driver_skills': driverSkills
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
    };
  }

  Future<Map<String, List<String>>> addAdminCatalogEntry({
    required String catalogKey,
    required String item,
  }) async {
    final response = await _client.post(
      _uri('/api/admin/catalogs/$catalogKey/entries'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'item': item}),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final catalogs = data['catalogs'] as Map<String, dynamic>? ?? const {};
    final vehicleAccessories =
        catalogs['vehicle_accessories'] as List<dynamic>? ?? const [];
    final driverDocuments =
        catalogs['driver_documents'] as List<dynamic>? ?? const [];
    final driverSkills =
        catalogs['driver_skills'] as List<dynamic>? ?? const [];
    return {
      'vehicle_accessories': vehicleAccessories
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
      'driver_documents': driverDocuments
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
      'driver_skills': driverSkills
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
    };
  }

  Future<Map<String, List<String>>> updateAdminCatalogEntry({
    required String catalogKey,
    required String oldItem,
    required String newItem,
  }) async {
    final response = await _client.patch(
      _uri('/api/admin/catalogs/$catalogKey/entries'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'oldItem': oldItem, 'newItem': newItem}),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final catalogs = data['catalogs'] as Map<String, dynamic>? ?? const {};
    final vehicleAccessories =
        catalogs['vehicle_accessories'] as List<dynamic>? ?? const [];
    final driverDocuments =
        catalogs['driver_documents'] as List<dynamic>? ?? const [];
    final driverSkills =
        catalogs['driver_skills'] as List<dynamic>? ?? const [];
    return {
      'vehicle_accessories': vehicleAccessories
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
      'driver_documents': driverDocuments
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
      'driver_skills': driverSkills
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
    };
  }

  Future<Map<String, List<String>>> deleteAdminCatalogEntry({
    required String catalogKey,
    required String item,
  }) async {
    final response = await _client.delete(
      _uri('/api/admin/catalogs/$catalogKey/entries'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'item': item}),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final catalogs = data['catalogs'] as Map<String, dynamic>? ?? const {};
    final vehicleAccessories =
        catalogs['vehicle_accessories'] as List<dynamic>? ?? const [];
    final driverDocuments =
        catalogs['driver_documents'] as List<dynamic>? ?? const [];
    final driverSkills =
        catalogs['driver_skills'] as List<dynamic>? ?? const [];
    return {
      'vehicle_accessories': vehicleAccessories
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
      'driver_documents': driverDocuments
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
      'driver_skills': driverSkills
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
    };
  }

  Future<Map<String, List<String>>> reorderAdminCatalogEntry({
    required String catalogKey,
    required String item,
    required String direction,
  }) async {
    final response = await _client.post(
      _uri('/api/admin/catalogs/$catalogKey/reorder'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'item': item, 'direction': direction}),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final catalogs = data['catalogs'] as Map<String, dynamic>? ?? const {};
    final vehicleAccessories =
        catalogs['vehicle_accessories'] as List<dynamic>? ?? const [];
    final driverDocuments =
        catalogs['driver_documents'] as List<dynamic>? ?? const [];
    final driverSkills =
        catalogs['driver_skills'] as List<dynamic>? ?? const [];
    return {
      'vehicle_accessories': vehicleAccessories
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
      'driver_documents': driverDocuments
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
      'driver_skills': driverSkills
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
    };
  }

  Future<Map<String, List<String>>> setAdminCatalogOrder({
    required String catalogKey,
    required List<String> items,
  }) async {
    final response = await _client.put(
      _uri('/api/admin/catalogs/$catalogKey/order'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'items': items}),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final catalogs = data['catalogs'] as Map<String, dynamic>? ?? const {};
    final vehicleAccessories =
        catalogs['vehicle_accessories'] as List<dynamic>? ?? const [];
    final driverDocuments =
        catalogs['driver_documents'] as List<dynamic>? ?? const [];
    final driverSkills =
        catalogs['driver_skills'] as List<dynamic>? ?? const [];
    return {
      'vehicle_accessories': vehicleAccessories
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
      'driver_documents': driverDocuments
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
      'driver_skills': driverSkills
          .map((entry) => entry.toString())
          .where((entry) => entry.trim().isNotEmpty)
          .toList(growable: false),
    };
  }

  Future<List<AdminVehicle>> getAdminVehicles() async {
    final response = await _client.get(_uri('/api/admin/vehicles'));
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final list = data['vehicles'] as List<dynamic>? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(AdminVehicle.fromJson)
        .toList(growable: false);
  }

  Future<AdminVehicle> createAdminVehicle(AdminVehicle vehicle) async {
    final response = await _client.post(
      _uri('/api/admin/vehicles'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(vehicle.toJson()),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return AdminVehicle.fromJson(data['vehicle'] as Map<String, dynamic>);
  }

  Future<AdminVehicle> updateAdminVehicle(AdminVehicle vehicle) async {
    final response = await _client.put(
      _uri('/api/admin/vehicles/${vehicle.id}'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(vehicle.toJson()),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return AdminVehicle.fromJson(data['vehicle'] as Map<String, dynamic>);
  }

  Future<AdminVehicle> setAdminVehicleActive(String id, bool active) async {
    final response = await _client.patch(
      _uri('/api/admin/vehicles/$id/status'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'active': active}),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return AdminVehicle.fromJson(data['vehicle'] as Map<String, dynamic>);
  }

  Future<AdminVehicle> setAdminVehicleSuspension({
    required String id,
    required bool suspended,
    String? reason,
  }) async {
    final response = await _client.patch(
      _uri('/api/admin/vehicles/$id/suspension'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'suspended': suspended,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      }),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return AdminVehicle.fromJson(data['vehicle'] as Map<String, dynamic>);
  }

  Future<void> deleteAdminVehicle(String id) async {
    final response = await _client.delete(_uri('/api/admin/vehicles/$id'));
    _throwOnError(response);
  }

  Future<List<AdminDriver>> getAdminDrivers() async {
    final response = await _client.get(_uri('/api/admin/drivers'));
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final list = data['drivers'] as List<dynamic>? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(AdminDriver.fromJson)
        .toList(growable: false);
  }

  Future<List<String>> getAdminDriverSkills() async {
    final response = await _client.get(_uri('/api/admin/driver-skills'));
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final list = data['skills'] as List<dynamic>? ?? const [];
    return list
        .map((entry) => entry.toString())
        .where((entry) => entry.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<List<AdminDriverAuditEvent>> getAdminDriverAudit({
    String? driverId,
    int limit = 100,
  }) async {
    final response = await _client.get(
      _uri('/api/admin/drivers/audit', {
        if (driverId != null && driverId.trim().isNotEmpty)
          'driverId': driverId,
        'limit': '$limit',
      }),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final list = data['audit'] as List<dynamic>? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(AdminDriverAuditEvent.fromJson)
        .toList(growable: false);
  }

  Future<AdminDriver> createAdminDriver(AdminDriver driver) async {
    final response = await _client.post(
      _uri('/api/admin/drivers'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(driver.toJson()),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return AdminDriver.fromJson(data['driver'] as Map<String, dynamic>);
  }

  Future<AdminDriver> updateAdminDriver(AdminDriver driver) async {
    final response = await _client.put(
      _uri('/api/admin/drivers/${driver.id}'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(driver.toJson()),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return AdminDriver.fromJson(data['driver'] as Map<String, dynamic>);
  }

  Future<AdminDriver> setAdminDriverStatus(String id, bool active) async {
    final response = await _client.patch(
      _uri('/api/admin/drivers/$id/status'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'active': active}),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return AdminDriver.fromJson(data['driver'] as Map<String, dynamic>);
  }

  Future<AdminDriver> setAdminDriverSuspension({
    required String id,
    required bool suspended,
    String? reason,
  }) async {
    final response = await _client.patch(
      _uri('/api/admin/drivers/$id/suspension'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'suspended': suspended,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      }),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return AdminDriver.fromJson(data['driver'] as Map<String, dynamic>);
  }

  Future<List<AdminCustomer>> getAdminCustomers() async {
    final response = await _client.get(_uri('/api/admin/customers'));
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final list = data['customers'] as List<dynamic>? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(AdminCustomer.fromJson)
        .toList(growable: false);
  }

  Future<AdminCustomer> setAdminCustomerStatus({
    required String id,
    required bool active,
  }) async {
    final response = await _client.patch(
      _uri('/api/admin/customers/$id/status'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'active': active}),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return AdminCustomer.fromJson(data['customer'] as Map<String, dynamic>);
  }

  Future<AdminCustomer> setAdminCustomerSuspension({
    required String id,
    required bool suspended,
    String? reason,
  }) async {
    final response = await _client.patch(
      _uri('/api/admin/customers/$id/suspension'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'suspended': suspended,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      }),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return AdminCustomer.fromJson(data['customer'] as Map<String, dynamic>);
  }

  Future<AdminDriver> setAdminDriverAvailability(
      String id, bool available) async {
    final response = await _client.patch(
      _uri('/api/admin/drivers/$id/availability'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'available': available}),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return AdminDriver.fromJson(data['driver'] as Map<String, dynamic>);
  }

  Future<void> deleteAdminDriver(String id) async {
    final response = await _client.delete(_uri('/api/admin/drivers/$id'));
    _throwOnError(response);
  }

  Future<List<DriverDetail>> getDrivers() async {
    final response = await _client.get(_uri('/api/drivers'));
    _throwOnError(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((e) => DriverDetail.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> registerDriverDeviceToken({
    required String driverId,
    required String token,
    String platform = 'flutter',
    String appState = 'foreground',
  }) async {
    final response = await _client.post(
      _uri('/api/driver/devices/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'driverId': driverId,
        'token': token,
        'platform': platform,
        'appState': appState,
      }),
    );
    _throwOnError(response);
  }

  Future<List<RideData>> getDriverRides({
    String? driverId,
    bool activeOnly = false,
    int? scheduledWindowHours,
  }) async {
    final query = <String, String>{
      if (driverId != null && driverId.isNotEmpty) 'driverId': driverId,
      if (activeOnly) 'active': '1',
      if (scheduledWindowHours != null && scheduledWindowHours > 0)
        'scheduledWindowHours': '$scheduledWindowHours',
    };
    final response = await _client.get(_uri('/api/driver/rides', query));
    _throwOnError(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((e) => RideData.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<DriverAccountStatement> getDriverAccountStatement({
    required String driverId,
    int windowDays = 30,
    int limit = 300,
    String? from,
    String? to,
  }) async {
    final response = await _client.get(
      _uri('/api/driver/account-statement', {
        'driverId': driverId,
        'windowDays': '$windowDays',
        'limit': '$limit',
        if (from != null && from.trim().isNotEmpty) 'from': from.trim(),
        if (to != null && to.trim().isNotEmpty) 'to': to.trim(),
      }),
    );
    _throwOnError(response);
    return DriverAccountStatement.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<String> exportDriverAccountStatementCsv({
    required String driverId,
    int windowDays = 30,
    int limit = 2000,
    String? from,
    String? to,
  }) async {
    final response = await _client.get(
      _uri('/api/driver/account-statement.csv', {
        'driverId': driverId,
        'windowDays': '$windowDays',
        'limit': '$limit',
        if (from != null && from.trim().isNotEmpty) 'from': from.trim(),
        if (to != null && to.trim().isNotEmpty) 'to': to.trim(),
      }),
    );
    _throwOnError(response);
    return response.body;
  }

  Future<DriverAccountStatement> getAdminDriverAccountStatement({
    required String driverId,
    int windowDays = 30,
    int limit = 300,
    String? from,
    String? to,
  }) async {
    final response = await _client.get(
      _uri('/api/admin/drivers/$driverId/account-statement', {
        'windowDays': '$windowDays',
        'limit': '$limit',
        if (from != null && from.trim().isNotEmpty) 'from': from.trim(),
        if (to != null && to.trim().isNotEmpty) 'to': to.trim(),
      }),
    );
    _throwOnError(response);
    return DriverAccountStatement.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> registerAdminDriverPayout({
    required String driverId,
    required double amount,
    String? note,
  }) async {
    final response = await _client.post(
      _uri('/api/admin/drivers/$driverId/payout'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'amount': amount,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      }),
    );
    _throwOnError(response);
  }

  Future<void> registerAdminDriverAdjustment({
    required String driverId,
    required String kind,
    required double amount,
    String? note,
  }) async {
    final response = await _client.post(
      _uri('/api/admin/drivers/$driverId/adjustment'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'kind': kind,
        'amount': amount,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      }),
    );
    _throwOnError(response);
  }

  Future<DriverDetail> updateDriverAvailability(
      String driverId, bool available) async {
    final response = await _client.patch(
      _uri('/api/drivers/$driverId/availability'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'available': available}),
    );
    _throwOnError(response);
    return DriverDetail.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<RideData> updateRideStatus(String rideId, String status,
      {String? driverId}) async {
    final response = await _client.post(
      _uri('/api/driver/rides/$rideId/status'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'status': status,
        if (driverId != null && driverId.trim().isNotEmpty)
          'driverId': driverId,
      }),
    );
    _throwOnError(response);
    return RideData.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<RideData> submitDriverCustomerRating({
    required String rideId,
    required String driverId,
    required int score,
    String? comment,
    List<String>? complaintTags,
    String? adminNotes,
  }) async {
    final response = await _client.post(
      _uri('/api/driver/rides/$rideId/customer-rating'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'driverId': driverId,
        'score': score,
        if (comment != null && comment.trim().isNotEmpty)
          'comment': comment.trim(),
        if (complaintTags != null && complaintTags.isNotEmpty)
          'complaintTags': complaintTags,
        if (adminNotes != null && adminNotes.trim().isNotEmpty)
          'adminNotes': adminNotes.trim(),
      }),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return RideData.fromJson(data['ride'] as Map<String, dynamic>);
  }

  Future<Map<String, List<String>>> getAdminIncidentsCatalog() async {
    final response = await _client.get(_uri('/api/admin/incidents/catalog'));
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final categories = data['categories'] as Map<String, dynamic>? ?? const {};
    return categories.map((key, value) {
      final list = value as List<dynamic>? ?? const [];
      return MapEntry(
        key,
        list
            .map((entry) => entry.toString())
            .where((entry) => entry.trim().isNotEmpty)
            .toList(growable: false),
      );
    });
  }

  Future<List<AdminIncident>> getAdminIncidents({
    String? subjectType,
    String? severity,
    String? status,
    int limit = 120,
  }) async {
    final response = await _client.get(
      _uri('/api/admin/incidents', {
        if (subjectType != null && subjectType.trim().isNotEmpty)
          'subjectType': subjectType.trim(),
        if (severity != null && severity.trim().isNotEmpty)
          'severity': severity.trim(),
        if (status != null && status.trim().isNotEmpty) 'status': status.trim(),
        'limit': '$limit',
      }),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final list = data['incidents'] as List<dynamic>? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(AdminIncident.fromJson)
        .toList(growable: false);
  }

  Future<AdminIncident> createAdminIncident({
    required String subjectType,
    required String subjectId,
    required String category,
    required String severity,
    required String title,
    String? details,
    String? reportedBy,
    String? rideId,
  }) async {
    final response = await _client.post(
      _uri('/api/admin/incidents'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'subjectType': subjectType,
        'subjectId': subjectId,
        'category': category,
        'severity': severity,
        'title': title,
        if (details != null && details.trim().isNotEmpty)
          'details': details.trim(),
        if (reportedBy != null && reportedBy.trim().isNotEmpty)
          'reportedBy': reportedBy.trim(),
        if (rideId != null && rideId.trim().isNotEmpty) 'rideId': rideId.trim(),
      }),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return AdminIncident.fromJson(data['incident'] as Map<String, dynamic>);
  }

  Future<AdminIncident> setAdminIncidentStatus({
    required String id,
    required String status,
  }) async {
    final response = await _client.patch(
      _uri('/api/admin/incidents/$id/status'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'status': status}),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return AdminIncident.fromJson(data['incident'] as Map<String, dynamic>);
  }

  Future<List<AdminSanction>> getAdminSanctions({
    String? subjectType,
    String? subjectId,
    int limit = 120,
  }) async {
    final response = await _client.get(
      _uri('/api/admin/sanctions', {
        if (subjectType != null && subjectType.trim().isNotEmpty)
          'subjectType': subjectType.trim(),
        if (subjectId != null && subjectId.trim().isNotEmpty)
          'subjectId': subjectId.trim(),
        'limit': '$limit',
      }),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final list = data['sanctions'] as List<dynamic>? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(AdminSanction.fromJson)
        .toList(growable: false);
  }

  Future<String> exportAdminIncidentsCsv({
    String? subjectType,
    String? severity,
    String? status,
    int limit = 1000,
  }) async {
    final response = await _client.get(
      _uri('/api/admin/incidents.csv', {
        if (subjectType != null && subjectType.trim().isNotEmpty)
          'subjectType': subjectType.trim(),
        if (severity != null && severity.trim().isNotEmpty)
          'severity': severity.trim(),
        if (status != null && status.trim().isNotEmpty) 'status': status.trim(),
        'limit': '$limit',
      }),
    );
    _throwOnError(response);
    return response.body;
  }

  Future<String> exportAdminSanctionsCsv({
    String? subjectType,
    String? subjectId,
    int limit = 1000,
  }) async {
    final response = await _client.get(
      _uri('/api/admin/sanctions.csv', {
        if (subjectType != null && subjectType.trim().isNotEmpty)
          'subjectType': subjectType.trim(),
        if (subjectId != null && subjectId.trim().isNotEmpty)
          'subjectId': subjectId.trim(),
        'limit': '$limit',
      }),
    );
    _throwOnError(response);
    return response.body;
  }

  Future<AdminIncident> reportDriverIncident({
    required String driverId,
    required String subjectType,
    required String subjectId,
    required String category,
    required String title,
    String severity = 'media',
    String? details,
    String? rideId,
  }) async {
    final response = await _client.post(
      _uri('/api/driver/incidents'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'driverId': driverId,
        'subjectType': subjectType,
        'subjectId': subjectId,
        'category': category,
        'severity': severity,
        'title': title,
        if (details != null && details.trim().isNotEmpty)
          'details': details.trim(),
        if (rideId != null && rideId.trim().isNotEmpty) 'rideId': rideId.trim(),
      }),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return AdminIncident.fromJson(data['incident'] as Map<String, dynamic>);
  }

  Future<List<DriverRatingEntry>> getDriverRatings({
    required String driverId,
    int limit = 30,
  }) async {
    final response = await _client.get(
      _uri('/api/driver/ratings', {
        'driverId': driverId,
        'limit': '$limit',
      }),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final list = data['ratings'] as List<dynamic>? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(DriverRatingEntry.fromJson)
        .toList(growable: false);
  }

  Future<DriverRatingEntry> replyDriverRating({
    required String ratingId,
    required String driverId,
    required String responseText,
  }) async {
    final response = await _client.post(
      _uri('/api/driver/ratings/$ratingId/reply'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'driverId': driverId,
        'response': responseText,
      }),
    );
    _throwOnError(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return DriverRatingEntry.fromJson(data['rating'] as Map<String, dynamic>);
  }

  Future<AdminRatingsDistribution> getAdminRatingsDistribution() async {
    final response = await _client.get(_uri('/api/admin/ratings/distribution'));
    _throwOnError(response);
    return AdminRatingsDistribution.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  void _throwOnError(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }

    String message = 'HTTP ${response.statusCode}';
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final err = body['error'];
      if (err is String && err.isNotEmpty) {
        message = err;
      }
    } catch (_) {
      // Ignora parseo de error.
    }

    throw Exception(message);
  }
}
