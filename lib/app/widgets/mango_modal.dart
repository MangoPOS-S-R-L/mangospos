import 'package:flutter/material.dart';

import '../theme/breakpoints.dart';

/// PRD 6 § 4.4 — Helper único para modales con anatomía preservada.
///
/// La regla es por **tipo de tarea**, no solo por tamaño de pantalla:
///
/// | Tipo            | Compact (<1366) | Regular/Wide          |
/// |-----------------|-----------------|------------------------|
/// | confirmation    | Card ~400 px    | Card ~400 px          |
/// | picker          | Card ~500 px    | Card ~500 px          |
/// | form            | Fullscreen      | Card grande max ~1100 |
/// | wizard          | Fullscreen      | Card grande max ~1150 |
///
/// Principio de **anatomía preservada**: el contenido interno (header,
/// body, footer) NO cambia entre breakpoints. Solo escala el contenedor
/// y el padding externo. Esto preserva el modelo mental del cajero — un
/// usuario entrenado en 1366 abre el mismo modal en 1280 y reconoce todo.
enum MangoModalType { confirmation, picker, form, wizard }

class MangoModal {
  const MangoModal._();

  /// Muestra un modal con dimensiones/insets adaptativos según [type] y
  /// el breakpoint actual.
  ///
  /// El [builder] recibe `BuildContext` y debe retornar el contenido
  /// interno del modal (sin envolver en `Dialog` — eso lo hace el helper).
  ///
  /// Si querés transición custom (fade + scale por defecto), pasá
  /// `useGeneralDialog: true`.
  static Future<T?> showAdaptive<T>({
    required BuildContext context,
    required MangoModalType type,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
    bool useGeneralDialog = false,
    Color barrierColor = Colors.black54,
  }) {
    if (useGeneralDialog) {
      return showGeneralDialog<T>(
        context: context,
        barrierDismissible: barrierDismissible,
        barrierLabel: 'Dismiss',
        barrierColor: barrierColor,
        transitionDuration: const Duration(milliseconds: 250),
        pageBuilder: (ctx, _, _) =>
            _AdaptiveContainer(type: type, child: builder(ctx)),
        transitionBuilder: (_, anim, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
          child: ScaleTransition(
            scale: CurvedAnimation(parent: anim, curve: Curves.easeOutBack),
            child: child,
          ),
        ),
      );
    }
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
      builder: (ctx) => _AdaptiveContainer(type: type, child: builder(ctx)),
    );
  }

  /// Si necesitás envolver un widget tú mismo (fuera de un `show*` call),
  /// usá este wrapper que aplica las mismas reglas.
  static Widget wrap({
    required BuildContext context,
    required MangoModalType type,
    required Widget child,
  }) =>
      _AdaptiveContainer(type: type, child: child);
}

class _AdaptiveContainer extends StatelessWidget {
  final MangoModalType type;
  final Widget child;

  const _AdaptiveContainer({required this.type, required this.child});

  @override
  Widget build(BuildContext context) {
    final compact = Breakpoints.isCompact(context);

    switch (type) {
      case MangoModalType.confirmation:
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: child,
          ),
        );

      case MangoModalType.picker:
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: child,
          ),
        );

      case MangoModalType.form:
      case MangoModalType.wizard:
        if (compact) {
          // Fullscreen: viewport vertical limitado de 768 px requiere
          // aprovechar todo el espacio. Anatomía interna sin cambios.
          return Dialog(
            insetPadding: EdgeInsets.zero,
            backgroundColor: Colors.transparent,
            shape: const RoundedRectangleBorder(),
            child: SizedBox.expand(child: child),
          );
        }
        // Regular/Wide: card grande centrada con max ~1150 px.
        final maxW = type == MangoModalType.wizard ? 1150.0 : 1100.0;
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 36,
            vertical: 36,
          ),
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW, maxHeight: 820),
            child: child,
          ),
        );
    }
  }
}
