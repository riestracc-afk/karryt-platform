import 'dart:io';

import 'package:flutter/foundation.dart';

const _productionApiBaseUrl = 'https://project-404e35e2-6a5d-421b-970.web.app';

String resolveApiBaseUrl() {
  const fromDefine = String.fromEnvironment('API_BASE_URL');
  if (fromDefine.isNotEmpty) {
    return fromDefine;
  }

  if (kIsWeb) {
    final host = Uri.base.host.toLowerCase();
    final isLocalHost = host == 'localhost' || host == '127.0.0.1';
    if (!isLocalHost && Uri.base.hasAuthority) {
      return Uri.base.origin;
    }

    return 'http://localhost:3000';
  }

  if (Platform.isAndroid || Platform.isWindows || Platform.isIOS || Platform.isMacOS) {
    if (kDebugMode || const bool.fromEnvironment('USE_LOCAL_API')) {
      return 'http://localhost:3000';
    }
    return _productionApiBaseUrl;
  }

  return 'http://localhost:3000';
}
