import 'package:flutter/material.dart';

import 'main.dart' show RideScreen;

void main() {
  runApp(const KarrytUserApp());
}

class KarrytUserApp extends StatelessWidget {
  const KarrytUserApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF14532D);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Karryt Usuario',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        scaffoldBackgroundColor: const Color(0xFFF3F6FB),
      ),
      home: const RideScreen(),
    );
  }
}
