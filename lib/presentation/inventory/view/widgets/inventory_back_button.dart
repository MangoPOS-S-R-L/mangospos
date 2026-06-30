import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';

/// Botón de "volver" estándar para las subvistas de inventario.
///
/// Estas vistas se abren desde Más Opciones (Ajustes) con `context.go`, que
/// REEMPLAZA el stack de navegación — por eso un `AppBar` no muestra el back
/// automático (`Navigator.canPop` es false). Si por alguna ruta sí hay
/// historial navegable, hacemos `pop`; si no, volvemos a Ajustes.
class InventoryBackButton extends StatelessWidget {
  const InventoryBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: () {
        if (context.canPop()) {
          context.pop();
        } else {
          context.go(AppRoutes.settings);
        }
      },
      icon: const Icon(Icons.arrow_back),
      tooltip: 'Volver',
    );
  }
}
