// Alta y edición de una bodega.
//
// Vivía dentro de `warehouses_view.dart`, pero desde la Fase 2 se abre
// también desde el interior de la bodega ("Editar" en el encabezado): dos
// pantallas con el mismo formulario, un solo archivo.
//
// Al CREAR pregunta si se copia la lista de insumos de otra bodega. Copia la
// lista, nunca las existencias: la bodega nueva nace con los mismos insumos
// en cero, lista para contarse, y el stock del negocio no cambia ni un gramo.

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/utils/app_toast.dart';
import '../../../../data/repositories/inventory_repository.dart';
import '../../state/inventory_state.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

/// Valor del selector que significa "todo el catálogo de insumos del
/// negocio" en vez de una bodega concreta.
const String kCopyFromWholeCatalog = '__ALL__';

/// Opciones del selector "copiar desde": de dónde se puede copiar la lista
/// y cuál viene elegida.
///
/// Fuera quedan la virtual `__IN_TRANSIT__` (no es un lugar, es mercancía en
/// camino) y las desactivadas (su catálogo puede estar congelado hace meses).
/// Siempre queda la salida "todo el catálogo", que es lo único que hay cuando
/// el negocio abre su primera bodega.
class CopySourceOptions {
  final List<InventoryWarehouseDetail> sources;

  /// Id de bodega, o [kCopyFromWholeCatalog].
  final String defaultSourceId;

  const CopySourceOptions({
    required this.sources,
    required this.defaultSourceId,
  });

  factory CopySourceOptions.from(List<InventoryWarehouseDetail> all) {
    final usable = all
        .where((w) => !w.isInTransit && w.isActive)
        .toList(growable: false);
    if (usable.isEmpty) {
      return const CopySourceOptions(
        sources: [],
        defaultSourceId: kCopyFromWholeCatalog,
      );
    }
    // La principal es el origen natural: es donde vive el catálogo real.
    final main = usable.firstWhere((w) => w.isMain, orElse: () => usable.first);
    return CopySourceOptions(sources: usable, defaultSourceId: main.id);
  }
}

/// Abre el formulario. Devuelve `true` si se guardó algo.
Future<bool> showWarehouseFormDialog(
  BuildContext context, {
  required String businessId,
  required InventoryRepository repo,
  InventoryWarehouseDetail? edit,
  List<InventoryWarehouseDetail> warehouses = const [],
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => WarehouseFormDialog(
      businessId: businessId,
      repo: repo,
      edit: edit,
      warehouses: warehouses,
    ),
  );
  return saved == true;
}

class WarehouseFormDialog extends StatefulWidget {
  final String businessId;
  final InventoryRepository repo;
  final InventoryWarehouseDetail? edit;

  /// Bodegas ya conocidas por quien abre el diálogo. Se usan para el selector
  /// de "copiar desde"; si llega vacío, el diálogo las pide él mismo.
  final List<InventoryWarehouseDetail> warehouses;

  const WarehouseFormDialog({
    super.key,
    required this.businessId,
    required this.repo,
    this.edit,
    this.warehouses = const [],
  });

  @override
  State<WarehouseFormDialog> createState() => _WarehouseFormDialogState();
}

class _WarehouseFormDialogState extends State<WarehouseFormDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _addressCtrl;
  late bool _isMain;
  late bool _isActive;
  bool _saving = false;
  String? _error;

  /// Copiar la lista de insumos arranca APAGADO: crear filas en cero cambia
  /// lo que se ve en Insumos y en el conteo, así que es una decisión que se
  /// toma, no algo que pase por defecto.
  bool _copyItems = false;
  String? _copySource;
  List<InventoryWarehouseDetail> _sources = const [];

  // ── F0 Almacenes por sección ─────────────────────────────────────────
  //
  // La pregunta que manda es "¿este almacén sirve a un área de producción?".
  // Si la respuesta es sí, el tipo queda en `production` y hay que decir a
  // qué área: de ahí saldrá el consumo de la venta cuando F1 esté activa.
  // Si es no, el almacén puede ser general, de mermas o de préstamos.
  late bool _servesProductionArea;
  String? _productionAreaId;
  late WarehouseType _nonProductionType;
  String? _keeperEmployeeId;
  late bool _showsInPos;
  List<WarehouseAssignmentOption> _areas = const [];
  List<WarehouseAssignmentOption> _keepers = const [];

  bool get _isEdit => widget.edit != null;

  /// Tipo que se va a guardar, resuelto desde los dos controles.
  WarehouseType get _effectiveType =>
      _servesProductionArea ? WarehouseType.production : _nonProductionType;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.edit?.name ?? '');
    _addressCtrl = TextEditingController(text: widget.edit?.address ?? '');
    _isMain = widget.edit?.isMain ?? false;
    _isActive = widget.edit?.isActive ?? true;
    final edit = widget.edit;
    _servesProductionArea = edit?.isProduction ?? false;
    _productionAreaId = edit?.productionAreaId;
    _nonProductionType = (edit != null && !edit.isProduction)
        ? edit.warehouseType
        : WarehouseType.general;
    _keeperEmployeeId = edit?.keeperEmployeeId;
    _showsInPos = edit?.showsInPos ?? false;
    _loadAssignments();
    if (!_isEdit) _loadSources();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  /// Bodegas desde las que se puede copiar: las reales y activas. Si el
  /// negocio todavía no tiene ninguna, queda sólo "todo el catálogo".
  Future<void> _loadSources() async {
    var list = widget.warehouses;
    if (list.isEmpty) {
      try {
        list = await widget.repo.getAllWarehouses(widget.businessId);
      } catch (e) {
        // El selector es un extra: si falla, el alta normal sigue su curso.
        debugPrint('[bodegas] no se pudieron leer las bodegas de origen: $e');
        return;
      }
    }
    final options = CopySourceOptions.from(list);
    if (!mounted) return;
    setState(() {
      _sources = options.sources;
      _copySource = options.defaultSourceId;
    });
  }

  /// Áreas de producción y empleados para los dos selectores. Los dos son
  /// opcionales: si fallan, el formulario sigue sirviendo para lo de siempre.
  Future<void> _loadAssignments() async {
    final results = await Future.wait([
      widget.repo.getProductionAreas(widget.businessId),
      widget.repo.getKeeperCandidates(widget.businessId),
    ]);
    if (!mounted) return;
    setState(() {
      _areas = results[0];
      _keepers = results[1];
    });
  }

  /// Un id que ya no está en la lista (área desactivada, empleado dado de
  /// baja) rompe el Dropdown de Flutter. Se muestra vacío en vez de tumbar
  /// el diálogo; guardar vuelve a escribir lo que se elija.
  String? _valueIfPresent(String? id, List<WarehouseAssignmentOption> list) {
    if (id == null) return null;
    return list.any((o) => o.id == id) ? id : null;
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'El nombre es obligatorio.');
      return;
    }
    if (name == '__IN_TRANSIT__') {
      setState(() => _error = 'Ese nombre está reservado por el sistema.');
      return;
    }
    if (_servesProductionArea && _productionAreaId == null) {
      setState(() => _error =
          'Elegí a qué área de producción sirve este almacén, o desmarcá la '
          'casilla.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final address = _addressCtrl.text.trim();
      if (_isEdit) {
        await widget.repo.updateWarehouse(
          businessId: widget.businessId,
          warehouseId: widget.edit!.id,
          name: name,
          address: address.isEmpty ? null : address,
          isMain: _isMain,
          isActive: _isActive,
          warehouseType: _effectiveType,
          productionAreaId: _servesProductionArea ? _productionAreaId : null,
          keeperEmployeeId: _keeperEmployeeId,
          showsInPos: _showsInPos,
        );
        _warnIfSectionsNotSupported(name);
      } else {
        final created = await widget.repo.createWarehouse(
          businessId: widget.businessId,
          name: name,
          address: address.isEmpty ? null : address,
          isMain: _isMain,
          isActive: _isActive,
          warehouseType: _effectiveType,
          productionAreaId: _servesProductionArea ? _productionAreaId : null,
          keeperEmployeeId: _keeperEmployeeId,
          showsInPos: _showsInPos,
        );
        _warnIfSectionsNotSupported(name);
        if (_copyItems) await _copyList(created.id, name);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = FriendlyError.from(e);
        });
      }
    }
  }

  /// El almacén se guarda igual contra un servidor sin la migración de la
  /// Fase 0, pero el tipo, el área y el responsable se pierden en silencio.
  /// Si el usuario configuró algo de eso, tiene que enterarse.
  void _warnIfSectionsNotSupported(String name) {
    // Servidor sin 20260901_0006: se guardó, pero desmarcando la anterior.
    // Decirlo, o el usuario cree que quedaron las dos marcadas.
    if (_showsInPos && widget.repo.posSourceSingleOnly && mounted) {
      AppToast.warning(
        context,
        'Este servidor solo admite UNA bodega en el punto de venta, así que '
        'se desmarcó la anterior. Para usar varias hay que aplicar la '
        'migración 20260901_0006_pos_multi_warehouse.',
      );
    }
    if (widget.repo.warehouseSectionsSupported) return;
    final configuro = _effectiveType != WarehouseType.general ||
        _productionAreaId != null ||
        _keeperEmployeeId != null ||
        _showsInPos;
    if (!configuro || !mounted) return;
    AppToast.warning(
      context,
      '$name se guardó, pero el área y el responsable necesitan la '
      'migración 20260901_0001_warehouse_sections aplicada en Supabase.',
    );
  }

  /// La copia NO puede tumbar el alta: la bodega ya existe, así que un fallo
  /// acá se informa y se sigue. Volver atrás dejaría al usuario sin bodega y
  /// sin explicación.
  Future<void> _copyList(String warehouseId, String name) async {
    final source = _copySource;
    try {
      final copied = await widget.repo.copyWarehouseItems(
        targetWarehouseId: warehouseId,
        sourceWarehouseId: source == kCopyFromWholeCatalog ? null : source,
      );
      if (!mounted) return;
      if (copied == null) {
        AppToast.warning(
          context,
          '$name se creó, pero copiar la lista necesita la migración '
          '20260819_0002_copy_warehouse_items aplicada en Supabase.',
        );
      } else if (copied == 0) {
        AppToast.info(context, '$name se creó. No había insumos que copiar.');
      } else {
        AppToast.success(
          context,
          '$name se creó con $copied insumo(s) en cero, sin existencias.',
        );
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.warning(
        context,
        '$name se creó, pero no se pudo copiar la lista de insumos: $e',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Editar bodega' : 'Nueva bodega'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Nombre *',
                  hintText: 'Bodega Principal, Cocina, Bar…',
                ),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _addressCtrl,
                decoration: const InputDecoration(
                  labelText: 'Dirección (opcional)',
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: _isMain,
                onChanged: (v) => setState(() => _isMain = v ?? false),
                title: const Text('Bodega principal'),
                subtitle: const Text(
                  'Solo puede haber una. Se baja la marca de la actual si la '
                  'cambiás.',
                ),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              CheckboxListTile(
                value: _isActive,
                onChanged: (v) => setState(() => _isActive = v ?? true),
                title: const Text('Activa'),
                subtitle: const Text(
                  'Si se desactiva, no aparecerá para recibir mercancía.',
                ),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: 12),
              _sectionBlock(),
              if (!_isEdit) ...[
                const SizedBox(height: 12),
                _copySection(),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: AppColors.destructive, fontSize: 12),
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
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(_isEdit ? 'Guardar' : 'Crear'),
        ),
      ],
    );
  }

  /// F0: qué clase de almacén es, a qué área sirve y quién responde por él.
  ///
  /// La casilla del área es la pregunta principal —es lo que decide de dónde
  /// va a salir el consumo de la venta cuando F1 esté activa— así que va
  /// arriba y el resto de los usos queda para cuando la respuesta es "no".
  Widget _sectionBlock() {
    final areaValue = _valueIfPresent(_productionAreaId, _areas);
    final keeperValue = _valueIfPresent(_keeperEmployeeId, _keepers);

    return Material(
      color: AppColors.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CheckboxListTile(
              value: _showsInPos,
              onChanged: (v) => setState(() => _showsInPos = v ?? false),
              title: const Text(
                'Mostrar los productos de esta bodega en el punto de venta',
              ),
              subtitle: const Text(
                'El punto de venta suma la existencia de todas las bodegas '
                'marcadas y descuenta de la principal primero; cuando se '
                'acaba, sigue con la siguiente. Podés marcar varias. Los '
                'productos que tengan área de producción no pasan por acá: '
                'salen de la bodega de su área.',
              ),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            if (_showsInPos) ...[
              const SizedBox(height: 2),
              Text(
                'Antes de guardar: si ninguna de las bodegas marcadas tiene '
                'existencia de un producto, ese producto se bloquea en la '
                'venta. Revisá que entre todas cubran el catálogo.',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: AppColors.destructive,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Divider(color: AppColors.border, height: 20),
            CheckboxListTile(
              value: _servesProductionArea,
              onChanged: (v) => setState(() {
                _servesProductionArea = v ?? false;
                if (!_servesProductionArea) _productionAreaId = null;
              }),
              title: const Text('Está asignado a un área de producción'),
              subtitle: const Text(
                'Cocina, Bar, Food Shop. Lo que se venda de esa área va a '
                'descontar de este almacén.',
              ),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            if (_servesProductionArea) ...[
              const SizedBox(height: 4),
              if (_areas.isEmpty)
                Text(
                  'Este negocio todavía no tiene áreas configuradas. Se crean '
                  'en Ajustes → Impresión → Áreas.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                )
              else
                DropdownButtonFormField<String>(
                  initialValue: areaValue,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Área que abastece *',
                    isDense: true,
                  ),
                  items: [
                    for (final a in _areas)
                      DropdownMenuItem(
                        value: a.id,
                        child: Text(a.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _productionAreaId = v),
                ),
            ] else ...[
              const SizedBox(height: 4),
              DropdownButtonFormField<WarehouseType>(
                initialValue: _nonProductionType,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Uso del almacén',
                  isDense: true,
                ),
                items: [
                  for (final t in const [
                    WarehouseType.general,
                    WarehouseType.waste,
                    WarehouseType.loan,
                  ])
                    DropdownMenuItem(
                      value: t,
                      child: Text(
                        '${t.label} — ${t.description}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setState(
                  () => _nonProductionType = v ?? WarehouseType.general,
                ),
              ),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: keeperValue,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Responsable',
                isDense: true,
                helperText: 'Quién responde por lo que entra y sale de acá.',
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Sin responsable'),
                ),
                for (final k in _keepers)
                  DropdownMenuItem<String?>(
                    value: k.id,
                    child: Text(k.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _keeperEmployeeId = v),
            ),
          ],
        ),
      ),
    );
  }

  Widget _copySection() {
    // `Material` y no un `Container` decorado: el ListTile de la casilla
    // pinta su tinta sobre el Material más cercano, y con una caja de color
    // en el medio Flutter lanza el error de "ink en un fondo intermedio".
    return Material(
      color: AppColors.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CheckboxListTile(
              value: _copyItems,
              onChanged: (v) => setState(() => _copyItems = v ?? false),
              title: const Text('Copiar la lista de insumos'),
              subtitle: const Text(
                'Se copian los insumos, NO las existencias: la bodega nueva '
                'arranca en cero y ya se puede contar y fijarle mínimos.',
              ),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            if (_copyItems) ...[
              const SizedBox(height: 4),
              DropdownButtonFormField<String>(
                initialValue: _copySource,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Copiar desde',
                  isDense: true,
                ),
                items: [
                  for (final w in _sources)
                    DropdownMenuItem(
                      value: w.id,
                      child: Text(w.name, overflow: TextOverflow.ellipsis),
                    ),
                  const DropdownMenuItem(
                    value: kCopyFromWholeCatalog,
                    child: Text('Todo el catálogo de insumos'),
                  ),
                ],
                onChanged: (v) => setState(() => _copySource = v),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
