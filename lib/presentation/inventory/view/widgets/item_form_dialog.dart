// PRD 9 Fase 1D — Alta/edición de insumos (formulario completo).
//
// Vivía dentro de `inventory_items_view.dart`; se extrajo cuando esa vista
// pasó a la matriz insumo × bodega (Insumos v2) para que el CRUD del maestro
// quede separado de la lectura de existencias. El contenido del formulario no
// cambió: mismos campos, mismas validaciones, mismo repo.

import 'package:flutter/material.dart';

import '../../../../core/inventory/unit_conversion.dart';
import '../../../../core/theme/app_colors.dart';
import 'unit_dropdown.dart';
import '../../../../data/repositories/inventory_repository.dart';
import '../../state/inventory_state.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

class ItemFormDialog extends StatefulWidget {
  final String businessId;
  final InventoryRepository repo;
  final InventoryItemSummary? edit;

  /// Nombre con el que arranca el campo cuando se crea un insumo desde otro
  /// lado — hoy, desde el diálogo de productos cuando el usuario marca que lo
  /// que está creando es un insumo y no un producto de menú. Ignorado en
  /// edición (ahí manda el nombre guardado).
  final String? initialName;

  /// Arranca con el foco en el CÓDIGO DE BARRAS en vez del nombre. Lo usa el
  /// conteo físico: se entra a la ficha justamente porque el insumo no tiene
  /// código, y así se dispara la pistola sin tocar el mouse. Con el foco en
  /// el nombre, un escaneo sobrescribiría el nombre del insumo.
  final bool focusBarcode;

  /// Código con el que arranca la ficha al CREARLA. Lo usa el conteo físico
  /// cuando se escanea algo que no existe: se da de alta el insumo con ese
  /// mismo código, que es el que la pistola va a volver a leer.
  final String? initialBarcode;

  /// Se llama con la fila recién insertada, ANTES de cerrar el diálogo. El
  /// `pop` solo dice "se guardó"; quien necesita el id del insumo nuevo —el
  /// conteo, para sumarlo a la sesión— lo recibe por acá.
  final void Function(Map<String, dynamic> created)? onCreated;

  const ItemFormDialog({
    super.key,
    required this.businessId,
    required this.repo,
    this.edit,
    this.initialName,
    this.focusBarcode = false,
    this.initialBarcode,
    this.onCreated,
  });

  @override
  State<ItemFormDialog> createState() => _ItemFormDialogState();
}

class _ItemFormDialogState extends State<ItemFormDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _skuCtrl;
  late final TextEditingController _barcodeCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _unitCtrl;
  late final TextEditingController _purchaseUnitCtrl;
  late final TextEditingController _packSizeCtrl;
  late final TextEditingController _costCtrl;
  late final TextEditingController _minStockCtrl;
  late final TextEditingController _maxStockCtrl;
  late String _costingMethod;
  late bool _isActive;
  late bool _tracksLots;
  // PRD inventario avanzado: clasificación del item.
  late String _itemClassification;
  // Secciones del selector según lo GUARDADO: una unidad fuera del catálogo
  // («bolsa» como base) queda en «Actual» aunque se elija otra.
  late final List<UnitSection> _baseSections;
  late final List<UnitSection> _purchaseSections;
  // Equivalencia propia: 1 [unidad base] = N [otra unidad] (1 ea = 200 g).
  late final TextEditingController _conversionFactorCtrl;
  String _conversionUnit = '';
  // Si la ficha llegó sabiendo qué equivalencia tenía. Si no (esquema viejo)
  // y nadie la toca, al guardar no se manda: así no se borra una que exista.
  late final bool _conversionKnown;
  bool _conversionTouched = false;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.edit != null;

  @override
  void initState() {
    super.initState();
    final e = widget.edit;
    _nameCtrl = TextEditingController(
      text: e?.name ?? widget.initialName?.trim() ?? '',
    );
    _skuCtrl = TextEditingController(text: e?.sku ?? '');
    _barcodeCtrl = TextEditingController(
      text: e?.barcode ?? widget.initialBarcode?.trim() ?? '',
    );
    _descCtrl = TextEditingController(text: e?.description ?? '');
    _baseSections = baseUnitSections(current: e?.unit);
    _purchaseSections = purchaseUnitSections(current: e?.purchaseUnit);
    // «gr», «CAJAS» o «LIBRA» arrancan como su unidad del catálogo. Es la misma
    // unidad con otro nombre: ninguna cantidad cambia.
    _unitCtrl = TextEditingController(
      text: unitSelectionValue(_baseSections, e?.unit, fallback: 'unidad'),
    );
    _purchaseUnitCtrl = TextEditingController(
      text: unitSelectionValue(
        _purchaseSections,
        e?.purchaseUnit,
        fallback: '',
      ),
    );
    _packSizeCtrl = TextEditingController(
      text: (e != null && e.packSize != 1) ? _trimNum(e.packSize) : '',
    );
    _conversionKnown = e == null || e.conversionKnown;
    _conversionUnit = e?.conversionUnit ?? '';
    _conversionFactorCtrl = TextEditingController(
      text: (e != null && e.conversionFactor > 0)
          ? _trimNum(e.conversionFactor)
          : '',
    );
    _costCtrl = TextEditingController(text: e?.cost.toString() ?? '0');
    _minStockCtrl =
        TextEditingController(text: e?.minStock.toString() ?? '0');
    _maxStockCtrl = TextEditingController(
        text: e?.maxStock != null ? e!.maxStock!.toString() : '');
    _costingMethod = e?.costingMethod == 'fifo' ? 'fifo' : 'average';
    _isActive = e?.isActive ?? true;
    _tracksLots = e?.tracksLots ?? false;
    _itemClassification = _normalizeClassification(e?.itemClassification);
  }

  static const _classificationOptions = <String, String>{
    'simple': 'Simple (default)',
    'raw_material': 'Materia prima',
    'finished_product': 'Producto terminado',
    'combo': 'Combo',
    'service': 'Servicio',
  };

  static String _normalizeClassification(String? raw) {
    final v = raw?.trim();
    if (v == null || v.isEmpty) return 'simple';
    return _classificationOptions.containsKey(v) ? v : 'simple';
  }

  static String _trimNum(double v) {
    final s = v.toStringAsFixed(2);
    if (s.endsWith('.00')) return s.substring(0, s.length - 3);
    if (s.endsWith('0')) return s.substring(0, s.length - 1);
    return s;
  }

  static String _classificationHint(String value) {
    switch (value) {
      case 'raw_material':
        return 'Materia prima: entra por compras y sale al producir productos '
            'terminados o al venderse como insumo.';
      case 'finished_product':
        return 'Producto terminado: se genera por órdenes de producción a '
            'partir de materias primas.';
      case 'combo':
        return 'Combo: paquete compuesto por otros items. No requiere '
            'transformación física.';
      case 'service':
        return 'Servicio: no afecta el stock físico (ej. delivery, '
            'instalación, asesoría).';
      case 'simple':
      default:
        return 'Item genérico — no participa en flujos de producción. '
            'Comportamiento legacy.';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _skuCtrl.dispose();
    _barcodeCtrl.dispose();
    _descCtrl.dispose();
    _unitCtrl.dispose();
    _purchaseUnitCtrl.dispose();
    _packSizeCtrl.dispose();
    _conversionFactorCtrl.dispose();
    _costCtrl.dispose();
    _minStockCtrl.dispose();
    _maxStockCtrl.dispose();
    super.dispose();
  }

  String? _orNull(String v) => v.trim().isEmpty ? null : v.trim();
  double _toDouble(String v) => double.tryParse(v.trim().replaceAll(',', '.')) ?? 0;
  double? _toDoubleOrNull(String v) {
    final t = v.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t.replaceAll(',', '.'));
  }

  /// Contenido por empaque a guardar. Si la unidad de compra es una MEDIDA
  /// (lb, gal, docena) sale de la conversión; si es un contenedor (caja, saco)
  /// manda lo escrito. Sin unidad de compra → 1 (sin empaque), lo que también
  /// resetea un valor previo al editar.
  double _packSizeForSave() => resolvePackSize(
        purchaseUnit: _purchaseUnitCtrl.text,
        baseUnit: _unitCtrl.text,
        manual: _toDoubleOrNull(_packSizeCtrl.text),
        conversionUnit: _conversion?.unit,
        conversionFactor: _conversion?.factor,
      );

  /// Contenido que sale solo cuando se compra en una medida convertible.
  double? get _autoPackSize => _purchaseUnitCtrl.text.trim().isEmpty
      ? null
      : autoPackSize(
          purchaseUnit: _purchaseUnitCtrl.text,
          baseUnit: _unitCtrl.text,
          conversionUnit: _conversion?.unit,
          conversionFactor: _conversion?.factor,
        );

  double? get _conversionFactorValue =>
      _toDoubleOrNull(_conversionFactorCtrl.text);

  List<UnitSection> get _conversionSections => conversionUnitSections(
        baseUnit: _unitCtrl.text,
        current: _conversionUnit,
      );

  /// La equivalencia válida para la base elegida, o null.
  ({String unit, double factor})? get _conversion => resolveItemConversion(
        baseUnit: _unitCtrl.text,
        unit: _conversionUnit,
        factor: _conversionFactorValue,
      );

  /// Qué mandar al guardar: null = no tocarla (la ficha llegó sin saber cuál
  /// tenía y nadie la cambió); '' = borrarla; si no, la unidad.
  String? get _conversionUnitForSave {
    final conversion = _conversion;
    if (conversion != null) return conversion.unit;
    if (!_conversionKnown && !_conversionTouched) return null;
    return '';
  }

  /// Ayuda bajo la equivalencia: «1 ea = 200 g», o por qué no se guardará.
  String? _conversionHint() {
    final conversion = _conversion;
    if (conversion != null) {
      return conversionLabel(
        baseUnit: _unitCtrl.text,
        unit: conversion.unit,
        factor: conversion.factor,
      );
    }
    if (_conversionUnit.trim().isEmpty) {
      return 'Para recetas en otra clase de unidad (1 ea = 200 g)';
    }
    if ((_conversionFactorValue ?? 0) <= 0) {
      return '¿Cuánto equivale 1 ${unitShortLabel(_unitCtrl.text)}?';
    }
    return 'No aplica con esta unidad base: no se guardará';
  }

  /// Ayuda bajo el campo de empaque: «24 ea / Caja».
  String? _packHelperText() {
    final pu = _purchaseUnitCtrl.text.trim();
    if (pu.isEmpty) return null;
    if (_autoPackSize == null &&
        (_toDoubleOrNull(_packSizeCtrl.text) ?? 0) <= 0) {
      return '¿Cuánto trae cada ${unitShortLabel(pu)}?';
    }
    return packLabel(
      packSize: _packSizeForSave(),
      baseUnit: _unitCtrl.text,
      purchaseUnit: pu,
    );
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'El nombre es obligatorio.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_isEdit) {
        await widget.repo.updateItem(
          itemId: widget.edit!.id,
          name: name,
          sku: _orNull(_skuCtrl.text),
          description: _orNull(_descCtrl.text),
          unit: _unitCtrl.text.trim().isEmpty
              ? 'unidad'
              : _unitCtrl.text.trim(),
          cost: _toDouble(_costCtrl.text),
          minStock: _toDouble(_minStockCtrl.text),
          maxStock: _toDoubleOrNull(_maxStockCtrl.text),
          isActive: _isActive,
          costingMethod: _costingMethod,
          barcode: _orNull(_barcodeCtrl.text) ?? '',
          tracksLots: _tracksLots,
          itemClassification: _itemClassification,
          purchaseUnit: _purchaseUnitCtrl.text.trim(),
          packSize: _packSizeForSave(),
          conversionUnit: _conversionUnitForSave,
          conversionFactor: _conversion?.factor,
        );
      } else {
        final created = await widget.repo.createItem(
          businessId: widget.businessId,
          name: name,
          sku: _orNull(_skuCtrl.text),
          description: _orNull(_descCtrl.text),
          unit: _unitCtrl.text.trim().isEmpty
              ? 'unidad'
              : _unitCtrl.text.trim(),
          cost: _toDouble(_costCtrl.text),
          minStock: _toDouble(_minStockCtrl.text),
          maxStock: _toDoubleOrNull(_maxStockCtrl.text),
          isActive: _isActive,
          costingMethod: _costingMethod,
          barcode: _orNull(_barcodeCtrl.text),
          tracksLots: _tracksLots,
          itemClassification: _itemClassification,
          purchaseUnit: _orNull(_purchaseUnitCtrl.text),
          packSize: _packSizeForSave(),
          conversionUnit: _conversionUnitForSave,
          conversionFactor: _conversion?.factor,
        );
        widget.onCreated?.call(created);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e is InventoryConversionUnsupportedException
              ? e.message
              : FriendlyError.from(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Editar insumo' : 'Nuevo insumo'),
      content: SizedBox(
        // Responsivo: en pantallas chicas usa el ancho disponible; en grandes, 580.
        width: MediaQuery.of(context).size.width < 640 ? double.maxFinite : 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: 'Nombre *'),
                autofocus: !widget.focusBarcode,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _skuCtrl,
                      decoration: const InputDecoration(labelText: 'SKU'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _barcodeCtrl,
                      autofocus: widget.focusBarcode,
                      decoration: const InputDecoration(
                        labelText: 'Código de barras',
                        hintText: 'EAN-13, UPC, etc.',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descCtrl,
                decoration: const InputDecoration(labelText: 'Descripción'),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _unitCtrl.text,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Unidad base (stock y receta)',
                      ),
                      items: unitDropdownItems(_baseSections),
                      selectedItemBuilder:
                          unitDropdownSelectedBuilder(_baseSections),
                      onChanged: (v) {
                        if (v != null) setState(() => _unitCtrl.text = v);
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _costCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Costo (RD\$)',
                        prefixText: 'RD\$ ',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Empaque de compra: en qué se compra (caja, saco, libra) y cuánto
              // trae en la unidad base («24 ea / Caja»). Si se compra en una
              // MEDIDA convertible el contenido sale solo: 1 lb = 453.59 g.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _purchaseUnitCtrl.text,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Unidad de compra',
                      ),
                      items: unitDropdownItems(
                        _purchaseSections,
                        emptyLabel: 'Sin empaque',
                      ),
                      selectedItemBuilder: unitDropdownSelectedBuilder(
                        _purchaseSections,
                        emptyLabel: 'Sin empaque',
                      ),
                      onChanged: (v) =>
                          setState(() => _purchaseUnitCtrl.text = v ?? ''),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _autoPackSize != null
                        ? InputDecorator(
                            decoration: InputDecoration(
                              labelText: 'Contenido por empaque',
                              helperText: _packHelperText(),
                            ),
                            child: Text(
                              '${formatUnitQty(_autoPackSize!)} '
                              '${unitShortLabel(_unitCtrl.text)} · automático',
                            ),
                          )
                        : TextField(
                            controller: _packSizeCtrl,
                            enabled: _purchaseUnitCtrl.text.trim().isNotEmpty,
                            decoration: InputDecoration(
                              labelText: 'Contenido por empaque',
                              hintText: '24',
                              helperText: _packHelperText(),
                              suffixText: unitShortLabel(_unitCtrl.text),
                            ),
                            keyboardType:
                                const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Equivalencia propia: cuánto pesa o mide UNA unidad base. Con
              // ella una receta en gramos descuenta de un insumo que se cuenta
              // por unidad (1 ea = 200 g de aguacate).
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 20, right: 8),
                    child: Text(
                      '1 ${unitShortLabel(_unitCtrl.text)} =',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: _conversionFactorCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Cantidad',
                        hintText: '200',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onChanged: (_) =>
                          setState(() => _conversionTouched = true),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      // Las opciones dependen de la base: al cambiarla, la key
                      // rehace el campo con la lista nueva.
                      key: ValueKey('conversion|${_unitCtrl.text}'),
                      initialValue: unitSelectionValue(
                        _conversionSections,
                        _conversionUnit,
                        fallback: '',
                      ),
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'Equivale a (opcional)',
                        helperText: _conversionHint(),
                        helperMaxLines: 2,
                      ),
                      items: unitDropdownItems(
                        _conversionSections,
                        emptyLabel: 'Sin equivalencia',
                      ),
                      selectedItemBuilder: unitDropdownSelectedBuilder(
                        _conversionSections,
                        emptyLabel: 'Sin equivalencia',
                      ),
                      onChanged: (v) => setState(() {
                        _conversionUnit = v ?? '';
                        _conversionTouched = true;
                      }),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _minStockCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Stock mínimo',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _maxStockCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Stock máximo (opcional)',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Clasificación del item',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.mutedForeground,
                ),
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                initialValue: _itemClassification,
                isExpanded: true,
                items: _classificationOptions.entries
                    .map(
                      (entry) => DropdownMenuItem<String>(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (v) => setState(
                  () => _itemClassification = v ?? 'simple',
                ),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _classificationHint(_itemClassification),
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.mutedForeground,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Método de costeo',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.mutedForeground,
                ),
              ),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'average',
                    label: Text('Promedio ponderado'),
                    icon: Icon(Icons.calculate_outlined),
                  ),
                  ButtonSegment(
                    value: 'fifo',
                    label: Text('FIFO'),
                    icon: Icon(Icons.layers_outlined),
                  ),
                ],
                selected: {_costingMethod},
                onSelectionChanged: (s) =>
                    setState(() => _costingMethod = s.first),
              ),
              const SizedBox(height: 6),
              Text(
                _costingMethod == 'fifo'
                    ? 'FIFO: la primera capa que entró es la primera en consumirse. Útil para perecederos.'
                    : 'Promedio: el costo se recalcula al recibir mercancía. Más simple para no perecederos.',
                style: TextStyle(
                    fontSize: 11, color: AppColors.mutedForeground),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: _isActive,
                onChanged: (v) => setState(() => _isActive = v ?? true),
                title: const Text('Insumo activo'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              CheckboxListTile(
                value: _tracksLots,
                onChanged: (v) => setState(() => _tracksLots = v ?? false),
                title: const Text('Rastrear lotes y vencimientos'),
                subtitle: Text(
                  'Al recibir mercancía se solicitará número de lote y fecha '
                  'de vencimiento. Útil para perecederos, farmacéuticos y '
                  'químicos.',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.mutedForeground,
                  ),
                ),
                isThreeLine: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style:
                      TextStyle(color: AppColors.destructive, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : Text(_isEdit ? 'Guardar' : 'Crear'),
        ),
      ],
    );
  }
}
