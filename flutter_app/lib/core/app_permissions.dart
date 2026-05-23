import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class AppPermissionsResult {
  const AppPermissionsResult({
    required this.granted,
    required this.denied,
    required this.permanentlyDenied,
  });

  final List<Permission> granted;
  final List<Permission> denied;
  final List<Permission> permanentlyDenied;

  bool get allGranted => denied.isEmpty && permanentlyDenied.isEmpty;
}

class AppPermissions {
  static bool _requestedForUser = false;
  static bool _requestedForDriver = false;

  static Future<AppPermissionsResult> ensureForUser() async {
    if (_requestedForUser || kIsWeb) {
      return const AppPermissionsResult(
        granted: <Permission>[],
        denied: <Permission>[],
        permanentlyDenied: <Permission>[],
      );
    }
    _requestedForUser = true;
    return _requestCommonPermissions();
  }

  static Future<AppPermissionsResult> ensureForDriver() async {
    if (_requestedForDriver || kIsWeb) {
      return const AppPermissionsResult(
        granted: <Permission>[],
        denied: <Permission>[],
        permanentlyDenied: <Permission>[],
      );
    }
    _requestedForDriver = true;
    return _requestCommonPermissions();
  }

  static Future<AppPermissionsResult> _requestCommonPermissions() async {
    final permissions = <Permission>[
      Permission.locationWhenInUse,
      Permission.notification,
      Permission.camera,
      Permission.microphone,
      Permission.phone,
      Permission.storage,
      Permission.photos,
    ];

    final granted = <Permission>[];
    final denied = <Permission>[];
    final permanentlyDenied = <Permission>[];

    for (final permission in permissions) {
      try {
        var status = await permission.status;
        if (!status.isGranted && !status.isLimited) {
          status = await permission.request();
        }

        if (status.isGranted || status.isLimited) {
          granted.add(permission);
        } else if (status.isPermanentlyDenied || status.isRestricted) {
          permanentlyDenied.add(permission);
        } else {
          denied.add(permission);
        }
      } catch (_) {
        denied.add(permission);
      }
    }

    return AppPermissionsResult(
      granted: granted,
      denied: denied,
      permanentlyDenied: permanentlyDenied,
    );
  }

  static Future<void> promptOpenSettingsIfNeeded(
    BuildContext context,
    AppPermissionsResult result,
  ) async {
    if (result.permanentlyDenied.isEmpty || !context.mounted) {
      return;
    }

    final shouldOpen = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Permisos requeridos'),
          content: const Text(
            'Detectamos permisos bloqueados permanentemente. Para usar correctamente la app, abre Ajustes y habilita los permisos.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Ahora no'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Abrir ajustes'),
            ),
          ],
        );
      },
    );

    if (shouldOpen == true) {
      await openAppSettings();
    }
  }
}
