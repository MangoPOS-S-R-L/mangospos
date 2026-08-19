// PRD 9 Fase 1D — Alta/edición de insumos (formulario completo).
//
// Vivía dentro de `inventory_items_view.dart`; se extrajo cuando esa vista
// pasó a la matriz insumo × bodega (Insumos v2) para que el CRUD del maestro
// quede separado de la lectura de existencias. El contenido del formulario no
// cambió: mismos campos, mismas validaciones, mismo repo.

import 'package:flutter/material.dart';

import '../../../../core/inventory/unit_conversion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../data/repositories/inventory_repository.dart';
import '../../state/inventory_state.dart';

class ItemFormDialog extends StatefulWidget {
  final String businessId;
  final InventoryRepository repo;
  final InventoryItemSummary? edit;

  const ItemFormDialog({
    super.key,
    required this.businessId,
    required this.repo,
    this.edit,
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
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.edit != null;

  @override
  void initState() {
    super.initState();
    final e = widget.edit;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _skuCtrl = TextEditingController(text: e?.sku ?? '');
    _barcodeCtrl = TextEditingController(text: e?.barcode ?? '');
    _descCtrl = TextEditingController(text: e?.description ?? '');
    _unitCtrl = TextEditingController(text: e?.unit ?? 'unidad');
    _purchaseUnitCtrl = TextEditingController(text: e?.purchaseUnit ?? '');
    _packSizeCtrl = TextEditingController(
      text: (e != null && e.packSize != 1) ? _trimNum(e.packSize) : '',
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

  /// Contenido por empaque a guardar. Vacío o inválido → 1 (sin empaque),
  /// lo que también resetea un valor previo al editar.
  double _packSizeForSave() {
    final raw = _packSizeCtrl.text.trim();
    if (raw.isEmpty) return 1;
    final v = double.tryParse(raw.replaceAll(',', '.'));
    return (v == null || v <= 0) ? 1 : v;
  }

  /// Opciones del dropdown de unidad base: las canónicas (unidad/ml/L/oz/g/kg)
  /// + la unidad actual del insumo si no está en la lista (para no perder
  /// valores legacy como 'lb' o 'gal' al editar).
  List<String> _baseUnitOptionsList() {
    final cur = _unitCtrl.text.trim();
    final opts = <String>[...baseUnitOptions];
    if (cur.isNotEmpty && !opts.contains(cur)) {
      opts.insert(0, cur);
    }
    return opts;
  }

  /// Valor seleccionado del dropdown (cae a la primera opción si está vacío).
  String _baseUnitValue() {
    final cur = _unitCtrl.text.trim();
    final opts = _baseUnitOptionsList();
    return opts.contains(cur) ? cur : opts.first;
  }

  /// Texto de ayuda bajo el campo de empaque: "1 botella = 750 ml".
  String? _packHelperText() {
    final pu = _purchaseUnitCtrl.text.trim();
    final base = _unitCtrl.text.trim();
    final size = double.tryParse(_packSizeCtrl.text.trim().replaceAll(',', '.'));
    if (pu.isEmpty || size == null || size <= 0) return null;
    return '1 $pu = ${_trimNum(size)} ${base.isEmpty ? 'unidad' : base}';
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
        );
      } else {
        await widget.repo.createItem(
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
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
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
                autofocus: true,
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
                  SizedBox(
                    width: 160,
                    child: DropdownButtonFormField<String>(
                      initialValue: _baseUnitValue(),
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Unidad base (stock)',
                      ),
                      items: _baseUnitOptionsList()
                          .map(
                            (u) => DropdownMenuItem(value: u, child: Text(u)),
                          )
                          .toList(growable: false),
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
              // Conversión de empaque: comprar/recibir en otra unidad (ej.
              // botella) que contiene N unidades base (ej. 750 ml). Vacío =
              // se compra en la unidad base.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _purchaseUnitCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Unidad de compra (opcional)',
                        hintText: 'botella, caja',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _packSizeCtrl,
                      decoration: InputDecoration(
                        labelText: 'Contenido por empaque',
                        hintText: '750',
                        helperText: _packHelperText(),
                        suffixText: _unitCtrl.text.trim().isEmpty
                            ? null
                            : _unitCtrl.text.trim(),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onChanged: (_) => setState(() {}),
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
