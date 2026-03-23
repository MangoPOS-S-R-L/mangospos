import 'package:flutter/material.dart';
import 'package:mangopos/app/theme/mango_colors.dart';

class CurrenciesView extends StatelessWidget {
  const CurrenciesView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.6,
        title: const Text('Monedas'),
      ),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Módulo de monedas listo para conectar con tasas, moneda base y activación por negocio.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
