import 'package:url_launcher/url_launcher.dart';

/// Abre la ubicación en la app de mapas del dispositivo (Google Maps o Apple Maps)
Future<void> openMapLocation({required double lat, required double lng, String? label}) async {
  final encodedLabel = Uri.encodeComponent(label ?? 'Ubicación');
  final googleUrl = 'https://www.google.com/maps/search/?api=1&query=$lat,$lng($encodedLabel)';
  final appleUrl = 'https://maps.apple.com/?q=$lat,$lng';

  final uri = Uri.parse(googleUrl);
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
    return;
  }
  final appleUri = Uri.parse(appleUrl);
  if (await canLaunchUrl(appleUri)) {
    await launchUrl(appleUri, mode: LaunchMode.externalApplication);
    return;
  }
  throw 'No se pudo abrir la app de mapas.';
}
