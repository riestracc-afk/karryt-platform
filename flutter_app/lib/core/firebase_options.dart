import 'package:firebase_core/firebase_core.dart';

/// Opciones de Firebase construidas a partir de variables --dart-define.
///
/// Uso en main():
///   final options = KarrytFirebaseOptions.currentPlatform;
///   await Firebase.initializeApp(options: options);
///
/// Si los dart-defines no están presentes (build local sin configurar),
/// [currentPlatform] devuelve null y Firebase.initializeApp() debe llamarse
/// sin opciones (confía en google-services.json / GoogleService-Info.plist).
class KarrytFirebaseOptions {
  static const String _projectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
    defaultValue: '',
  );
  static const String _apiKey = String.fromEnvironment(
    'FIREBASE_API_KEY',
    defaultValue: '',
  );
  static const String _appId = String.fromEnvironment(
    'FIREBASE_APP_ID',
    defaultValue: '',
  );
  static const String _messagingSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
    defaultValue: '',
  );
  static const String _storageBucket = String.fromEnvironment(
    'FIREBASE_STORAGE_BUCKET',
    defaultValue: '',
  );
  static const String _authDomain = String.fromEnvironment(
    'FIREBASE_AUTH_DOMAIN',
    defaultValue: '',
  );

  /// Devuelve true cuando las variables mínimas requeridas están presentes.
  static bool get isConfigured =>
      _projectId.isNotEmpty && _apiKey.isNotEmpty && _appId.isNotEmpty;

  /// Opciones para la plataforma actual, o null si no están configuradas.
  static FirebaseOptions? get currentPlatform {
    if (!isConfigured) return null;
    return FirebaseOptions(
      apiKey: _apiKey,
      appId: _appId,
      messagingSenderId: _messagingSenderId,
      projectId: _projectId,
      storageBucket: _storageBucket.isNotEmpty ? _storageBucket : null,
      authDomain: _authDomain.isNotEmpty ? _authDomain : null,
    );
  }
}
