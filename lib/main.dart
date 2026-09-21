import 'package:flutter/material.dart';
import 'screens/hasta_listesi_sayfasi.dart';

void main() => runApp(const GrafikApp());

class GrafikApp extends StatelessWidget {
  const GrafikApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: HastaListesiSayfasi(),
    );
  }
}