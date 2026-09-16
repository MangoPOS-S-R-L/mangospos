// Pedido sugerido (Compras F2) — reemplaza a «Sugerencias de reorden».
//
// Cuánto pedir sale de `fn_purchase_projection`: consumo real (ventas + mermas
// + producción) × (tiempo de entrega + días de cobertura) + mínimo, menos lo
// que hay, lo que viene en camino y lo ya pedido. Aquí se agrupa por suplidor,
// se redondea a empaques, se edita y se crean TODAS las órdenes en borrador de
// un toque (`fn_purchase_orders_create_batch`, todo o nada).
//
// Sin la función de proyección (20260915_0004 sin aplicar) muestra la vista
// vieja de Reorden.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/core/currency/business_currency.dart';
import 'package:mangopos/core/currency/business_currency_provider.dart';
import 'package:mangopos/core/inventory/price_comparison.dart';
import 'package:mangopos/core/inventory/purchase_quantity.dart';
import 'package:mangopos/core/inventory/suggested_order.dart';
import 'package:mangopos/core/inventory/unit_conversion.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/core/utils/friendly_error.dart';
import 'package:mangopos/data/repositories/price_comparison_repository.dart';
import 'package:mangopos/data/repositories/purchase_projection_repository.dart';
import 'package:mangopos/presentation/inventory/state/inventory_state.dart';
import 'package:mangopos/presentation/inventory/view/inventory_reorder_view.dart';
import 'package:mangopos/presentation/inventory/view/widgets/price_comparison_dialog.dart';
import 'package:mangopos/presentation/inventory/viewmodel/inventory_viewmodel.dart';
import 'package:mangopos/presentation/purchases/state/purchases_state.dart';
import 'package:mangopos/presentation/purchases/viewmodel/purchases_viewmodel.dart';

const _coverageOptions = [3, 7, 15, 30];

const _classificationOptions = [
  ('', 'Todas'),
  ('raw_material', 'Materia prima'),
  ('finished_product', 'Producto terminado'),
  ('simple', 'Simple'),
];

const _allSuppliers = '';
const _noSupplier = '__sin_suplidor__';

class PurchaseSuggestedOrderView extends ConsumerStatefulWidget {
  const PurchaseSuggestedOrderView({super.key});

  @override
  ConsumerState<PurchaseSuggestedOrderView> createState() =>
      _PurchaseSuggestedOrderViewState();
}

class _PurchaseSuggestedOrderViewState
    extends ConsumerState<PurchaseSuggestedOrderView> {
  String? _businessId;
  bool _loading = true;
  bool _unsupported = false;
  bool _creating = false;
  String? _error;
  int _loadSeq = 0;

  List<InventoryWarehouse> _warehouses = const [];
  String? _warehouseId;
  Map<String, SuggestedOrderSupplier> _suppliers = const {};
  List<ProjectionLine> _lines = const [];

  /// Precios por suplidor de cada insumo en pantalla (F4); llegan después.
  Map<String, List<SupplierPrice>> _prices = const {};

  int _coverageDays = 7;
  bool _onlyNeeded = true;
  String _classification = '';
  String _supplierFilter = _allSuppliers;
  String _search = '';

  final Map<String, LineEdit> _edits = {};
  final Map<String, TextEditingController> _packsCtrls = {};
  final Map<String, TextEditingController> _costCtrls = {};
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _load(first: true));
  }

  @override
  void dispose() {
    for (final c in _packsCtrls.values) {
      c.dispose();
    }
    for (final c in _costCtrls.values) {
      c.dispose();
    }
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool first = false}) async {
    final seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final businessId = _businessId ??= await BusinessResolver.ensure('auto');
      final repo = ref.read(purchaseProjectionRepositoryProvider);
      if (first) {
        final warehouses =
            await ref.read(inventoryRepositoryProvider).getWarehouses(businessId);
        var suppliers = const <String, SuggestedOrderSupplier>{};
        try {
          suppliers = await repo.getSuppliers(businessId);
        } catch (e) {
          debugPrint('[pedido sugerido] no se pudieron leer los suplidores: $e');
        }
        _warehouses = warehouses
            .where((w) => w.name != '__IN_TRANSIT__')
            .toList(growable: false);
        _suppliers = suppliers;
        if (_warehouseId == null && _warehouses.isNotEmpty) {
          _warehouseId = _warehouses
              .firstWhere((w) => w.isMain, orElse: () => _warehouses.first)
              .id;
        }
      }
      final lines = await repo.getProjection(
        businessId: businessId,
        warehouseId: _warehouseId,
        coverageDays: _coverageDays,
        onlyNeeded: _onlyNeeded,
      );
      if (!mounted || seq != _loadSeq) return;
      if (lines == null) {
        setState(() {
          _unsupported = true;
          _loading = false;
        });
        return;
      }
      setState(() {
        _lines = lines;
        // Lo sugerido cambió: las cantidades escritas a mano ya no aplican. El
        // suplidor, el costo y lo marcado se conservan.
        for (final entry in _edits.entries.toList()) {
          final e = entry.value;
          _edits[entry.key] = LineEdit(
            costPerOrderUnit: e.costPerOrderUnit,
            supplierId: e.supplierId,
            selected: e.selected,
          );
        }
        for (final line in lines) {
          final draft = resolveOrderLine(line, _edits[line.itemId]);
          _packsCtrls[line.itemId]?.text = formatUnitQty(draft.packs);
          if (_edits[line.itemId]?.costPerOrderUnit == null) {
            _costCtrls[line.itemId]?.text =
                draft.costPerOrderUnit.toStringAsFixed(2);
          }
        }
        _loading = false;
      });
      unawaited(_loadPrices(businessId, lines, seq));
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _error = FriendlyError.humanize(
          'No se pudo calcular el pedido sugerido: $e',
        );
        _loading = false;
      });
    }
  }

  String? _effectiveSupplierId(ProjectionLine line) =>
      _edits[line.itemId]?.supplierId ?? line.supplierId;

  List<ProjectionLine> get _visibleLines {
    final query = _search.trim().toLowerCase();
    return _lines.where((line) {
      if (_classification.isNotEmpty && line.classification != _classification) {
        return false;
      }
      if (_supplierFilter != _allSuppliers) {
        final supplierId = _effectiveSupplierId(line);
        if (_supplierFilter == _noSupplier
            ? supplierId != null
            : supplierId != _supplierFilter) {
          return false;
        }
      }
      if (query.isNotEmpty &&
          !line.itemName.toLowerCase().contains(query) &&
          !(line.sku?.toLowerCase().contains(query) ?? false)) {
        return false;
      }
      return true;
    }).toList(growable: false);
  }

  void _edit(String itemId, LineEdit Function(LineEdit current) change) {
    setState(() => _edits[itemId] = change(_edits[itemId] ?? const LineEdit()));
  }

  double _parse(String raw) =>
      double.tryParse(raw.replaceAll(',', '.').trim()) ?? 0;

  TextEditingController _packsCtrl(OrderLineDraft d) => _packsCtrls.putIfAbsent(
        d.line.itemId,
        () => TextEditingController(text: formatUnitQty(d.packs)),
      );

  TextEditingController _costCtrl(OrderLineDraft d) => _costCtrls.putIfAbsent(
        d.line.itemId,
        () => TextEditingController(text: d.costPerOrderUnit.toStringAsFixed(2)),
      );

  void _setSelected(Iterable<OrderLineDraft> lines, bool value) {
    setState(() {
      for (final l in lines) {
        _edits[l.line.itemId] =
            (_edits[l.line.itemId] ?? const LineEdit()).copyWith(selected: value);
      }
    });
  }

  Future<void> _pickSupplier(ProjectionLine line) async {
    final active = _suppliers.values.where((s) => s.isActive).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (active.isEmpty) {
      AppToast.info(
        context,
        'No tienes suplidores activos. Crea uno en Inventario → Proveedores.',
      );
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => _SupplierPickerDialog(
        suppliers: active,
        currentId: _effectiveSupplierId(line),
        itemName: line.itemName,
      ),
    );
    if (picked == null || !mounted) return;
    _edit(line.itemId, (e) => e.copyWith(supplierId: picked, selected: true));
  }

  /// Precios por suplidor de lo que está en pantalla (F4). No frena la lista:
  /// llegan después y encienden el aviso «otro suplidor está X% más barato».
  Future<void> _loadPrices(
    String businessId,
    List<ProjectionLine> lines,
    int seq,
  ) async {
    try {
      final prices = await ref.read(priceComparisonRepositoryProvider).getComparison(
            businessId: businessId,
            itemIds: [for (final l in lines) l.itemId],
          );
      if (!mounted || seq != _loadSeq || prices == null) return;
      setState(() => _prices = groupPricesByItem(prices));
    } catch (e) {
      debugPrint('[pedido sugerido] no se pudieron leer los precios: $e');
    }
  }

  CheaperSupplier? _cheaperFor(ProjectionLine line) {
    final prices = _prices[line.itemId];
    if (prices == null) return null;
    return cheaperAlternative(prices, currentSupplierId: _effectiveSupplierId(line));
  }

  /// El comparador con opción de elegir. Si se elige otro suplidor, la línea
  /// pasa a su grupo con SU último costo (el sistema sugiere, la persona decide).
  Future<void> _comparePrices(ProjectionLine line) async {
    final picked = await showPriceComparisonDialog(
      context,
      itemId: line.itemId,
      itemName: line.itemName,
      unit: line.unit,
      currentSupplierId: _effectiveSupplierId(line),
      allowPick: true,
    );
    if (picked == null || !mounted) return;
    double? lastBase;
    for (final p in _prices[line.itemId] ?? const <SupplierPrice>[]) {
      if (p.supplierId == picked) lastBase = p.lastCostBase;
    }
    final perOrderUnit =
        lastBase == null ? null : lastBase * (line.hasPack ? line.packSize : 1);
    _edit(
      line.itemId,
      (e) => e.copyWith(
        supplierId: picked,
        selected: true,
        costPerOrderUnit: perOrderUnit,
      ),
    );
    if (perOrderUnit != null) {
      _costCtrls[line.itemId]?.text = perOrderUnit.toStringAsFixed(2);
    }
  }

  String get _warehouseName {
    for (final w in _warehouses) {
      if (w.id == _warehouseId) return w.name;
    }
    return 'el almacén';
  }

  Future<void> _createOrders(List<SupplierOrderDraft> orders) async {
    final creatable = orders.where((o) => o.canCreate).toList(growable: false);
    final warehouseId = _warehouseId;
    final businessId = _businessId;
    if (_creating || creatable.isEmpty || businessId == null) return;
    if (warehouseId == null) {
      AppToast.info(context, 'Tu negocio no tiene almacenes activos.');
      return;
    }
    final currency = currentBusinessCurrencyOrFallback(ref);
    final total = creatable.fold<double>(0, (sum, o) => sum + o.subtotal);
    final belowMinimum = creatable.where((o) => o.missingForMinimum > 0).length;
    final n = creatable.length;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(n == 1 ? 'Crear 1 orden en borrador' : 'Crear $n órdenes en borrador'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Suman ${currency.formatAmount(total)} antes de impuestos, '
              'para $_warehouseName.',
            ),
            if (belowMinimum > 0) ...[
              const SizedBox(height: 8),
              Text(
                belowMinimum == 1
                    ? '1 no llega al pedido mínimo de su suplidor.'
                    : '$belowMinimum no llegan al pedido mínimo de su suplidor.',
                style: const TextStyle(
                  color: AppColors.warning,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 8),
            const Text(
              'Quedan en borrador: puedes revisarlas y mandarlas desde Compras.',
              style: TextStyle(color: MangoColors.muted, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
            ),
            child: const Text('Crear órdenes'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final today = DateTime.now();
    final batch = [
      for (final o in creatable)
        SuggestedOrderBatchOrder(
          supplierId: o.supplierId!,
          supplierName: o.supplierName,
          expectedDate: o.expectedDate(today),
          notes: 'Pedido sugerido · cobertura de $_coverageDays días',
          items: [
            for (final l in o.orderLines)
              PurchaseDraftItem(
                inventoryItemId: l.line.itemId,
                description: l.line.itemName,
                quantity: l.baseQuantity,
                unitCost: l.unitCostBase,
                // Foto del empaque: la orden se ve y se recibe en cajas.
                purchaseUnit: l.line.hasPack ? l.line.purchaseUnit : '',
                packSize: l.line.hasPack ? l.line.packSize : 1,
              ),
          ],
        ),
    ];
    final drafts = {for (final o in creatable) o.supplierId!: o};
    final key = _batchKey(warehouseId, batch, today);

    setState(() => _creating = true);
    try {
      final repo = ref.read(purchaseProjectionRepositoryProvider);
      final created = await repo.createOrdersBatch(
            businessId: businessId,
            warehouseId: warehouseId,
            orders: batch,
            idempotencyKey: key,
          ) ??
          await _createOneByOne(businessId, warehouseId, batch, key);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _CreatedOrdersDialog(
          created: created,
          drafts: drafts,
          suppliers: _suppliers,
          currency: currency,
        ),
      );
      if (!mounted) return;
      _edits.clear();
      await _load();
    } catch (e) {
      if (!mounted) return;
      AppToast.error(
        context,
        FriendlyError.humanize('No se crearon las órdenes: $e'),
      );
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  /// Base sin `fn_purchase_orders_create_batch`: una orden tras otra, con la
  /// misma llave por suplidor que usaría la base.
  Future<List<CreatedSupplierOrder>> _createOneByOne(
    String businessId,
    String warehouseId,
    List<SuggestedOrderBatchOrder> batch,
    String key,
  ) async {
    final purchases = ref.read(purchasesRepositoryProvider);
    final created = <CreatedSupplierOrder>[];
    for (final o in batch) {
      try {
        final result = await purchases.createPurchaseOrderWithNumber(
          businessId: businessId,
          supplierId: o.supplierId,
          warehouseId: warehouseId,
          orderNumber: await purchases.generateNextOrderNumber(businessId),
          status: 'draft',
          expectedDate: o.expectedDate,
          notes: o.notes,
          items: o.items,
          idempotencyKey: '$key:${o.supplierId}',
        );
        created.add(
          CreatedSupplierOrder(
            supplierId: o.supplierId,
            id: result.id,
            orderNumber: result.orderNumber,
            reused: result.reused,
          ),
        );
      } catch (e) {
        if (created.isEmpty) rethrow;
        throw Exception(
          'se crearon ${created.length} de ${batch.length} antes del error con '
          '${o.supplierName}. Revisa Compras antes de volver a crearlas. $e',
        );
      }
    }
    return created;
  }

  /// Llave del lote a partir de lo que se pide: tocar dos veces o reintentar
  /// tras perder la red devuelve las mismas órdenes; cambiar una cantidad
  /// arma otra llave.
  String _batchKey(
    String warehouseId,
    List<SuggestedOrderBatchOrder> batch,
    DateTime today,
  ) {
    final b = StringBuffer('$warehouseId|${today.year}-${today.month}-${today.day}');
    for (final o in batch) {
      b.write('|${o.supplierId}');
      for (final i in o.items) {
        b.write(';${i.inventoryItemId}:${i.quantity}:${i.unitCost}');
      }
    }
    var hash = 0x811c9dc5;
    for (final unit in b.toString().codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return 'pedido-sugerido-${hash.toRadixString(16)}';
  }

  @override
  Widget build(BuildContext context) {
    if (_unsupported) return const InventoryReorderView();

    final currency = currentBusinessCurrencyOrFallback(ref);
    final orders = buildSupplierOrders(
      lines: _visibleLines,
      edits: _edits,
      suppliers: _suppliers,
    );
    final creatable = orders.where((o) => o.canCreate).toList(growable: false);
    final supplierOptions = {
      for (final o in buildSupplierOrders(
        lines: _lines,
        edits: _edits,
        suppliers: _suppliers,
      ))
        if (o.supplierId != null) o.supplierId!: o.supplierName,
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
        title: const Text('Pedido sugerido'),
        actions: [
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
            warehouseId: _warehouseId,
            coverageDays: _coverageDays,
            onlyNeeded: _onlyNeeded,
            classification: _classification,
            supplierFilter: _supplierFilter,
            supplierOptions: supplierOptions,
            searchCtrl: _searchCtrl,
            onWarehouse: (id) {
              if (id == _warehouseId) return;
              setState(() => _warehouseId = id);
              _load();
            },
            onCoverage: (days) {
              if (days == _coverageDays) return;
              setState(() => _coverageDays = days);
              _load();
            },
            onOnlyNeeded: (value) {
              setState(() => _onlyNeeded = value);
              _load();
            },
            onClassification: (v) => setState(() => _classification = v),
            onSupplier: (v) => setState(() => _supplierFilter = v),
            onSearch: (v) => setState(() => _search = v),
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                      valueColor:
                          AlwaysStoppedAnimation(MangoColors.primaryOrange),
                    ),
                  )
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_error!, textAlign: TextAlign.center),
                        ),
                      )
                    : orders.isEmpty
                        ? _EmptyState(
                            onlyNeeded: _onlyNeeded,
                            filtered: _lines.isNotEmpty,
                            coverageDays: _coverageDays,
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                            itemCount: orders.length,
                            itemBuilder: (_, i) {
                              final order = orders[i];
                              return _SupplierOrderCard(
                                order: order,
                                currency: currency,
                                packsCtrl: _packsCtrl,
                                costCtrl: _costCtrl,
                                onPacks: (d, raw) => _edit(
                                  d.line.itemId,
                                  (e) => e.copyWith(packs: _parse(raw)),
                                ),
                                onCost: (d, raw) => _edit(
                                  d.line.itemId,
                                  (e) => e.copyWith(costPerOrderUnit: _parse(raw)),
                                ),
                                onToggle: (d, value) => _setSelected([d], value),
                                onToggleAll: (value) =>
                                    _setSelected(order.lines, value),
                                onPickSupplier: _pickSupplier,
                                cheaperFor: _cheaperFor,
                                onComparePrices: _comparePrices,
                              );
                            },
                          ),
          ),
          if (!_loading && _error == null && creatable.isNotEmpty)
            _CreateBar(
              orders: creatable,
              currency: currency,
              creating: _creating,
              onCreate: () => _createOrders(orders),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Filtros
// ---------------------------------------------------------------------------

class _FiltersBar extends StatelessWidget {
  final List<InventoryWarehouse> warehouses;
  final String? warehouseId;
  final int coverageDays;
  final bool onlyNeeded;
  final String classification;
  final String supplierFilter;
  final Map<String, String> supplierOptions;
  final TextEditingController searchCtrl;
  final ValueChanged<String> onWarehouse;
  final ValueChanged<int> onCoverage;
  final ValueChanged<bool> onOnlyNeeded;
  final ValueChanged<String> onClassification;
  final ValueChanged<String> onSupplier;
  final ValueChanged<String> onSearch;

  const _FiltersBar({
    required this.warehouses,
    required this.warehouseId,
    required this.coverageDays,
    required this.onlyNeeded,
    required this.classification,
    required this.supplierFilter,
    required this.supplierOptions,
    required this.searchCtrl,
    required this.onWarehouse,
    required this.onCoverage,
    required this.onOnlyNeeded,
    required this.onClassification,
    required this.onSupplier,
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
              if (warehouses.length > 1)
                _LabeledDropdown<String>(
                  label: 'Almacén',
                  value: warehouseId,
                  items: [
                    for (final w in warehouses) (w.id, w.name),
                  ],
                  onChanged: onWarehouse,
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Cubrir',
                    style: TextStyle(fontSize: 12, color: MangoColors.muted),
                  ),
                  const SizedBox(width: 6),
                  for (final days in _coverageOptions)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: ChoiceChip(
                        label: Text('$days d'),
                        selected: days == coverageDays,
                        onSelected: (_) => onCoverage(days),
                        visualDensity: VisualDensity.compact,
                        selectedColor:
                            MangoColors.primaryOrange.withValues(alpha: 0.16),
                      ),
                    ),
                ],
              ),
              FilterChip(
                label: const Text('Solo lo que falta'),
                selected: onlyNeeded,
                onSelected: onOnlyNeeded,
                visualDensity: VisualDensity.compact,
                selectedColor: MangoColors.primaryOrange.withValues(alpha: 0.16),
              ),
              _LabeledDropdown<String>(
                label: 'Clasificación',
                value: classification,
                items: _classificationOptions,
                onChanged: onClassification,
              ),
              _LabeledDropdown<String>(
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
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Pedir = consumo diario × (entrega + $coverageDays días) + mínimo, '
            'menos lo que hay, lo que viene en camino y lo ya pedido. Si el '
            'suplidor no tiene tiempo de entrega se usan '
            '$kDefaultSupplierLeadTimeDays días.',
            style: const TextStyle(fontSize: 11, color: MangoColors.muted),
          ),
        ],
      ),
    );
  }
}

class _LabeledDropdown<T> extends StatelessWidget {
  final String label;
  final T? value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;

  const _LabeledDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: MangoColors.muted),
        ),
        const SizedBox(width: 6),
        // Ancho fijo + isExpanded: un suplidor de nombre largo se corta con
        // «…» en vez de desbordar la barra.
        SizedBox(
          width: 200,
          child: DropdownButton<T>(
            value: value,
            isDense: true,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final (v, text) in items)
                DropdownMenuItem<T>(
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

// ---------------------------------------------------------------------------
// Orden por suplidor
// ---------------------------------------------------------------------------

class _SupplierOrderCard extends StatelessWidget {
  final SupplierOrderDraft order;
  final BusinessCurrency currency;
  final TextEditingController Function(OrderLineDraft) packsCtrl;
  final TextEditingController Function(OrderLineDraft) costCtrl;
  final void Function(OrderLineDraft, String) onPacks;
  final void Function(OrderLineDraft, String) onCost;
  final void Function(OrderLineDraft, bool) onToggle;
  final ValueChanged<bool> onToggleAll;
  final ValueChanged<ProjectionLine> onPickSupplier;
  final CheaperSupplier? Function(ProjectionLine) cheaperFor;
  final ValueChanged<ProjectionLine> onComparePrices;

  const _SupplierOrderCard({
    required this.order,
    required this.currency,
    required this.packsCtrl,
    required this.costCtrl,
    required this.onPacks,
    required this.onCost,
    required this.onToggle,
    required this.onToggleAll,
    required this.onPickSupplier,
    required this.cheaperFor,
    required this.onComparePrices,
  });

  @override
  Widget build(BuildContext context) {
    final withoutSupplier = order.supplierId == null;
    final selected = order.lines.where((l) => l.selected).length;
    final allSelected = selected == order.lines.length;
    final missing = order.missingForMinimum;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 8),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: (withoutSupplier ? AppColors.warning : MangoColors.primaryOrange)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    withoutSupplier
                        ? Icons.help_outline
                        : Icons.local_shipping_outlined,
                    size: 18,
                    color: withoutSupplier
                        ? AppColors.warning
                        : MangoColors.primaryOrange,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        order.supplierName,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: MangoColors.darkGray,
                        ),
                      ),
                      Text(
                        [
                          if (!withoutSupplier)
                            'Entrega en ${order.leadTimeDays} '
                                '${order.leadTimeDays == 1 ? 'día' : 'días'}'
                                '${order.leadTimeIsDefault ? ' (por defecto)' : ''}',
                          '${order.orderLineCount} de ${order.lines.length} '
                              'por pedir',
                        ].join(' · '),
                        style: const TextStyle(
                          fontSize: 11,
                          color: MangoColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  currency.formatAmount(order.subtotal),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: MangoColors.darkGray,
                  ),
                ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: () => onToggleAll(!allSelected),
                  child: Text(allSelected ? 'Ninguno' : 'Todos'),
                ),
              ],
            ),
          ),
          if (withoutSupplier)
            const _Banner(
              color: AppColors.warning,
              background: AppColors.warningSurface,
              text: 'Estos insumos no tienen suplidor: nunca se les ha comprado '
                  'ni están vinculados. Elige uno con el botón de cambiar '
                  'suplidor para poder pedirlos.',
            )
          else if (missing > 0)
            _Banner(
              color: AppColors.warning,
              background: AppColors.warningSurface,
              text: 'Faltan ${currency.formatAmount(missing)} para el pedido '
                  'mínimo de ${currency.formatAmount(order.minOrderAmount ?? 0)}.',
            ),
          const Divider(height: 1, color: MangoColors.cardBorder),
          for (final d in order.lines)
            _LineRow(
              draft: d,
              currency: currency,
              packsCtrl: packsCtrl(d),
              costCtrl: costCtrl(d),
              onPacks: (raw) => onPacks(d, raw),
              onCost: (raw) => onCost(d, raw),
              onToggle: (value) => onToggle(d, value),
              onPickSupplier: () => onPickSupplier(d.line),
              cheaper: cheaperFor(d.line),
              onComparePrices: () => onComparePrices(d.line),
            ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final Color color;
  final Color background;
  final String text;

  const _Banner({
    required this.color,
    required this.background,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  final OrderLineDraft draft;
  final BusinessCurrency currency;
  final TextEditingController packsCtrl;
  final TextEditingController costCtrl;
  final ValueChanged<String> onPacks;
  final ValueChanged<String> onCost;
  final ValueChanged<bool> onToggle;
  final VoidCallback onPickSupplier;

  /// Otro suplidor reciente claramente más barato (F4), si lo hay.
  final CheaperSupplier? cheaper;
  final VoidCallback onComparePrices;

  const _LineRow({
    required this.draft,
    required this.currency,
    required this.packsCtrl,
    required this.costCtrl,
    required this.onPacks,
    required this.onCost,
    required this.onToggle,
    required this.onPickSupplier,
    this.cheaper,
    required this.onComparePrices,
  });

  static String _costSourceLabel(String? source) => switch (source) {
        'ultima_compra' => 'última compra',
        'lista' => 'precio de lista',
        'insumo' => 'costo del insumo',
        _ => 'sin costo',
      };

  @override
  Widget build(BuildContext context) {
    final line = draft.line;
    final unit = line.unit;
    final alt = cheaper;
    String qty(double v) => formatUnitQty(v);

    final packsCaption = [
      if (line.hasPack) '= ${qty(draft.baseQuantity)} $unit',
      if (draft.surplusBase > 0) '+${qty(draft.surplusBase)} de más',
      if (draft.raisedToMinimum) 'mínimo del suplidor',
    ].join(' · ');

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
            _Pill(
              // Un negativo es consumo sin su entrada registrada: la base lo
              // cuenta como 0 para no pedir de más (20260915_0006), pero se
              // avisa porque hay que corregir el conteo o la compra.
              label: line.stock < 0
                  ? 'Existencia negativa (${qty(line.stock)} $unit): revisa conteo o compras'
                  : 'Hay ${qty(line.stock)} $unit',
              color: line.stock <= 0 ? AppColors.destructive : MangoColors.muted,
            ),
            if (line.inTransit > 0)
              _Pill(label: 'En camino ${qty(line.inTransit)}', color: AppColors.info),
            if (line.onOrder > 0)
              _Pill(label: 'Ya pedido ${qty(line.onOrder)}', color: AppColors.info),
            _Pill(
              label: 'Consume ${qty(line.dailyConsumption)}/día'
                  '${line.windowDays < 30 ? ' (${line.windowDays} d de historia)' : ''}',
              color: MangoColors.muted,
            ),
            if (line.daysOfSupply != null)
              _Pill(
                label: 'Alcanza ${qty(line.daysOfSupply!)} días',
                color: line.daysOfSupply! < line.leadTimeDays
                    ? AppColors.destructive
                    : MangoColors.muted,
              ),
            if (line.minStock > 0)
              _Pill(
                label: 'Mín ${qty(line.minStock)}'
                    '${line.minStockFromWarehouse ? ' (almacén)' : ''}',
                color: MangoColors.muted,
              ),
            _Pill(
              label: 'Sugerido ${qty(line.suggestedBase)} $unit',
              color: MangoColors.primaryOrange,
            ),
            if (alt != null)
              InkWell(
                onTap: onComparePrices,
                borderRadius: BorderRadius.circular(6),
                child: _Pill(
                  label: '${alt.cheaper.supplierName} está '
                      '${alt.savingPct.toStringAsFixed(0)}% más barato',
                  color: AppColors.success,
                ),
              ),
          ],
        ),
      ],
    );

    final inputs = Wrap(
      spacing: 10,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: [
        SizedBox(
          width: 128,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: packsCtrl,
                onChanged: onPacks,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
                ],
                textAlign: TextAlign.end,
                decoration: _dense(suffix: line.orderUnit),
              ),
              if (packsCaption.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  packsCaption,
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontSize: 10, color: MangoColors.muted),
                ),
              ],
            ],
          ),
        ),
        SizedBox(
          width: 128,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: costCtrl,
                onChanged: onCost,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
                ],
                textAlign: TextAlign.end,
                decoration: _dense(prefix: currency.symbol),
              ),
              const SizedBox(height: 2),
              Text(
                'por ${line.orderUnit} · ${_costSourceLabel(line.costSource)}',
                textAlign: TextAlign.end,
                style: const TextStyle(fontSize: 10, color: MangoColors.muted),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 96,
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              currency.formatAmount(draft.willOrder ? draft.subtotal : 0),
              textAlign: TextAlign.end,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: draft.willOrder ? MangoColors.darkGray : MangoColors.muted,
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Comparar precios',
          icon: const Icon(Icons.price_change_outlined, size: 20),
          onPressed: onComparePrices,
        ),
        IconButton(
          tooltip: 'Cambiar suplidor',
          icon: const Icon(Icons.swap_horiz, size: 20),
          onPressed: onPickSupplier,
        ),
      ],
    );

    final checkbox = Checkbox(
      value: draft.selected,
      onChanged: (v) => onToggle(v ?? false),
      activeColor: MangoColors.primaryOrange,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 10, 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 700) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [checkbox, Expanded(child: info)],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 44, top: 8),
                  child: inputs,
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
              inputs,
            ],
          );
        },
      ),
    );
  }

  static InputDecoration _dense({String? suffix, String? prefix}) {
    return InputDecoration(
      isDense: true,
      suffixText: suffix,
      prefixText: prefix,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
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

class _CreateBar extends StatelessWidget {
  final List<SupplierOrderDraft> orders;
  final BusinessCurrency currency;
  final bool creating;
  final VoidCallback onCreate;

  const _CreateBar({
    required this.orders,
    required this.currency,
    required this.creating,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    final lines = orders.fold<int>(0, (sum, o) => sum + o.orderLineCount);
    final total = orders.fold<double>(0, (sum, o) => sum + o.subtotal);
    final n = orders.length;
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
                '${n == 1 ? '1 orden' : '$n órdenes'} · '
                '${lines == 1 ? '1 línea' : '$lines líneas'} · '
                '${currency.formatAmount(total)}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: MangoColors.darkGray,
                ),
              ),
            ),
            FilledButton.icon(
              onPressed: creating ? null : onCreate,
              icon: creating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.add_shopping_cart, size: 18),
              label: Text(creating ? 'Creando...' : 'Crear en borrador'),
              style: FilledButton.styleFrom(
                backgroundColor: MangoColors.primaryOrange,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool onlyNeeded;
  final bool filtered;
  final int coverageDays;

  const _EmptyState({
    required this.onlyNeeded,
    required this.filtered,
    required this.coverageDays,
  });

  @override
  Widget build(BuildContext context) {
    final (title, body) = filtered
        ? ('Ningún insumo coincide con los filtros', 'Cambia la clasificación, el suplidor o la búsqueda.')
        : onlyNeeded
            ? (
                'Nada que pedir para $coverageDays días',
                'Lo que hay, lo que viene en camino y lo ya pedido cubre el '
                    'consumo. Quita «Solo lo que falta» para ver todos los insumos.',
              )
            : ('No hay insumos para proyectar', 'Este almacén no tiene insumos activos.');
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 56,
              color: MangoColors.successGreen.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: MangoColors.darkGray,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(color: MangoColors.muted, fontSize: 12),
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

class _SupplierPickerDialog extends StatefulWidget {
  final List<SuggestedOrderSupplier> suppliers;
  final String? currentId;
  final String itemName;

  const _SupplierPickerDialog({
    required this.suppliers,
    required this.currentId,
    required this.itemName,
  });

  @override
  State<_SupplierPickerDialog> createState() => _SupplierPickerDialogState();
}

class _SupplierPickerDialogState extends State<_SupplierPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final visible = q.isEmpty
        ? widget.suppliers
        : widget.suppliers
            .where((s) => s.name.toLowerCase().contains(q))
            .toList(growable: false);
    return AlertDialog(
      title: Text('Suplidor para ${widget.itemName}'),
      content: SizedBox(
        width: 380,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Buscar suplidor',
                prefixIcon: const Icon(Icons.search, size: 18),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.separated(
                itemCount: visible.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final s = visible[i];
                  return ListTile(
                    dense: true,
                    title: Text(s.name),
                    subtitle: s.leadTimeDays == null
                        ? null
                        : Text('Entrega en ${s.leadTimeDays} días'),
                    trailing: s.id == widget.currentId
                        ? const Icon(Icons.check, color: MangoColors.primaryOrange)
                        : null,
                    onTap: () => Navigator.of(context).pop(s.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}

class _CreatedOrdersDialog extends StatelessWidget {
  final List<CreatedSupplierOrder> created;
  final Map<String, SupplierOrderDraft> drafts;
  final Map<String, SuggestedOrderSupplier> suppliers;
  final BusinessCurrency currency;

  const _CreatedOrdersDialog({
    required this.created,
    required this.drafts,
    required this.suppliers,
    required this.currency,
  });

  Future<void> _share(
    BuildContext context,
    SupplierOrderDraft draft,
    CreatedSupplierOrder order,
  ) async {
    final text = supplierOrderMessage(
      order: draft,
      orderNumber: order.orderNumber,
      expectedDate: draft.expectedDate(DateTime.now()),
    );
    final uri = whatsappOrderLink(suppliers[order.supplierId]?.chatPhone, text);
    var opened = false;
    if (uri != null) {
      try {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (e) {
        debugPrint('[pedido sugerido] no se pudo abrir WhatsApp: $e');
      }
    }
    if (opened) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    AppToast.info(
      context,
      uri == null
          ? 'El suplidor no tiene WhatsApp ni teléfono: el pedido quedó copiado.'
          : 'No se pudo abrir WhatsApp: el pedido quedó copiado.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final reused = created.where((o) => o.reused).length;
    return AlertDialog(
      title: Text(
        created.length == 1 ? 'Orden creada' : '${created.length} órdenes creadas',
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (reused > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  reused == 1
                      ? '1 ya existía con este mismo pedido: no se duplicó.'
                      : '$reused ya existían con este mismo pedido: no se duplicaron.',
                  style: const TextStyle(color: MangoColors.muted, fontSize: 12),
                ),
              ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: created.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final order = created[i];
                  final draft = drafts[order.supplierId];
                  final name = draft?.supplierName ??
                      suppliers[order.supplierId]?.name ??
                      'Suplidor';
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${order.orderNumber} · $name'),
                    subtitle: draft == null
                        ? null
                        : Text(
                            '${currency.formatAmount(draft.subtotal)} · '
                            '${draft.orderLineCount} '
                            '${draft.orderLineCount == 1 ? 'línea' : 'líneas'}'
                            '${order.reused ? ' · ya existía' : ''}',
                          ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (draft != null)
                          IconButton(
                            tooltip: 'Mandar pedido por WhatsApp',
                            icon: const Icon(Icons.chat_outlined, size: 20),
                            onPressed: () => _share(context, draft, order),
                          ),
                        IconButton(
                          tooltip: 'Ver orden',
                          icon: const Icon(Icons.open_in_new, size: 20),
                          onPressed: () {
                            Navigator.of(context).pop();
                            context.go(AppRoutes.purchasesOrderDetailPath(order.id));
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          style: FilledButton.styleFrom(backgroundColor: MangoColors.primaryOrange),
          child: const Text('Listo'),
        ),
      ],
    );
  }
}
