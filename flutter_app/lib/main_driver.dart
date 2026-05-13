import 'package:flutter/material.dart';

import 'main.dart' show DriverScreen;

void main() {
  runApp(const KarrytDriverApp());
}

class KarrytDriverApp extends StatelessWidget {
  const KarrytDriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF1D4ED8);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Karryt Chofer',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        scaffoldBackgroundColor: const Color(0xFFF3F6FB),
      ),
      home: const DriverScreen(),
    );
  }
}
