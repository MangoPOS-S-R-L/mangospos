// Activos fijos — alta y edición de la ficha.
//
// En el ALTA se elige también dónde queda y quién responde. En la EDICIÓN
// no: la ubicación y el responsable se cambian con «Trasladar / reasignar»,
// que deja su propio evento en la historia (quién lo movió, de dónde a
// dónde). Si la edición los tocara, la historia diría solo «datos editados».

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/app_toast.dart';
import '../../../core/utils/friendly_error.dart';
import '../../../data/repositories/fixed_assets_repository.dart';
import '../state/fixed_assets_state.dart';

/// Abre el formulario. Devuelve la ficha guardada, o null si se canceló.
/// [asset] null = alta.
Future<FixedAsset?> showFixedAssetFormDialog(
  BuildContext context, {
  required FixedAssetsRepository repo,
  required String businessId,
  required List<FixedAssetOption> warehouses,
  required List<FixedAssetOption> employees,
  List<String> knownCategories = const [],
  FixedAsset? asset,
}) {
  return showDialog<FixedAsset>(
    context: context,
    barrierDismissible: false,
    builder: (_) => FixedAssetFormDialog(
      repo: repo,
      businessId: businessId,
      warehouses: warehouses,
      employees: employees,
      knownCategories: knownCategories,
      asset: asset,
    ),
  );
}

/// Mensaje para un error de guardado: el código del RPC traducido, la
/// migración que falta, o el genérico.
String fixedAssetSaveError(Object e) {
  if (e is FixedAssetsMigrationMissing) return e.toString();
  return fixedAssetErrorMessage(e) ?? FriendlyError.from(e);
}

String fmtFixedAssetDate(DateTime? d) {
  if (d == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year}';
}

class FixedAssetFormDialog extends StatefulWidget {
  const FixedAssetFormDialog({
    super.key,
    required this.repo,
    required this.businessId,
    required this.warehouses,
    required this.employees,
    this.knownCategories = const [],
    this.asset,
  });

  final FixedAssetsRepository repo;
  final String businessId;
  final List<FixedAssetOption> warehouses;
  final List<FixedAssetOption> employees;
  final List<String> knownCategories;
  final FixedAsset? asset;

  @override
  State<FixedAssetFormDialog> createState() => _FixedAssetFormDialogState();
}

class _FixedAssetFormDialogState extends State<FixedAssetFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _category;
  late final TextEditingController _brand;
  late final TextEditingController _model;
  late final TextEditingController _serial;
  late final TextEditingController _cost;
  late final TextEditingController _supplier;
  late final TextEditingController _location;
  late final TextEditingController _notes;
  DateTime? _purchaseDate;
  DateTime? _warrantyUntil;
  String? _warehouseId;
  String? _employeeId;
  bool _saving = false;
  String? _error;

  /// Un id por formulario abierto: si el guardado se corta por la red y se
  /// vuelve a tocar «Registrar», el servidor devuelve la misma ficha.
  late final String _requestId = const Uuid().v4();

  bool get _isEdit => widget.asset != null;

  @override
  void initState() {
    super.initState();
    final a = widget.asset;
    _name = TextEditingController(text: a?.name ?? '');
    _category = TextEditingController(text: a?.category ?? '');
    _brand = TextEditingController(text: a?.brand ?? '');
    _model = TextEditingController(text: a?.model ?? '');
    _serial = TextEditingController(text: a?.serialNumber ?? '');
    _cost = TextEditingController(
      text: a?.purchaseCost == null ? '' : _fmtCost(a!.purchaseCost!),
    );
    _supplier = TextEditingController(text: a?.supplierName ?? '');
    _location = TextEditingController(text: a?.locationNote ?? '');
    _notes = TextEditingController(text: a?.notes ?? '');
    _purchaseDate = a?.purchaseDate;
    _warrantyUntil = a?.warrantyUntil;
    _warehouseId = a?.warehouseId;
    _employeeId = a?.assignedEmployeeId;
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _category,
      _brand,
      _model,
      _serial,
      _cost,
      _supplier,
      _location,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  static String _fmtCost(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  /// Sugeridas + las que ya usa el negocio, sin repetir.
  List<String> get _categorySuggestions {
    final seen = <String>{};
    return [
      for (final c in [...kFixedAssetCategorySuggestions, ...widget.knownCategories])
        if (seen.add(foldFixedAssetText(c))) c,
    ];
  }

  Future<void> _pickDate({required bool warranty}) async {
    final now = DateTime.now();
    final current = warranty ? _warrantyUntil : _purchaseDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: DateTime(1990),
      lastDate: DateTime(now.year + 20),
      helpText: warranty ? 'Garantía hasta' : 'Fecha de compra',
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (warranty) {
        _warrantyUntil = picked;
      } else {
        _purchaseDate = picked;
      }
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Escribe el nombre del activo.');
      return;
    }
    double? cost;
    if (_cost.text.trim().isNotEmpty) {
      cost = parseFixedAssetAmount(_cost.text);
      if (cost == null) {
        setState(() => _error = 'El costo no es un número válido.');
        return;
      }
      if (cost < 0) {
        setState(() => _error = 'El costo no puede ser negativo.');
        return;
      }
    }

    final draft = FixedAssetDraft(
      name: name,
      category: _category.text,
      brand: _brand.text,
      model: _model.text,
      serialNumber: _serial.text,
      purchaseDate: _purchaseDate,
      purchaseCost: cost,
      supplierName: _supplier.text,
      warrantyUntil: _warrantyUntil,
      warehouseId: _warehouseId,
      locationNote: _location.text,
      assignedEmployeeId: _employeeId,
      notes: _notes.text,
    );

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = _isEdit
          ? await widget.repo.updateAsset(
              assetId: widget.asset!.id,
              draft: draft,
            )
          : await widget.repo.createAsset(
              businessId: widget.businessId,
              draft: draft,
              clientRequestId: _requestId,
            );
      if (!mounted) return;
      AppToast.success(
        context,
        _isEdit ? '${saved.code} actualizado.' : '${saved.code} registrado.',
      );
      Navigator.pop(context, saved);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = fixedAssetSaveError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return AlertDialog(
      insetPadding: narrow
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 24)
          : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      contentPadding: EdgeInsets.fromLTRB(narrow ? 16 : 24, 16, narrow ? 16 : 24, 8),
      title: Text(
        _isEdit ? 'Editar ${widget.asset!.code}' : 'Nuevo activo',
      ),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: LayoutBuilder(
            builder: (context, c) {
              final twoCols = c.maxWidth >= 460;
              Widget pair(Widget a, Widget b) => twoCols
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: a),
                        const SizedBox(width: 12),
                        Expanded(child: b),
                      ],
                    )
                  : Column(children: [a, const SizedBox(height: 12), b]);

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    key: const Key('fixed-asset-form-name'),
                    controller: _name,
                    autofocus: !_isEdit,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Nombre *',
                      hintText: 'Ej.: Horno de convección',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('fixed-asset-form-category'),
                    controller: _category,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Categoría',
                      hintText: 'Elige una o escribe la tuya',
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final s in _categorySuggestions)
                        ChoiceChip(
                          label: Text(s),
                          visualDensity: VisualDensity.compact,
                          selected: foldFixedAssetText(_category.text.trim()) ==
                              foldFixedAssetText(s),
                          onSelected: (_) =>
                              setState(() => _category.text = s),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  pair(
                    TextField(
                      controller: _brand,
                      decoration: const InputDecoration(
                        labelText: 'Marca',
                        isDense: true,
                      ),
                    ),
                    TextField(
                      controller: _model,
                      decoration: const InputDecoration(
                        labelText: 'Modelo',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  pair(
                    TextField(
                      controller: _serial,
                      decoration: const InputDecoration(
                        labelText: 'Número de serie',
                        isDense: true,
                      ),
                    ),
                    TextField(
                      controller: _supplier,
                      decoration: const InputDecoration(
                        labelText: 'Proveedor',
                        hintText: 'Dónde se compró',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  pair(
                    _DateField(
                      label: 'Fecha de compra',
                      value: _purchaseDate,
                      onPick: () => _pickDate(warranty: false),
                      onClear: () => setState(() => _purchaseDate = null),
                    ),
                    _DateField(
                      label: 'Garantía hasta',
                      value: _warrantyUntil,
                      onPick: () => _pickDate(warranty: true),
                      onClear: () => setState(() => _warrantyUntil = null),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('fixed-asset-form-cost'),
                    controller: _cost,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Costo de compra',
                      helperText: 'Acepta 1,250.50 o 1250,50',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_isEdit)
                    _Hint(
                      'La ubicación y el responsable se cambian con '
                      '«Trasladar / reasignar», para que quede en la historia '
                      'quién lo movió y de dónde a dónde.',
                    )
                  else ...[
                    Text(
                      'Dónde queda y quién responde',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.foreground,
                      ),
                    ),
                    const SizedBox(height: 8),
                    pair(
                      FixedAssetWarehouseDropdown(
                        warehouses: widget.warehouses,
                        value: _warehouseId,
                        onChanged: (v) => setState(() => _warehouseId = v),
                      ),
                      FixedAssetEmployeeDropdown(
                        employees: widget.employees,
                        value: _employeeId,
                        onChanged: (v) => setState(() => _employeeId = v),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _location,
                      decoration: const InputDecoration(
                        labelText: 'Nota de ubicación',
                        hintText: 'Ej.: Cocina caliente, junto a la plancha',
                        isDense: true,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notes,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Notas',
                      hintText: 'Mantenimiento, accesorios, contacto técnico…',
                      isDense: true,
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!,
                      key: const Key('fixed-asset-form-error'),
                      style: TextStyle(
                        color: AppColors.destructive,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('fixed-asset-form-save'),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(_isEdit ? 'Guardar' : 'Registrar activo'),
        ),
      ],
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onPick,
    required this.onClear,
  });

  final String label;
  final DateTime? value;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPick,
      borderRadius: BorderRadius.circular(6),
      child: InputDecorator(
        isEmpty: value == null,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          suffixIcon: value == null
              ? const Icon(Icons.calendar_today_outlined, size: 18)
              : IconButton(
                  tooltip: 'Quitar fecha',
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: onClear,
                ),
        ),
        child: Text(fmtFixedAssetDate(value)),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.infoSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.infoBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: AppColors.info),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: AppColors.foreground),
            ),
          ),
        ],
      ),
    );
  }
}

/// Selector de bodega con «Sin bodega». Si la bodega actual ya no está en
/// la lista (se desactivó), se agrega igual: un Dropdown con un valor que no
/// está entre sus opciones revienta.
class FixedAssetWarehouseDropdown extends StatelessWidget {
  const FixedAssetWarehouseDropdown({
    super.key,
    required this.warehouses,
    required this.value,
    required this.onChanged,
    this.currentName,
  });

  final List<FixedAssetOption> warehouses;
  final String? value;
  final ValueChanged<String?> onChanged;

  /// Nombre de la bodega actual, por si ya no está entre las activas.
  final String? currentName;

  @override
  Widget build(BuildContext context) {
    final options = [...warehouses];
    final v = value;
    if (v != null && !options.any((o) => o.id == v)) {
      options.add(FixedAssetOption(v, currentName ?? 'Bodega actual'));
    }
    return DropdownButtonFormField<String?>(
      key: const Key('fixed-asset-warehouse'),
      initialValue: v,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Bodega', isDense: true),
      items: [
        const DropdownMenuItem<String?>(
          value: null,
          child: Text('Sin bodega'),
        ),
        for (final w in options)
          DropdownMenuItem<String?>(
            value: w.id,
            child: Text(w.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

/// Selector de responsable con «Sin responsable». Mismo cuidado que el de
/// bodega con un empleado que ya no está activo.
class FixedAssetEmployeeDropdown extends StatelessWidget {
  const FixedAssetEmployeeDropdown({
    super.key,
    required this.employees,
    required this.value,
    required this.onChanged,
    this.currentName,
  });

  final List<FixedAssetOption> employees;
  final String? value;
  final ValueChanged<String?> onChanged;
  final String? currentName;

  @override
  Widget build(BuildContext context) {
    final options = [...employees];
    final v = value;
    if (v != null && !options.any((o) => o.id == v)) {
      options.add(FixedAssetOption(v, currentName ?? 'Responsable actual'));
    }
    return DropdownButtonFormField<String?>(
      key: const Key('fixed-asset-employee'),
      initialValue: v,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Responsable',
        isDense: true,
      ),
      items: [
        const DropdownMenuItem<String?>(
          value: null,
          child: Text('Sin responsable'),
        ),
        for (final e in options)
          DropdownMenuItem<String?>(
            value: e.id,
            child: Text(e.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    );
  }
}
