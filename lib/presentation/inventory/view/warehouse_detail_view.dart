// Fase 2 Bodegas — dentro de una bodega.
//
// La pantalla que faltaba. Hasta ahora, desde Bodegas no se podía ajustar,
// ni transferir, ni contar, ni ver el kardex: había que volver al hub y
// entrar por otra puerta. Acá la bodega es el CONTEXTO y todo lo que se
// hace, se hace sobre ella.
//
// Tres pestañas:
//   · Stock          — qué hay acá y cuánto falta contra el mínimo LOCAL.
//   · Movimientos    — el kardex de esta bodega, con saldo por insumo.
//   · Transferencias — lo que entra y lo que sale, con lo pendiente arriba.
//
// Sobre el mínimo: `inventory_items.min_stock` es del NEGOCIO. Comparar ese
// número contra el stock de un solo almacén miente, así que la columna
// "Mínimo acá" usa el mínimo propio de la bodega
// (`inventory_stock.min_stock`) y sólo cae al global cuando el negocio opera
// con una sola bodega — ahí son el mismo sitio. Ver [WarehouseMinStock].

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../app/router/routes.dart';
import '../../../app/widgets/skeleton_loading.dart';
import '../../../core/currency/business_currency.dart';
import '../../../core/currency/business_currency_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../../../services/session/session_controller.dart';
import '../state/inventory_state.dart';
import '../state/kardex_state.dart';
import '../state/transfers_state.dart';
import '../state/warehouse_overview_state.dart';
import '../viewmodel/inventory_viewmodel.dart';
import 'item_adjust_dialog.dart';
import 'transfer_send_dialog.dart';
import 'widgets/warehouse_form_dialog.dart';
import 'widgets/warehouse_visuals.dart';

enum WarehouseTab { stock, movements, transfers }

/// Ancho a partir del cual la tabla cabe entera; por debajo se pasa a
/// tarjetas apiladas, que es como se lee en una tablet de 1024 en vertical.
const double _kTableBreakpoint = 900;

const double _kColHere = 118;
const double _kColMin = 196;
const double _kColValue = 128;
const double _kColActions = 168;

final NumberFormat _fmtQty = NumberFormat.decimalPattern('es_DO');
final DateFormat _fmtTime = DateFormat('HH:mm');
final DateFormat _fmtDate = DateFormat('dd/MM/yy');

class WarehouseDetailView extends ConsumerStatefulWidget {
  final String warehouseId;
  final WarehouseTab initialTab;

  const WarehouseDetailView({
    super.key,
    required this.warehouseId,
    this.initialTab = WarehouseTab.stock,
  });

  @override
  ConsumerState<WarehouseDetailView> createState() =>
      _WarehouseDetailViewState();
}

class _WarehouseDetailViewState extends ConsumerState<WarehouseDetailView> {
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  String? _businessId;

  /// Todas las bodegas del negocio: hacen falta para ubicar ésta, para el
  /// selector del ajuste y para saber si el negocio tiene una sola (y
  /// entonces el mínimo global sí aplica acá).
  List<InventoryWarehouseDetail> _all = const [];
  InventoryStockMatrix _matrix = InventoryStockMatrix.empty;
  WarehouseMinStock _mins = WarehouseMinStock.empty;

  int _movementsToday = 0;
  int _inboundToday = 0;
  int _outboundToday = 0;
  DateTime? _lastActivityAt;

  late WarehouseTab _tab = widget.initialTab;

  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  String _query = '';
  bool _onlyLow = false;
  String? _classification;

  List<KardexMovement> _movements = const [];
  bool _movementsLoading = false;
  String? _movementsError;

  List<StockTransfer> _transfers = const [];
  bool _transfersLoading = false;
  String? _transfersError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  InventoryRepository get _repo => ref.read(inventoryRepositoryProvider);

  InventoryWarehouseDetail? get _warehouse {
    for (final w in _all) {
      if (w.id == widget.warehouseId) return w;
    }
    return null;
  }

  /// Bodegas que forman las columnas de la matriz y el destino posible de un
  /// ajuste: las activas, sin la virtual de tránsito… y SIEMPRE ésta.
  ///
  /// Lo último importa: si la bodega está desactivada y se entra desde el
  /// menú a ver su histórico, dejarla fuera de la matriz haría que todo
  /// apareciera en cero — "acá no hay nada" cuando en realidad la mercancía
  /// sigue guardada ahí, congelada.
  List<InventoryWarehouseDetail> get _visible => _all
      .where(
        (w) => !w.isInTransit && (w.isActive || w.id == widget.warehouseId),
      )
      .toList(growable: false);

  List<InventoryWarehouse> get _warehousesForDialogs => _visible
      .map((w) => InventoryWarehouse(id: w.id, name: w.name, isMain: w.isMain))
      .toList(growable: false);

  // ── Carga ───────────────────────────────────────────────────────────────

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final businessId = await resolveBusinessIdOrNull(
        Supabase.instance.client,
        'auto',
      );
      if (businessId == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'No se pudo resolver el negocio activo.';
        });
        return;
      }
      _businessId = businessId;
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _load() async {
    final businessId = _businessId;
    if (businessId == null) return;
    try {
      final all = await _repo.getAllWarehouses(businessId);
      final exists = all.any((w) => w.id == widget.warehouseId);
      if (!exists) {
        if (!mounted) return;
        setState(() {
          _all = all;
          _loading = false;
          _error = 'Esta bodega ya no existe en el negocio activo.';
        });
        return;
      }
      final visibleIds = all
          .where(
            (w) =>
                !w.isInTransit &&
                (w.isActive || w.id == widget.warehouseId),
          )
          .map((w) => w.id)
          .toList(growable: false);
      // "Una sola bodega" se mide sobre las ACTIVAS: es la condición para que
      // el mínimo global del negocio valga como mínimo de esta bodega.
      final activeCount = all
          .where((w) => !w.isInTransit && w.isActive)
          .length;

      // La matriz trae el maestro completo y el stock de TODAS las bodegas
      // visibles: hace falta para el diálogo de ajuste (que muestra dónde
      // más está el insumo) y para el porcentaje que representa esta bodega
      // dentro del negocio. Es la misma lectura que hidrata Insumos, así que
      // el caché offline se comparte.
      //
      // El kardex y las transferencias entran en la MISMA tanda aunque su
      // pestaña esté cerrada: el encabezado dice "última actividad" y la
      // pestaña de transferencias trae un contador. Un dato que aparece
      // recién cuando tocás la pestaña es peor que no mostrarlo.
      final now = DateTime.now();
      final results = await Future.wait<dynamic>([
        _repo.getItemsMatrix(businessId: businessId, warehouseIds: visibleIds),
        _repo.getWarehouseMinStock(widget.warehouseId),
        _repo.getMovementCounts(
          businessId: businessId,
          warehouseId: widget.warehouseId,
          since: DateTime(now.year, now.month, now.day),
        ),
        _movementsOrEmpty(businessId),
        _transfersOrEmpty(businessId),
      ]);

      if (!mounted) return;
      final counts = results[2] as ({int inbound, int outbound});
      final movements = results[3] as List<KardexMovement>;
      setState(() {
        _all = all;
        _matrix = results[0] as InventoryStockMatrix;
        _mins = WarehouseMinStock(
          overrides: results[1] as Map<String, double>,
          singleWarehouse: activeCount == 1,
          supported: _repo.warehouseMinStockSupported,
        );
        _inboundToday = counts.inbound;
        _outboundToday = counts.outbound;
        _movementsToday = counts.inbound + counts.outbound;
        _movements = movements;
        _movementsError = null;
        _lastActivityAt = movements.isEmpty
            ? _lastActivityAt
            : movements.first.createdAt;
        _transfers = results[4] as List<StockTransfer>;
        _transfersError = null;
        _loading = false;
        _refreshing = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = _matrix.items.isEmpty ? e.toString() : null;
      });
      if (_matrix.items.isNotEmpty && mounted) {
        AppToast.warning(context, 'No se pudo actualizar: ${_short(e)}');
      }
    }
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await _load();
  }

  /// El kardex de esta bodega. Es una señal de apoyo: si falla, el stock —lo
  /// que se vino a ver— tiene que seguir apareciendo.
  Future<List<KardexMovement>> _movementsOrEmpty(String businessId) async {
    try {
      final rows = await _repo.getKardexMovements(
        businessId: businessId,
        warehouseId: widget.warehouseId,
        limit: 80,
      );
      return rows.map(KardexMovement.fromMap).toList(growable: false);
    } catch (e) {
      debugPrint('[bodega] no se pudo leer el kardex: $e');
      return const [];
    }
  }

  /// Transferencias donde participa ESTA bodega, en cualquier sentido.
  Future<List<StockTransfer>> _transfersOrEmpty(String businessId) async {
    try {
      final all = await _repo.listTransfers(businessId: businessId, limit: 60);
      return all
          .where(
            (t) =>
                t.fromWarehouseId == widget.warehouseId ||
                t.toWarehouseId == widget.warehouseId,
          )
          .toList(growable: false);
    } catch (e) {
      debugPrint('[bodega] no se pudieron leer las transferencias: $e');
      return const [];
    }
  }

  /// Reintento de UNA pestaña. La carga normal viene de [_load]; esto es lo
  /// que corre el botón "Reintentar" cuando su lectura falló.
  Future<void> _loadTab(WarehouseTab tab, {bool force = false}) async {
    final businessId = _businessId;
    if (businessId == null) return;

    if (tab == WarehouseTab.movements) {
      if (_movementsLoading || (_movements.isNotEmpty && !force)) return;
      setState(() {
        _movementsLoading = true;
        _movementsError = null;
      });
      try {
        final rows = await _repo.getKardexMovements(
          businessId: businessId,
          warehouseId: widget.warehouseId,
          limit: 80,
        );
        if (!mounted) return;
        final movements = rows
            .map(KardexMovement.fromMap)
            .toList(growable: false);
        setState(() {
          _movements = movements;
          _movementsLoading = false;
          _lastActivityAt = movements.isEmpty
              ? _lastActivityAt
              : movements.first.createdAt;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _movementsLoading = false;
          _movementsError = e.toString();
        });
      }
      return;
    }

    if (tab == WarehouseTab.transfers) {
      if (_transfersLoading || (_transfers.isNotEmpty && !force)) return;
      setState(() {
        _transfersLoading = true;
        _transfersError = null;
      });
      try {
        final all = await _repo.listTransfers(
          businessId: businessId,
          limit: 60,
        );
        if (!mounted) return;
        setState(() {
          _transfers = all
              .where(
                (t) =>
                    t.fromWarehouseId == widget.warehouseId ||
                    t.toWarehouseId == widget.warehouseId,
              )
              .toList(growable: false);
          _transfersLoading = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _transfersLoading = false;
          _transfersError = e.toString();
        });
      }
    }
  }

  static String _short(Object e) {
    final text = e.toString();
    return text.length > 90 ? '${text.substring(0, 90)}…' : text;
  }

  // ── Derivados ───────────────────────────────────────────────────────────

  double _qtyOf(String itemId) =>
      _matrix.quantityOf(itemId, widget.warehouseId);

  /// Insumos que la tabla pinta: los que están acá (o los que el usuario
  /// busca, aunque todavía no hayan entrado a esta bodega — así es como se
  /// les da entrada por primera vez).
  List<InventoryItemSummary> _visibleItems({bool ignoreLow = false}) {
    final lower = _query.toLowerCase();
    return _matrix.items.where((item) {
      if (!item.isActive) return false;
      if (_classification != null &&
          item.itemClassification != _classification) {
        return false;
      }
      if (!ignoreLow && _onlyLow && !_mins.isLow(item, _qtyOf(item.id))) {
        return false;
      }
      if (lower.isNotEmpty) {
        return item.name.toLowerCase().contains(lower) ||
            item.sku.toLowerCase().contains(lower) ||
            item.barcode.toLowerCase().contains(lower);
      }
      return _matrix.hasStockRow(item.id, widget.warehouseId) ||
          _mins.hasOverride(item.id);
    }).toList(growable: false);
  }

  int _lowCount() => _matrix.items
      .where((i) => i.isActive && _mins.isLow(i, _qtyOf(i.id)))
      .length;

  double _warehouseValue() {
    var total = 0.0;
    for (final item in _matrix.items) {
      total += _qtyOf(item.id) * item.cost;
    }
    return total;
  }

  double _businessValue() {
    var total = 0.0;
    for (final item in _matrix.items) {
      final row = _matrix.byWarehouse[item.id];
      if (row == null) continue;
      for (final qty in row.values) {
        total += qty * item.cost;
      }
    }
    return total;
  }

  int _itemsHere() => _matrix.items
      .where((i) => i.isActive && _qtyOf(i.id) > 0)
      .length;

  Map<String, double> _stockRowOf(String itemId) {
    final row = _matrix.byWarehouse[itemId] ?? const <String, double>{};
    return {for (final w in _visible) w.id: row[w.id] ?? 0};
  }

  // ── Acciones ────────────────────────────────────────────────────────────

  Future<void> _openAdjust(
    InventoryItemSummary item, {
    String? reasonCode,
  }) async {
    final businessId = _businessId;
    if (businessId == null) return;
    final saved = await showItemAdjustDialog(
      context,
      businessId: businessId,
      item: item,
      warehouses: _warehousesForDialogs,
      // Fijo a ESTA bodega: es el sentido de haber entrado acá. Nunca se
      // escribe en un almacén que nadie eligió.
      warehouseId: widget.warehouseId,
      stockByWarehouse: _stockRowOf(item.id),
      initialReasonCode: reasonCode,
    );
    if (!saved || !mounted) return;
    AppToast.success(context, 'Ajuste registrado en el kardex.');
    await _refresh();
  }

  Future<void> _openTransfer() async {
    final sent = await showDialog<bool>(
      context: context,
      builder: (_) =>
          TransferSendDialog(initialFromWarehouseId: widget.warehouseId),
    );
    if (sent == true) await _refresh();
  }

  Future<void> _openEdit() async {
    final businessId = _businessId;
    final warehouse = _warehouse;
    if (businessId == null || warehouse == null) return;
    final saved = await showWarehouseFormDialog(
      context,
      businessId: businessId,
      repo: _repo,
      edit: warehouse,
    );
    if (saved) await _refresh();
  }

  /// El conteo físico vive en su propia pantalla (sesiones, congelado,
  /// segunda vuelta). Desde acá se llega con la bodega ya en la cabeza del
  /// usuario, que es lo que importaba.
  void _openPhysicalCount() => context.push(
    '${AppRoutes.inventoryPhysicalCount}?warehouse=${widget.warehouseId}',
  );

  Future<void> _editMin(InventoryItemSummary item) async {
    if (!_mins.supported) {
      AppToast.warning(
        context,
        'Los mínimos por bodega necesitan la migración '
        '20260819_0001_warehouse_min_stock aplicada en Supabase.',
      );
      return;
    }
    final current = _mins.overrides[item.id];
    final result = await showDialog<_MinResult>(
      context: context,
      builder: (_) => _MinStockDialog(
        item: item,
        warehouseName: _warehouse?.name ?? 'esta bodega',
        current: current,
        globalMin: item.minStock,
      ),
    );
    if (result == null) return;
    try {
      await _repo.setWarehouseMinStock(
        warehouseId: widget.warehouseId,
        itemId: item.id,
        minStock: result.clear ? null : result.value,
      );
      if (!mounted) return;
      AppToast.success(
        context,
        result.clear
            ? 'Se quitó el mínimo de ${item.name} en esta bodega.'
            : 'Mínimo de ${item.name} acá: '
                  '${_fmtQty.format(result.value)} ${item.unit}.',
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo guardar el mínimo: ${_short(e)}');
    }
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      setState(() => _query = value.trim());
    });
  }

  void _selectTab(WarehouseTab tab) => setState(() => _tab = tab);

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final currency = currentBusinessCurrencyOrFallback(ref);
    final session = ref.watch(sessionProvider.notifier);
    final canAdjust = session.hasPermission('inventario.ajustes.crear');
    final canTransfer = session.hasPermission(
      'inventario.transferencias.crear',
    );
    final canCount = session.hasPermission('inventario.conteo.crear');

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _kTableBreakpoint;
            if (_error != null && _matrix.items.isEmpty) return _errorState();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(
                  currency: currency,
                  wide: wide,
                  canTransfer: canTransfer,
                  canCount: canCount,
                ),
                if (_refreshing)
                  LinearProgressIndicator(
                    minHeight: 2,
                    backgroundColor: AppColors.muted,
                    color: AppColors.primary,
                  ),
                Expanded(
                  child: _loading
                      ? _skeleton(wide)
                      : _body(currency: currency, wide: wide, canAdjust: canAdjust),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _errorState() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 40, color: AppColors.destructive),
          const SizedBox(height: 12),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.foreground),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _bootstrap, child: const Text('Reintentar')),
        ],
      ),
    ),
  );

  // ── Encabezado ──────────────────────────────────────────────────────────

  Widget _header({
    required BusinessCurrency currency,
    required bool wide,
    required bool canTransfer,
    required bool canCount,
  }) {
    final w = _warehouse;
    final name = w?.name ?? 'Bodega';
    final index = _all.indexWhere((x) => x.id == widget.warehouseId);
    final accent = warehouseAccent(
      index: index < 0 ? 0 : index,
      isMain: w?.isMain ?? false,
      isActive: w?.isActive ?? true,
    );

    final subtitleParts = <String>[
      (w?.address.isEmpty ?? true) ? 'Sin dirección registrada' : w!.address,
      if (_lastActivityAt != null)
        'última actividad ${_relative(_lastActivityAt!)}',
    ];

    final actions = <Widget>[
      OutlinedButton.icon(
        onPressed: _loading ? null : _openEdit,
        icon: const Icon(Icons.edit_outlined, size: 17),
        label: const Text('Editar'),
      ),
      if (canTransfer)
        OutlinedButton.icon(
          onPressed: _loading ? null : _openTransfer,
          icon: const Icon(Icons.swap_horiz, size: 17),
          label: const Text('Transferir'),
        ),
      if (canCount)
        FilledButton.icon(
          onPressed: _loading ? null : _openPhysicalCount,
          icon: const Icon(Icons.checklist, size: 17),
          label: const Text('Conteo físico'),
        ),
    ];

    return Container(
      padding: EdgeInsets.fromLTRB(wide ? 20 : 12, 14, wide ? 24 : 12, 14),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              IconButton(
                tooltip: 'Volver a Bodegas',
                onPressed: () => context.canPop()
                    ? context.pop()
                    : context.go(AppRoutes.inventoryWarehouses),
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 4),
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                ),
                child: Icon(warehouseIcon(name), size: 24, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: wide ? 26 : 20,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.4,
                              color: AppColors.foreground,
                            ),
                          ),
                        ),
                        const SizedBox(width: 9),
                        if (w != null)
                          _Chip(
                            text: w.isActive ? 'Activa' : 'Inactiva',
                            color: w.isActive
                                ? AppColors.success
                                : AppColors.mutedForeground,
                          ),
                        if (w?.isMain == true) ...[
                          const SizedBox(width: 6),
                          _Chip(text: 'Principal', color: AppColors.primary),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitleParts.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              if (wide) ...[
                for (final action in actions) ...[
                  const SizedBox(width: 10),
                  action,
                ],
              ],
            ],
          ),
          if (!wide) ...[
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final action in actions) ...[
                    action,
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _relative(DateTime when) {
    final diff = DateTime.now().difference(when);
    if (diff.inMinutes < 1) return 'hace un momento';
    if (diff.inMinutes < 60) return 'hace ${diff.inMinutes} min';
    if (diff.inHours < 24) {
      return 'hace ${diff.inHours} ${diff.inHours == 1 ? 'hora' : 'horas'}';
    }
    if (diff.inDays < 30) {
      return 'hace ${diff.inDays} ${diff.inDays == 1 ? 'día' : 'días'}';
    }
    return 'el ${_fmtDate.format(when)}';
  }

  // ── Cuerpo ──────────────────────────────────────────────────────────────

  Widget _body({
    required BusinessCurrency currency,
    required bool wide,
    required bool canAdjust,
  }) {
    return RefreshIndicator(
      onRefresh: _refresh,
      color: AppColors.primary,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(wide ? 24 : 12, 16, wide ? 24 : 12, 0),
            sliver: SliverToBoxAdapter(child: _kpis(currency, wide)),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(wide ? 24 : 12, 16, wide ? 24 : 12, 0),
            sliver: SliverToBoxAdapter(child: _tabs()),
          ),
          ...switch (_tab) {
            WarehouseTab.stock => _stockSlivers(currency, wide, canAdjust),
            WarehouseTab.movements => _movementsSlivers(wide),
            WarehouseTab.transfers => _transfersSlivers(wide),
          },
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }

  Widget _kpis(BusinessCurrency currency, bool wide) {
    final value = _warehouseValue();
    final business = _businessValue();
    final share = business <= 0 ? 0.0 : (value / business) * 100;
    final low = _lowCount();
    final lowItem = _matrix.items
        .where((i) => i.isActive && _mins.isLow(i, _qtyOf(i.id)))
        .toList(growable: false);

    String lowSub() {
      if (!_mins.supported && !_mins.singleWarehouse) {
        return 'Sin mínimos por bodega configurados';
      }
      if (low == 0) return 'Nada por reponer acá';
      final first = lowItem.first;
      final missing = _mins.shortfall(first, _qtyOf(first.id));
      return '${first.name} · faltan ${_fmtQty.format(missing)} ${first.unit}';
    }

    final cards = <Widget>[
      _KpiCard(
        icon: Icons.payments_outlined,
        iconColor: AppColors.success,
        label: 'Valor en existencias',
        value: currency.formatAmount(value),
        sub: business <= 0
            ? 'Sin existencias en el negocio'
            : '${share.toStringAsFixed(1)}% del total del negocio',
      ),
      _KpiCard(
        icon: Icons.inventory_2_outlined,
        iconColor: AppColors.info,
        label: 'Insumos con stock',
        value: '${_itemsHere()}',
        sub: 'de ${_matrix.items.where((i) => i.isActive).length} en el '
            'catálogo',
      ),
      _KpiCard(
        icon: Icons.warning_amber_rounded,
        iconColor: AppColors.warning,
        label: 'Bajo mínimo',
        value: '$low',
        valueColor: low > 0 ? AppColors.warning : null,
        sub: lowSub(),
      ),
      _KpiCard(
        icon: Icons.history,
        iconColor: AppColors.mutedForeground,
        label: 'Movimientos hoy',
        value: '$_movementsToday',
        sub: '$_inboundToday entradas · $_outboundToday salidas',
      ),
    ];

    if (!wide) {
      return Column(
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            cards[i],
          ],
        ],
      );
    }
    return Row(
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(width: 14),
          Expanded(child: cards[i]),
        ],
      ],
    );
  }

  Widget _tabs() {
    final pendingTransfers = _transfers
        .where((t) => t.isInTransit || t.needsApproval)
        .length;

    Widget tab(WarehouseTab value, String label, String? count, Color? cColor) {
      final selected = _tab == value;
      return InkWell(
        onTap: () => _selectTab(value),
        child: Padding(
          padding: const EdgeInsets.only(right: 20),
          child: Container(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 11),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: selected ? AppColors.primary : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected
                        ? AppColors.foreground
                        : AppColors.mutedForeground,
                  ),
                ),
                if (count != null && count != '0') ...[
                  const SizedBox(width: 7),
                  Container(
                    constraints: const BoxConstraints(minWidth: 18),
                    height: 18,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppColors.foreground
                          : (cColor ?? AppColors.muted),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: Text(
                      count,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: selected ? Colors.white : AppColors.foreground,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            tab(WarehouseTab.stock, 'Stock', '${_itemsHere()}', null),
            tab(WarehouseTab.movements, 'Movimientos', null, null),
            tab(
              WarehouseTab.transfers,
              'Transferencias',
              '$pendingTransfers',
              AppColors.reserved.withValues(alpha: 0.16),
            ),
          ],
        ),
      ),
    );
  }

  // ── Pestaña Stock ───────────────────────────────────────────────────────

  List<Widget> _stockSlivers(
    BusinessCurrency currency,
    bool wide,
    bool canAdjust,
  ) {
    final items = _visibleItems();
    final padding = EdgeInsets.symmetric(horizontal: wide ? 24 : 12);

    return [
      SliverPadding(
        padding: padding.copyWith(top: 16, bottom: 12),
        sliver: SliverToBoxAdapter(child: _stockToolbar(wide)),
      ),
      if (items.isEmpty)
        SliverPadding(
          padding: padding,
          sliver: SliverToBoxAdapter(child: _emptyStock()),
        )
      else ...[
        if (wide)
          SliverPadding(
            padding: padding,
            sliver: SliverToBoxAdapter(child: _stockHeaderRow()),
          ),
        SliverPadding(
          padding: padding,
          sliver: SliverList.builder(
            itemCount: items.length,
            itemBuilder: (context, i) => wide
                ? _StockRow(
                    item: items[i],
                    quantity: _qtyOf(items[i].id),
                    mins: _mins,
                    currency: currency,
                    canAdjust: canAdjust,
                    onAdjust: () => _openAdjust(items[i]),
                    onTransfer: _openTransfer,
                    onEditMin: () => _editMin(items[i]),
                    onCount: () =>
                        _openAdjust(items[i], reasonCode: 'physical_count'),
                  )
                : _StockCard(
                    item: items[i],
                    quantity: _qtyOf(items[i].id),
                    mins: _mins,
                    currency: currency,
                    canAdjust: canAdjust,
                    onAdjust: () => _openAdjust(items[i]),
                    onEditMin: () => _editMin(items[i]),
                  ),
          ),
        ),
        SliverPadding(
          padding: padding.copyWith(top: wide ? 0 : 4),
          sliver: SliverToBoxAdapter(child: _stockFooter(currency, wide)),
        ),
      ],
    ];
  }

  Widget _stockToolbar(bool wide) {
    final lowCount = _matrix.items
        .where((i) => i.isActive && _mins.isLow(i, _qtyOf(i.id)))
        .length;

    final search = TextField(
      controller: _searchCtrl,
      onChanged: _onSearchChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Buscar o escanear en esta bodega',
        prefixIcon: Icon(Icons.search, color: AppColors.mutedForeground),
        suffixIcon: _query.isEmpty
            ? Icon(Icons.qr_code_scanner, color: AppColors.primary)
            : IconButton(
                tooltip: 'Limpiar',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() => _query = '');
                },
              ),
        filled: true,
        fillColor: AppColors.card,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: AppColors.border),
        ),
      ),
    );

    final filters = <Widget>[
      _FilterPill(
        label: 'Bajo mínimo',
        count: lowCount,
        selected: _onlyLow,
        color: AppColors.primary,
        onTap: () => setState(() => _onlyLow = !_onlyLow),
      ),
      PopupMenuButton<String?>(
        tooltip: 'Clasificación',
        onSelected: (v) => setState(() => _classification = v),
        itemBuilder: (_) => const [
          PopupMenuItem(value: null, child: Text('Todas')),
          PopupMenuItem(value: 'simple', child: Text('Simples')),
          PopupMenuItem(value: 'raw_material', child: Text('Materia prima')),
          PopupMenuItem(
            value: 'finished_product',
            child: Text('Producto terminado'),
          ),
        ],
        child: _FilterPill(
          label: switch (_classification) {
            'simple' => 'Simples',
            'raw_material' => 'Materia prima',
            'finished_product' => 'Terminados',
            _ => 'Clasificación',
          },
          selected: _classification != null,
          trailingIcon: Icons.expand_more,
          color: AppColors.primary,
        ),
      ),
    ];

    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          search,
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < filters.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                filters[i],
              ],
            ],
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(child: search),
        for (final filter in filters) ...[const SizedBox(width: 10), filter],
      ],
    );
  }

  Widget _stockHeaderRow() {
    Widget head(String text, {TextAlign align = TextAlign.left}) => Text(
      text.toUpperCase(),
      textAlign: align,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.5,
        color: AppColors.mutedForeground,
      ),
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.lg),
        ),
      ),
      child: Row(
        children: [
          Expanded(child: head('Insumo')),
          SizedBox(
            width: _kColHere,
            child: head('Acá', align: TextAlign.right),
          ),
          const SizedBox(width: 16),
          SizedBox(width: _kColMin, child: head('Mínimo de esta bodega')),
          const SizedBox(width: 16),
          SizedBox(
            width: _kColValue,
            child: head('Valor', align: TextAlign.right),
          ),
          const SizedBox(width: 16),
          const SizedBox(width: _kColActions),
        ],
      ),
    );
  }

  Widget _stockFooter(BusinessCurrency currency, bool wide) {
    final low = _lowCount();
    final name = _warehouse?.name ?? 'esta bodega';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border),
        borderRadius: wide
            ? const BorderRadius.vertical(
                bottom: Radius.circular(AppRadius.lg),
              )
            : BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${_itemsHere()} insumos con existencia en $name'
              '${low > 0 ? ' · $low bajo mínimo' : ''}',
              style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
            ),
          ),
          Text(
            'Valor en esta bodega  ',
            style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
          ),
          Text(
            currency.formatAmount(_warehouseValue()),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: AppColors.foreground,
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyStock() {
    final searching = _query.isNotEmpty || _onlyLow || _classification != null;
    return Container(
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Icon(
            searching ? Icons.search_off : Icons.inventory_2_outlined,
            size: 34,
            color: AppColors.mutedForeground,
          ),
          const SizedBox(height: 10),
          Text(
            searching
                ? 'Ningún insumo con esos filtros en esta bodega.'
                : 'Esta bodega todavía no tiene existencias.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            searching
                ? 'Buscá por nombre, SKU o código de barras para darle entrada '
                      'a un insumo que todavía no está acá.'
                : 'Recibí mercancía, transferí desde otra bodega o ajustá el '
                      'stock para empezar.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: AppColors.mutedForeground),
          ),
        ],
      ),
    );
  }

  // ── Pestaña Movimientos ─────────────────────────────────────────────────

  List<Widget> _movementsSlivers(bool wide) {
    final padding = EdgeInsets.symmetric(horizontal: wide ? 24 : 12);
    if (_movementsLoading) {
      return [
        SliverPadding(
          padding: padding.copyWith(top: 16),
          sliver: SliverToBoxAdapter(child: _listSkeleton()),
        ),
      ];
    }
    if (_movementsError != null) {
      return [
        SliverPadding(
          padding: padding.copyWith(top: 16),
          sliver: SliverToBoxAdapter(
            child: _tabError(_movementsError!, () => _loadTab(
              WarehouseTab.movements,
              force: true,
            )),
          ),
        ),
      ];
    }
    if (_movements.isEmpty) {
      return [
        SliverPadding(
          padding: padding.copyWith(top: 16),
          sliver: SliverToBoxAdapter(
            child: _tabEmpty(
              Icons.history,
              'Sin movimientos registrados en esta bodega.',
              'Los ajustes, recepciones, consumos y transferencias aparecen '
                  'acá con su saldo.',
            ),
          ),
        ),
      ];
    }

    return [
      SliverPadding(
        padding: padding.copyWith(top: 16, bottom: 8),
        sliver: SliverToBoxAdapter(
          child: Text(
            'Últimos ${_movements.length} movimientos · el saldo es el de ese '
            'insumo en esta bodega después del movimiento.',
            style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
          ),
        ),
      ),
      SliverPadding(
        padding: padding,
        sliver: SliverList.builder(
          itemCount: _movements.length,
          itemBuilder: (context, i) => _MovementRow(
            movement: _movements[i],
            wide: wide,
            isLast: i == _movements.length - 1,
          ),
        ),
      ),
    ];
  }

  // ── Pestaña Transferencias ──────────────────────────────────────────────

  List<Widget> _transfersSlivers(bool wide) {
    final padding = EdgeInsets.symmetric(horizontal: wide ? 24 : 12);
    if (_transfersLoading) {
      return [
        SliverPadding(
          padding: padding.copyWith(top: 16),
          sliver: SliverToBoxAdapter(child: _listSkeleton()),
        ),
      ];
    }
    if (_transfersError != null) {
      return [
        SliverPadding(
          padding: padding.copyWith(top: 16),
          sliver: SliverToBoxAdapter(
            child: _tabError(_transfersError!, () => _loadTab(
              WarehouseTab.transfers,
              force: true,
            )),
          ),
        ),
      ];
    }
    if (_transfers.isEmpty) {
      return [
        SliverPadding(
          padding: padding.copyWith(top: 16),
          sliver: SliverToBoxAdapter(
            child: _tabEmpty(
              Icons.swap_horiz,
              'Esta bodega no tiene transferencias.',
              'Lo que entra y lo que sale hacia otras bodegas se lista acá, '
                  'con lo pendiente de recibir arriba.',
            ),
          ),
        ),
      ];
    }

    // Lo pendiente primero: es lo único sobre lo que hay que actuar.
    final sorted = [..._transfers]
      ..sort((a, b) {
        final aPending = a.isInTransit || a.needsApproval;
        final bPending = b.isInTransit || b.needsApproval;
        if (aPending != bPending) return aPending ? -1 : 1;
        final aDate = a.sentAt ?? DateTime(2000);
        final bDate = b.sentAt ?? DateTime(2000);
        return bDate.compareTo(aDate);
      });

    return [
      SliverPadding(
        padding: padding.copyWith(top: 16),
        sliver: SliverList.builder(
          itemCount: sorted.length,
          itemBuilder: (context, i) => _TransferRow(
            transfer: sorted[i],
            warehouseId: widget.warehouseId,
            isLast: i == sorted.length - 1,
            onOpen: () => context.push(AppRoutes.inventoryTransfers),
          ),
        ),
      ),
    ];
  }

  Widget _tabError(String message, VoidCallback onRetry) => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
      children: [
        Icon(Icons.error_outline, size: 28, color: AppColors.destructive),
        const SizedBox(height: 10),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, color: AppColors.mutedForeground),
        ),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: onRetry, child: const Text('Reintentar')),
      ],
    ),
  );

  Widget _tabEmpty(IconData icon, String title, String body) => Container(
    padding: const EdgeInsets.all(40),
    decoration: BoxDecoration(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
      children: [
        Icon(icon, size: 34, color: AppColors.mutedForeground),
        const SizedBox(height: 10),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: AppColors.foreground,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          body,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, color: AppColors.mutedForeground),
        ),
      ],
    ),
  );

  Widget _listSkeleton() => Column(
    children: List.generate(
      5,
      (i) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: SkeletonBox(height: 60, borderRadius: AppRadius.lg),
      ),
    ),
  );

  Widget _skeleton(bool wide) => SingleChildScrollView(
    padding: EdgeInsets.all(wide ? 24 : 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: List.generate(
            wide ? 4 : 1,
            (i) => Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i == 3 ? 0 : 14),
                child: const SkeletonBox(height: 92, borderRadius: 12),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        const SkeletonBox(width: 260, height: 18, borderRadius: 6),
        const SizedBox(height: 18),
        const SkeletonBox(height: 44, borderRadius: 10),
        const SizedBox(height: 12),
        for (var i = 0; i < 6; i++) ...[
          const SkeletonBox(height: 66, borderRadius: 10),
          const SizedBox(height: 8),
        ],
      ],
    ),
  );
}

// ── Piezas ────────────────────────────────────────────────────────────────

class _KpiCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final String sub;
  final Color? valueColor;

  const _KpiCard({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    required this.sub,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(17, 15, 17, 15),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.soft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: valueColor ?? AppColors.foreground,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            sub,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: AppColors.mutedForeground),
          ),
        ],
      ),
    );
  }
}

/// Fila de la tabla de stock. La columna del mínimo es la novedad: una barra
/// con la marca del mínimo LOCAL y, debajo, cuánto falta. Se toca para
/// configurarlo.
class _StockRow extends StatelessWidget {
  final InventoryItemSummary item;
  final double quantity;
  final WarehouseMinStock mins;
  final BusinessCurrency currency;
  final bool canAdjust;
  final VoidCallback onAdjust;
  final VoidCallback onTransfer;
  final VoidCallback onEditMin;
  final VoidCallback onCount;

  const _StockRow({
    required this.item,
    required this.quantity,
    required this.mins,
    required this.currency,
    required this.canAdjust,
    required this.onAdjust,
    required this.onTransfer,
    required this.onEditMin,
    required this.onCount,
  });

  @override
  Widget build(BuildContext context) {
    final low = mins.isLow(item, quantity);
    final min = mins.minFor(item);

    return Container(
      constraints: const BoxConstraints(minHeight: 66),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
      decoration: BoxDecoration(
        color: low ? AppColors.warningSurface : AppColors.card,
        border: Border(
          left: BorderSide(color: AppColors.border),
          right: BorderSide(color: AppColors.border),
          bottom: BorderSide(color: AppColors.border),
        ),
      ),
      child: Row(
        children: [
          Expanded(child: _name(low)),
          SizedBox(width: _kColHere, child: _here(low)),
          const SizedBox(width: 16),
          SizedBox(width: _kColMin, child: _min(min, low)),
          const SizedBox(width: 16),
          SizedBox(
            width: _kColValue,
            child: Text(
              currency.formatAmount(quantity * item.cost),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: AppColors.foreground,
              ),
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(width: _kColActions, child: _actions()),
        ],
      ),
    );
  }

  Widget _name(bool low) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 34,
          decoration: BoxDecoration(
            color: low ? AppColors.warning : Colors.transparent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.foreground,
                      ),
                    ),
                  ),
                  if (item.tracksLots) ...[
                    const SizedBox(width: 7),
                    _Chip(text: 'PERECEDERO', color: AppColors.warning),
                  ] else if (item.itemClassification == 'finished_product') ...[
                    const SizedBox(width: 7),
                    _Chip(text: 'TERMINADO', color: AppColors.success),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                [
                  if (item.sku.isNotEmpty) item.sku,
                  item.costingMethod == 'fifo' ? 'FIFO' : 'promedio',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _here(bool low) => Column(
    crossAxisAlignment: CrossAxisAlignment.end,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        _fmtQty.format(quantity),
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w800,
          color: low ? AppColors.warning : AppColors.foreground,
        ),
      ),
      Text(
        item.unit,
        style: TextStyle(fontSize: 11, color: AppColors.mutedForeground),
      ),
    ],
  );

  Widget _min(double? min, bool low) {
    return InkWell(
      onTap: onEditMin,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _MinBar(quantity: quantity, min: min, low: low),
            const SizedBox(height: 5),
            Text(
              _minLabel(min),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: low ? FontWeight.w800 : FontWeight.w500,
                color: low ? AppColors.warning : AppColors.mutedForeground,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _minLabel(double? min) {
    if (min == null) {
      // Sin mínimo local, el global se muestra COMO REFERENCIA y se dice de
      // quién es: es del negocio, no de esta bodega.
      if (item.minStock > 0) {
        return 'mín global ${_fmtQty.format(item.minStock)} ${item.unit}';
      }
      return 'sin mínimo · tocá para fijarlo';
    }
    final missing = mins.shortfall(item, quantity);
    if (missing > 0) {
      return 'faltan ${_fmtQty.format(missing)} de ${_fmtQty.format(min)}';
    }
    return 'mín ${_fmtQty.format(min)} ${item.unit} acá';
  }

  Widget _actions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (canAdjust)
          Flexible(
            child: InkWell(
              onTap: onAdjust,
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Container(
                height: 36,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.tune, size: 15, color: AppColors.foreground),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        'Ajustar',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.foreground,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(width: 6),
        SizedBox(
          width: 34,
          child: PopupMenuButton<String>(
            tooltip: 'Más acciones',
            padding: EdgeInsets.zero,
            icon: Icon(
              Icons.more_vert,
              size: 18,
              color: AppColors.mutedForeground,
            ),
            onSelected: (value) {
              switch (value) {
                case 'count':
                  onCount();
                case 'transfer':
                  onTransfer();
                case 'min':
                  onEditMin();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'count',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.checklist, size: 18),
                  title: Text('Contar acá'),
                ),
              ),
              PopupMenuItem(
                value: 'transfer',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.swap_horiz, size: 18),
                  title: Text('Transferir'),
                ),
              ),
              PopupMenuItem(
                value: 'min',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.rule, size: 18),
                  title: Text('Mínimo de esta bodega'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Versión apilada de la fila para pantallas angostas.
class _StockCard extends StatelessWidget {
  final InventoryItemSummary item;
  final double quantity;
  final WarehouseMinStock mins;
  final BusinessCurrency currency;
  final bool canAdjust;
  final VoidCallback onAdjust;
  final VoidCallback onEditMin;

  const _StockCard({
    required this.item,
    required this.quantity,
    required this.mins,
    required this.currency,
    required this.canAdjust,
    required this.onAdjust,
    required this.onEditMin,
  });

  @override
  Widget build(BuildContext context) {
    final low = mins.isLow(item, quantity);
    final min = mins.minFor(item);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: low ? AppColors.warningSurface : AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.foreground,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.sku.isEmpty ? item.unit : item.sku,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${_fmtQty.format(quantity)} ${item.unit}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: low ? AppColors.warning : AppColors.foreground,
                    ),
                  ),
                  Text(
                    currency.formatAmount(quantity * item.cost),
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onEditMin,
                  child: Text(
                    min == null
                        ? (item.minStock > 0
                              ? 'mín global ${_fmtQty.format(item.minStock)} '
                                    '${item.unit}'
                              : 'sin mínimo acá')
                        : 'mín ${_fmtQty.format(min)} ${item.unit} acá',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: low ? FontWeight.w800 : FontWeight.w500,
                      color: low
                          ? AppColors.warning
                          : AppColors.mutedForeground,
                    ),
                  ),
                ),
              ),
              if (canAdjust)
                OutlinedButton.icon(
                  onPressed: onAdjust,
                  icon: const Icon(Icons.tune, size: 15),
                  label: const Text('Ajustar'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 36),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Barra de stock con la marca del mínimo. La marca negra es el mínimo; el
/// relleno, lo que hay. Sin mínimo la marca no se dibuja — no hay contra qué.
class _MinBar extends StatelessWidget {
  final double quantity;
  final double? min;
  final bool low;

  const _MinBar({required this.quantity, required this.min, required this.low});

  @override
  Widget build(BuildContext context) {
    // La escala es 2× el mínimo (o el propio stock si no hay mínimo): así el
    // mínimo cae en el medio de la barra y se lee de un vistazo si estamos
    // por encima o por debajo.
    final scale = (min != null && min! > 0)
        ? (min! * 2).clamp(1, double.infinity)
        : (quantity <= 0 ? 1.0 : quantity);
    final fill = (quantity / scale).clamp(0.0, 1.0);
    final mark = (min == null || min! <= 0)
        ? null
        : (min! / scale).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return SizedBox(
          height: 8,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: 2,
                left: 0,
                right: 0,
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.muted,
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                ),
              ),
              Positioned(
                top: 2,
                left: 0,
                child: Container(
                  height: 4,
                  width: width * fill,
                  decoration: BoxDecoration(
                    color: low ? AppColors.warning : AppColors.success,
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                ),
              ),
              if (mark != null)
                Positioned(
                  top: 0,
                  left: (width * mark).clamp(0.0, width - 2),
                  child: Container(
                    width: 2,
                    height: 8,
                    color: AppColors.foreground,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _MovementRow extends StatelessWidget {
  final KardexMovement movement;
  final bool wide;
  final bool isLast;

  const _MovementRow({
    required this.movement,
    required this.wide,
    required this.isLast,
  });

  static const Map<String, (String, IconData)> _types = {
    'purchase': ('Compra', Icons.local_shipping_outlined),
    'sale': ('Venta', Icons.point_of_sale_outlined),
    'adjustment': ('Ajuste', Icons.tune),
    'transfer_in': ('Entra', Icons.call_received),
    'transfer_out': ('Sale', Icons.call_made),
    'waste': ('Merma', Icons.delete_outline),
    'return': ('Devolución', Icons.undo),
    'production': ('Producción', Icons.factory_outlined),
  };

  @override
  Widget build(BuildContext context) {
    final inbound = movement.isInbound;
    final color = inbound ? AppColors.success : AppColors.destructive;
    final type = _types[movement.movementType];
    final label = type?.$1 ?? movement.movementType;
    final icon = type?.$2 ?? Icons.swap_vert;
    final when = movement.createdAt;

    final quantity = Text(
      '${inbound ? '+' : ''}${_fmtQty.format(movement.quantity)}',
      textAlign: TextAlign.right,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w800,
        color: color,
      ),
    );

    final balance = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _fmtQty.format(movement.runningBalance),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.foreground,
          ),
        ),
        Text(
          movement.itemUnit,
          style: TextStyle(fontSize: 10.5, color: AppColors.mutedForeground),
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      margin: EdgeInsets.only(bottom: isLast ? 0 : 8),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  when == null ? '—' : _fmtTime.format(when),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
                Text(
                  when == null ? '' : _fmtDate.format(when),
                  style: TextStyle(
                    fontSize: 10.5,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  movement.itemName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
                Text(
                  [
                    if (movement.itemSku.isNotEmpty) movement.itemSku,
                    if (movement.createdByName?.isNotEmpty ?? false)
                      movement.createdByName!,
                    if (movement.notes?.isNotEmpty ?? false) movement.notes!,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (wide) ...[
            Container(
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 13, color: color),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
          ],
          SizedBox(width: 76, child: quantity),
          const SizedBox(width: 14),
          SizedBox(width: 70, child: balance),
        ],
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  final StockTransfer transfer;
  final String warehouseId;
  final bool isLast;
  final VoidCallback onOpen;

  const _TransferRow({
    required this.transfer,
    required this.warehouseId,
    required this.isLast,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final outgoing = transfer.fromWarehouseId == warehouseId;
    final counterpart = outgoing
        ? transfer.toWarehouseName
        : transfer.fromWarehouseName;
    final pending = transfer.isInTransit || transfer.needsApproval;
    final color = pending
        ? AppColors.reserved
        : (transfer.status == StockTransferStatus.cancelled
              ? AppColors.mutedForeground
              : AppColors.success);

    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        margin: EdgeInsets.only(bottom: isLast ? 0 : 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(
            color: pending
                ? AppColors.reserved.withValues(alpha: 0.35)
                : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(
                outgoing ? Icons.call_made : Icons.call_received,
                size: 17,
                color: color,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${outgoing ? 'Hacia' : 'Desde'} $counterpart',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.foreground,
                    ),
                  ),
                  Text(
                    [
                      transfer.transferNumber,
                      '${transfer.itemCount} insumo(s)',
                      if (transfer.sentAt != null)
                        _fmtDate.format(transfer.sentAt!),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _Chip(text: transfer.status.label, color: color),
          ],
        ),
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  final String label;
  final int? count;
  final bool selected;
  final Color color;
  final IconData? trailingIcon;
  final VoidCallback? onTap;

  const _FilterPill({
    required this.label,
    required this.selected,
    required this.color,
    this.count,
    this.trailingIcon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? color : AppColors.foreground;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: selected
              ? color.withValues(alpha: 0.08)
              : AppColors.card,
          border: Border.all(
            color: selected ? color.withValues(alpha: 0.45) : AppColors.border,
          ),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: fg,
              ),
            ),
            if (count != null && count! > 0) ...[
              const SizedBox(width: 6),
              Container(
                constraints: const BoxConstraints(minWidth: 18),
                height: 18,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(
                  color: selected ? color : AppColors.muted,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: selected ? Colors.white : AppColors.foreground,
                  ),
                ),
              ),
            ],
            if (trailingIcon != null) ...[
              const SizedBox(width: 4),
              Icon(trailingIcon, size: 18, color: AppColors.mutedForeground),
            ],
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  final Color color;
  const _Chip({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

/// Resultado del diálogo de mínimo: un valor, o la orden de quitarlo.
class _MinResult {
  final double value;
  final bool clear;
  const _MinResult({required this.value, this.clear = false});
}

class _MinStockDialog extends StatefulWidget {
  final InventoryItemSummary item;
  final String warehouseName;
  final double? current;
  final double globalMin;

  const _MinStockDialog({
    required this.item,
    required this.warehouseName,
    required this.current,
    required this.globalMin,
  });

  @override
  State<_MinStockDialog> createState() => _MinStockDialogState();
}

class _MinStockDialogState extends State<_MinStockDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.current == null ? '' : _fmtQty.format(widget.current),
  );
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _save() {
    final raw = _ctrl.text.trim().replaceAll(',', '.');
    final value = double.tryParse(raw);
    if (value == null || value < 0) {
      setState(() => _error = 'Escribí una cantidad válida.');
      return;
    }
    Navigator.pop(context, _MinResult(value: value));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Mínimo en ${widget.warehouseName}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.item.name,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.foreground,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.globalMin > 0
                  ? 'El mínimo del negocio es '
                        '${_fmtQty.format(widget.globalMin)} '
                        '${widget.item.unit}. Este número aplica sólo acá.'
                  : 'Este número aplica sólo a esta bodega.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: AppColors.mutedForeground,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _ctrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                labelText: 'Mínimo (${widget.item.unit})',
                errorText: _error,
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              const _MinResult(value: 0, clear: true),
            ),
            child: Text(
              'Quitar mínimo',
              style: TextStyle(color: AppColors.destructive),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _save, child: const Text('Guardar')),
      ],
    );
  }
}
