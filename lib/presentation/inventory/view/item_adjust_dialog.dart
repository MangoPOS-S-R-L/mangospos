// Insumos v2 — Ajuste con la bodega EN CONTEXTO.
//
// El ajuste nace en la celda de una bodega concreta: se abre ya cargado con
// esa bodega y la muestra arriba de todo. Nunca se escribe un movimiento en
// una bodega que el usuario no eligió — que era el agujero del ajuste viejo,
// donde el almacén salía del estado global de la pantalla.
//
// Además cuenta en el idioma real del piso: si el insumo se compra en
// botellas, se teclean botellas y la app convierte a la unidad base.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/currency/business_currency.dart';
import '../../../core/currency/business_currency_provider.dart';
import '../../../core/inventory/pack_conversion.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../services/session/session_controller.dart';
import '../state/adjust_reasons.dart';
import '../state/inventory_state.dart';
import '../viewmodel/inventory_viewmodel.dart';

/// Formateador compartido: `decimalPattern` parsea el patrón del locale
/// en cada construcción y acá se pedía uno por método de build.
final NumberFormat _fmtQty = NumberFormat.decimalPattern('es_DO');

/// Abre el ajuste contextual. Devuelve `true` si se guardó algo.
Future<bool> showItemAdjustDialog(
  BuildContext context, {
  required String businessId,
  required InventoryItemSummary item,
  required List<InventoryWarehouse> warehouses,
  required String warehouseId,
  required Map<String, double> stockByWarehouse,
  String? initialReasonCode,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ItemAdjustDialog(
      businessId: businessId,
      item: item,
      warehouses: warehouses,
      warehouseId: warehouseId,
      stockByWarehouse: stockByWarehouse,
      initialReasonCode: initialReasonCode,
    ),
  );
  return saved == true;
}

class ItemAdjustDialog extends ConsumerStatefulWidget {
  final String businessId;
  final InventoryItemSummary item;
  final List<InventoryWarehouse> warehouses;

  /// Bodega que disparó el ajuste (la celda tocada).
  final String warehouseId;

  /// Stock del insumo por bodega — alimenta el "en sistema" del banner y el
  /// selector de "Cambiar" sin ir de nuevo al server.
  final Map<String, double> stockByWarehouse;

  /// Motivo preseleccionado. El botón "Contar" del móvil entra con
  /// `physical_count` porque el conteo físico ES la acción de piso.
  final String? initialReasonCode;

  const ItemAdjustDialog({
    super.key,
    required this.businessId,
    required this.item,
    required this.warehouses,
    required this.warehouseId,
    required this.stockByWarehouse,
    this.initialReasonCode,
  });

  @override
  ConsumerState<ItemAdjustDialog> createState() => _ItemAdjustDialogState();
}

class _ItemAdjustDialogState extends ConsumerState<ItemAdjustDialog> {
  late final TextEditingController _countedCtrl;
  late final TextEditingController _notesCtrl;
  late String _warehouseId;
  AdjustReason? _reason;

  /// True: se teclea en unidad de COMPRA (botellas) y la app convierte.
  /// Solo aplica si el insumo tiene empaque real.
  late bool _countInPack;

  bool _submitting = false;
  String? _error;

  InventoryItemSummary get _item => widget.item;

  bool get _hasPack =>
      hasPack(_item.packSize, _item.purchaseUnit, baseUnit: _item.unit);

  double get _systemStock => widget.stockByWarehouse[_warehouseId] ?? 0;

  @override
  void initState() {
    super.initState();
    _warehouseId = widget.warehouseId;
    _countInPack = hasPack(
      _item.packSize,
      _item.purchaseUnit,
      baseUnit: _item.unit,
    );
    _notesCtrl = TextEditingController();
    _countedCtrl = TextEditingController(text: _seedCounted());
    _reason = widget.initialReasonCode == null
        ? null
        : adjustReasonByCode(widget.initialReasonCode!);
  }

  /// Arranca con lo que dice el sistema: el usuario corrige sobre ese número
  /// en vez de teclear desde cero (y si no cambia nada, el guardar se bloquea).
  String _seedCounted() {
    final base = _systemStock;
    final value = _countInPack ? baseToPack(base, _item.packSize) : base;
    return _trim(value);
  }

  @override
  void dispose() {
    _countedCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  static String _trim(double v) {
    if (v == v.roundToDouble() && v.abs() < 1e12) {
      return v.toStringAsFixed(0);
    }
    final s = v.toStringAsFixed(3);
    return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  double? get _typed {
    final raw = _countedCtrl.text.trim().replaceAll(',', '.');
    if (raw.isEmpty) return null;
    return double.tryParse(raw);
  }

  /// Conteo llevado SIEMPRE a unidad base: es lo que viaja al RPC.
  double? get _countedBase {
    final typed = _typed;
    if (typed == null) return null;
    return _countInPack ? packToBase(typed, _item.packSize) : typed;
  }

  double get _delta => (_countedBase ?? _systemStock) - _systemStock;

  bool get _notesRequired => _reason?.code == 'other';

  String get _warehouseName {
    for (final w in widget.warehouses) {
      if (w.id == _warehouseId) return w.name;
    }
    return 'Bodega';
  }

  String? _validate() {
    if (_reason == null) return 'Selecciona un motivo de ajuste';
    final counted = _countedBase;
    if (counted == null) return 'Ingresa la cantidad contada';
    if (counted < 0) return 'La cantidad contada no puede ser negativa';
    if (_delta == 0) {
      return 'El conteo es igual a lo que dice el sistema; nada que ajustar';
    }
    if (_notesRequired && _notesCtrl.text.trim().isEmpty) {
      return 'Las notas son obligatorias cuando el motivo es "Otro"';
    }
    return null;
  }

  Future<void> _submit() async {
    // Un ajuste reescribe el stock contra el conteo físico: va bajo
    // `inventario.ajustes.crear`, no bajo el acceso al módulo.
    if (!ref
        .read(sessionProvider.notifier)
        .hasPermission('inventario.ajustes.crear')) {
      setState(() {
        _error = 'No tienes permiso para registrar ajustes de inventario.';
      });
      return;
    }
    final invalid = _validate();
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    try {
      await ref
          .read(inventoryRepositoryProvider)
          .adjustInventory(
            businessId: widget.businessId,
            warehouseId: _warehouseId,
            itemId: _item.id,
            countedQuantity: _countedBase!,
            reasonCode: _reason!.code,
            notes: _notesCtrl.text.trim().isEmpty
                ? null
                : _notesCtrl.text.trim(),
            costPerUnit: _item.cost,
          );
      if (!mounted) return;
      navigator.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = _humanizeError(e.toString());
      });
    }
  }

  String _humanizeError(String raw) {
    if (raw.contains('INSUFFICIENT_ROLE')) {
      return 'No tienes permisos para ajustar inventario';
    }
    if (raw.contains('NO_CHANGE')) {
      return 'El stock contado es igual al actual';
    }
    if (raw.contains('NOTES_REQUIRED_FOR_OTHER')) {
      return 'Las notas son obligatorias para motivo "Otro"';
    }
    if (raw.contains('INVALID_COUNTED_QUANTITY')) {
      return 'Cantidad contada inválida';
    }
    // La base rechaza un delta nulo/cero. Pasa con insumos que nunca tuvieron
    // stock en esta bodega si no se aplicó la migración 20260822_0001.
    if (raw.contains('INVALID_QUANTITY')) {
      return 'No se pudo calcular la diferencia contra esta bodega. '
          'Avisa a soporte: falta el fix INVALID_QUANTITY en la base.';
    }
    if (raw.contains('REASON_REQUIRED')) return 'Selecciona un motivo';
    return 'Error: $raw';
  }

  Future<void> _pickWarehouse() async {
    final fmt = _fmtQty;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppColors.card,
        title: const Text('Ajustar en otra bodega'),
        children: [
          for (final w in widget.warehouses)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, w.id),
              child: Row(
                children: [
                  Icon(
                    w.id == _warehouseId
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: w.id == _warehouseId
                        ? AppColors.primary
                        : AppColors.mutedForeground,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      w.isMain ? '${w.name}  ·  principal' : w.name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.foreground,
                      ),
                    ),
                  ),
                  Text(
                    '${fmt.format(widget.stockByWarehouse[w.id] ?? 0)} '
                    '${_item.unit}',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null || picked == _warehouseId || !mounted) return;
    setState(() {
      _warehouseId = picked;
      // El conteo previo era de OTRA bodega: re-sembramos con lo que dice el
      // sistema acá para no arrastrar un número que ya no significa nada.
      _countedCtrl.text = _seedCounted();
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final currency = currentBusinessCurrencyOrFallback(ref);
    final isNarrow = MediaQuery.of(context).size.width < 640;
    return AlertDialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      title: _title(),
      content: SizedBox(
        width: isNarrow ? double.maxFinite : 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _warehouseBanner(),
              const SizedBox(height: 14),
              _countedFields(),
              const SizedBox(height: 14),
              _deltaBanner(currency),
              const SizedBox(height: 16),
              Text(
                'Motivo',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final reason in kAdjustReasons)
                    _ReasonChip(
                      reason: reason,
                      selected: _reason?.code == reason.code,
                      onTap: _submitting
                          ? null
                          : () => setState(() {
                              _reason = reason;
                              _error = null;
                            }),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _notesCtrl,
                minLines: 2,
                maxLines: 3,
                enabled: !_submitting,
                decoration: InputDecoration(
                  hintText: 'Notas — qué pasó, quién lo vio',
                  helperText: _notesRequired
                      ? 'Obligatorio para el motivo "Otro"'
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 16,
                      color: AppColors.destructive,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.destructive,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Divider(color: AppColors.border, height: 1),
              const SizedBox(height: 10),
              Text(
                _footerHint(),
                style: TextStyle(
                  fontSize: 11,
                  height: 1.45,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Guardar ajuste'),
        ),
      ],
    );
  }

  Widget _title() {
    final bits = <String>[
      _classificationLabel(_item.itemClassification),
      _item.costingMethod == 'fifo' ? 'FIFO' : 'Promedio',
      if (_hasPack)
        '1 ${_item.purchaseUnit} = ${_trim(_item.packSize)} ${_item.unit}',
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Ajustar ${_item.name}',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                bits.join(' · '),
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Cerrar',
          onPressed: _submitting ? null : () => Navigator.pop(context, false),
          icon: Icon(Icons.close, color: AppColors.mutedForeground),
        ),
      ],
    );
  }

  static String _classificationLabel(String value) => switch (value) {
    'raw_material' => 'Materia prima',
    'finished_product' => 'Producto terminado',
    'combo' => 'Combo',
    'service' => 'Servicio',
    _ => 'Insumo',
  };

  Widget _warehouseBanner() {
    final fmt = _fmtQty;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          Icon(Icons.warehouse_outlined, size: 20, color: AppColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'BODEGA A AJUSTAR',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$_warehouseName  ·  ${fmt.format(_systemStock)} '
                  '${_item.unit} en sistema',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: AppColors.foreground,
                  ),
                ),
              ],
            ),
          ),
          if (widget.warehouses.length > 1)
            OutlinedButton(
              onPressed: _submitting ? null : _pickWarehouse,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                backgroundColor: AppColors.card,
                side: BorderSide(
                  color: AppColors.primary.withValues(alpha: 0.5),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Cambiar',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
        ],
      ),
    );
  }

  Widget _countedFields() {
    if (!_hasPack) {
      return TextField(
        controller: _countedCtrl,
        autofocus: true,
        enabled: !_submitting,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (_) => setState(() => _error = null),
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        decoration: InputDecoration(
          labelText: 'Contado en ${_item.unit}',
          suffixText: _item.unit,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
        ),
      );
    }

    final typed = _typed ?? 0;
    final mirrored = _countInPack
        ? packToBase(typed, _item.packSize)
        : baseToPack(typed, _item.packSize);
    final typedUnit = _countInPack ? _item.purchaseUnit : _item.unit;
    final mirroredUnit = _countInPack ? _item.unit : _item.purchaseUnit;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: TextField(
            controller: _countedCtrl,
            autofocus: true,
            enabled: !_submitting,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() => _error = null),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            decoration: InputDecoration(
              labelText: 'Contado en $typedUnit',
              suffixText: typedUnit,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Contar en $mirroredUnit',
          onPressed: _submitting
              ? null
              : () => setState(() {
                  _countInPack = !_countInPack;
                  _countedCtrl.text = _trim(mirrored);
                }),
          icon: Icon(Icons.swap_horiz, color: AppColors.primary),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
            decoration: BoxDecoration(
              color: AppColors.background,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '= en $mirroredUnit',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.mutedForeground,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Expanded(
                      child: Text(
                        _trim(mirrored),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: AppColors.mutedForeground,
                        ),
                      ),
                    ),
                    Text(
                      mirroredUnit,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _deltaBanner(BusinessCurrency currency) {
    final delta = _delta;
    final fmt = _fmtQty;
    final neutral = delta == 0;
    final negative = delta < 0;
    final color = neutral
        ? AppColors.mutedForeground
        : (negative ? AppColors.destructive : AppColors.success);
    final packNote = _hasPack && delta != 0
        ? ' (${_trim(baseToPack(delta.abs(), _item.packSize))} '
              '${_item.purchaseUnit})'
        : '';
    final value = _item.cost * delta.abs();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          Icon(
            neutral
                ? Icons.remove
                : (negative ? Icons.arrow_downward : Icons.arrow_upward),
            size: 20,
            color: color,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              neutral
                  ? 'Sin diferencia con el sistema'
                  : '${negative ? '−' : '+'}${fmt.format(delta.abs())} '
                        '${_item.unit}$packNote',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ),
          if (!neutral && _item.cost > 0)
            Text(
              negative
                  ? '≈ ${currency.formatAmount(value)} en merma'
                  : '≈ ${currency.formatAmount(value)} de más',
              style: TextStyle(fontSize: 12, color: color),
            ),
        ],
      ),
    );
  }

  String _footerHint() {
    final fmt = _fmtQty;
    final newTotal = _item.stock + _delta;
    return 'Queda en el kardex de $_warehouseName a tu nombre. '
        'El total del negocio pasa a ${fmt.format(newTotal)} ${_item.unit}.';
  }
}

class _ReasonChip extends StatelessWidget {
  final AdjustReason reason;
  final bool selected;
  final VoidCallback? onTap;

  const _ReasonChip({
    required this.reason,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.primary : AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.full),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.border,
            ),
            borderRadius: BorderRadius.circular(AppRadius.full),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                reason.icon,
                size: 16,
                color: selected ? Colors.white : AppColors.mutedForeground,
              ),
              const SizedBox(width: 6),
              Text(
                reason.label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : AppColors.foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
