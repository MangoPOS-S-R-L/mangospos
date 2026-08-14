import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/presentation/sales/state/catalog_view_prefs.dart';

/// Alterna el catálogo entre mosaico y lista.
///
/// Un solo botón que muestra el icono del modo AL QUE SE VA, no del actual —
/// es lo que espera el dedo: el icono es la acción, no el estado.
class CatalogViewToggle extends ConsumerWidget {
  const CatalogViewToggle({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(catalogViewModeProvider);
    final goingToList = mode == CatalogViewMode.grid;

    return IconButton(
      onPressed: () => ref.read(catalogViewModeProvider.notifier).toggle(),
      icon: Icon(
        goingToList ? Icons.view_list_rounded : Icons.grid_view_rounded,
        size: compact ? 20 : 22,
      ),
      tooltip: goingToList ? 'Ver en lista' : 'Ver en mosaico',
      visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
      color: const Color(0xFF475569),
    );
  }
}

/// Multiplicador de cantidad: se toca ANTES del producto.
///
/// Inactivo se ve como un botón neutro con «1×». Activo se pinta lleno para
/// que sea imposible no verlo — el riesgo real de esta función es agregar 6
/// unidades sin darse cuenta, así que el estado tiene que gritar.
class QuantityMultiplierButton extends ConsumerWidget {
  const QuantityMultiplierButton({super.key, this.compact = false});

  final bool compact;

  /// Atajos del selector. Cubren los casos de barra (rondas de 2 a 6) y de
  /// colmado (docenas). Para el resto está «Otra cantidad».
  static const _presets = <int>[1, 2, 3, 4, 5, 6, 8, 10, 12, 24];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(quantityMultiplierProvider);
    final active = value != 1;

    return Semantics(
      button: true,
      label: active
          ? 'Multiplicador activo: $value unidades por producto'
          : 'Multiplicador de cantidad',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _pick(context, ref, value),
        onLongPress: active
            ? () => ref.read(quantityMultiplierProvider.notifier).reset()
            : null,
        child: Container(
          height: compact ? 34 : 38,
          constraints: BoxConstraints(minWidth: compact ? 42 : 48),
          padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF2563EB) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? const Color(0xFF2563EB) : const Color(0xFFCBD5E1),
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            '$value×',
            style: TextStyle(
              fontSize: compact ? 13 : 14,
              fontWeight: FontWeight.w700,
              color: active ? Colors.white : const Color(0xFF475569),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref, int current) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Cantidad por producto',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              const Text(
                'Se aplica al siguiente producto que toques y vuelve a 1.',
                style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final n in _presets)
                    _PresetChip(
                      value: n,
                      selected: n == current,
                      onTap: () => Navigator.pop(sheetContext, n),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () async {
                  final custom = await _askCustom(sheetContext, current);
                  if (custom != null && sheetContext.mounted) {
                    Navigator.pop(sheetContext, custom);
                  }
                },
                icon: const Icon(Icons.dialpad_rounded, size: 18),
                label: const Text('Otra cantidad'),
              ),
            ],
          ),
        ),
      ),
    );

    if (picked != null) {
      ref.read(quantityMultiplierProvider.notifier).set(picked);
    }
  }

  Future<int?> _askCustom(BuildContext context, int current) {
    final controller = TextEditingController(text: '$current');
    return showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cantidad por producto'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            helperText: 'Entre 1 y ${QuantityMultiplier.max}',
          ),
          onSubmitted: (v) =>
              Navigator.pop(dialogContext, int.tryParse(v.trim())),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              dialogContext,
              int.tryParse(controller.text.trim()),
            ),
            child: const Text('Aplicar'),
          ),
        ],
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final int value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        width: 62,
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF2563EB) : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? const Color(0xFF2563EB) : const Color(0xFFE2E8F0),
          ),
        ),
        child: Text(
          '$value×',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : const Color(0xFF334155),
          ),
        ),
      ),
    );
  }
}
