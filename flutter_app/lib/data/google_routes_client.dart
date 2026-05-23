import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class GoogleRoutesResponse {
  const GoogleRoutesResponse({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
  });

  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;
}

class GoogleRoutesClient {
  GoogleRoutesClient({required this.apiKey});

  final String apiKey;

  static const _baseUrl =
      'https://routes.googleapis.com/directions/v2:computeRoutes';

  Future<GoogleRoutesResponse?> getRoute(
    LatLng origin,
    LatLng destination,
  ) async {
    if (apiKey.isEmpty) {
      return null;
    }

    try {
      final departureTime = DateTime.now().toUtc().toIso8601String();
      final body = jsonEncode({
        'origin': {
          'location': {
            'latLng': {
              'latitude': origin.latitude,
              'longitude': origin.longitude,
            },
          },
        },
        'destination': {
          'location': {
            'latLng': {
              'latitude': destination.latitude,
              'longitude': destination.longitude,
            },
          },
        },
        'travelMode': 'DRIVE',
        'routingPreference': 'TRAFFIC_AWARE_OPTIMAL',
        'computeAlternativeRoutes': false,
        'polylineQuality': 'HIGH_QUALITY',
        'departureTime': departureTime,
      });

      final response = await http.post(
        Uri.parse('$_baseUrl?key=$apiKey'),
        headers: const {
          'Content-Type': 'application/json',
          'X-Goog-FieldMask':
              'routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline,routes.legs.distanceMeters,routes.legs.duration',
        },
        body: body,
      );

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

      final polyline = route['polyline'];
      final encodedPolyline =
          polyline is Map ? polyline['encodedPolyline'] : null;
      final points = encodedPolyline is String
          ? _decodePolyline(encodedPolyline)
          : [origin, destination];

      final distanceMetersRaw = _readMeters(route['distanceMeters']) ??
          _readMeters(route['distance']) ??
          _readMetersFromLegs(route['legs']) ??
          0.0;

      final durationSecondsRaw = _readSeconds(route['duration']) ??
          _readSecondsFromLegs(route['legs']) ??
          0.0;

      if (distanceMetersRaw <= 0 || durationSecondsRaw <= 0 || points.isEmpty) {
        if (kDebugMode) {
          // ignore: avoid_print
          print('Google Routes response without usable route data: $response');
        }
        return null;
      }

      return GoogleRoutesResponse(
        points: points,
        distanceMeters: distanceMetersRaw,
        durationSeconds: durationSecondsRaw,
      );
    } catch (_) {
      return null;
    }
  }

  double? _readMeters(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is Map) {
      final meters = value['meters'];
      if (meters is num) {
        return meters.toDouble();
      }
      return double.tryParse('$meters');
    }
    return double.tryParse('$value');
  }

  double? _readSeconds(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is Map) {
      final seconds = value['seconds'];
      if (seconds is num) {
        return seconds.toDouble();
      }
      return double.tryParse('$seconds');
    }
    return double.tryParse('$value');
  }

  double? _readMetersFromLegs(dynamic legs) {
    if (legs is! List || legs.isEmpty) {
      return null;
    }
    final first = legs.first;
    if (first is! Map) {
      return null;
    }
    return _readMeters(first['distance']);
  }

  double? _readSecondsFromLegs(dynamic legs) {
    if (legs is! List || legs.isEmpty) {
      return null;
    }
    final first = legs.first;
    if (first is! Map) {
      return null;
    }
    return _readSeconds(first['duration']);
  }

  List<LatLng> _decodePolyline(String encoded) {
    final polyline = <LatLng>[];
    int index = 0;
    int lat = 0;
    int lng = 0;

    while (index < encoded.length) {
      int result = 0;
      int shift = 0;
      int b;

      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);

      final dlat = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
      lat += dlat;

      result = 0;
      shift = 0;

      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);

      final dlng = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
      lng += dlng;

      polyline.add(LatLng(lat / 1e5, lng / 1e5));
    }

    return polyline;
  }
}
