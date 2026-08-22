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
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../app/widgets/skeleton_loading.dart';
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
import 'item_adjust_dialog.dart';
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

/// Formateador de cantidades COMPARTIDO. `NumberFormat.decimalPattern`
/// parsea el patrón del locale en cada construcción, y esta pantalla lo
/// pedía dentro de métodos por celda: con una fila por insumo y una columna
/// por bodega eran cientos de construcciones en cada frame.
final NumberFormat _fmtQty = NumberFormat.decimalPattern('es_DO');

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

  /// Pintamos la copia local y la lectura fresca sigue en vuelo.
  ///
  /// Es DISTINTO de `_matrix.fromCache`, que solo dice de dónde salieron los
  /// datos. Con este flag arriba la matriz viene del caché pero estamos
  /// online: no corresponde el cartel de "sin conexión", sino la barrita de
  /// progreso. Sin separarlos, un arranque normal gritaba que no había red.
  bool _awaitingFresh = false;
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
      _businessId = businessId;

      // Cache-first: si hay copia local se pinta YA y la red queda de
      // refresco. SharedPreferences resuelve en memoria, así que esto no
      // agrega latencia cuando no hay nada guardado.
      await _primeFromCache(businessId);

      final warehouses = await _repo.getWarehouses(businessId);
      final visible = warehouses
          .where((w) => w.name != '__IN_TRANSIT__')
          .toList(growable: false);
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

  /// Pinta la última copia local para no dejar la pantalla en esqueleto
  /// mientras responde la red. No toca `_error`: si algo falla acá, el
  /// arranque normal sigue su curso y manda lo que diga el servidor.
  Future<void> _primeFromCache(String businessId) async {
    try {
      final cached = await _repo.getCachedWarehouses(businessId);
      if (cached == null) return;
      final visible = cached
          .where((w) => w.name != '__IN_TRANSIT__')
          .toList(growable: false);
      if (visible.isEmpty) return;

      final matrix = await _repo.getCachedItemsMatrix(
        businessId: businessId,
        warehouseIds: visible.map((w) => w.id).toList(growable: false),
      );
      if (matrix == null || matrix.items.isEmpty || !mounted) return;

      await ref
          .read(inventoryWarehouseScopeProvider.notifier)
          .ensureRestored(businessId, validIds: visible.map((w) => w.id));
      if (!mounted) return;

      setState(() {
        _warehouses = visible;
        _matrix = matrix;
        _loading = false;
        _awaitingFresh = true;
      });
    } catch (e) {
      // El caché es un atajo, no una fuente de verdad: si falla, se sigue.
      debugPrint('[insumos] no se pudo pintar desde caché: $e');
    }
  }

  Future<void> _load() async {
    final businessId = _businessId;
    if (businessId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      // Sin `query`: se trae el maestro COMPLETO una vez y el texto se
      // filtra en memoria. El repositorio filtraba client-side de todos
      // modos, así que la ida a red por tecla no traía ni una fila distinta
      // y sí costaba dos consultas más una serialización del snapshot
      // offline por bodega.
      final matrix = await _repo.getItemsMatrix(
        businessId: businessId,
        warehouseIds: _warehouseIds,
      );
      if (!mounted) return;
      setState(() {
        _matrix = matrix;
        _loading = false;
        _refreshing = false;
        _awaitingFresh = false;
        _error = null;
        _lastMovements.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _awaitingFresh = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await _load();
  }

  void _onSearchChanged(String value) {
    // 120 ms y no 300: ya no espera una respuesta de red, solo coalesce
    // pulsaciones para no reconstruir la tabla en cada tecla.
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      setState(() => _query = value.trim());
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
    setState(() => _query = normalized);

    var hits = _visibleItems();
    // Si no aparece en memoria puede ser un insumo dado de alta en otra
    // terminal después de nuestra última lectura: SOLO en ese caso vale la
    // pena ir a red, y así el escaneo normal resuelve sin esperar nada.
    if (hits.isEmpty) {
      await _refresh();
      if (!mounted) return;
      hits = _visibleItems();
    }
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

  /// Predicado ÚNICO de la tabla: texto, filtros de la toolbar y contexto de
  /// bodega. Todo se resuelve en memoria sobre la matriz ya cargada.
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
    if (_query.isNotEmpty && !_matchesQuery(item, _query.toLowerCase())) {
      return false;
    }
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

  /// Mismo criterio que aplicaba el repositorio. El código de barras entra
  /// porque la barra de búsqueda acepta el disparo de la pistola.
  static bool _matchesQuery(InventoryItemSummary item, String lower) =>
      item.name.toLowerCase().contains(lower) ||
      item.sku.toLowerCase().contains(lower) ||
      item.description.toLowerCase().contains(lower) ||
      item.barcode.toLowerCase().contains(lower);

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
      builder: (_) =>
          ItemFormDialog(businessId: businessId, repo: _repo, edit: edit),
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

    // El esqueleto NO reemplaza la pantalla entera: el encabezado, la barra
    // de bodega y la toolbar no dependen de la matriz, así que se pintan de
    // una y solo el contenido de la tabla espera. Antes toda la vista era un
    // spinner centrado y la pantalla aparecía de golpe al final.
    final showSkeleton = _loading && _matrix.items.isEmpty;

    Widget body;
    if (_error != null && _matrix.items.isEmpty) {
      body = _errorState();
    } else {
      // `CustomScrollView` y no `SingleChildScrollView`: con la tabla dentro
      // de una `Column` se construían TODAS las filas en cada `setState`, y
      // eso crecía linealmente con el catálogo (~0.3 ms por fila medidos).
      // Con `SliverList.builder` solo se construyen las que entran en
      // pantalla, así que el costo de un click deja de depender de cuántos
      // insumos tenga el negocio.
      final pad = isCompact ? 14.0 : 24.0;
      body = LayoutBuilder(
        builder: (context, constraints) {
          // La tabla necesita un ancho mínimo; si no entra, sigue el camino
          // viejo con scroll horizontal (ver `_desktopTable`). Ese caso no
          // puede ser sliver: un sliver no vive dentro de un scroll
          // horizontal, y meter TODA la página en uno haría que el buscador
          // y los filtros también se desplacen de lado.
          final tableMinWidth =
              _kColName +
              _kColCost +
              _kColWarehouse * _warehouses.length +
              _kColTotal +
              _kColActions;
          final tableOverflows =
              !isCompact && (constraints.maxWidth - pad * 2) < tableMinWidth;

          return RefreshIndicator(
            color: AppColors.primary,
            onRefresh: _refresh,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    pad,
                    isCompact ? 12 : 24,
                    pad,
                    0,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _header(
                          isCompact: isCompact,
                          isNarrow: isNarrow,
                          canCreate: canEditItems,
                          busy: showSkeleton,
                        ),
                        SizedBox(height: isCompact ? 12 : 16),
                        // Las bodegas llegan ANTES que la matriz (son dos
                        // lecturas distintas), así que en cuanto se sabe
                        // cuáles son se pinta la barra de verdad aunque la
                        // tabla siga cargando.
                        if (_warehouses.isEmpty)
                          _scopeBarSkeleton(isCompact: isCompact)
                        else
                          _scopeBar(isCompact: isCompact, isNarrow: isNarrow),
                        SizedBox(height: isCompact ? 10 : 14),
                        _toolbar(stacked: isCompact || isNarrow),
                        // Solo cuando el caché es el resultado FINAL (la red
                        // falló). Con `_awaitingFresh` la copia local es un
                        // adelanto y el aviso correcto es la barra de
                        // progreso de arriba.
                        if (_matrix.fromCache && !_awaitingFresh) ...[
                          const SizedBox(height: 10),
                          _offlineBanner(),
                        ],
                        SizedBox(height: isCompact ? 12 : 16),
                      ],
                    ),
                  ),
                ),
                ..._contentSlivers(
                  items,
                  currency,
                  pad: pad,
                  contentWidth: constraints.maxWidth - pad * 2,
                  isCompact: isCompact,
                  showSkeleton: showSkeleton,
                  tableOverflows: tableOverflows,
                  canAdjust: canAdjust,
                  canEdit: canEditItems,
                ),
                SliverPadding(
                  padding: EdgeInsets.only(bottom: isCompact ? 28 : 24),
                ),
              ],
            ),
          );
        },
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
              if (_refreshing || _awaitingFresh)
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
                });
              },
              icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
              label: const Text('Limpiar filtros'),
            ),
          ],
        ],
      ),
    );
  }

  // ── Esqueletos de carga ─────────────────────────────────────────────────
  //
  // Todos usan `SkeletonBlock` dentro de UN solo `SkeletonShimmer`: la
  // animación se paga una vez para todo el subárbol en vez de una por pieza.
  // Y todos respetan la geometría de la vista real, que es la única razón
  // por la que un esqueleto sirve: al llegar los datos nada cambia de sitio.

  /// Anchos de nombre que varían por fila. Con todas las barras iguales el
  /// esqueleto se lee como una tabla vacía, no como algo cargando.
  static const List<double> _kSkeletonNameWidths = [
    190,
    148,
    224,
    172,
    202,
    138,
    214,
    160,
  ];

  Widget _scopeBarSkeleton({required bool isCompact}) {
    final pills = [
      for (var i = 0; i < 3; i++)
        SkeletonBlock(width: i == 0 ? 128 : 104, height: 34, borderRadius: 999),
    ];

    if (isCompact) {
      return SkeletonShimmer(
        child: SizedBox(
          height: 38,
          child: Row(
            children: [
              for (final pill in pills) ...[pill, const SizedBox(width: 7)],
            ],
          ),
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
      child: SkeletonShimmer(
        child: Row(
          children: [
            for (final pill in pills) ...[pill, const SizedBox(width: 7)],
          ],
        ),
      ),
    );
  }

  Widget _desktopTableSkeleton() {
    // Si todavía no sabemos cuántas bodegas hay, asumimos dos: es el caso
    // más común y evita que la tabla se reacomode cuando lleguen.
    final columns = _warehouses.isEmpty ? 2 : _warehouses.length;
    final minWidth =
        _kColName +
        _kColCost +
        _kColWarehouse * columns +
        _kColTotal +
        _kColActions;

    return LayoutBuilder(
      builder: (context, constraints) {
        final overflows = constraints.maxWidth < minWidth;
        final width = overflows ? minWidth : constraints.maxWidth;
        var colWarehouse = _kColWarehouse;
        if (!overflows) {
          colWarehouse += ((width - minWidth) / columns).clamp(
            0.0,
            _kColWarehouseMax - _kColWarehouse,
          );
        }

        return SizedBox(
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
                // El encabezado real cuando ya conocemos los nombres de las
                // bodegas: es texto estático y no tiene por qué parpadear.
                if (_warehouses.isEmpty)
                  _skeletonTableHeader(columns, colWarehouse)
                else
                  _tableHeader(colWarehouse),
                SkeletonShimmer(
                  child: Column(
                    children: [
                      for (var i = 0; i < 8; i++)
                        _skeletonTableRow(i, columns, colWarehouse),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _skeletonTableHeader(int columns, double colWarehouse) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
      // Redondeo propio: en el camino sliver el marco lo dibuja un
      // `DecoratedSliver`, que NO recorta a sus hijos. En el camino con
      // scroll horizontal el `Clip.antiAlias` del contenedor lo tapa igual,
      // así que sirve para los dos.
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.lg),
        ),
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: SkeletonShimmer(
        child: Row(
          children: [
            // `Align` no es decorativo: `Expanded` y `SizedBox(width:)`
            // imponen ancho TIGHT y el `width` del bloque se ignoraría,
            // pintando una barra que ocupa toda la columna.
            const Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: SkeletonBlock(width: 68, height: 10, borderRadius: 3),
              ),
            ),
            const SizedBox(
              width: _kColCost,
              child: Align(
                alignment: Alignment.centerLeft,
                child: SkeletonBlock(width: 48, height: 10, borderRadius: 3),
              ),
            ),
            for (var i = 0; i < columns; i++)
              SizedBox(
                width: colWarehouse,
                child: const Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: SkeletonBlock(
                      width: 62,
                      height: 10,
                      borderRadius: 3,
                    ),
                  ),
                ),
              ),
            const SizedBox(
              width: _kColTotal,
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: SkeletonBlock(width: 92, height: 10, borderRadius: 3),
                ),
              ),
            ),
            const SizedBox(width: _kColActions),
          ],
        ),
      ),
    );
  }

  Widget _skeletonTableRow(int index, int columns, double colWarehouse) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.muted)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SkeletonBlock(
                  width:
                      _kSkeletonNameWidths[index % _kSkeletonNameWidths.length],
                  height: 13,
                  borderRadius: 4,
                ),
                const SizedBox(height: 6),
                const SkeletonBlock(width: 116, height: 9, borderRadius: 4),
              ],
            ),
          ),
          const SizedBox(
            width: _kColCost,
            child: Align(
              alignment: Alignment.centerLeft,
              child: SkeletonBlock(width: 66, height: 12, borderRadius: 4),
            ),
          ),
          for (var i = 0; i < columns; i++)
            SizedBox(
              width: colWarehouse,
              child: const Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: SkeletonBlock(width: 42, height: 12, borderRadius: 4),
                ),
              ),
            ),
          const SizedBox(
            width: _kColTotal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: SkeletonBlock(width: 58, height: 14, borderRadius: 4),
                ),
                SizedBox(height: 6),
                Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: SkeletonBlock(width: 92, height: 8, borderRadius: 999),
                ),
              ],
            ),
          ),
          const SizedBox(
            width: _kColActions,
            child: Align(
              alignment: Alignment.centerRight,
              child: SkeletonBlock(width: 96, height: 28, borderRadius: 8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mobileListSkeleton() {
    return SkeletonShimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SkeletonBlock(width: 168, height: 46, borderRadius: 10),
          const SizedBox(height: 14),
          const SkeletonBlock(width: 132, height: 10, borderRadius: 3),
          const SizedBox(height: 8),
          for (var i = 0; i < 5; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _skeletonMobileCard(i),
            ),
        ],
      ),
    );
  }

  Widget _skeletonMobileCard(int index) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
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
                    SkeletonBlock(
                      width:
                          _kSkeletonNameWidths[index %
                              _kSkeletonNameWidths.length],
                      height: 14,
                      borderRadius: 4,
                    ),
                    const SizedBox(height: 6),
                    const SkeletonBlock(width: 104, height: 9, borderRadius: 4),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              const SkeletonBlock(width: 52, height: 22, borderRadius: 4),
            ],
          ),
          const SizedBox(height: 10),
          const SkeletonBlock(height: 34, borderRadius: 8),
          const SizedBox(height: 10),
          Row(
            children: const [
              Expanded(child: SkeletonBlock(height: 46, borderRadius: 8)),
              SizedBox(width: 8),
              SkeletonBlock(width: 52, height: 46, borderRadius: 8),
            ],
          ),
        ],
      ),
    );
  }

  // ── Header ──────────────────────────────────────────────────────────────

  Widget _header({
    required bool isCompact,
    required bool isNarrow,
    required bool canCreate,
    required bool busy,
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
                  // Deshabilitado y no oculto: si desapareciera mientras
                  // carga, el encabezado saltaría al llegar los datos —
                  // justo lo que un esqueleto viene a evitar.
                  onPressed: busy ? null : () => _openForm(),
                  icon: Icon(Icons.add_circle, color: AppColors.primary),
                ),
            ],
          ),
        ],
      );
    }

    // Sin atajos a Transferencias ni al Kardex: los dos tienen su propia
    // pantalla en el hub y tener dos caminos para lo mismo confunde más de lo
    // que ahorra. Acá queda el maestro del insumo y el ajuste por celda.
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canCreate) ...[
          FilledButton.icon(
            onPressed: busy ? null : () => _openForm(),
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
          Expanded(child: Wrap(spacing: 7, runSpacing: 7, children: chips)),
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
                  setState(() => _query = '');
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

  // ── Contenido como slivers ──────────────────────────────────────────────

  /// El contenido de la página. Es lo único que se construye perezosamente:
  /// el encabezado, la barra de bodega y la toolbar son piezas únicas y van
  /// en un `SliverToBoxAdapter` arriba.
  List<Widget> _contentSlivers(
    List<InventoryItemSummary> items,
    BusinessCurrency currency, {
    required double pad,
    required double contentWidth,
    required bool isCompact,
    required bool showSkeleton,
    required bool tableOverflows,
    required bool canAdjust,
    required bool canEdit,
  }) {
    Widget boxed(Widget child) => SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: pad),
      sliver: SliverToBoxAdapter(child: child),
    );

    if (showSkeleton) {
      return [
        boxed(isCompact ? _mobileListSkeleton() : _desktopTableSkeleton()),
      ];
    }
    if (items.isEmpty) return [boxed(_emptyState())];

    if (isCompact) {
      return [
        boxed(_mobileListHeader(items, canAdjust: canAdjust)),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: pad),
          sliver: SliverList.builder(
            itemCount: items.length,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _mobileCard(
                items[index],
                canAdjust: canAdjust,
                canEdit: canEdit,
              ),
            ),
          ),
        ),
      ];
    }

    if (tableOverflows) {
      // Único camino NO perezoso que queda: la tabla completa dentro de un
      // scroll horizontal. Un sliver no puede vivir ahí dentro.
      return [
        boxed(
          _desktopTable(
            items,
            currency,
            canAdjust: canAdjust,
            canEdit: canEdit,
          ),
        ),
      ];
    }

    return _desktopTableSlivers(
      items,
      currency,
      pad: pad,
      contentWidth: contentWidth,
      canAdjust: canAdjust,
      canEdit: canEdit,
    );
  }

  List<Widget> _desktopTableSlivers(
    List<InventoryItemSummary> items,
    BusinessCurrency currency, {
    required double pad,
    required double contentWidth,
    required bool canAdjust,
    required bool canEdit,
  }) {
    final columns = _warehouses.length;
    final minWidth =
        _kColName +
        _kColCost +
        _kColWarehouse * columns +
        _kColTotal +
        _kColActions;
    var colWarehouse = _kColWarehouse;
    if (columns > 0) {
      colWarehouse += ((contentWidth - minWidth) / columns).clamp(
        0.0,
        _kColWarehouseMax - _kColWarehouse,
      );
    }

    return [
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: pad),
        // `DecoratedSliver` pinta el marco de la tarjeta detrás de un grupo
        // de slivers y `SliverMainAxisGroup` los encadena como una sola
        // pieza. Así el encabezado y el pie siguen siendo widgets normales y
        // solo las FILAS son perezosas.
        sliver: DecoratedSliver(
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: AppColors.border),
            boxShadow: AppShadows.soft,
          ),
          sliver: SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(child: _tableHeader(colWarehouse)),
              SliverList.builder(
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  final row = _tableRow(
                    item,
                    currency,
                    colWarehouse: colWarehouse,
                    canAdjust: canAdjust,
                    canEdit: canEdit,
                  );
                  if (_expandedItemId != item.id) return row;
                  // La fila expandida y su panel viajan juntos: son un solo
                  // elemento de la lista, así el índice sigue alineado con
                  // `items`.
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      row,
                      _distributionPanel(item, canAdjust: canAdjust),
                    ],
                  );
                },
              ),
              SliverToBoxAdapter(child: _tableFooter(items, currency)),
            ],
          ),
        ),
      ),
    ];
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
    Widget head(
      String text, {
      TextAlign align = TextAlign.left,
      Color? color,
    }) => Text(
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
      // Redondeo propio: en el camino sliver el marco lo dibuja un
      // `DecoratedSliver`, que NO recorta a sus hijos. En el camino con
      // scroll horizontal el `Clip.antiAlias` del contenedor lo tapa igual,
      // así que sirve para los dos.
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.lg),
        ),
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
              decoration: BoxDecoration(border: _columnSeparator(i)),
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
      'out_of_stock' ||
      'critical' => AppColors.destructive.withValues(alpha: 0.035),
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
              Expanded(
                child: _nameCell(item, rail: rail, expanded: expanded),
              ),
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
                child: _rowActions(
                  item,
                  canAdjust: canAdjust,
                  canEdit: canEdit,
                ),
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
                    _Pill(text: 'INACTIVO', color: AppColors.mutedForeground),
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
    final fmt = _fmtQty;
    final zero = qty == 0;

    // MEDIDO: un `Tooltip` por celda costaba el 43% del rebuild de la tabla
    // (41 ms → 23 ms con 40 filas al quitarlo) y el `Material` anidado otro
    // 9%. `Semantics` deja la etiqueta accesible por casi nada, y el
    // `InkWell` funciona igual porque el `Material` de la FILA ya es su
    // ancestro. El tinte de la bodega en contexto va con `Ink`, que pinta
    // sobre ese mismo `Material` y solo se monta cuando hace falta.
    Widget cell = InkWell(
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
    );
    if (highlighted) {
      cell = Ink(color: AppColors.primary.withValues(alpha: 0.07), child: cell);
    }
    return Semantics(
      button: canAdjust,
      label: canAdjust
          ? 'Ajustar ${item.name} en ${warehouse.name}'
          : '${warehouse.name}: ${fmt.format(qty)} ${item.unit}',
      child: cell,
    );
  }

  Widget _totalCell(InventoryItemSummary item) {
    final fmt = _fmtQty;
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
    final fill = scale == null ? null : (item.stock / scale).clamp(0.0, 1.0);
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
            child: InkWell(
              onTap: () => _openAdjust(item),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Container(
                height: 32,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.tune, size: 15, color: AppColors.foreground),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Ajustar',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
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
        const SizedBox(width: 4),
        SizedBox(
          width: _kRowMenuWidth,
          child: _rowMenu(item, canEdit: canEdit),
        ),
      ],
    );
  }

  Widget _rowMenu(InventoryItemSummary item, {required bool canEdit}) {
    // Con `icon:` este widget monta un `IconButton` completo —estilo
    // resoluble por estado, FocusNode, constraints de 48— por fila. Con
    // `child:` se queda en un `InkWell`. Junto con el botón "Ajustar" de
    // abajo, esos dos eran el 36% del rebuild de la tabla.
    return PopupMenuButton<String>(
      tooltip: 'Más acciones',
      padding: EdgeInsets.zero,
      child: SizedBox(
        width: _kRowMenuWidth,
        height: 40,
        child: Icon(
          Icons.more_vert,
          size: 19,
          color: AppColors.mutedForeground,
        ),
      ),
      onSelected: (value) {
        switch (value) {
          case 'edit':
            _openForm(edit: item);
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
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(AppRadius.lg),
        ),
      ),
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
                    text:
                        '${items.length} '
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
            scopeName == null ? 'Valor de existencias' : 'Valor en $scopeName',
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
    final fmt = _fmtQty;
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
    final fmt = _fmtQty;
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
                              onPressed: () =>
                                  _openAdjust(item, warehouseId: warehouse.id),
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
                              onPressed: () =>
                                  _openAdjust(item, warehouseId: warehouse.id),
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
    final fmt = _fmtQty;
    final when = last.createdAt;
    final ago = when == null ? '' : ' ${_relativeDay(when)}';
    final signed = (last.quantity > 0 ? '+' : '') + fmt.format(last.quantity);
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

  /// Encabezado de la lista móvil. Las cards NO van acá: viven en un
  /// `SliverList.builder` para que solo se construyan las visibles.
  Widget _mobileListHeader(
    List<InventoryItemSummary> items, {
    required bool canAdjust,
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
    final fmt = _fmtQty;
    final scope = _scopeId;
    final qty = scope == null ? item.stock : _matrix.quantityOf(item.id, scope);
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
                    scope == null
                        ? '${item.unit} en total'
                        : '${item.unit} acá',
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
              _MobileSquareButton(child: _rowMenu(item, canEdit: canEdit)),
            ],
          ),
        ],
      ),
    );
  }

  /// "Dónde más está" — el dato que el móvil no puede mostrar en columnas.
  String _elsewhereLabel(InventoryItemSummary item, String? scope) {
    final fmt = _fmtQty;
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
                color: active ? const Color(0xFFC2410C) : AppColors.foreground,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.expand_more, size: 17, color: AppColors.mutedForeground),
          ],
        ),
      ),
    );
  }
}

/// Barra de existencias con la marca del mínimo. La marca es la lectura
/// clave: dice si el relleno llega o no llega a donde tiene que llegar.
/// Ancho fijo de la barra. Estar declarado acá es lo que permite prescindir
/// del `LayoutBuilder`: no hay nada que medir en tiempo de layout.
const double _kStockBarWidth = 92;

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
    const width = _kStockBarWidth;
    return SizedBox(
      width: width,
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
      ),
    );
  }
}

/// Caja cuadrada secundaria de las cards móviles (46 de alto: se toca con el
/// pulgar y con guantes de cocina). Al sacar el atajo de transferencia quedó
/// envolviendo solo el menú de la fila, así que ya no arma el botón: recibe
/// el hijo hecho y le pone el marco.
class _MobileSquareButton extends StatelessWidget {
  final Widget child;

  const _MobileSquareButton({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 46,
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Center(child: child),
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
