// Activos fijos — alta y edición de la ficha.
//
// En el ALTA se elige también dónde queda y quién responde. En la EDICIÓN
// no: la ubicación y el responsable se cambian con «Trasladar / reasignar»,
// que deja su propio evento en la historia (quién lo movió, de dónde a
// dónde). Si la edición los tocara, la historia diría solo «datos editados».
//
// 20261001_0050: los activos YA tienen etiqueta. El código se puede escribir
// (vacío = el sistema asigna AF-00001), una ficha puede cubrir varias
// unidades («Silla de madera ×40») y el costo pasa a ser VALOR UNITARIO, con
// el total a la vista. Si la cantidad baja en una edición, se pide el motivo:
// queda en la historia («se rompieron 2»).
//
// El mismo formulario sirve para registrar en el acto lo que aparece durante
// una verificación: la ubicación queda fija (la de la verificación) y el
// guardado pasa por [FixedAssetFormDialog.onCreate].

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../../core/currency/business_currency.dart';
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
  BusinessCurrency money = BusinessCurrency.fallbackDop,
  bool supportsQuantity = true,
  String? initialCode,
  FixedAssetOption? lockedWarehouse,
  String? title,
  Future<FixedAsset> Function(FixedAssetDraft draft, String clientRequestId)?
  onCreate,
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
      money: money,
      supportsQuantity: supportsQuantity,
      initialCode: initialCode,
      lockedWarehouse: lockedWarehouse,
      title: title,
      onCreate: onCreate,
    ),
  );
}

/// Mensaje para un error de guardado: el código del RPC traducido, la
/// migración que falta, o el genérico.
String fixedAssetSaveError(Object e) {
  if (e is FixedAssetsMigrationMissing ||
      e is FixedAssetVerificationMigrationMissing ||
      e is FixedAssetVerificationNotFound) {
    return e.toString();
  }
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
    this.money = BusinessCurrency.fallbackDop,
    this.supportsQuantity = true,
    this.initialCode,
    this.lockedWarehouse,
    this.title,
    this.onCreate,
  });

  final FixedAssetsRepository repo;
  final String businessId;
  final List<FixedAssetOption> warehouses;
  final List<FixedAssetOption> employees;
  final List<String> knownCategories;
  final FixedAsset? asset;
  final BusinessCurrency money;

  /// false = la base solo tiene 0052: no hay código propio ni cantidad.
  final bool supportsQuantity;

  /// Código con el que arranca el campo (el que se escaneó y no existía).
  final String? initialCode;

  /// Ubicación fija (alta durante una verificación de esa ubicación).
  final FixedAssetOption? lockedWarehouse;
  final String? title;

  /// Reemplaza `repo.createAsset` en el alta (p. ej. el alta en el acto de
  /// una verificación). Recibe el id del intento para que un reintento no
  /// duplique.
  final Future<FixedAsset> Function(
    FixedAssetDraft draft,
    String clientRequestId,
  )?
  onCreate;

  @override
  State<FixedAssetFormDialog> createState() => _FixedAssetFormDialogState();
}

class _FixedAssetFormDialogState extends State<FixedAssetFormDialog> {
  late final TextEditingController _code;
  late final TextEditingController _quantity;
  late final TextEditingController _name;
  late final TextEditingController _category;
  late final TextEditingController _brand;
  late final TextEditingController _model;
  late final TextEditingController _serial;
  late final TextEditingController _cost;
  late final TextEditingController _supplier;
  late final TextEditingController _location;
  late final TextEditingController _notes;
  late final TextEditingController _changeNote;
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
    _code = TextEditingController(text: a?.code ?? widget.initialCode ?? '');
    _quantity = TextEditingController(text: '${a?.quantity ?? 1}');
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
    _changeNote = TextEditingController();
    _purchaseDate = a?.purchaseDate;
    _warrantyUntil = a?.warrantyUntil;
    _warehouseId = widget.lockedWarehouse?.id ?? a?.warehouseId;
    _employeeId = a?.assignedEmployeeId;
  }

  @override
  void dispose() {
    for (final c in [
      _code,
      _quantity,
      _name,
      _category,
      _brand,
      _model,
      _serial,
      _cost,
      _supplier,
      _location,
      _notes,
      _changeNote,
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

  /// Cantidad escrita (null si no es un entero).
  int? get _typedQuantity => int.tryParse(_quantity.text.trim());

  /// En la edición: ¿bajó la cantidad? Entonces el motivo es obligatorio.
  bool get _quantityDecreased {
    final a = widget.asset;
    final q = _typedQuantity;
    return a != null && q != null && q < a.quantity;
  }

  bool get _quantityChanged {
    final a = widget.asset;
    final q = _typedQuantity;
    return a != null && q != null && q != a.quantity;
  }

  /// «Total: RD$100,000.00 (40 × RD$2,500.00)», o null si falta un dato.
  String? get _totalLabel {
    final unit = parseFixedAssetAmount(_cost.text);
    if (unit == null || unit < 0) return null;
    final q = widget.supportsQuantity ? (_typedQuantity ?? 0) : 1;
    if (q < 1) return null;
    final total = widget.money.formatAmount(unit * q);
    return q == 1
        ? 'Total: $total'
        : 'Total: $total ($q × ${widget.money.formatAmount(unit)})';
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

  void _fail(String message) => setState(() => _error = message);

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return _fail('Escribe el nombre del activo.');

    String? code;
    int? quantity;
    String? changeNote;
    if (widget.supportsQuantity) {
      code = _code.text.trim();
      if (code.length > kFixedAssetCodeMaxLength) {
        return _fail(
          'El código de etiqueta no puede pasar de '
          '$kFixedAssetCodeMaxLength caracteres.',
        );
      }
      if (_isEdit && code.isEmpty) {
        return _fail('El código no puede quedar vacío.');
      }
      quantity = _typedQuantity;
      if (quantity == null || quantity < 1) {
        return _fail(
          'La cantidad tiene que ser un número entero de 1 en adelante.',
        );
      }
      if (_quantityChanged) {
        changeNote = _changeNote.text.trim();
        if (_quantityDecreased && changeNote.isEmpty) {
          return _fail(
            'Escribe por qué baja la cantidad (por ejemplo: «se rompieron 2»).',
          );
        }
      }
    }

    double? cost;
    if (_cost.text.trim().isNotEmpty) {
      cost = parseFixedAssetAmount(_cost.text);
      if (cost == null) return _fail('El valor unitario no es un número válido.');
      if (cost < 0) return _fail('El valor unitario no puede ser negativo.');
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
      code: code,
      quantity: quantity,
      changeNote: changeNote,
    );

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final FixedAsset saved;
      if (_isEdit) {
        saved = await widget.repo.updateAsset(
          assetId: widget.asset!.id,
          draft: draft,
        );
      } else if (widget.onCreate != null) {
        saved = await widget.onCreate!(draft, _requestId);
      } else {
        saved = await widget.repo.createAsset(
          businessId: widget.businessId,
          draft: draft,
          clientRequestId: _requestId,
        );
      }
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
    final total = _totalLabel;
    return AlertDialog(
      insetPadding: narrow
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 24)
          : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      contentPadding: EdgeInsets.fromLTRB(narrow ? 16 : 24, 16, narrow ? 16 : 24, 8),
      title: Text(
        widget.title ??
            (_isEdit ? 'Editar ${widget.asset!.code}' : 'Nuevo activo'),
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
                  if (widget.supportsQuantity) ...[
                    pair(
                      TextField(
                        key: const Key('fixed-asset-form-code'),
                        controller: _code,
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(
                            kFixedAssetCodeMaxLength,
                          ),
                        ],
                        decoration: InputDecoration(
                          labelText:
                              _isEdit ? 'Código de etiqueta *' : 'Código de etiqueta',
                          helperText: _isEdit
                              ? null
                              : 'Déjalo vacío y el sistema asigna AF-00001',
                          isDense: true,
                        ),
                      ),
                      TextField(
                        key: const Key('fixed-asset-form-quantity'),
                        controller: _quantity,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Cantidad *',
                          helperText: 'Varias iguales con una sola etiqueta',
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    if (_quantityChanged) ...[
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('fixed-asset-form-change-note'),
                        controller: _changeNote,
                        decoration: InputDecoration(
                          labelText: _quantityDecreased
                              ? 'Por qué baja de ${widget.asset!.quantity} a '
                                    '${_typedQuantity ?? ''} *'
                              : 'Por qué sube la cantidad (opcional)',
                          hintText: _quantityDecreased
                              ? 'Ej.: se rompieron 2'
                              : 'Ej.: se compraron 5 más',
                          isDense: true,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                  ] else ...[
                    const _Hint(
                      'Código propio y cantidad: falta aplicar la migración '
                      '20261001_0050_fixed_asset_verification.sql. Por ahora '
                      'el sistema asigna el código y cada ficha es una unidad.',
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    key: const Key('fixed-asset-form-name'),
                    controller: _name,
                    autofocus: !_isEdit && widget.initialCode == null,
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
                  TextField(
                    key: const Key('fixed-asset-form-cost'),
                    controller: _cost,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Valor unitario',
                      helperText: 'Lo que costó o lo que vale hoy, por unidad. '
                          'Acepta 1,250.50 o 1250,50',
                      helperMaxLines: 2,
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  if (total != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      total,
                      key: const Key('fixed-asset-form-total'),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: AppColors.foreground,
                      ),
                    ),
                  ],
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
                  const SizedBox(height: 16),
                  if (_isEdit)
                    const _Hint(
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
                      widget.lockedWarehouse != null
                          ? InputDecorator(
                              key: const Key('fixed-asset-locked-warehouse'),
                              decoration: const InputDecoration(
                                labelText: 'Bodega',
                                helperText: 'La de la verificación',
                                isDense: true,
                              ),
                              child: Text(
                                widget.lockedWarehouse!.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            )
                          : FixedAssetWarehouseDropdown(
                              warehouses: widget.warehouses,
                              value: _warehouseId,
                              onChanged: (v) =>
                                  setState(() => _warehouseId = v),
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
