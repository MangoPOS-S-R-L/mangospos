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

  bool get _isEdit => widget.edit != null;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.edit?.name ?? '');
    _addressCtrl = TextEditingController(text: widget.edit?.address ?? '');
    _isMain = widget.edit?.isMain ?? false;
    _isActive = widget.edit?.isActive ?? true;
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
        );
      } else {
        final created = await widget.repo.createWarehouse(
          businessId: widget.businessId,
          name: name,
          address: address.isEmpty ? null : address,
          isMain: _isMain,
          isActive: _isActive,
        );
        if (_copyItems) await _copyList(created.id, name);
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
              if (!_isEdit) _copySection(),
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
