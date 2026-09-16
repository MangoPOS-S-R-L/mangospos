// Editor de presentaciones de dos niveles (Compras F5a) dentro de la ficha del
// insumo: «Lata = 355 mL», «Caja = 24 Lata». La marcada con ★ es la de COMPRA:
// al guardar se aplana en la unidad de compra y el contenido de la ficha, así
// que órdenes, recepciones y costos la usan sin cambiar nada.
//
// Solo arma y valida la lista (con las mismas reglas que la base); guardar lo
// hace el formulario con `ItemPresentationsRepository`.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/inventory/item_presentations.dart';
import '../../../../core/inventory/unit_conversion.dart';
import '../../../../core/theme/app_colors.dart';
import 'unit_dropdown.dart';

class ItemPresentationsEditor extends StatefulWidget {
  final String baseUnit;
  final List<PresentationDraft> initial;
  final ValueChanged<List<PresentationDraft>> onChanged;
  final bool enabled;

  const ItemPresentationsEditor({
    super.key,
    required this.baseUnit,
    required this.initial,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  State<ItemPresentationsEditor> createState() => _ItemPresentationsEditorState();
}

class _Row {
  _Row({
    required this.id,
    required String unit,
    required double qty,
    this.containsUnit,
    this.isDefault = false,
  })  : sections = purchaseUnitSections(current: unit.trim().isEmpty ? null : unit),
        qtyCtrl = TextEditingController(text: qty > 0 ? formatUnitQty(qty) : '') {
    this.unit = unit.trim().isEmpty ? '' : unitSelectionValue(sections, unit, fallback: unit.trim());
  }

  final int id;
  final List<UnitSection> sections;
  final TextEditingController qtyCtrl;
  late String unit;
  String? containsUnit;
  bool isDefault;

  double get qty => double.tryParse(qtyCtrl.text.trim().replaceAll(',', '.')) ?? 0;
}

class _ItemPresentationsEditorState extends State<ItemPresentationsEditor> {
  final List<_Row> _rows = [];
  int _nextId = 0;

  @override
  void initState() {
    super.initState();
    for (final d in widget.initial) {
      _rows.add(_Row(
        id: _nextId++,
        unit: d.unit,
        qty: d.containsQty,
        containsUnit: d.containsUnit,
        isDefault: d.isPurchaseDefault,
      ));
    }
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.qtyCtrl.dispose();
    }
    super.dispose();
  }

  List<PresentationDraft> get _drafts => [
        for (final r in _rows)
          PresentationDraft(
            unit: r.unit,
            containsQty: r.qty,
            containsUnit: r.containsUnit,
            isPurchaseDefault: r.isDefault,
          ),
      ];

  void _emit() {
    setState(() {});
    widget.onChanged(_drafts);
  }

  void _add() {
    _rows.add(_Row(id: _nextId++, unit: '', qty: 0));
    _emit();
  }

  void _remove(_Row row) {
    _rows.remove(row);
    // El campo se desmonta en este cuadro: el controlador se libera después.
    WidgetsBinding.instance.addPostFrameCallback((_) => row.qtyCtrl.dispose());
    _emit();
  }

  void _rename(_Row row, String value) {
    final old = row.unit.trim().toLowerCase();
    row.unit = value;
    // Las que contenían el nombre viejo siguen apuntando a esta fila.
    if (old.isNotEmpty && value.trim().isNotEmpty) {
      for (final other in _rows) {
        if (other.id != row.id && other.containsUnit?.trim().toLowerCase() == old) {
          other.containsUnit = value.trim();
        }
      }
    }
    _emit();
  }

  void _toggleDefault(_Row row) {
    final wasDefault = row.isDefault;
    for (final r in _rows) {
      r.isDefault = false;
    }
    row.isDefault = !wasDefault;
    _emit();
  }

  bool _containsBase(_Row r) {
    final c = r.containsUnit?.trim() ?? '';
    return c.isEmpty ||
        c.toLowerCase() == widget.baseUnit.trim().toLowerCase() ||
        sameUnit(c, widget.baseUnit);
  }

  /// Contenedores posibles para [row]: las otras presentaciones que contienen
  /// la base (máximo dos niveles).
  List<String> _containerOptions(_Row row) => [
        for (final r in _rows)
          if (r.id != row.id && r.unit.trim().isNotEmpty && _containsBase(r)) r.unit.trim(),
      ];

  @override
  Widget build(BuildContext context) {
    final check = checkPresentations(_drafts, widget.baseUnit);
    final canAdd = widget.enabled && _rows.length < kMaxItemPresentations;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Presentaciones',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.mutedForeground,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: canAdd ? _add : null,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Agregar'),
            ),
          ],
        ),
        Text(
          'Cómo viene el insumo, hasta dos niveles: «Lata = 355 ${unitShortLabel(widget.baseUnit)}», '
          '«Caja = 24 Lata». La marcada con ★ es la de compra: órdenes y recepciones la usan.',
          style: TextStyle(fontSize: 11, color: AppColors.mutedForeground),
        ),
        for (var i = 0; i < _rows.length; i++) _buildRow(_rows[i], check.items[i]),
        if (check.errors.isNotEmpty) ...[
          const SizedBox(height: 6),
          for (final e in check.errors)
            Text(
              e,
              style: TextStyle(fontSize: 11, color: AppColors.destructive),
            ),
        ],
      ],
    );
  }

  Widget _buildRow(_Row row, ResolvedPresentation resolved) {
    final options = _containerOptions(row);
    final raw = row.containsUnit?.trim() ?? '';
    var selected = '';
    var stale = false;
    if (!_containsBase(row)) {
      final match = options.where((o) => o.toLowerCase() == raw.toLowerCase());
      if (match.isNotEmpty) {
        selected = match.first;
      } else {
        selected = raw;
        stale = true;
      }
    }
    final containerItems = <DropdownMenuItem<String>>[
      DropdownMenuItem(
        value: '',
        child: Text('${unitShortLabel(widget.baseUnit)} (base)', overflow: TextOverflow.ellipsis),
      ),
      for (final o in options)
        DropdownMenuItem(value: o, child: Text(o, overflow: TextOverflow.ellipsis)),
      if (stale)
        DropdownMenuItem(
          value: selected,
          child: Text('$selected (no está)', overflow: TextOverflow.ellipsis),
        ),
    ];
    final label = resolved.baseQty == null || row.unit.trim().isEmpty
        ? null
        : presentationChainLabel(resolved, widget.baseUnit);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('presentacion-unidad-${row.id}'),
                  initialValue: row.unit,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Presentación', isDense: true),
                  items: unitDropdownItems(row.sections, emptyLabel: 'Elige…'),
                  selectedItemBuilder: unitDropdownSelectedBuilder(row.sections, emptyLabel: 'Elige…'),
                  onChanged: widget.enabled ? (v) => _rename(row, v ?? '') : null,
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Text('=', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              SizedBox(
                width: 72,
                child: TextField(
                  controller: row.qtyCtrl,
                  enabled: widget.enabled,
                  textAlign: TextAlign.end,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
                  decoration: const InputDecoration(labelText: 'Cant.', isDense: true),
                  onChanged: (_) => _emit(),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String>(
                  key: ValueKey(
                    'presentacion-contiene-${row.id}-$selected-${options.join('|')}',
                  ),
                  initialValue: selected,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'de', isDense: true),
                  items: containerItems,
                  onChanged: widget.enabled
                      ? (v) {
                          row.containsUnit = (v == null || v.isEmpty) ? null : v;
                          _emit();
                        }
                      : null,
                ),
              ),
              IconButton(
                tooltip: row.isDefault ? 'Es la de compra' : 'Usar como la de compra',
                icon: Icon(
                  row.isDefault ? Icons.star : Icons.star_border,
                  color: row.isDefault ? Colors.amber.shade700 : AppColors.mutedForeground,
                  size: 20,
                ),
                onPressed: widget.enabled ? () => _toggleDefault(row) : null,
              ),
              IconButton(
                tooltip: 'Quitar',
                icon: Icon(Icons.close, size: 18, color: AppColors.mutedForeground),
                onPressed: widget.enabled ? () => _remove(row) : null,
              ),
            ],
          ),
          if (label != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 2),
              child: Text(
                label,
                style: TextStyle(fontSize: 11, color: AppColors.mutedForeground),
              ),
            ),
        ],
      ),
    );
  }
}
