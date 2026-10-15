import 'package:flutter/material.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_radius.dart';
import 'package:mangopos/core/theme/app_spacing.dart';

/// Filtro de la lista de Productos que siempre dice por qué campo filtra.
///
/// Sin filtro el control muestra su nombre («Categoría», «Menú»…), no
/// «Todas»: en pantallas de menos de 1366 px las tres cajas decían «Todas /
/// Todos / Todas» y solo una etiqueta diminuta arriba las distinguía. Con
/// filtro muestra el valor con el nombre: de prefijo en escritorio, encima en
/// chiquito en [compact]. La opción para quitarlo dice [allLabel] («Todas
/// las categorías»).
class ProductFilterDropdown extends StatelessWidget {
  const ProductFilterDropdown({
    super.key,
    required this.name,
    required this.allLabel,
    required this.items,
    required this.value,
    required this.onChanged,
    required this.compact,
  });

  final String name;
  final String allLabel;
  final List<Map<String, dynamic>> items;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool compact;

  Widget _closedLabel(String? selected) {
    if (selected == null) {
      return _line(
        name,
        style: TextStyle(
          fontSize: 14,
          color: AppColors.mutedForeground,
          fontWeight: FontWeight.w500,
        ),
      );
    }
    final valueStyle = TextStyle(
      fontSize: 14,
      color: AppColors.foreground,
      fontWeight: FontWeight.w600,
    );
    if (!compact) return _line('$name: $selected', style: valueStyle);
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: TextStyle(
            fontSize: 10,
            height: 1.1,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: AppColors.mutedForeground,
          ),
        ),
        _line(selected, style: valueStyle.copyWith(height: 1.2)),
      ],
    );
  }

  Widget _line(String text, {required TextStyle style}) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: style,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = value != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      decoration: BoxDecoration(
        border: Border.all(
          color: active ? AppColors.primary : AppColors.border,
        ),
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          // En móvil los filtros van dentro de Expanded (ancho acotado), así
          // que pueden expandirse y elipsar. En escritorio la fila les da
          // ancho infinito, donde isExpanded reventaría el layout.
          isExpanded: compact,
          hint: _closedLabel(null),
          // El menú abierto muestra solo el nombre de cada opción; el botón
          // cerrado es el que lleva el nombre del filtro.
          selectedItemBuilder: (context) => [
            _closedLabel(null),
            ...items.map(
              (item) => _closedLabel((item['name'] ?? '') as String),
            ),
          ],
          icon: Icon(Icons.arrow_drop_down, color: AppColors.mutedForeground),
          items: [
            DropdownMenuItem<String>(value: null, child: Text(allLabel)),
            ...items.map((item) {
              return DropdownMenuItem<String>(
                value: item['id'].toString(),
                child: Text(item['name'] ?? ''),
              );
            }),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}
