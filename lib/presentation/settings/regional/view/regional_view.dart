import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import '../../../../core/theme/app_colors.dart';

class RegionalView extends StatelessWidget {
  const RegionalView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.6,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Regresar',
          onPressed: () => Navigator.of(context).canPop()
              ? Navigator.of(context).pop()
              : context.go(AppRoutes.settings),
        ),
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
