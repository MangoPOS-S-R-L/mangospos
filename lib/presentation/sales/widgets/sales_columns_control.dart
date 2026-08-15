import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/sales_table_columns_provider.dart';
import '../view/theme/sales_theme.dart';

/// Selector de "mesas por fila" para el grid del salón.
///
/// Muestra `Auto` (el cálculo histórico por ancho + zoom) o un número fijo de
/// columnas. Las opciones cambian según el ancho real de la pantalla: en
/// escritorio el salón trabaja entre 5 y 8 mesas por fila; en pantallas
/// angostas (tablet vertical / móvil) entre 1 y 4, que es lo que cabe sin que
/// el card quede ilegible.
///
/// Persiste vía [salesTableColumnsProvider] (shared_preferences, por device).
class SalesColumnsControl extends ConsumerWidget {
  /// Layout apretado: solo icono + número, sin la palabra "por fila".
  final bool compact;

  const SalesColumnsControl({super.key, this.compact = false});

  /// Opciones fijas ofrecidas según el ancho disponible.
  static List<int> optionsForWidth(double width) =>
      width >= 900 ? const [5, 6, 7, 8] : const [1, 2, 3, 4];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final columns = ref.watch(salesTableColumnsProvider);
    final notifier = ref.read(salesTableColumnsProvider.notifier);
    final options = optionsForWidth(MediaQuery.sizeOf(context).width);
    final isAuto = columns == salesTableColumnsAuto;

    // Un valor guardado en otra pantalla (p.ej. 8 en escritorio y luego se
    // abre en tablet vertical) sigue siendo válido: se agrega a la lista para
    // que el usuario pueda verlo marcado y cambiarlo.
    final values = <int>[
      ...options,
      if (!isAuto && !options.contains(columns)) columns,
    ]..sort();

    return PopupMenuButton<int>(
      tooltip: 'Mesas por fila',
      position: PopupMenuPosition.under,
      onSelected: notifier.set,
      itemBuilder: (_) => [
        _item(
          value: salesTableColumnsAuto,
          label: 'Automático',
          selected: isAuto,
        ),
        const PopupMenuDivider(),
        ...values.map(
          (v) => _item(
            value: v,
            label: '$v por fila',
            selected: !isAuto && columns == v,
          ),
        ),
      ],
      child: Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 10,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.view_week_outlined,
              size: 18,
              color: Color(0xFF475569),
            ),
            const SizedBox(width: 6),
            Text(
              isAuto ? 'Auto' : (compact ? '$columns' : '$columns/fila'),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF475569),
              ),
            ),
            const SizedBox(width: 2),
            const Icon(
              Icons.expand_more_rounded,
              size: 16,
              color: Color(0xFF94A3B8),
            ),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<int> _item({
    required int value,
    required String label,
    required bool selected,
  }) {
    return PopupMenuItem<int>(
      value: value,
      height: 40,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: selected
                ? const Icon(
                    Icons.check_rounded,
                    size: 18,
                    color: SalesTheme.primary,
                  )
                : null,
          ),
          Text(
            label,
            style: TextStyle(
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected
                  ? SalesTheme.foreground
                  : SalesTheme.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}
