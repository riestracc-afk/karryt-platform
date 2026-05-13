import 'package:flutter/material.dart';

import 'main.dart' show AdminScreen;

void main() {
  runApp(const KarrytAdminApp());
}

class KarrytAdminApp extends StatelessWidget {
  const KarrytAdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF7C2D12);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Karryt Admin PC',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        scaffoldBackgroundColor: const Color(0xFFF3F6FB),
      ),
      home: const _AdminDesktopFrame(),
    );
  }
}

class _AdminDesktopFrame extends StatelessWidget {
  const _AdminDesktopFrame();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: const AdminScreen(),
      ),
    );
  }
}
