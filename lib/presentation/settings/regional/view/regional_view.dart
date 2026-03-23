import 'package:flutter/material.dart';
import 'package:mangopos/app/theme/mango_colors.dart';

class RegionalView extends StatelessWidget {
  const RegionalView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.6,
        title: const Text('Configuraciones regionales'),
      ),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Módulo regional listo para conectar idioma, zona horaria, formato de fecha y formato numérico.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
