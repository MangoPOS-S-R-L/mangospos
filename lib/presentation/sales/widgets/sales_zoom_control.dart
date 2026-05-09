import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/sales_zoom_provider.dart';

/// Control de zoom para grids de la pantalla de ventas (catalogo de productos
/// y grid de mesas). Botones +/- con porcentaje al medio. Si ya esta en min/max
/// el boton correspondiente se deshabilita.
///
/// Persiste la preferencia via `salesZoomProvider` (shared_preferences).
class SalesZoomControl extends ConsumerWidget {
  /// Tamano de los botones. Default ergonomico para tablet (touch >= 36px).
  final double buttonSize;

  /// Si true muestra el porcentaje al medio. Apaga para layouts compactos.
  final bool showLabel;

  const SalesZoomControl({
    super.key,
    this.buttonSize = 36,
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zoom = ref.watch(salesZoomProvider);
    final notifier = ref.read(salesZoomProvider.notifier);
    final canZoomIn = zoom < salesZoomMax - 0.001;
    final canZoomOut = zoom > salesZoomMin + 0.001;
    final pct = (zoom * 100).round();

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ZoomBtn(
            icon: Icons.remove,
            tooltip: 'Reducir tamaño',
            enabled: canZoomOut,
            size: buttonSize,
            onTap: notifier.zoomOut,
          ),
          if (showLabel) ...[
            const SizedBox(width: 4),
            GestureDetector(
              onDoubleTap: zoom != salesZoomDefault ? notifier.reset : null,
              child: Tooltip(
                message: zoom != salesZoomDefault
                    ? 'Doble tap para volver a 100%'
                    : 'Tamaño actual',
                child: Container(
                  alignment: Alignment.center,
                  constraints: const BoxConstraints(minWidth: 44),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    '$pct%',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF475569),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
          ] else
            const SizedBox(width: 2),
          _ZoomBtn(
            icon: Icons.add,
            tooltip: 'Aumentar tamaño',
            enabled: canZoomIn,
            size: buttonSize,
            onTap: notifier.zoomIn,
          ),
        ],
      ),
    );
  }
}

class _ZoomBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final double size;
  final VoidCallback onTap;

  const _ZoomBtn({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.size,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(8),
            child: Icon(
              icon,
              size: 18,
              color: enabled
                  ? const Color(0xFF475569)
                  : const Color(0xFFCBD5E1),
            ),
          ),
        ),
      ),
    );
  }
}
