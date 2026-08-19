// Insumos v2 — una fila por insumo, una columna por bodega.
//
// El insumo dejó de ser una ficha con un número ambiguo: es una
// DISTRIBUCIÓN. La tabla muestra dónde está la mercancía, cuánto hay en cada
// sitio y qué falta contra el mínimo. De ahí salen las cuatro reglas de la
// pantalla:
//
//   1. Una columna por bodega. El stock ya no es un número sin dueño.
//   2. El ajuste nace en la celda: tocás la cantidad de Bar y el ajuste ya
//      viene con Bar cargado. Nunca se escribe en una bodega no elegida.
//   3. El contexto de bodega viaja: elegirla acá deja el módulo entero
//      (ajustes, salidas, kardex) en ese contexto y se recuerda al volver.
//   4. Se cuenta en el idioma real del piso (botellas, cajas) y la app
//      convierte a la unidad base.
//
// El CRUD del maestro vive en `widgets/item_form_dialog.dart`; el ajuste
// contextual, en `item_adjust_dialog.dart`.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../app/router/routes.dart';
import '../../../core/currency/business_currency.dart';
import '../../../core/currency/business_currency_provider.dart';
import '../../../core/inventory/pack_conversion.dart';
import '../../../core/theme/app_breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../../../services/session/session_controller.dart';
import '../../sales/widgets/pos_barcode_scanner.dart';
import '../state/inventory_state.dart';
import '../state/inventory_warehouse_scope.dart';
import '../state/kardex_state.dart';
import '../viewmodel/inventory_viewmodel.dart';
import '../viewmodel/kardex_viewmodel.dart';
import 'item_adjust_dialog.dart';
import 'transfer_send_dialog.dart';
import 'widgets/inventory_back_button.dart';
import 'widgets/item_form_dialog.dart';

/// Estado del filtro de actividad. `min_stock` y las bajas viven en el
/// maestro, así que el default es "solo activos": lo dado de baja no debería
/// competir por atención en la operación diaria.
enum _StatusFilter { active, inactive, all }

/// Colores del punto de cada bodega. La principal siempre va en el naranja
/// de marca; el resto rota por la paleta para que la columna, el chip y la
/// card de distribución hablen del mismo sitio.
const List<Color> _kWarehouseDots = <Color>[
  AppColors.info,
  AppColors.reserved,
  AppColors.success,
  AppColors.warning,
  Color(0xFF0EA5E9),
  Color(0xFFEC4899),
  Color(0xFF14B8A6),
];

/// Alto de los chips de la toolbar. Es un valor COMPARTIDO a propósito: con
/// alturas intrínsecas, el chip con contador medía 40 y el de menú 39, así
/// que en escritorio quedaban desalineados y en el carrusel horizontal del
/// móvil desbordaban la tira. Un solo número los alinea y garantiza que la
/// tira nunca sea más baja que su contenido.
const double _kFilterChipHeight = 40;

/// Ancho mínimo de la tabla antes de pasar a scroll horizontal.
const double _kColName = 300;
const double _kColCost = 116;
const double _kColWarehouse = 108;

/// Techo al que puede crecer una columna de bodega cuando sobra ancho. Sin
/// este reparto, TODO el aire de una pantalla ancha caía en la columna del
/// nombre: con dos bodegas quedaba un océano en blanco a la izquierda y los
/// encabezados de bodega partidos en dos líneas a la derecha.
const double _kColWarehouseMax = 168;
const double _kColTotal = 168;

/// El botón "Ajustar" (~93) más el menú (36) más el aire entre ellos. A 124
/// no entraban y el `more_vert` se salía de la fila.
const double _kColActions = 148;

/// Ancho del disparador del menú de fila. `PopupMenuButton` monta un
/// `IconButton`, que impone 48 de mínimo salvo que el padre lo acote — de
/// ahí el `SizedBox` explícito en vez de confiar en `padding: zero`.
const double _kRowMenuWidth = 36;

class InventoryItemsView extends ConsumerStatefulWidget {
  const InventoryItemsView({super.key});

  @override
  ConsumerState<InventoryItemsView> createState() => _InventoryItemsViewState();
}

class _InventoryItemsViewState extends ConsumerState<InventoryItemsView> {
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  String? _businessId;

  /// Bodegas VISIBLES: activas y sin la virtual `__IN_TRANSIT__` (esa es
  /// mercancía en tránsito, no un sitio donde alguien pueda contar).
  List<InventoryWarehouse> _warehouses = const [];
  InventoryStockMatrix _matrix = InventoryStockMatrix.empty;

  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _query = '';
  Timer? _searchDebounce;

  bool _onlyLowStock = false;
  String? _classification;
  String? _costing;
  _StatusFilter _status = _StatusFilter.active;

  /// Insumo con la distribución desplegada (solo uno a la vez: dos paneles
  /// abiertos vuelven la tabla ilegible).
  String? _expandedItemId;

  /// itemId → (warehouseId → último movimiento). Se carga al expandir.
  final Map<String, Map<String, KardexMovement>> _lastMovements = {};
  bool _loadingMovements = false;

  /// Con un diálogo arriba (ajuste, ficha, transferencia) el lector NO debe
  /// disparar otro flujo: la pistola escribe en el campo que esté enfocado y
  /// esta pantalla sigue montada debajo.
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  InventoryRepository get _repo => ref.read(inventoryRepositoryProvider);

  /// Bodega en contexto. `null` = "Todas · comparar".
  ///
  /// `read` y no `watch`: lo consultan también los handlers (abrir ajuste,
  /// contar) fuera de `build`. El rebuild lo dispara el `watch` explícito
  /// del `build`.
  String? get _scopeId => ref.read(inventoryWarehouseScopeProvider);

  List<String> get _warehouseIds =>
      _warehouses.map((w) => w.id).toList(growable: false);

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
      final warehouses = await _repo.getWarehouses(businessId);
      final visible = warehouses
          .where((w) => w.name != '__IN_TRANSIT__')
          .toList(growable: false);
      _businessId = businessId;
      _warehouses = visible;

      // El contexto persistido manda; si apunta a una bodega que ya no
      // existe, vuelve solo a "Todas".
      await ref
          .read(inventoryWarehouseScopeProvider.notifier)
          .ensureRestored(businessId, validIds: visible.map((w) => w.id));

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
    if (businessId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final matrix = await _repo.getItemsMatrix(
        businessId: businessId,
        warehouseIds: _warehouseIds,
        query: _query,
      );
      if (!mounted) return;
      setState(() {
        _matrix = matrix;
        _loading = false;
        _refreshing = false;
        _error = null;
        _lastMovements.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await _load();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() {
        _query = value.trim();
        _refreshing = true;
      });
      _load();
    });
  }

  /// Un escaneo NO es tecleo: resuelve de una y, si cae en un solo insumo,
  /// abre el conteo de esa bodega. Es el flujo de piso completo — apuntar,
  /// disparar, contar.
  Future<void> _onScan(String code) async {
    final normalized = code.trim();
    if (normalized.isEmpty || _dialogOpen) return;
    _searchDebounce?.cancel();
    _searchCtrl.text = normalized;
    setState(() {
      _query = normalized;
      _refreshing = true;
    });
    await _load();
    if (!mounted) return;
    final hits = _visibleItems();
    if (hits.length == 1) {
      await _openAdjust(hits.first, reasonCode: 'physical_count');
    } else if (hits.isEmpty) {
      AppToast.warning(context, 'Ningún insumo con el código "$normalized".');
    }
  }

  void _selectScope(String? warehouseId) {
    ref.read(inventoryWarehouseScopeProvider.notifier).select(warehouseId);
    // El resto del módulo (cuadre, salidas, kardex) lee el mismo contexto:
    // lo empujamos al viewmodel compartido para que no haya dos verdades.
    if (warehouseId != null) {
      unawaited(
        ref.read(inventoryViewModelProvider).selectWarehouse(warehouseId),
      );
    }
    setState(() => _expandedItemId = null);
  }

  /// Bodega donde caen las acciones cuando no se disparan desde una celda:
  /// la del contexto, o la principal si estamos en "Todas".
  String? get _defaultWarehouseId {
    final scope = _scopeId;
    if (scope != null && _warehouseIds.contains(scope)) return scope;
    for (final w in _warehouses) {
      if (w.isMain) return w.id;
    }
    return _warehouses.isEmpty ? null : _warehouses.first.id;
  }

  /// Predicado ÚNICO de la tabla. El texto tecleado ya viene filtrado desde
  /// el repositorio, así que acá solo quedan los filtros de la toolbar y el
  /// contexto de bodega.
  ///
  /// [ignoreLowStock] deja fuera el filtro de "bajo mínimo" para poder contar
  /// cuántos insumos aparecerían al activarlo —el número del badge— con
  /// exactamente los mismos criterios que la lista. Sin eso el badge promete
  /// un número y el filtro entrega otro.
  bool _matchesFilters(
    InventoryItemSummary item, {
    bool ignoreLowStock = false,
  }) {
    switch (_status) {
      case _StatusFilter.active:
        if (!item.isActive) return false;
      case _StatusFilter.inactive:
        if (item.isActive) return false;
      case _StatusFilter.all:
        break;
    }
    if (_classification != null && item.itemClassification != _classification) {
      return false;
    }
    if (_costing != null && item.costingMethod != _costing) return false;
    if (!ignoreLowStock && _onlyLowStock && !item.isLowStock) return false;
    // En contexto de UNA bodega la lista se limita a lo que vive ahí. La
    // excepción es la búsqueda: si el usuario escribe (o escanea) quiere
    // encontrar el insumo aunque esa bodega todavía no lo tenga — es
    // justamente cómo se le da entrada por primera vez.
    final scope = _scopeId;
    if (scope != null &&
        _query.isEmpty &&
        !_matrix.hasStockRow(item.id, scope)) {
      return false;
    }
    return true;
  }

  /// Los insumos que la tabla realmente pinta, tras filtros y contexto.
  List<InventoryItemSummary> _visibleItems() =>
      _matrix.items.where(_matchesFilters).toList(growable: false);

  /// Cuántos insumos saldrían al tocar "Bajo mínimo". Mismo pipeline que la
  /// lista: el badge y el resultado no pueden discrepar.
  int _lowStockCount() => _matrix.items
      .where((i) => i.isLowStock && _matchesFilters(i, ignoreLowStock: true))
      .length;

  /// Cuántos insumos tienen existencia en cada bodega — el número del chip.
  Map<String, int> _itemsPerWarehouse() {
    final counts = <String, int>{for (final w in _warehouses) w.id: 0};
    for (final item in _matrix.items) {
      if (!item.isActive) continue;
      for (final id in _matrix.warehousesWithStock(item.id)) {
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }
    return counts;
  }

  Map<String, double> _stockRowOf(String itemId) {
    final row = _matrix.byWarehouse[itemId] ?? const <String, double>{};
    return {for (final w in _warehouses) w.id: row[w.id] ?? 0};
  }

  // ── Acciones ────────────────────────────────────────────────────────────

  Future<void> _openForm({InventoryItemSummary? edit}) async {
    final businessId = _businessId;
    if (businessId == null) return;
    _dialogOpen = true;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => ItemFormDialog(
        businessId: businessId,
        repo: _repo,
        edit: edit,
      ),
    );
    _dialogOpen = false;
    if (saved == true) await _refresh();
  }

  Future<void> _openAdjust(
    InventoryItemSummary item, {
    String? warehouseId,
    String? reasonCode,
  }) async {
    final businessId = _businessId;
    final targetId = warehouseId ?? _defaultWarehouseId;
    if (businessId == null || targetId == null) return;
    _dialogOpen = true;
    final saved = await showItemAdjustDialog(
      context,
      businessId: businessId,
      item: item,
      warehouses: _warehouses,
      warehouseId: targetId,
      stockByWarehouse: _stockRowOf(item.id),
      initialReasonCode: reasonCode,
    );
    _dialogOpen = false;
    if (!saved || !mounted) return;
    AppToast.success(context, 'Ajuste registrado en el kardex.');
    await _refresh();
  }

  Future<void> _openTransfer() async {
    _dialogOpen = true;
    await showDialog<void>(
      context: context,
      builder: (_) => const TransferSendDialog(),
    );
    _dialogOpen = false;
    if (mounted) await _refresh();
  }

  /// Abre el kardex ya filtrado por el insumo (y la bodega, si el
  /// movimiento se pidió desde una celda concreta).
  Future<void> _openKardex(
    InventoryItemSummary item, {
    String? warehouseId,
  }) async {
    await ref
        .read(kardexViewModelProvider)
        .applyFilters(
          KardexFilters(itemId: item.id, warehouseId: warehouseId),
        );
    if (!mounted) return;
    context.push(AppRoutes.inventoryKardex);
  }

  Future<void> _toggleActive(InventoryItemSummary item) async {
    try {
      await _repo.setItemActive(itemId: item.id, isActive: !item.isActive);
      if (!mounted) return;
      AppToast.success(
        context,
        item.isActive
            ? '"${item.name}" quedó inactivo.'
            : '"${item.name}" volvió a estar activo.',
      );
      await _refresh();
    } on InventoryWriteDeniedException {
      if (!mounted) return;
      AppToast.error(
        context,
        'Tu usuario no tiene permiso para modificar insumos.',
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo actualizar el insumo: $e');
    }
  }

  Future<void> _confirmDelete(InventoryItemSummary item) async {
    _dialogOpen = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar insumo'),
        content: Text(
          '¿Seguro que quieres eliminar "${item.name}"?\n\n'
          'Si el insumo tiene historial (kardex, recetas o compras) se '
          'marcará como Inactivo para no perder esos registros.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.destructive,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    _dialogOpen = false;
    if (confirmed != true || !mounted) return;

    setState(() => _refreshing = true);
    try {
      final hardDeleted = await _repo.deleteItem(itemId: item.id);
      if (!mounted) return;
      AppToast.info(
        context,
        hardDeleted
            ? 'Insumo "${item.name}" eliminado.'
            : 'El insumo "${item.name}" tiene historial: se marcó como '
                  'Inactivo.',
      );
    } on InventoryWriteDeniedException {
      if (!mounted) return;
      setState(() => _refreshing = false);
      AppToast.error(
        context,
        'No se eliminó "${item.name}": tu usuario no tiene permiso para '
        'modificar insumos.',
      );
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _refreshing = false);
      AppToast.error(context, 'Error eliminando insumo: $e');
      return;
    }
    await _refresh();
  }

  /// Carga el último movimiento por bodega del insumo expandido. Una sola
  /// lectura del kardex: se queda con el más reciente de cada bodega.
  Future<void> _loadLastMovements(String itemId) async {
    final businessId = _businessId;
    if (businessId == null || _lastMovements.containsKey(itemId)) return;
    setState(() => _loadingMovements = true);
    try {
      final rows = await _repo.getKardexMovements(
        businessId: businessId,
        itemId: itemId,
        limit: 60,
      );
      final latest = <String, KardexMovement>{};
      for (final raw in rows) {
        final movement = KardexMovement.fromMap(raw);
        // Vienen ordenados desc por fecha: el primero de cada bodega gana.
        latest.putIfAbsent(movement.warehouseId, () => movement);
      }
      if (!mounted) return;
      setState(() {
        _lastMovements[itemId] = latest;
        _loadingMovements = false;
      });
    } catch (e) {
      if (!mounted) return;
      // El desglose sigue siendo útil sin la última línea de historial.
      setState(() {
        _lastMovements[itemId] = const {};
        _loadingMovements = false;
      });
    }
  }

  void _toggleExpanded(InventoryItemSummary item) {
    final next = _expandedItemId == item.id ? null : item.id;
    setState(() => _expandedItemId = next);
    if (next != null) unawaited(_loadLastMovements(next));
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // El maestro de insumos va bajo `inventario.productos.crear_editar`; el
    // ajuste, bajo `inventario.ajustes.crear`. Son permisos distintos: quien
    // cuenta en el piso no necesariamente puede editar la ficha.
    final session = ref.watch(sessionProvider.notifier);
    final canEditItems = session.hasPermission(
      'inventario.productos.crear_editar',
    );
    final canAdjust = session.hasPermission('inventario.ajustes.crear');
    final currency = currentBusinessCurrencyOrFallback(ref);
    // Rebuild al cambiar el contexto de bodega (los getters usan `read`).
    ref.watch(inventoryWarehouseScopeProvider);

    final isCompact = ResponsiveHelper.useCompactShell(context);
    // `useCompactShell` corta en 480: entre eso y ~1000 seguimos con tabla,
    // pero header y toolbar tienen que apilarse o desbordan.
    final isNarrow = MediaQuery.of(context).size.width < 1000;
    final items = _visibleItems();

    Widget body;
    if (_loading && _matrix.items.isEmpty) {
      body = Center(child: CircularProgressIndicator(color: AppColors.primary));
    } else if (_error != null && _matrix.items.isEmpty) {
      body = _errorState();
    } else {
      body = RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _refresh,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: isCompact
              ? const EdgeInsets.fromLTRB(14, 12, 14, 28)
              : const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(
                isCompact: isCompact,
                isNarrow: isNarrow,
                canCreate: canEditItems,
              ),
              SizedBox(height: isCompact ? 12 : 16),
              _scopeBar(isCompact: isCompact, isNarrow: isNarrow),
              SizedBox(height: isCompact ? 10 : 14),
              _toolbar(stacked: isCompact || isNarrow),
              if (_matrix.fromCache) ...[
                const SizedBox(height: 10),
                _offlineBanner(),
              ],
              SizedBox(height: isCompact ? 12 : 16),
              if (items.isEmpty)
                _emptyState()
              else if (isCompact)
                _mobileList(items, currency, canAdjust: canAdjust,
                    canEdit: canEditItems)
              else
                _desktopTable(items, currency,
                    canAdjust: canAdjust, canEdit: canEditItems),
            ],
          ),
        ),
      );
    }

    return BarcodeScanListener(
      enabled: !_loading,
      onScan: _onScan,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Stack(
            children: [
              body,
              if (_refreshing)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(minHeight: 2),
                ),
            ],
          ),
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

  Widget _offlineBanner() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: AppColors.warning.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(AppRadius.md),
      border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
    ),
    child: Row(
      children: [
        Icon(Icons.cloud_off, size: 16, color: AppColors.warning),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Sin conexión: estás viendo la última copia local. Los ajustes '
            'que registres se envían al reconectar.',
            style: TextStyle(fontSize: 12, color: AppColors.foreground),
          ),
        ),
      ],
    ),
  );

  Widget _emptyState() {
    final filtering =
        _query.isNotEmpty ||
        _onlyLowStock ||
        _classification != null ||
        _costing != null ||
        _status != _StatusFilter.active;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 36,
            color: AppColors.mutedForeground,
          ),
          const SizedBox(height: 10),
          Text(
            filtering
                ? 'Ningún insumo coincide con los filtros.'
                : 'Todavía no hay insumos cargados.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            filtering
                ? 'Probá quitar un filtro o cambiar de bodega.'
                : 'Creá el primero con "Nuevo insumo".',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.mutedForeground),
          ),
          if (filtering) ...[
            const SizedBox(height: 14),
            TextButton.icon(
              onPressed: () {
                _searchDebounce?.cancel();
                _searchCtrl.clear();
                setState(() {
                  _query = '';
                  _onlyLowStock = false;
                  _classification = null;
                  _costing = null;
                  _status = _StatusFilter.active;
                  _refreshing = true;
                });
                _load();
              },
              icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
              label: const Text('Limpiar filtros'),
            ),
          ],
        ],
      ),
    );
  }

  // ── Header ──────────────────────────────────────────────────────────────

  Widget _header({
    required bool isCompact,
    required bool isNarrow,
    required bool canCreate,
  }) {
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Insumos',
          style: TextStyle(
            fontSize: isCompact ? 20 : 28,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
            color: AppColors.foreground,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Qué tenés, dónde está y qué falta reponer',
          style: TextStyle(
            fontSize: isCompact ? 12 : 14,
            color: AppColors.mutedForeground,
          ),
        ),
      ],
    );

    if (isCompact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: InventoryBackButton(),
              ),
              const SizedBox(width: 2),
              Expanded(child: title),
              if (canCreate)
                IconButton(
                  tooltip: 'Nuevo insumo',
                  onPressed: () => _openForm(),
                  icon: Icon(Icons.add_circle, color: AppColors.primary),
                ),
            ],
          ),
        ],
      );
    }

    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        OutlinedButton.icon(
          onPressed: _openTransfer,
          icon: const Icon(Icons.swap_horiz, size: 18),
          label: const Text('Transferir'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.foreground,
            side: BorderSide(color: AppColors.border),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          ),
        ),
        if (canCreate) ...[
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: () => _openForm(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Nuevo insumo'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            ),
          ),
        ],
      ],
    );

    final titleRow = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: InventoryBackButton(),
        ),
        const SizedBox(width: 4),
        Expanded(child: title),
        if (!isNarrow) actions,
      ],
    );

    if (!isNarrow) return titleRow;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        titleRow,
        const SizedBox(height: 12),
        Align(alignment: Alignment.centerRight, child: actions),
      ],
    );
  }

  // ── Barra de contexto de bodega ─────────────────────────────────────────

  Widget _scopeBar({required bool isCompact, required bool isNarrow}) {
    final scope = _scopeId;
    final counts = _itemsPerWarehouse();

    final chips = <Widget>[
      _ScopeChip(
        label: isCompact ? 'Todas' : 'Todas · comparar',
        icon: Icons.grid_view_rounded,
        selected: scope == null,
        onTap: () => _selectScope(null),
      ),
      for (var i = 0; i < _warehouses.length; i++)
        _ScopeChip(
          label: _warehouses[i].name,
          dot: _dotColor(i),
          trailing: '${counts[_warehouses[i].id] ?? 0}',
          selected: scope == _warehouses[i].id,
          onTap: () => _selectScope(_warehouses[i].id),
        ),
    ];

    if (isCompact) {
      return SizedBox(
        height: 38,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: chips.length,
          separatorBuilder: (_, _) => const SizedBox(width: 7),
          itemBuilder: (_, i) => chips[i],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.soft,
      ),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Text(
              'BODEGA',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: AppColors.mutedForeground,
              ),
            ),
          ),
          Expanded(
            child: Wrap(spacing: 7, runSpacing: 7, children: chips),
          ),
          if (!isNarrow) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 250,
              child: Text(
                'Al elegir una bodega, todo el módulo queda en ese contexto: '
                'ajustes, salidas y kardex.',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: AppColors.mutedForeground,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _dotColor(int index) {
    if (_warehouses[index].isMain) return AppColors.primary;
    return _kWarehouseDots[index % _kWarehouseDots.length];
  }

  // ── Toolbar: búsqueda + filtros ─────────────────────────────────────────

  Widget _toolbar({required bool stacked}) {
    final lowCount = _lowStockCount();

    final search = TextField(
      controller: _searchCtrl,
      focusNode: _searchFocus,
      onChanged: _onSearchChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: AppColors.card,
        hintText: 'Buscar o escanear código',
        prefixIcon: Icon(Icons.search, color: AppColors.mutedForeground),
        suffixIcon: _query.isEmpty
            ? Icon(Icons.qr_code_scanner, color: AppColors.primary)
            : IconButton(
                tooltip: 'Limpiar',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  _searchDebounce?.cancel();
                  _searchCtrl.clear();
                  setState(() {
                    _query = '';
                    _refreshing = true;
                  });
                  _load();
                },
              ),
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
      _FilterChip(
        label: 'Bajo mínimo',
        count: lowCount == 0 ? null : '$lowCount',
        active: _onlyLowStock,
        onTap: () => setState(() => _onlyLowStock = !_onlyLowStock),
      ),
      _FilterMenu<String>(
        label: 'Clasificación',
        value: _classification ?? '',
        active: _classification != null,
        options: const [
          ('', 'Todas'),
          ('raw_material', 'Materia prima'),
          ('finished_product', 'Producto terminado'),
          ('combo', 'Combo'),
          ('service', 'Servicio'),
          ('simple', 'Simple'),
        ],
        onSelected: (v) =>
            setState(() => _classification = v.isEmpty ? null : v),
      ),
      _FilterMenu<String>(
        label: 'Costeo',
        value: _costing ?? '',
        active: _costing != null,
        options: const [
          ('', 'Todos'),
          ('average', 'Promedio'),
          ('fifo', 'FIFO'),
        ],
        onSelected: (v) => setState(() => _costing = v.isEmpty ? null : v),
      ),
      _FilterMenu<_StatusFilter>(
        label: 'Estado',
        value: _status,
        active: _status != _StatusFilter.active,
        options: const [
          (_StatusFilter.active, 'Activos'),
          (_StatusFilter.inactive, 'Inactivos'),
          (_StatusFilter.all, 'Todos'),
        ],
        onSelected: (v) => setState(() => _status = v),
      ),
    ];

    if (stacked) {
      return Column(
        children: [
          search,
          const SizedBox(height: 10),
          SizedBox(
            height: _kFilterChipHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: filters.length,
              separatorBuilder: (_, _) => const SizedBox(width: 7),
              itemBuilder: (_, i) => filters[i],
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(child: search),
        const SizedBox(width: 10),
        ...[
          for (final f in filters) ...[f, const SizedBox(width: 8)],
        ],
      ],
    );
  }

  // ── Tabla escritorio: matriz insumo × bodega ────────────────────────────

  Widget _desktopTable(
    List<InventoryItemSummary> items,
    BusinessCurrency currency, {
    required bool canAdjust,
    required bool canEdit,
  }) {
    final minWidth =
        _kColName +
        _kColCost +
        _kColWarehouse * _warehouses.length +
        _kColTotal +
        _kColActions;

    return LayoutBuilder(
      builder: (context, constraints) {
        final overflows = constraints.maxWidth < minWidth;
        final width = overflows ? minWidth : constraints.maxWidth;

        // El sobrante lo toman PRIMERO las columnas de bodega (hasta su
        // techo) y recién después el nombre, que es quien absorbe el resto
        // vía `Expanded`. Así las cantidades no quedan apretadas contra el
        // borde derecho mientras el nombre nada en blanco.
        var colWarehouse = _kColWarehouse;
        if (!overflows && _warehouses.isNotEmpty) {
          final slack = width - minWidth;
          colWarehouse += (slack / _warehouses.length).clamp(
            0.0,
            _kColWarehouseMax - _kColWarehouse,
          );
        }

        final table = SizedBox(
          width: width,
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: AppColors.border),
              boxShadow: AppShadows.soft,
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _tableHeader(colWarehouse),
                for (final item in items) ...[
                  _tableRow(
                    item,
                    currency,
                    colWarehouse: colWarehouse,
                    canAdjust: canAdjust,
                    canEdit: canEdit,
                  ),
                  if (_expandedItemId == item.id)
                    _distributionPanel(item, canAdjust: canAdjust),
                ],
                _tableFooter(items, currency),
              ],
            ),
          ),
        );
        return overflows
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: table,
              )
            : table;
      },
    );
  }

  Widget _tableHeader(double colWarehouse) {
    final scope = _scopeId;
    Widget head(String text, {TextAlign align = TextAlign.left, Color? color}) =>
        Text(
          text,
          textAlign: align,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
            color: color ?? AppColors.mutedForeground,
          ),
        );

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: head('INSUMO')),
          SizedBox(width: _kColCost, child: head('COSTO')),
          for (var i = 0; i < _warehouses.length; i++)
            Container(
              width: colWarehouse,
              padding: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                border: _columnSeparator(i),
              ),
              child: head(
                _warehouses[i].name.toUpperCase(),
                align: TextAlign.right,
                color: scope == _warehouses[i].id
                    ? AppColors.primary
                    : AppColors.mutedForeground,
              ),
            ),
          SizedBox(
            width: _kColTotal,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: head(
                'TOTAL · MÍNIMO',
                align: TextAlign.right,
                color: AppColors.foreground,
              ),
            ),
          ),
          const SizedBox(width: _kColActions),
        ],
      ),
    );
  }

  /// Separadores verticales que agrupan la lectura: la bodega principal
  /// queda a un lado y el bloque de totales al otro.
  Border? _columnSeparator(int index) {
    final isFirst = index == 0;
    final isLast = index == _warehouses.length - 1;
    if (!isFirst && !isLast) return null;
    return Border(right: BorderSide(color: AppColors.border));
  }

  Widget _tableRow(
    InventoryItemSummary item,
    BusinessCurrency currency, {
    required double colWarehouse,
    required bool canAdjust,
    required bool canEdit,
  }) {
    final scope = _scopeId;
    final level = item.lowStockLevel;
    final rail = switch (level) {
      'out_of_stock' || 'critical' => AppColors.destructive,
      'low' => AppColors.warning,
      _ => Colors.transparent,
    };
    final rowBg = switch (level) {
      'out_of_stock' || 'critical' => AppColors.destructive.withValues(
        alpha: 0.035,
      ),
      'low' => AppColors.warning.withValues(alpha: 0.04),
      _ => item.isActive ? AppColors.card : AppColors.background,
    };
    final expanded = _expandedItemId == item.id;

    return Material(
      color: rowBg,
      child: InkWell(
        onTap: () => _toggleExpanded(item),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 11, 18, 11),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: expanded ? AppColors.border : AppColors.muted,
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(child: _nameCell(item, rail: rail, expanded: expanded)),
              SizedBox(width: _kColCost, child: _costCell(item, currency)),
              for (var i = 0; i < _warehouses.length; i++)
                Container(
                  width: colWarehouse,
                  decoration: BoxDecoration(border: _columnSeparator(i)),
                  child: _warehouseCell(
                    item,
                    _warehouses[i],
                    highlighted: scope == _warehouses[i].id,
                    canAdjust: canAdjust,
                  ),
                ),
              SizedBox(width: _kColTotal, child: _totalCell(item)),
              SizedBox(
                width: _kColActions,
                child: _rowActions(item, canAdjust: canAdjust, canEdit: canEdit),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nameCell(
    InventoryItemSummary item, {
    required Color rail,
    required bool expanded,
  }) {
    final meta = <String>[
      if (item.sku.isNotEmpty) item.sku,
      item.unit,
      item.costingMethod == 'fifo' ? 'FIFO' : 'promedio',
    ];
    return Row(
      children: [
        Container(
          width: 3,
          height: 34,
          decoration: BoxDecoration(
            color: rail,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Icon(
          expanded ? Icons.expand_less : Icons.expand_more,
          size: 18,
          color: AppColors.mutedForeground,
        ),
        const SizedBox(width: 6),
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
                        color: item.isActive
                            ? AppColors.foreground
                            : AppColors.mutedForeground,
                      ),
                    ),
                  ),
                  if (!item.isActive) ...[
                    const SizedBox(width: 7),
                    _Pill(
                      text: 'INACTIVO',
                      color: AppColors.mutedForeground,
                    ),
                  ] else if (item.itemClassification != 'simple') ...[
                    const SizedBox(width: 7),
                    _ClassificationChip(value: item.itemClassification),
                  ],
                  if (item.tracksLots) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.inventory_rounded,
                      size: 13,
                      color: AppColors.mutedForeground,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                meta.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.mutedForeground,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _costCell(InventoryItemSummary item, BusinessCurrency currency) {
    final packed = hasPack(
      item.packSize,
      item.purchaseUnit,
      baseUnit: item.unit,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          currency.formatAmount(item.cost),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.foreground,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Text(
          packed
              ? '${currency.formatAmount(item.cost * item.packSize)} / '
                    '${item.purchaseUnit}'
              : 'por ${item.unit}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10, color: AppColors.mutedForeground),
        ),
      ],
    );
  }

  /// La celda ES el disparador del ajuste: al tocarla, el diálogo abre con
  /// esta bodega cargada. Ese es el corazón de la pantalla.
  Widget _warehouseCell(
    InventoryItemSummary item,
    InventoryWarehouse warehouse, {
    required bool highlighted,
    required bool canAdjust,
  }) {
    final qty = _matrix.quantityOf(item.id, warehouse.id);
    final present = _matrix.hasStockRow(item.id, warehouse.id);
    final fmt = NumberFormat.decimalPattern('es_DO');
    final zero = qty == 0;

    return Tooltip(
      message: canAdjust
          ? 'Ajustar ${item.name} en ${warehouse.name}'
          : '${warehouse.name}: ${fmt.format(qty)} ${item.unit}',
      waitDuration: const Duration(milliseconds: 600),
      child: Material(
        color: highlighted
            ? AppColors.primary.withValues(alpha: 0.07)
            : Colors.transparent,
        child: InkWell(
          onTap: canAdjust
              ? () => _openAdjust(item, warehouseId: warehouse.id)
              : null,
          child: Container(
            padding: const EdgeInsets.fromLTRB(6, 10, 12, 10),
            alignment: Alignment.centerRight,
            child: Text(
              present ? fmt.format(qty) : '—',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: zero ? FontWeight.w500 : FontWeight.w600,
                color: zero
                    ? AppColors.mutedForeground.withValues(alpha: 0.55)
                    : AppColors.foreground,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _totalCell(InventoryItemSummary item) {
    final fmt = NumberFormat.decimalPattern('es_DO');
    final level = item.lowStockLevel;
    final color = switch (level) {
      'out_of_stock' || 'critical' => AppColors.destructive,
      'low' => AppColors.warning,
      _ => item.isActive ? AppColors.foreground : AppColors.mutedForeground,
    };

    // Escala de la barra: el máximo configurado si existe; si no, el doble
    // del mínimo (para que el mínimo caiga a media barra y se lea de un
    // vistazo si estamos por encima o por debajo).
    //
    // Sin mínimo NI máximo no hay contra qué medir, y entonces NO hay barra.
    // Antes se caía al propio stock como escala, lo que pintaba una barra
    // siempre llena: en un negocio sin mínimos configurados la tabla salía
    // con un trazo negro macizo bajo cada total que no decía nada y se leía
    // como un error de render.
    final double? scale = () {
      final max = item.maxStock;
      if (max != null && max > 0) return max;
      if (item.minStock > 0) return item.minStock * 2;
      return null;
    }();
    final fill = scale == null
        ? null
        : (item.stock / scale).clamp(0.0, 1.0);
    final minMark = (scale == null || item.minStock <= 0)
        ? null
        : (item.minStock / scale).clamp(0.0, 1.0);

    final packed = hasPack(
      item.packSize,
      item.purchaseUnit,
      baseUnit: item.unit,
    );
    final shortfall = item.shortfall;
    final String minLabel;
    if (item.minStock <= 0) {
      minLabel = 'sin mínimo';
    } else if (shortfall > 0) {
      final packs = packed
          ? ' · ${_fmtNum(baseToPack(shortfall, item.packSize))} '
                '${item.purchaseUnit}'
          : '';
      minLabel = 'faltan ${fmt.format(shortfall)}$packs';
    } else {
      minLabel = 'mín ${fmt.format(item.minStock)} ${item.unit}';
    }

    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  fmt.format(item.stock),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: color,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                item.unit,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
          if (fill != null) ...[
            const SizedBox(height: 4),
            _StockBar(fill: fill, minMark: minMark, color: color),
          ],
          const SizedBox(height: 3),
          Text(
            minLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              fontWeight: shortfall > 0 ? FontWeight.w800 : FontWeight.w500,
              color: shortfall > 0 ? color : AppColors.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }

  Widget _rowActions(
    InventoryItemSummary item, {
    required bool canAdjust,
    required bool canEdit,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        // `Flexible` + ellipsis: el ancho de "Ajustar" depende de la fuente y
        // de la escala de texto del sistema. Con el botón rígido, una escala
        // alta lo desbordaba de la columna y salían las franjas amarillas.
        // Así, en el peor caso se recorta la etiqueta en vez de romper la
        // fila —el ícono y el menú siguen accesibles.
        if (canAdjust)
          Flexible(
            child: OutlinedButton.icon(
              onPressed: () => _openAdjust(item),
              icon: const Icon(Icons.tune, size: 15),
              label: const Text(
                'Ajustar',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.foreground,
                side: BorderSide(color: AppColors.border),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        const SizedBox(width: 4),
        SizedBox(
          width: _kRowMenuWidth,
          child: _rowMenu(item, canEdit: canEdit),
        ),
      ],
    );
  }

  Widget _rowMenu(InventoryItemSummary item, {required bool canEdit}) {
    return PopupMenuButton<String>(
      tooltip: 'Más acciones',
      icon: Icon(Icons.more_vert, size: 19, color: AppColors.mutedForeground),
      padding: EdgeInsets.zero,
      onSelected: (value) {
        switch (value) {
          case 'edit':
            _openForm(edit: item);
          case 'kardex':
            _openKardex(item, warehouseId: _scopeId);
          case 'transfer':
            _openTransfer();
          case 'toggle':
            _toggleActive(item);
          case 'delete':
            _confirmDelete(item);
        }
      },
      itemBuilder: (_) => [
        if (canEdit)
          const PopupMenuItem(
            value: 'edit',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.edit_outlined, size: 18),
              title: Text('Editar ficha'),
            ),
          ),
        const PopupMenuItem(
          value: 'kardex',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.receipt_long_outlined, size: 18),
            title: Text('Ver kardex'),
          ),
        ),
        const PopupMenuItem(
          value: 'transfer',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.swap_horiz, size: 18),
            title: Text('Transferir'),
          ),
        ),
        if (canEdit) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'toggle',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                item.isActive
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 18,
              ),
              title: Text(item.isActive ? 'Desactivar' : 'Activar'),
            ),
          ),
          PopupMenuItem(
            value: 'delete',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.delete_outline,
                size: 18,
                color: AppColors.destructive,
              ),
              title: Text(
                'Eliminar',
                style: TextStyle(color: AppColors.destructive),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _tableFooter(
    List<InventoryItemSummary> items,
    BusinessCurrency currency,
  ) {
    final scope = _scopeId;
    final low = items.where((i) => i.isLowStock).length;
    final inactive = items.where((i) => !i.isActive).length;
    // El valor sigue al contexto: en "Todas" es el del negocio; dentro de
    // una bodega, el de esa bodega. Un total que no responde al filtro es
    // un número que nadie puede cuadrar.
    final value = items.fold<double>(0, (acc, item) {
      final qty = scope == null
          ? item.stock
          : _matrix.quantityOf(item.id, scope);
      return acc + qty * item.cost;
    });
    final scopeName = scope == null
        ? null
        : _warehouses
              .firstWhere(
                (w) => w.id == scope,
                orElse: () => const InventoryWarehouse(
                  id: '',
                  name: 'bodega',
                  isMain: false,
                ),
              )
              .name;

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 13, 18, 13),
      color: AppColors.background,
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.mutedForeground,
                ),
                children: [
                  TextSpan(
                    text: '${items.length} '
                        '${items.length == 1 ? 'insumo' : 'insumos'}',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppColors.foreground,
                    ),
                  ),
                  if (low > 0) TextSpan(text: ' · $low bajo mínimo'),
                  if (inactive > 0) TextSpan(text: ' · $inactive inactivo'),
                ],
              ),
            ),
          ),
          Text(
            scopeName == null
                ? 'Valor de existencias'
                : 'Valor en $scopeName',
            style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
          ),
          const SizedBox(width: 10),
          Text(
            currency.formatAmount(value),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: AppColors.foreground,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  // ── Panel de distribución (fila expandida) ──────────────────────────────

  Widget _distributionPanel(
    InventoryItemSummary item, {
    required bool canAdjust,
  }) {
    final fmt = NumberFormat.decimalPattern('es_DO');
    final movements = _lastMovements[item.id];
    final packed = hasPack(
      item.packSize,
      item.purchaseUnit,
      baseUnit: item.unit,
    );
    final shortfall = item.shortfall;

    final summary = item.minStock <= 0
        ? '${fmt.format(item.stock)} ${item.unit} en total · sin mínimo '
              'configurado'
        : shortfall > 0
        ? '${fmt.format(item.stock)} de ${fmt.format(item.minStock)} '
              '${item.unit} mínimos · faltan ${fmt.format(shortfall)}'
              '${packed ? ' (${_fmtNum(baseToPack(shortfall, item.packSize))} '
                    '${item.purchaseUnit})' : ''}'
        : '${fmt.format(item.stock)} ${item.unit} · por encima del mínimo '
              'de ${fmt.format(item.minStock)}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(34, 16, 18, 18),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.warehouse_outlined,
                size: 18,
                color: AppColors.primary,
              ),
              const SizedBox(width: 9),
              Text(
                'Distribución de ${item.name}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ),
              if (_loadingMovements && movements == null) ...[
                const SizedBox(width: 10),
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (var i = 0; i < _warehouses.length; i++)
                SizedBox(
                  width: 232,
                  child: _distributionCard(
                    item,
                    _warehouses[i],
                    dot: _dotColor(i),
                    last: movements?[_warehouses[i].id],
                    canAdjust: canAdjust,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _distributionCard(
    InventoryItemSummary item,
    InventoryWarehouse warehouse, {
    required Color dot,
    required KardexMovement? last,
    required bool canAdjust,
  }) {
    final fmt = NumberFormat.decimalPattern('es_DO');
    final qty = _matrix.quantityOf(item.id, warehouse.id);
    final present = _matrix.hasStockRow(item.id, warehouse.id);
    final zero = qty == 0;
    final packed = hasPack(
      item.packSize,
      item.purchaseUnit,
      baseUnit: item.unit,
    );
    final packs = !packed
        ? item.unit
        : zero
        ? 'sin existencia'
        : '${_fmtNum(baseToPack(qty, item.packSize))} ${item.purchaseUnit}';
    final isScope = _scopeId == warehouse.id;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: isScope ? AppColors.primary : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  warehouse.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
              ),
              if (warehouse.isMain)
                Text(
                  'principal',
                  style: TextStyle(
                    fontSize: 10,
                    color: AppColors.mutedForeground,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 9),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                present ? fmt.format(qty) : '0',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: zero
                      ? AppColors.mutedForeground.withValues(alpha: 0.55)
                      : AppColors.foreground,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  packed ? '${item.unit} · $packs' : item.unit,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _lastMovementLabel(last, present: present),
            maxLines: 2,
            style: TextStyle(
              fontSize: 11,
              height: 1.45,
              color: AppColors.mutedForeground,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: canAdjust
                    ? (isScope
                          ? FilledButton(
                              onPressed: () => _openAdjust(
                                item,
                                warehouseId: warehouse.id,
                              ),
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              child: const Text('Ajustar aquí'),
                            )
                          : OutlinedButton(
                              onPressed: () => _openAdjust(
                                item,
                                warehouseId: warehouse.id,
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.foreground,
                                side: BorderSide(color: AppColors.border),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              child: const Text('Ajustar aquí'),
                            ))
                    : const SizedBox.shrink(),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: 'Kardex de ${warehouse.name}',
                onPressed: () => _openKardex(item, warehouseId: warehouse.id),
                icon: Icon(
                  Icons.receipt_long_outlined,
                  size: 17,
                  color: AppColors.mutedForeground,
                ),
                style: IconButton.styleFrom(
                  side: BorderSide(color: AppColors.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  minimumSize: const Size(34, 34),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _lastMovementLabel(KardexMovement? last, {required bool present}) {
    if (last == null) {
      return present
          ? 'Sin movimientos recientes acá'
          : 'Nunca tuvo este insumo';
    }
    final fmt = NumberFormat.decimalPattern('es_DO');
    final when = last.createdAt;
    final ago = when == null ? '' : ' ${_relativeDay(when)}';
    final signed =
        (last.quantity > 0 ? '+' : '') + fmt.format(last.quantity);
    return '${_movementLabel(last.movementType)}$ago · $signed';
  }

  static String _relativeDay(DateTime when) {
    final days = DateTime.now().difference(when).inDays;
    if (days <= 0) return 'hoy';
    if (days == 1) return 'ayer';
    if (days < 30) return 'hace $days días';
    final months = (days / 30).floor();
    return months == 1 ? 'hace un mes' : 'hace $months meses';
  }

  static String _movementLabel(String type) => switch (type) {
    'purchase' => 'Compra',
    'sale' => 'Venta',
    'adjustment' => 'Ajuste',
    'transfer_in' => 'Entrada de traslado',
    'transfer_out' => 'Salida de traslado',
    'waste' => 'Merma',
    'breakage' => 'Rotura',
    'theft' => 'Faltante',
    'expiration' => 'Vencimiento',
    'donation' => 'Donación',
    'return' || 'return_from_customer' => 'Devolución',
    'return_to_supplier' => 'Devolución a proveedor',
    _ => 'Movimiento',
  };

  // ── Móvil: piso de bodega ───────────────────────────────────────────────

  Widget _mobileList(
    List<InventoryItemSummary> items,
    BusinessCurrency currency, {
    required bool canAdjust,
    required bool canEdit,
  }) {
    final scope = _scopeId;
    final scopeName = scope == null ? null : _warehouseNameOf(scope);
    final label = _onlyLowStock
        ? 'BAJO MÍNIMO${scopeName == null ? '' : ' · $scopeName'} · '
              '${items.length}'
        : '${items.length} '
              '${items.length == 1 ? 'INSUMO' : 'INSUMOS'}'
              '${scopeName == null ? '' : ' EN ${scopeName.toUpperCase()}'}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (canAdjust) ...[
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              onPressed: () {
                _searchFocus.requestFocus();
                AppToast.info(
                  context,
                  'Dispará el lector: el insumo se abre para contar.',
                );
              },
              icon: const Icon(Icons.qr_code_scanner, size: 20),
              label: const Text(
                'Escanear para contar',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
            color: AppColors.mutedForeground,
          ),
        ),
        const SizedBox(height: 8),
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _mobileCard(
              item,
              canAdjust: canAdjust,
              canEdit: canEdit,
            ),
          ),
      ],
    );
  }

  String _warehouseNameOf(String id) {
    for (final w in _warehouses) {
      if (w.id == id) return w.name;
    }
    return 'Bodega';
  }

  Widget _mobileCard(
    InventoryItemSummary item, {
    required bool canAdjust,
    required bool canEdit,
  }) {
    final fmt = NumberFormat.decimalPattern('es_DO');
    final scope = _scopeId;
    final qty = scope == null
        ? item.stock
        : _matrix.quantityOf(item.id, scope);
    final level = item.lowStockLevel;
    final accent = switch (level) {
      'out_of_stock' || 'critical' => AppColors.destructive,
      'low' => AppColors.warning,
      _ => AppColors.foreground,
    };
    final borderColor = level == null
        ? AppColors.border
        : accent.withValues(alpha: 0.45);

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: borderColor),
        boxShadow: AppShadows.soft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        height: 1.25,
                        color: item.isActive
                            ? AppColors.foreground
                            : AppColors.mutedForeground,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (item.sku.isNotEmpty) item.sku,
                        item.unit,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.mutedForeground,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    fmt.format(qty),
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: accent,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    scope == null ? '${item.unit} en total' : '${item.unit} acá',
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.inventory_outlined,
                  size: 15,
                  color: AppColors.mutedForeground,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _elsewhereLabel(item, scope),
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.4,
                      color: AppColors.foreground,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (canAdjust)
                Expanded(
                  child: SizedBox(
                    height: 46,
                    child: FilledButton(
                      onPressed: () =>
                          _openAdjust(item, reasonCode: 'physical_count'),
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                      ),
                      child: const Text(
                        'Contar',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                )
              else
                const Spacer(),
              const SizedBox(width: 8),
              _MobileSquareButton(
                icon: Icons.swap_horiz,
                tooltip: 'Transferir',
                onTap: _openTransfer,
              ),
              const SizedBox(width: 8),
              _MobileSquareButton(
                icon: Icons.more_horiz,
                tooltip: 'Más acciones',
                child: _rowMenu(item, canEdit: canEdit),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// "Dónde más está" — el dato que el móvil no puede mostrar en columnas.
  String _elsewhereLabel(InventoryItemSummary item, String? scope) {
    final fmt = NumberFormat.decimalPattern('es_DO');
    final parts = <String>[];
    for (final w in _warehouses) {
      if (w.id == scope) continue;
      final qty = _matrix.quantityOf(item.id, w.id);
      if (qty <= 0) continue;
      parts.add('${fmt.format(qty)} ${item.unit} en ${w.name}');
    }
    final total = item.minStock > 0
        ? 'total ${fmt.format(item.stock)} de ${fmt.format(item.minStock)} '
              '${item.unit} mínimos'
        : 'total ${fmt.format(item.stock)} ${item.unit}';
    if (parts.isEmpty) {
      return scope == null
          ? (item.stock > 0
                ? total
                : 'Sin existencia en ninguna bodega · $total')
          : 'Solo hay en esta bodega · $total';
    }
    return '${parts.take(2).join(' · ')} · $total';
  }
}

/// Recorta decimales sobrantes: 6 → "6", 6.20 → "6.2", 6.27 → "6.27".
String _fmtNum(double value) {
  if (value == value.roundToDouble() && value.abs() < 1e12) {
    return value.toStringAsFixed(0);
  }
  final s = value.toStringAsFixed(2);
  return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

// ── Piezas visuales ───────────────────────────────────────────────────────

/// Chip de la barra de contexto de bodega.
class _ScopeChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color? dot;
  final String? trailing;
  final bool selected;
  final VoidCallback onTap;

  const _ScopeChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.dot,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : AppColors.foreground;
    return Material(
      color: selected ? AppColors.foreground : AppColors.background,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.full),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? AppColors.foreground : AppColors.border,
            ),
            borderRadius: BorderRadius.circular(AppRadius.full),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: fg),
                const SizedBox(width: 6),
              ] else if (dot != null) ...[
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 7),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: fg,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 7),
                Text(
                  trailing!,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: selected
                        ? Colors.white70
                        : AppColors.mutedForeground,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Filtro booleano con contador (ej. "Bajo mínimo · 2").
class _FilterChip extends StatelessWidget {
  final String label;
  final String? count;
  final bool active;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.active,
    required this.onTap,
    this.count,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active ? const Color(0xFFC2410C) : AppColors.foreground;
    return Material(
      color: active
          ? AppColors.primary.withValues(alpha: 0.10)
          : AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Container(
          height: _kFilterChipHeight,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            border: Border.all(
              color: active
                  ? AppColors.primary.withValues(alpha: 0.45)
                  : AppColors.border,
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
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: 6),
                Container(
                  constraints: const BoxConstraints(minWidth: 18),
                  height: 18,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: active ? const Color(0xFFC2410C) : AppColors.primary,
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                  child: Text(
                    count!,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
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
}

/// Filtro de opciones. `T` no puede ser nullable: `PopupMenuButton` trata el
/// `null` devuelto por el menú como "cancelado". Para el caso "todos" se usa
/// el sentinel `''`.
class _FilterMenu<T extends Object> extends StatelessWidget {
  final String label;
  final T? value;
  final bool active;
  final List<(T, String)> options;
  final ValueChanged<T> onSelected;

  const _FilterMenu({
    required this.label,
    required this.value,
    required this.active,
    required this.options,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    String current = label;
    for (final option in options) {
      if (option.$1 == value) current = option.$2;
    }
    return PopupMenuButton<T>(
      tooltip: label,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final option in options)
          PopupMenuItem<T>(
            value: option.$1,
            child: Row(
              children: [
                Icon(
                  option.$1 == value
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 16,
                  color: option.$1 == value
                      ? AppColors.primary
                      : AppColors.mutedForeground,
                ),
                const SizedBox(width: 8),
                Text(option.$2),
              ],
            ),
          ),
      ],
      child: Container(
        height: _kFilterChipHeight,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: active
              ? AppColors.primary.withValues(alpha: 0.10)
              : AppColors.card,
          border: Border.all(
            color: active
                ? AppColors.primary.withValues(alpha: 0.45)
                : AppColors.border,
          ),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              active ? current : label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: active
                    ? const Color(0xFFC2410C)
                    : AppColors.foreground,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.expand_more,
              size: 17,
              color: AppColors.mutedForeground,
            ),
          ],
        ),
      ),
    );
  }
}

/// Barra de existencias con la marca del mínimo. La marca es la lectura
/// clave: dice si el relleno llega o no llega a donde tiene que llegar.
class _StockBar extends StatelessWidget {
  final double fill;
  final double? minMark;
  final Color color;

  const _StockBar({
    required this.fill,
    required this.minMark,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 92,
      height: 8,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return Stack(
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
                    color: color,
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                ),
              ),
              if (minMark != null)
                Positioned(
                  top: 0,
                  left: (width * minMark!).clamp(0.0, width - 2),
                  child: Container(
                    width: 2,
                    height: 8,
                    color: AppColors.foreground,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Botón cuadrado secundario de las cards móviles (44px+ de lado: se toca
/// con el pulgar y con guantes de cocina).
class _MobileSquareButton extends StatelessWidget {
  final IconData? icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Widget? child;

  const _MobileSquareButton({
    required this.tooltip,
    this.icon,
    this.onTap,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 46,
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: child != null
          ? Center(child: child)
          : IconButton(
              tooltip: tooltip,
              onPressed: onTap,
              icon: Icon(icon, size: 20, color: AppColors.foreground),
            ),
    );
  }
}

class _ClassificationChip extends StatelessWidget {
  final String value;
  const _ClassificationChip({required this.value});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (value) {
      'raw_material' => ('MATERIA PRIMA', AppColors.info),
      'finished_product' => ('TERMINADO', AppColors.success),
      'combo' => ('COMBO', AppColors.primary),
      'service' => ('SERVICIO', AppColors.mutedForeground),
      _ => ('SIMPLE', AppColors.mutedForeground),
    };
    return _Pill(text: label, color: color);
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  const _Pill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}
