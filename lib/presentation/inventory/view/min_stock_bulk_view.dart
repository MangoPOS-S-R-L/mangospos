// Mínimos en lote (Compras F3).
//
// Cambia el mínimo de muchos insumos a la vez: se filtra (almacén, suplidor,
// clasificación, rotación, búsqueda), se selecciona y se aplica el sugerido por
// consumo, un valor, un porcentaje o se quita; o se exporta a Excel, se llena
// «Mínimo nuevo» y se vuelve a subir. Nada se guarda hasta «Guardar»: todo va en
// UNA transacción con `fn_inventory_set_min_stock_bulk` (20260915_0007).
//
// Sin almacén se edita el mínimo GENERAL del insumo (el de las alertas de stock
// bajo); con almacén, el mínimo PROPIO de ese almacén.

import 'package:excel/excel.dart' show Excel;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/core/inventory/min_stock_bulk.dart';
import 'package:mangopos/core/inventory/suggested_order.dart';
import 'package:mangopos/core/inventory/unit_conversion.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/core/utils/export/report_exporter.dart';
import 'package:mangopos/core/utils/friendly_error.dart';
import 'package:mangopos/data/repositories/min_stock_bulk_repository.dart';
import 'package:mangopos/data/repositories/purchase_projection_repository.dart';
import 'package:mangopos/presentation/inventory/state/inventory_state.dart';
import 'package:mangopos/presentation/inventory/viewmodel/inventory_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';

const _editPermission = 'inventario.productos.crear_editar';

const _safetyOptions = [2, 3, 5, 7];

const _classificationOptions = [
  ('', 'Todas'),
  ('raw_material', 'Materia prima'),
  ('finished_product', 'Producto terminado'),
  ('simple', 'Simple'),
];

const _allSuppliers = '';
const _noSupplier = '__sin_suplidor__';

/// Valor del selector de alcance que significa «mínimo general».
const _generalScope = '';

class MinStockBulkView extends ConsumerStatefulWidget {
  const MinStockBulkView({super.key});

  @override
  ConsumerState<MinStockBulkView> createState() => _MinStockBulkViewState();
}

class _MinStockBulkViewState extends ConsumerState<MinStockBulkView> {
  String? _businessId;
  bool _loading = true;
  bool _unsupported = false;
  bool _saving = false;
  String? _error;
  int _loadSeq = 0;

  List<InventoryWarehouse> _warehouses = const [];

  /// null = mínimo general.
  String? _warehouseId;
  Map<String, SuggestedOrderSupplier> _suppliers = const {};
  List<MinStockRow> _rows = const [];
  Map<String, MinStockRow> _rowsById = const {};

  int _safetyDays = 3;
  String _classification = '';
  String _supplierFilter = _allSuppliers;
  final Set<RotationClass> _rotations = {};
  String _search = '';
  bool _onlyChanged = false;

  final Set<String> _selected = {};

  /// itemId → mínimo nuevo sin guardar (null = quitar).
  final Map<String, double?> _pending = {};
  final Map<String, TextEditingController> _ctrls = {};
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _load(first: true));
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    _searchCtrl.dispose();
    super.dispose();
  }

  bool get _perWarehouse => _warehouseId != null;

  String get _warehouseName {
    for (final w in _warehouses) {
      if (w.id == _warehouseId) return w.name;
    }
    return 'el almacén';
  }

  String get _scopeLabel => _perWarehouse
      ? 'mínimo propio de $_warehouseName'
      : 'mínimo general';

  Map<String, double?> get _changes => realMinStockChanges(
        pending: _pending,
        rows: _rowsById,
        perWarehouse: _perWarehouse,
      );

  String _pendingText(String itemId) {
    if (!_pending.containsKey(itemId)) return '';
    final value = _pending[itemId];
    return value == null ? '' : formatUnitQty(value);
  }

  TextEditingController _ctrl(String itemId) => _ctrls.putIfAbsent(
        itemId,
        () => TextEditingController(text: _pendingText(itemId)),
      );

  void _syncCtrls(Iterable<String> itemIds) {
    for (final id in itemIds) {
      _ctrls[id]?.text = _pendingText(id);
    }
  }

  Future<void> _load({bool first = false, bool resetEdits = false}) async {
    final seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final businessId = _businessId ??= await BusinessResolver.ensure('auto');
      final projectionRepo = ref.read(purchaseProjectionRepositoryProvider);
      final repo = ref.read(minStockBulkRepositoryProvider);
      if (first) {
        final warehouses =
            await ref.read(inventoryRepositoryProvider).getWarehouses(businessId);
        _warehouses = warehouses
            .where((w) => w.name != '__IN_TRANSIT__')
            .toList(growable: false);
        try {
          _suppliers = await projectionRepo.getSuppliers(businessId);
        } catch (e) {
          debugPrint('[mínimos en lote] no se pudieron leer los suplidores: $e');
        }
      }

      final warehouseId = _warehouseId;
      final results = await Future.wait<Object?>([
        projectionRepo.getProjection(
          businessId: businessId,
          warehouseId: warehouseId,
          safetyDays: _safetyDays,
        ),
        repo.getItemLimits(businessId),
        warehouseId == null
            ? Future.value(const <String, double>{})
            : repo.getWarehouseMins(warehouseId),
      ]);
      if (!mounted || seq != _loadSeq) return;

      final lines = results[0] as List<ProjectionLine>?;
      if (lines == null) {
        setState(() {
          _unsupported = true;
          _loading = false;
        });
        return;
      }
      final limits = results[1] as Map<String, ({double min, double? max})>;
      final mins = results[2] as Map<String, double>;
      final rotation = rotationClasses(lines);
      final rows = [
        for (final line in lines)
          MinStockRow(
            line: line,
            rotation: rotation[line.itemId] ?? RotationClass.dormant,
            globalMin: limits[line.itemId]?.min ?? line.minStock,
            warehouseMin: warehouseId == null ? null : mins[line.itemId],
            maxStock: limits[line.itemId]?.max,
          ),
      ]..sort((a, b) {
          final byUse = b.line.dailyConsumption.compareTo(a.line.dailyConsumption);
          return byUse != 0
              ? byUse
              : a.line.itemName.toLowerCase().compareTo(b.line.itemName.toLowerCase());
        });

      setState(() {
        _rows = rows;
        _rowsById = {for (final r in rows) r.itemId: r};
        if (resetEdits) {
          _pending.clear();
          _selected.clear();
          _onlyChanged = false;
        }
        _selected.removeWhere((id) => !_rowsById.containsKey(id));
        _syncCtrls(_ctrls.keys);
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _error = FriendlyError.humanize('No se pudieron cargar los mínimos: $e');
        _loading = false;
      });
    }
  }

  List<MinStockRow> get _visibleRows {
    final query = _search.trim().toLowerCase();
    final changed = _onlyChanged ? _changes.keys.toSet() : null;
    return _rows.where((r) {
      final line = r.line;
      if (_classification.isNotEmpty && line.classification != _classification) {
        return false;
      }
      if (_supplierFilter != _allSuppliers) {
        if (_supplierFilter == _noSupplier
            ? line.supplierId != null
            : line.supplierId != _supplierFilter) {
          return false;
        }
      }
      if (_rotations.isNotEmpty && !_rotations.contains(r.rotation)) return false;
      if (changed != null && !changed.contains(r.itemId)) return false;
      if (query.isNotEmpty &&
          !line.itemName.toLowerCase().contains(query) &&
          !(line.sku?.toLowerCase().contains(query) ?? false)) {
        return false;
      }
      return true;
    }).toList(growable: false);
  }

  /// Si hay cambios sin guardar, pregunta antes de perderlos.
  Future<bool> _confirmDiscard() async {
    final n = _changes.length;
    if (n == 0) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cambios sin guardar'),
        content: Text(
          n == 1
              ? 'Tienes 1 mínimo sin guardar. Si cambias de almacén se pierde.'
              : 'Tienes $n mínimos sin guardar. Si cambias de almacén se pierden.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Seguir editando'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.destructive),
            child: const Text('Descartar'),
          ),
        ],
      ),
    );
    return discard == true;
  }

  Future<void> _changeScope(String scope) async {
    final next = scope == _generalScope ? null : scope;
    if (next == _warehouseId) return;
    if (!await _confirmDiscard() || !mounted) return;
    setState(() => _warehouseId = next);
    await _load(resetEdits: true);
  }

  void _onTyped(String itemId, String raw) {
    final text = raw.trim();
    setState(() {
      if (text.isEmpty) {
        _pending.remove(itemId);
        return;
      }
      final value = double.tryParse(text.replaceAll(',', '.'));
      if (value == null || value < 0) return;
      _pending[itemId] = value;
    });
  }

  void _setPending(String itemId, double? value, {bool undo = false}) {
    setState(() {
      if (undo) {
        _pending.remove(itemId);
      } else {
        _pending[itemId] = value;
      }
      _syncCtrls([itemId]);
    });
  }

  Future<void> _bulk(MinStockBulkAction action) async {
    final rows = [
      for (final id in _selected)
        if (_rowsById[id] != null) _rowsById[id]!,
    ];
    if (rows.isEmpty) return;
    var value = 0.0;
    if (action == MinStockBulkAction.setValue ||
        action == MinStockBulkAction.adjustPercent) {
      final percent = action == MinStockBulkAction.adjustPercent;
      final picked = await showDialog<double>(
        context: context,
        builder: (_) => _NumberDialog(
          title: percent
              ? 'Subir o bajar ${rows.length} mínimos'
              : 'Poner el mismo mínimo a ${rows.length} insumos',
          label: percent ? 'Porcentaje (negativo para bajar)' : 'Mínimo',
          suffix: percent ? '%' : null,
          allowNegative: percent,
        ),
      );
      if (picked == null || !mounted) return;
      value = picked;
    }
    final values = bulkMinStock(rows: rows, action: action, value: value);
    setState(() {
      _pending.addAll(values);
      _syncCtrls(values.keys);
    });
    AppToast.info(
      context,
      '${values.length} ${values.length == 1 ? 'mínimo' : 'mínimos'} sin guardar. '
      'Revísalos y toca «Guardar».',
    );
  }

  Future<void> _save() async {
    final changes = _changes;
    final businessId = _businessId;
    if (_saving || changes.isEmpty || businessId == null) return;
    final n = changes.length;
    final clears = changes.values.where((v) => v == null).length;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(n == 1 ? 'Guardar 1 mínimo' : 'Guardar $n mínimos'),
        content: Text(
          'Se cambia el $_scopeLabel de $n ${n == 1 ? 'insumo' : 'insumos'}'
          '${clears > 0 ? ' ($clears se ${clears == 1 ? 'quita' : 'quitan'})' : ''}. '
          'Se guardan todos juntos: si uno falla, no se guarda ninguno.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: MangoColors.primaryOrange),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    try {
      final result = await ref.read(minStockBulkRepositoryProvider).setMinStockBulk(
            businessId: businessId,
            warehouseId: _warehouseId,
            changes: changes,
          );
      if (!mounted) return;
      AppToast.success(
        context,
        'Se guardaron ${result.updated} ${result.updated == 1 ? 'mínimo' : 'mínimos'}'
        '${result.unchanged > 0 ? ' (${result.unchanged} ya tenían ese valor)' : ''}.',
      );
      _pending.clear();
      _onlyChanged = false;
      await _load();
    } on MinStockBulkUnsupported catch (e) {
      if (mounted) AppToast.warning(context, e.toString());
    } on PostgrestException catch (e) {
      if (!mounted) return;
      final denied = e.message.contains('ACCESS_DENIED') || e.message.contains('AUTH_REQUIRED');
      AppToast.error(
        context,
        denied
            ? 'No tienes permiso para editar insumos en este negocio.'
            : FriendlyError.humanize('No se guardaron los mínimos: ${e.message}'),
      );
    } catch (e) {
      if (mounted) {
        AppToast.error(context, FriendlyError.humanize('No se guardaron los mínimos: $e'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _export() async {
    final rows = _visibleRows;
    if (rows.isEmpty) {
      AppToast.info(context, 'No hay insumos para exportar con estos filtros.');
      return;
    }
    final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
    final scope = _perWarehouse
        ? _warehouseName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        : 'general';
    try {
      final saved = await ReportExporter.exportExcel(
        filename: 'minimos_${scope}_$stamp',
        sheetName: 'Minimos',
        headers: minStockExportHeaders,
        rows: buildMinStockExportRows(rows),
        numericColumns: minStockExportNumericColumns,
      );
      if (!mounted) return;
      if (saved) {
        AppToast.success(
          context,
          'Excel listo. Llena «Mínimo nuevo» (o escribe «quitar») y súbelo con «Importar».',
        );
      } else {
        AppToast.info(context, 'No se pudo guardar el archivo: la tabla quedó copiada.');
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, FriendlyError.humanize('No se pudo exportar: $e'));
      }
    }
  }

  Future<void> _import() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
    );
    if (picked == null || picked.files.isEmpty || !mounted) return;
    final MinStockImportResult result;
    try {
      final bytes = await picked.files.first.readAsBytes();
      if (!mounted) return;
      final book = Excel.decodeBytes(bytes);
      final table = <List<String?>>[];
      for (final sheet in book.tables.values) {
        for (final row in sheet.rows) {
          table.add(row.map((cell) => cell?.value?.toString()).toList());
        }
        break; // solo la primera hoja
      }
      result = parseMinStockImport(table, _rows);
    } catch (e) {
      AppToast.error(context, FriendlyError.humanize('No se pudo leer el Excel: $e'));
      return;
    }
    if (!mounted) return;
    final apply = await showDialog<bool>(
      context: context,
      builder: (_) => _ImportSummaryDialog(result: result, scopeLabel: _scopeLabel),
    );
    if (apply != true || !mounted) return;
    setState(() {
      _pending.addAll(result.changes);
      _syncCtrls(result.changes.keys);
      _onlyChanged = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final canEdit =
        ref.watch(sessionProvider.notifier).hasPermission(_editPermission);

    if (_unsupported) {
      return Scaffold(
        appBar: AppBar(title: const Text('Mínimos en lote')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Esta pantalla usa la proyección de compras: necesita la migración '
              '20260915_0004 aplicada en Supabase.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final visible = _visibleRows;
    final changes = _changes;
    final visibleSelected = visible.where((r) => _selected.contains(r.itemId)).length;
    final supplierOptions = <String, String>{
      for (final r in _rows)
        if (r.line.supplierId != null)
          r.line.supplierId!: _suppliers[r.line.supplierId]?.name ??
              r.line.supplierName ??
              'Suplidor',
    };

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.6,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Regresar',
          onPressed: () => Navigator.of(context).canPop()
              ? Navigator.of(context).pop()
              : context.go(AppRoutes.inventoryHome),
        ),
        title: const Text('Mínimos en lote'),
        actions: [
          IconButton(
            tooltip: 'Exportar a Excel',
            icon: const Icon(Icons.download_outlined),
            onPressed: _loading ? null : _export,
          ),
          if (canEdit)
            IconButton(
              tooltip: 'Importar Excel',
              icon: const Icon(Icons.upload_file_outlined),
              onPressed: _loading ? null : _import,
            ),
          IconButton(
            tooltip: 'Recalcular',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _load(),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          _FiltersBar(
            warehouses: _warehouses,
            scope: _warehouseId ?? _generalScope,
            safetyDays: _safetyDays,
            classification: _classification,
            supplierFilter: _supplierFilter,
            supplierOptions: supplierOptions,
            rotations: _rotations,
            onlyChanged: _onlyChanged,
            searchCtrl: _searchCtrl,
            canEdit: canEdit,
            onScope: _changeScope,
            onSafety: (days) {
              if (days == _safetyDays) return;
              setState(() => _safetyDays = days);
              _load();
            },
            onClassification: (v) => setState(() => _classification = v),
            onSupplier: (v) => setState(() => _supplierFilter = v),
            onRotation: (c, on) => setState(() => on ? _rotations.add(c) : _rotations.remove(c)),
            onOnlyChanged: (v) => setState(() => _onlyChanged = v),
            onSearch: (v) => setState(() => _search = v),
          ),
          if (!_loading && _error == null)
            _SelectionBar(
              visibleCount: visible.length,
              selectedCount: _selected.length,
              visibleSelected: visibleSelected,
              canEdit: canEdit,
              onSelectAll: (select) => setState(() {
                for (final r in visible) {
                  select ? _selected.add(r.itemId) : _selected.remove(r.itemId);
                }
              }),
              onClearSelection: () => setState(_selected.clear),
              onAction: _bulk,
            ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation(MangoColors.primaryOrange),
                    ),
                  )
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_error!, textAlign: TextAlign.center),
                        ),
                      )
                    : visible.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                _rows.isEmpty
                                    ? 'Este negocio no tiene insumos activos.'
                                    : 'Ningún insumo coincide con los filtros.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: MangoColors.muted),
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                            itemCount: visible.length,
                            itemBuilder: (_, i) {
                              final row = visible[i];
                              final id = row.itemId;
                              return _MinRow(
                                row: row,
                                perWarehouse: _perWarehouse,
                                selected: _selected.contains(id),
                                hasPending: _pending.containsKey(id),
                                pendingValue: _pending[id],
                                changed: changes.containsKey(id),
                                canEdit: canEdit,
                                ctrl: _ctrl(id),
                                onToggle: (v) => setState(
                                  () => v ? _selected.add(id) : _selected.remove(id),
                                ),
                                onTyped: (raw) => _onTyped(id, raw),
                                onUseSuggested: () => _setPending(id, row.suggestedMin),
                                onClear: () => _setPending(id, null),
                                onUndo: () => _setPending(id, null, undo: true),
                              );
                            },
                          ),
          ),
          if (!_loading && changes.isNotEmpty)
            _SaveBar(
              count: changes.length,
              scopeLabel: _scopeLabel,
              saving: _saving,
              onDiscard: () => setState(() {
                _pending.clear();
                _onlyChanged = false;
                _syncCtrls(_ctrls.keys);
              }),
              onSave: _save,
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Filtros y selección
// ---------------------------------------------------------------------------

class _FiltersBar extends StatelessWidget {
  final List<InventoryWarehouse> warehouses;
  final String scope;
  final int safetyDays;
  final String classification;
  final String supplierFilter;
  final Map<String, String> supplierOptions;
  final Set<RotationClass> rotations;
  final bool onlyChanged;
  final TextEditingController searchCtrl;
  final bool canEdit;
  final ValueChanged<String> onScope;
  final ValueChanged<int> onSafety;
  final ValueChanged<String> onClassification;
  final ValueChanged<String> onSupplier;
  final void Function(RotationClass, bool) onRotation;
  final ValueChanged<bool> onOnlyChanged;
  final ValueChanged<String> onSearch;

  const _FiltersBar({
    required this.warehouses,
    required this.scope,
    required this.safetyDays,
    required this.classification,
    required this.supplierFilter,
    required this.supplierOptions,
    required this.rotations,
    required this.onlyChanged,
    required this.searchCtrl,
    required this.canEdit,
    required this.onScope,
    required this.onSafety,
    required this.onClassification,
    required this.onSupplier,
    required this.onRotation,
    required this.onOnlyChanged,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    final sortedSuppliers = supplierOptions.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    final supplierValue = supplierFilter == _allSuppliers ||
            supplierFilter == _noSupplier ||
            supplierOptions.containsKey(supplierFilter)
        ? supplierFilter
        : _allSuppliers;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: const BoxDecoration(
        color: MangoColors.white,
        border: Border(bottom: BorderSide(color: MangoColors.cardBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Dropdown(
                label: 'Mínimo',
                width: 240,
                value: scope,
                items: [
                  (_generalScope, 'General (todo el negocio)'),
                  for (final w in warehouses) (w.id, 'Propio de ${w.name}'),
                ],
                onChanged: onScope,
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Colchón',
                    style: TextStyle(fontSize: 12, color: MangoColors.muted),
                  ),
                  const SizedBox(width: 6),
                  for (final days in _safetyOptions)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: ChoiceChip(
                        label: Text('$days d'),
                        selected: days == safetyDays,
                        onSelected: (_) => onSafety(days),
                        visualDensity: VisualDensity.compact,
                        selectedColor: MangoColors.primaryOrange.withValues(alpha: 0.16),
                      ),
                    ),
                ],
              ),
              _Dropdown(
                label: 'Clasificación',
                value: classification,
                items: _classificationOptions,
                onChanged: onClassification,
              ),
              _Dropdown(
                label: 'Suplidor',
                value: supplierValue,
                items: [
                  (_allSuppliers, 'Todos'),
                  (_noSupplier, 'Sin suplidor'),
                  for (final e in sortedSuppliers) (e.key, e.value),
                ],
                onChanged: onSupplier,
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: searchCtrl,
                  onChanged: onSearch,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Buscar insumo o SKU',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in RotationClass.values)
                FilterChip(
                  label: Text(c.label),
                  selected: rotations.contains(c),
                  onSelected: (on) => onRotation(c, on),
                  visualDensity: VisualDensity.compact,
                  selectedColor: _rotationColor(c).withValues(alpha: 0.16),
                ),
              FilterChip(
                label: const Text('Solo lo que cambia'),
                selected: onlyChanged,
                onSelected: onOnlyChanged,
                visualDensity: VisualDensity.compact,
                selectedColor: MangoColors.primaryOrange.withValues(alpha: 0.16),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Mínimo sugerido = consumo diario × (tiempo de entrega + $safetyDays días '
            'de colchón). ${scope == _generalScope ? 'El general es el que usan las alertas de stock bajo.' : 'El propio del almacén manda sobre el general; quitarlo vuelve al general.'}',
            style: const TextStyle(fontSize: 11, color: MangoColors.muted),
          ),
          if (!canEdit) ...[
            const SizedBox(height: 6),
            const Text(
              'Solo lectura: para cambiar mínimos necesitas el permiso de editar insumos.',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.warning,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Dropdown extends StatelessWidget {
  final String label;
  final String value;
  final List<(String, String)> items;
  final ValueChanged<String> onChanged;
  final double width;

  const _Dropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.width = 200,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: MangoColors.muted)),
        const SizedBox(width: 6),
        // Ancho fijo + isExpanded: un nombre largo se corta con «…».
        SizedBox(
          width: width,
          child: DropdownButton<String>(
            value: value,
            isDense: true,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final (v, text) in items)
                DropdownMenuItem<String>(
                  value: v,
                  child: Text(text, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ],
    );
  }
}

class _SelectionBar extends StatelessWidget {
  final int visibleCount;
  final int selectedCount;
  final int visibleSelected;
  final bool canEdit;
  final ValueChanged<bool> onSelectAll;
  final VoidCallback onClearSelection;
  final ValueChanged<MinStockBulkAction> onAction;

  const _SelectionBar({
    required this.visibleCount,
    required this.selectedCount,
    required this.visibleSelected,
    required this.canEdit,
    required this.onSelectAll,
    required this.onClearSelection,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final allVisible = visibleCount > 0 && visibleSelected == visibleCount;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
      color: const Color(0xFFFAFAFA),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                tristate: true,
                value: allVisible ? true : (visibleSelected == 0 ? false : null),
                onChanged: canEdit ? (_) => onSelectAll(!allVisible) : null,
                activeColor: MangoColors.primaryOrange,
              ),
              Text(
                '$visibleCount ${visibleCount == 1 ? 'insumo' : 'insumos'}'
                '${selectedCount > 0 ? ' · $selectedCount seleccionados' : ''}',
                style: const TextStyle(fontSize: 12, color: MangoColors.darkGray),
              ),
            ],
          ),
          if (canEdit && selectedCount > 0) ...[
            FilledButton.tonal(
              onPressed: () => onAction(MinStockBulkAction.applySuggested),
              child: const Text('Aplicar sugerido'),
            ),
            OutlinedButton(
              onPressed: () => onAction(MinStockBulkAction.setValue),
              child: const Text('Poner valor'),
            ),
            OutlinedButton(
              onPressed: () => onAction(MinStockBulkAction.adjustPercent),
              child: const Text('Subir / bajar %'),
            ),
            OutlinedButton(
              onPressed: () => onAction(MinStockBulkAction.clear),
              child: const Text('Quitar'),
            ),
            TextButton(
              onPressed: onClearSelection,
              child: const Text('Limpiar selección'),
            ),
          ],
        ],
      ),
    );
  }
}

Color _rotationColor(RotationClass c) => switch (c) {
      RotationClass.star => MangoColors.primaryOrange,
      RotationClass.active => AppColors.success,
      RotationClass.slow => AppColors.warning,
      RotationClass.dormant => MangoColors.muted,
    };

// ---------------------------------------------------------------------------
// Fila
// ---------------------------------------------------------------------------

class _MinRow extends StatelessWidget {
  final MinStockRow row;
  final bool perWarehouse;
  final bool selected;
  final bool hasPending;
  final double? pendingValue;
  final bool changed;
  final bool canEdit;
  final TextEditingController ctrl;
  final ValueChanged<bool> onToggle;
  final ValueChanged<String> onTyped;
  final VoidCallback onUseSuggested;
  final VoidCallback onClear;
  final VoidCallback onUndo;

  const _MinRow({
    required this.row,
    required this.perWarehouse,
    required this.selected,
    required this.hasPending,
    required this.pendingValue,
    required this.changed,
    required this.canEdit,
    required this.ctrl,
    required this.onToggle,
    required this.onTyped,
    required this.onUseSuggested,
    required this.onClear,
    required this.onUndo,
  });

  @override
  Widget build(BuildContext context) {
    final line = row.line;
    final unit = line.unit;
    String qty(double v) => formatUnitQty(v);
    final clearing = hasPending && pendingValue == null;
    final overMax = row.maxStock != null &&
        pendingValue != null &&
        row.maxStock! > 0 &&
        pendingValue! > row.maxStock!;

    final String currentSource;
    if (!perWarehouse) {
      currentSource = 'general';
    } else if (row.warehouseMin != null) {
      currentSource = 'propio';
    } else {
      currentSource = 'rige el general';
    }

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          line.sku == null ? line.itemName : '${line.itemName} · ${line.sku}',
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: MangoColors.darkGray,
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            _Pill(label: row.rotation.label, color: _rotationColor(row.rotation)),
            _Pill(
              label: line.stock < 0
                  ? 'Existencia negativa (${qty(line.stock)} $unit)'
                  : 'Hay ${qty(line.stock)} $unit',
              color: line.stock <= 0 ? AppColors.destructive : MangoColors.muted,
            ),
            _Pill(label: 'Consume ${qty(line.dailyConsumption)}/día', color: MangoColors.muted),
            _Pill(
              label: line.supplierName ?? 'Sin suplidor',
              color: line.supplierName == null ? AppColors.warning : MangoColors.muted,
            ),
            if (line.leadTimeDays > 0)
              _Pill(
                label: 'Entrega ${line.leadTimeDays} d${line.leadTimeIsDefault ? ' (por defecto)' : ''}',
                color: MangoColors.muted,
              ),
          ],
        ),
      ],
    );

    Widget figure(String caption, String value, {Widget? action, Color? color}) => SizedBox(
          width: 96,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(caption, style: const TextStyle(fontSize: 10, color: MangoColors.muted)),
              Text(
                value,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: color ?? MangoColors.darkGray,
                ),
              ),
              ?action,
            ],
          ),
        );

    final numbers = Wrap(
      spacing: 10,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: [
        figure('Actual · $currentSource', '${qty(row.currentMin)} $unit'),
        figure(
          'Sugerido',
          '${qty(row.suggestedMin)} $unit',
          color: MangoColors.primaryOrange,
          action: canEdit
              ? InkWell(
                  onTap: onUseSuggested,
                  child: const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Text(
                      'usar',
                      style: TextStyle(
                        fontSize: 11,
                        color: MangoColors.primaryOrange,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                )
              : null,
        ),
        figure('Máximo', row.maxStock == null ? '—' : '${qty(row.maxStock!)} $unit'),
        SizedBox(
          width: 132,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (clearing)
                InputChip(
                  label: const Text('Se quita'),
                  onDeleted: canEdit ? onUndo : null,
                  deleteButtonTooltipMessage: 'Deshacer',
                  labelStyle: const TextStyle(color: AppColors.destructive, fontSize: 12),
                  visualDensity: VisualDensity.compact,
                )
              else
                TextField(
                  controller: ctrl,
                  enabled: canEdit,
                  onChanged: onTyped,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
                  textAlign: TextAlign.end,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: 'Nuevo',
                    suffixText: unit,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    enabledBorder: changed
                        ? OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: MangoColors.primaryOrange, width: 1.5),
                          )
                        : null,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  ),
                ),
              if (overMax)
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Text(
                    'sobre el máximo',
                    style: TextStyle(fontSize: 10, color: AppColors.warning),
                  ),
                ),
            ],
          ),
        ),
        if (canEdit && !clearing && (perWarehouse ? row.warehouseMin != null : row.globalMin > 0))
          IconButton(
            tooltip: perWarehouse ? 'Quitar el mínimo propio' : 'Quitar el mínimo',
            icon: const Icon(Icons.backspace_outlined, size: 18),
            onPressed: onClear,
          ),
      ],
    );

    final checkbox = Checkbox(
      value: selected,
      onChanged: canEdit ? (v) => onToggle(v ?? false) : null,
      activeColor: MangoColors.primaryOrange,
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(4, 8, 10, 8),
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: changed ? MangoColors.primaryOrange.withValues(alpha: 0.5) : MangoColors.cardBorder,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 760) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [checkbox, Expanded(child: info)],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 44, top: 8),
                  child: numbers,
                ),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              checkbox,
              Expanded(child: info),
              const SizedBox(width: 8),
              numbers,
            ],
          );
        },
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  const _Pill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}

class _SaveBar extends StatelessWidget {
  final int count;
  final String scopeLabel;
  final bool saving;
  final VoidCallback onDiscard;
  final VoidCallback onSave;

  const _SaveBar({
    required this.count,
    required this.scopeLabel,
    required this.saving,
    required this.onDiscard,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: const BoxDecoration(
        color: MangoColors.white,
        border: Border(top: BorderSide(color: MangoColors.cardBorder)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$count ${count == 1 ? 'cambio' : 'cambios'} sin guardar · $scopeLabel',
                style: const TextStyle(fontWeight: FontWeight.w700, color: MangoColors.darkGray),
              ),
            ),
            TextButton(
              onPressed: saving ? null : onDiscard,
              child: const Text('Descartar'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: saving ? null : onSave,
              icon: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.save_outlined, size: 18),
              label: Text(saving ? 'Guardando...' : 'Guardar $count'),
              style: FilledButton.styleFrom(backgroundColor: MangoColors.primaryOrange),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Diálogos
// ---------------------------------------------------------------------------

class _NumberDialog extends StatefulWidget {
  final String title;
  final String label;
  final String? suffix;
  final bool allowNegative;

  const _NumberDialog({
    required this.title,
    required this.label,
    this.suffix,
    this.allowNegative = false,
  });

  @override
  State<_NumberDialog> createState() => _NumberDialogState();
}

class _NumberDialogState extends State<_NumberDialog> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final value = double.tryParse(_ctrl.text.trim().replaceAll(',', '.'));
    if (value == null) {
      setState(() => _error = 'Escribe un número.');
      return;
    }
    if (!widget.allowNegative && value < 0) {
      setState(() => _error = 'No puede ser negativo.');
      return;
    }
    if (widget.allowNegative && value <= -100) {
      setState(() => _error = 'Bajar 100% o más deja el mínimo en 0; usa «Quitar».');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: _ctrl,
          autofocus: true,
          keyboardType: TextInputType.numberWithOptions(
            decimal: true,
            signed: widget.allowNegative,
          ),
          inputFormatters: [
            FilteringTextInputFormatter.allow(
              RegExp(widget.allowNegative ? r'[-\d.,]' : r'[\d.,]'),
            ),
          ],
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: widget.label,
            suffixText: widget.suffix,
            errorText: _error,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(backgroundColor: MangoColors.primaryOrange),
          child: const Text('Aplicar'),
        ),
      ],
    );
  }
}

class _ImportSummaryDialog extends StatelessWidget {
  final MinStockImportResult result;
  final String scopeLabel;

  const _ImportSummaryDialog({required this.result, required this.scopeLabel});

  @override
  Widget build(BuildContext context) {
    final n = result.changes.length;
    final clears = result.changes.values.where((v) => v == null).length;
    final shownErrors = result.errors.take(12).toList();
    return AlertDialog(
      title: const Text('Importar mínimos'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                n == 0
                    ? 'El archivo no trae mínimos nuevos.'
                    : '$n ${n == 1 ? 'insumo' : 'insumos'} con mínimo nuevo'
                        '${clears > 0 ? ' ($clears se quitan)' : ''}. '
                        'Se cargan como $scopeLabel, SIN guardar: los revisas y tocas «Guardar».',
              ),
              if (result.skipped > 0) ...[
                const SizedBox(height: 6),
                Text(
                  '${result.skipped} filas sin «Mínimo nuevo» se dejaron igual.',
                  style: const TextStyle(color: MangoColors.muted, fontSize: 12),
                ),
              ],
              if (shownErrors.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  '${result.errors.length} ${result.errors.length == 1 ? 'fila no se pudo leer' : 'filas no se pudieron leer'}:',
                  style: const TextStyle(
                    color: AppColors.destructive,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                for (final e in shownErrors)
                  Text('• $e', style: const TextStyle(fontSize: 12)),
                if (result.errors.length > shownErrors.length)
                  Text(
                    '… y ${result.errors.length - shownErrors.length} más.',
                    style: const TextStyle(fontSize: 12, color: MangoColors.muted),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: n == 0 ? null : () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(backgroundColor: MangoColors.primaryOrange),
          child: Text(n == 1 ? 'Cargar 1 cambio' : 'Cargar $n cambios'),
        ),
      ],
    );
  }
}
