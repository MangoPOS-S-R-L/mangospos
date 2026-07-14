// Buscador de insumo con autocompletado (nombre, SKU o código de barras).
// Reemplaza a los dropdowns de "Insumo" en los filtros de inventario
// (Kardex, Lotes...): con catálogos grandes elegir de una lista cerrada era
// inviable. Seleccionar una opción aplica el filtro (`onSelected(id)`);
// borrar el texto o tocar la X lo quita (`onSelected(null)`).

import 'package:flutter/material.dart';

import '../../state/inventory_state.dart';

class ItemSearchField extends StatefulWidget {
  final List<InventoryItemSummary> items;
  final String? selectedItemId;
  final ValueChanged<String?> onSelected;
  final String labelText;

  /// Ancho fijo del campo. `null` = ocupa el ancho disponible del padre
  /// (útil dentro de un `Expanded`).
  final double? width;

  const ItemSearchField({
    super.key,
    required this.items,
    required this.selectedItemId,
    required this.onSelected,
    this.labelText = 'Insumo',
    this.width = 240,
  });

  @override
  State<ItemSearchField> createState() => _ItemSearchFieldState();
}

class _ItemSearchFieldState extends State<ItemSearchField> {
  // Controlador interno del Autocomplete, capturado en fieldViewBuilder para
  // poder sincronizar el texto cuando el filtro cambia desde fuera
  // (ej. "Limpiar filtros").
  TextEditingController? _fieldCtrl;

  String _nameFor(String? id) {
    if (id == null) return '';
    return widget.items.where((i) => i.id == id).firstOrNull?.name ?? '';
  }

  @override
  void didUpdateWidget(covariant ItemSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedItemId != widget.selectedItemId) {
      _fieldCtrl?.text = _nameFor(widget.selectedItemId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final field = Autocomplete<InventoryItemSummary>(
      initialValue: TextEditingValue(text: _nameFor(widget.selectedItemId)),
      displayStringForOption: (i) => i.name,
      optionsBuilder: (TextEditingValue value) {
        final q = value.text.trim().toLowerCase();
        if (q.isEmpty) return const Iterable<InventoryItemSummary>.empty();
        return widget.items
            .where(
              (i) =>
                  i.name.toLowerCase().contains(q) ||
                  i.sku.toLowerCase().contains(q) ||
                  i.barcode.toLowerCase().contains(q),
            )
            .take(30);
      },
      onSelected: (i) => widget.onSelected(i.id),
      fieldViewBuilder: (context, ctrl, focus, onFieldSubmitted) {
        _fieldCtrl = ctrl;
        return TextField(
          controller: ctrl,
          focusNode: focus,
          decoration: InputDecoration(
            labelText: widget.labelText,
            hintText: 'Buscar por nombre o SKU…',
            border: const OutlineInputBorder(),
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 18),
            suffixIcon: widget.selectedItemId != null
                ? IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    tooltip: 'Quitar filtro de insumo',
                    onPressed: () {
                      ctrl.clear();
                      widget.onSelected(null);
                    },
                  )
                : null,
          ),
          onChanged: (text) {
            // Vaciar el texto quita el filtro sin exigir el botón X.
            if (text.trim().isEmpty && widget.selectedItemId != null) {
              widget.onSelected(null);
            }
          },
          onSubmitted: (_) => onFieldSubmitted(),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320, maxWidth: 360),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final item = options.elementAt(index);
                  return ListTile(
                    dense: true,
                    title: Text(item.name),
                    subtitle: item.sku.trim().isEmpty ? null : Text(item.sku),
                    onTap: () => onSelected(item),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
    if (widget.width == null) return field;
    return SizedBox(width: widget.width, child: field);
  }
}
