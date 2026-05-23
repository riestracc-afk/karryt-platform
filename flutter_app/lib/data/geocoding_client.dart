import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Timeout corto para no bloquear la UI en redes pobres (estilo Uber/DiDi).
const Duration _kProviderTimeout = Duration(seconds: 4);

/// TTL del caché persistente de sugerencias (14 días).
const Duration _kCacheTtl = Duration(days: 14);

/// Prefijo de claves del caché de geocoding en SharedPreferences.
const String _kCachePrefix = 'geocache_v1_';

String _normalizeCacheKey(String query) {
  final lower = query.trim().toLowerCase();
  final collapsed = lower.replaceAll(RegExp(r'\s+'), ' ');
  return collapsed;
}

class GeocodeSuggestion {
  GeocodeSuggestion({
    required this.displayName,
    required this.lat,
    required this.lng,
    this.placeId,
    this.primaryText,
    this.secondaryText,
    this.provider = 'nominatim',
    this.streetNumberConfirmed,
    this.routeConfirmed,
    this.validationGranularity,
    this.addressComplete,
    this.possibleNextAction,
  });

  final String displayName;
  final double lat;
  final double lng;
  final String? placeId;
  final String? primaryText;
  final String? secondaryText;
  final String provider;
  final bool? streetNumberConfirmed;
  final bool? routeConfirmed;
  final String? validationGranularity;
  final bool? addressComplete;
  final String? possibleNextAction;

  bool get isGooglePrediction =>
      provider == 'google' && placeId != null && placeId!.trim().isNotEmpty;

  bool get hasCoordinates => lat != 0 || lng != 0;

  factory GeocodeSuggestion.fromJson(Map<String, dynamic> json) {
    return GeocodeSuggestion(
      displayName: json['display_name'] as String? ?? 'Direccion',
      lat: double.tryParse('${json['lat']}') ?? 0,
      lng: double.tryParse('${json['lon']}') ?? 0,
      placeId: json['place_id'] as String?,
      primaryText: json['primary_text'] as String?,
      secondaryText: json['secondary_text'] as String?,
      provider: json['provider'] as String? ??
          ((json['place_id'] as String?)?.isNotEmpty == true
              ? 'google'
              : 'nominatim'),
      streetNumberConfirmed: json['street_number_confirmed'] as bool?,
      routeConfirmed: json['route_confirmed'] as bool?,
      validationGranularity: json['validation_granularity'] as String?,
      addressComplete: json['address_complete'] as bool?,
      possibleNextAction: json['possible_next_action'] as String?,
    );
  }
}

class GeocodingClient {
  GeocodingClient({this.googlePlacesApiKey = ''});

  final String googlePlacesApiKey;

  /// Caché en memoria para esta sesión (instantáneo).
  final Map<String, List<GeocodeSuggestion>> _memoryCache = {};

  /// Devuelve sugerencias cacheadas (memoria + disco) sin tocar la red.
  /// Útil para mostrar resultados instantáneos mientras la red responde.
  Future<List<GeocodeSuggestion>> readCachedSuggestions(String query) async {
    final key = _normalizeCacheKey(query);
    if (key.isEmpty) return const [];

    final mem = _memoryCache[key];
    if (mem != null && mem.isNotEmpty) {
      return mem;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_kCachePrefix$key');
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const [];
      final ts = decoded['ts'] as int?;
      if (ts == null) return const [];
      final age = DateTime.now().millisecondsSinceEpoch - ts;
      if (age > _kCacheTtl.inMilliseconds) {
        await prefs.remove('$_kCachePrefix$key');
        return const [];
      }
      final list = decoded['items'];
      if (list is! List) return const [];
      final items = list
          .whereType<Map>()
          .map((e) => GeocodeSuggestion.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false);
      _memoryCache[key] = items;
      return items;
    } catch (_) {
      return const [];
    }
  }

  /// Persiste sugerencias en caché de memoria + disco.
  Future<void> writeCachedSuggestions(
    String query,
    List<GeocodeSuggestion> items,
  ) async {
    final key = _normalizeCacheKey(query);
    if (key.isEmpty || items.isEmpty) return;
    _memoryCache[key] = items;
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = jsonEncode({
        'ts': DateTime.now().millisecondsSinceEpoch,
        'items': items
            .map((s) => {
                  'display_name': s.displayName,
                  'lat': s.lat.toString(),
                  'lon': s.lng.toString(),
                  'place_id': s.placeId,
                  'primary_text': s.primaryText,
                  'secondary_text': s.secondaryText,
                  'provider': s.provider,
                })
            .toList(),
      });
      await prefs.setString('$_kCachePrefix$key', payload);
    } catch (_) {
      // Ignorar errores de persistencia.
    }
  }

  /// Ejecuta Nominatim y ArcGIS en paralelo y devuelve la primera lista no vacía
  /// disponible. Si ambas responden, mezcla resultados priorizando ArcGIS (más preciso para MX).
  Future<List<GeocodeSuggestion>> searchParallel(
    String query, {
    double? biasLat,
    double? biasLng,
  }) async {
    final futures = <Future<List<GeocodeSuggestion>>>[
      searchArcGis(query),
      searchAddresses(query, biasLat: biasLat, biasLng: biasLng),
    ];

    final results = await Future.wait(
      futures.map((f) => f.catchError((_) => const <GeocodeSuggestion>[])),
    );

    final merged = <GeocodeSuggestion>[];
    for (final list in results) {
      merged.addAll(list);
    }
    return merged;
  }

  Future<String?> reverseGeocode(double lat, double lng) async {
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'lat': lat.toString(),
        'lon': lng.toString(),
        'format': 'jsonv2',
        'accept-language': 'es',
        'zoom': '18',
      });

      final response = await http.get(
        uri,
        headers: const {
          'User-Agent': 'Karryt Flutter/1.0 (logistics app)',
        },
      ).timeout(_kProviderTimeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final displayName = data['display_name'];
      if (displayName is String && displayName.trim().isNotEmpty) {
        return displayName.trim();
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  Future<List<GeocodeSuggestion>> searchGooglePredictions(
    String query, {
    double? biasLat,
    double? biasLng,
  }) async {
    final normalizedQuery = query.trim();
    if (googlePlacesApiKey.trim().isEmpty || normalizedQuery.isEmpty) {
      return const [];
    }

    try {
      final params = <String, String>{
        'input': normalizedQuery,
        'key': googlePlacesApiKey,
        'language': 'es',
        'components': 'country:mx',
        'types': 'address',
      };

      if (biasLat != null && biasLng != null) {
        params['location'] = '$biasLat,$biasLng';
        params['radius'] = '30000';
        params['strictbounds'] = 'false';
      }

      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/place/autocomplete/json',
        params,
      );

      final response = await http.get(uri).timeout(_kProviderTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const [];
      }

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) {
        return const [];
      }

      final status = (data['status'] as String? ?? '').toUpperCase();
      if (status != 'OK' && status != 'ZERO_RESULTS') {
        return const [];
      }

      final predictions = data['predictions'];
      if (predictions is! List) {
        return const [];
      }

      return predictions.whereType<Map>().map((item) {
        final raw = item.cast<String, dynamic>();
        final structured =
            raw['structured_formatting'] as Map<String, dynamic>?;
        final primary = structured?['main_text'] as String?;
        final secondary = structured?['secondary_text'] as String?;
        final display = [
          if (primary != null && primary.trim().isNotEmpty) primary.trim(),
          if (secondary != null && secondary.trim().isNotEmpty)
            secondary.trim(),
        ].join(', ');

        return GeocodeSuggestion(
          displayName: display.isNotEmpty
              ? display
              : (raw['description'] as String? ?? 'Direccion'),
          lat: 0,
          lng: 0,
          placeId: raw['place_id'] as String?,
          primaryText: primary,
          secondaryText: secondary,
          provider: 'google',
        );
      }).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<GeocodeSuggestion?> resolveGooglePrediction(
    GeocodeSuggestion suggestion,
  ) async {
    final placeId = suggestion.placeId?.trim();
    if (googlePlacesApiKey.trim().isEmpty ||
        placeId == null ||
        placeId.isEmpty) {
      return null;
    }

    try {
      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/place/details/json',
        {
          'place_id': placeId,
          'fields': 'formatted_address,geometry/location',
          'language': 'es',
          'key': googlePlacesApiKey,
        },
      );

      final response = await http.get(uri).timeout(_kProviderTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) {
        return null;
      }

      final status = (data['status'] as String? ?? '').toUpperCase();
      if (status != 'OK') {
        return null;
      }

      final result = data['result'] as Map<String, dynamic>?;
      final geometry = result?['geometry'] as Map<String, dynamic>?;
      final location = geometry?['location'] as Map<String, dynamic>?;

      final lat = (location?['lat'] as num?)?.toDouble();
      final lng = (location?['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) {
        return null;
      }

      final formattedAddress =
          (result?['formatted_address'] as String?)?.trim();
      return GeocodeSuggestion(
        displayName: formattedAddress?.isNotEmpty == true
            ? formattedAddress!
            : suggestion.displayName,
        lat: lat,
        lng: lng,
        placeId: suggestion.placeId,
        primaryText: suggestion.primaryText,
        secondaryText: suggestion.secondaryText,
        provider: 'google',
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<GeocodeSuggestion>> searchAddresses(
    String query, {
    double? biasLat,
    double? biasLng,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      return const [];
    }

    final queryParameters = <String, String>{
      'q': normalizedQuery,
      'format': 'jsonv2',
      'accept-language': 'es',
      'addressdetails': '1',
      'limit': '8',
      'countrycodes': 'mx',
      'dedupe': '1',
    };

    if (biasLat != null && biasLng != null) {
      const latDelta = 0.22;
      final lngDelta =
          latDelta / math.max(0.3, math.cos(biasLat * math.pi / 180).abs());

      queryParameters['viewbox'] =
          '${(biasLng - lngDelta).toStringAsFixed(4)},${(biasLat + latDelta).toStringAsFixed(4)},${(biasLng + lngDelta).toStringAsFixed(4)},${(biasLat - latDelta).toStringAsFixed(4)}';
    }

    try {
      final uri =
          Uri.https('nominatim.openstreetmap.org', '/search', queryParameters);

      final response = await http.get(
        uri,
        headers: const {
          'User-Agent': 'Karryt Flutter/1.0 (logistics app)',
        },
      ).timeout(_kProviderTimeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const [];
      }

      final data = jsonDecode(response.body);
      if (data is! List) {
        return const [];
      }

      return data
          .whereType<Map>()
          .map((item) =>
              GeocodeSuggestion.fromJson(item.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<GeocodeSuggestion>> searchArcGis(String query) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      return const [];
    }

    try {
      final uri = Uri.https(
        'geocode.arcgis.com',
        '/arcgis/rest/services/World/GeocodeServer/findAddressCandidates',
        {
          'SingleLine': normalizedQuery,
          'f': 'pjson',
          'outFields': 'Match_addr',
          'countryCode': 'MEX',
          'maxLocations': '8',
        },
      );

      final response = await http.get(uri).timeout(_kProviderTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const [];
      }

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) {
        return const [];
      }

      final candidates = data['candidates'];
      if (candidates is! List) {
        return const [];
      }

      return candidates.whereType<Map>().map((item) {
        final raw = item.cast<String, dynamic>();
        final location = raw['location'] as Map<String, dynamic>?;
        final lat = (location?['y'] as num?)?.toDouble() ?? 0;
        final lng = (location?['x'] as num?)?.toDouble() ?? 0;
        final matchAddr = (raw['address'] as String?)?.trim();
        return GeocodeSuggestion(
          displayName: (matchAddr != null && matchAddr.isNotEmpty)
              ? matchAddr
              : 'Direccion',
          lat: lat,
          lng: lng,
          provider: 'arcgis',
        );
      }).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
}
