import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'core/app_theme.dart';
import 'core/firebase_options.dart';
import 'main.dart' show DriverScreen;

/// Handler de mensajes FCM cuando la app está en segundo plano o terminada.
/// Debe ser una función de nivel superior (no un método).
/// Firebase ya está inicializado antes de que esto se invoque.
/// No puede actualizar la UI; el bucle de polling cargará el viaje cuando
/// el chofer abra la app desde la notificación.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // No-op intencional: la notificación del sistema ya fue mostrada por FCM.
  // Al abrir la app, _loadRides() recogerá la oferta automáticamente.
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (Firebase.apps.isEmpty) {
      final options = KarrytFirebaseOptions.currentPlatform;
      if (options != null) {
        await Firebase.initializeApp(options: options);
      } else {
        await Firebase.initializeApp();
      }
    }
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  } catch (_) {
    // Firebase no configurado — las notificaciones push no estarán disponibles.
  }
  runApp(const KarrytDriverApp());
}

class KarrytDriverApp extends StatelessWidget {
  const KarrytDriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Karryt Chofer',
      theme: buildKarrytTheme(KarrytRoleTheme.driver),
      home: const DriverScreen(),
    );
  }
}
