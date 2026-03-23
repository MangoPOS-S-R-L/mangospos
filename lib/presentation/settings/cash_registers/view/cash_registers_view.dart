import 'package:flutter/material.dart';
import 'package:mangopos/app/theme/mango_colors.dart';

class CashRegistersView extends StatelessWidget {
  const CashRegistersView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.6,
        title: const Text('Cajas'),
      ),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Módulo de configuración de cajas listo para conectar con su lógica específica.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
