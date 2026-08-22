// Fase 2 Bodegas — el mapa: cada tarjeta es una puerta.
//
// Antes esto era un CRUD de nombre y dirección cuyo único botón era el lápiz
// de editar: se podía cambiar cómo se llama el almacén, nunca ver lo que hay
// adentro. De ahí las cuatro decisiones de esta pantalla:
//
//   1. La tarjeta es la puerta. "Abrir bodega" es la acción primaria y el
//      lápiz baja al menú ⋮ — al revés de como estaba.
//   2. Cada tarjeta dice algo operativo: valor de las existencias, insumos
//      con stock, qué falta contra el mínimo, qué viene en camino y hace
//      cuánto que nadie cuenta.
//   3. "En tránsito" sale de la lista. Es un estado del sistema —mercancía
//      que salió y todavía no se recibió—, no un lugar al que se manda gente.
//   4. La inactiva se ve inactiva: atenuada, al final y con "Reactivar" en
//      vez de "Abrir". Sigue visible para auditoría, pero no compite.
//
// El interior de cada bodega vive en `warehouse_detail_view.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
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
import '../state/warehouse_overview_state.dart';
import '../viewmodel/inventory_viewmodel.dart';
import 'transfer_send_dialog.dart';
import 'widgets/inventory_back_button.dart';
import 'widgets/warehouse_form_dialog.dart';
import 'widgets/warehouse_visuals.dart';

/// Ancho al que caben tres tarjetas cómodas; por debajo se baja a dos y
/// después a una. Son anchos de CONTENIDO (ya descontado el padding).
const double _kThreeColumns = 1120;
const double _kTwoColumns = 760;

class WarehousesView extends ConsumerStatefulWidget {
  const WarehousesView({super.key});

  @override
  ConsumerState<WarehousesView> createState() => _WarehousesViewState();
}

class _WarehousesViewState extends ConsumerState<WarehousesView> {
  bool _loading = true;
  bool _refreshing = false;

  /// Pintamos la copia local y la lectura fresca sigue en vuelo.
  bool _awaitingFresh = false;
  String? _error;
  String? _businessId;
  InventoryWarehousesOverview _overview = InventoryWarehousesOverview.empty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  InventoryRepository get _repo => ref.read(inventoryRepositoryProvider);

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
      await _primeFromCache(businessId);
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
  /// mientras responde la red. El caché no guarda transferencias ni conteos,
  /// así que las tarjetas arrancan con valor e insumos y completan al llegar
  /// la lectura fresca.
  Future<void> _primeFromCache(String businessId) async {
    try {
      final cached = await _repo.getCachedWarehousesOverview(businessId);
      if (cached == null || cached.warehouses.isEmpty || !mounted) return;
      setState(() {
        _overview = cached;
        _loading = false;
        _awaitingFresh = true;
      });
    } catch (e) {
      // El caché es un atajo, no una fuente de verdad.
      debugPrint('[bodegas] no se pudo pintar desde caché: $e');
    }
  }

  Future<void> _load() async {
    final businessId = _businessId;
    if (businessId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final overview = await _repo.getWarehousesOverview(businessId);
      if (!mounted) return;
      setState(() {
        _overview = overview;
        _loading = false;
        _refreshing = false;
        _awaitingFresh = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _awaitingFresh = false;
        // Con algo pintado desde el caché, un fallo de red no borra la
        // pantalla: se avisa arriba y se deja lo que hay.
        _error = _overview.warehouses.isEmpty ? e.toString() : null;
      });
      if (_overview.warehouses.isNotEmpty && mounted) {
        AppToast.warning(context, 'No se pudo actualizar: ${_shortError(e)}');
      }
    }
  }

  static String _shortError(Object e) {
    final text = e.toString();
    return text.length > 90 ? '${text.substring(0, 90)}…' : text;
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await _load();
  }

  // ── Acciones ────────────────────────────────────────────────────────────

  Future<void> _openForm({WarehouseOverview? edit}) async {
    final businessId = _businessId;
    if (businessId == null) return;
    final saved = await showWarehouseFormDialog(
      context,
      businessId: businessId,
      repo: _repo,
      edit: edit?.warehouse,
      // Ya las tenemos cargadas: el selector de "copiar desde" no necesita
      // volver a pedirlas.
      warehouses: _overview.warehouses
          .map((w) => w.warehouse)
          .toList(growable: false),
    );
    if (saved) await _refresh();
  }

  /// Desactivar no borra: la bodega inactiva sigue en el mapa, atenuada, para
  /// que el histórico de movimientos siga teniendo dónde apoyarse.
  Future<void> _toggleActive(WarehouseOverview w) async {
    final businessId = _businessId;
    if (businessId == null) return;
    final activate = !w.isActive;
    if (!activate && w.itemsWithStock > 0) {
      final confirmed = await _confirmDeactivate(w);
      if (confirmed != true) return;
    }
    try {
      await _repo.updateWarehouse(
        businessId: businessId,
        warehouseId: w.warehouse.id,
        name: w.warehouse.name,
        address: w.warehouse.address.isEmpty ? null : w.warehouse.address,
        isMain: w.warehouse.isMain,
        isActive: activate,
      );
      if (!mounted) return;
      AppToast.success(
        context,
        activate
            ? '${w.name} vuelve a recibir mercancía.'
            : '${w.name} quedó desactivada.',
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo cambiar el estado: ${_shortError(e)}');
    }
  }

  Future<bool?> _confirmDeactivate(WarehouseOverview w) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Desactivar ${w.name}'),
        content: Text(
          'Todavía tiene ${w.itemsWithStock} insumo(s) con existencia. La '
          'mercancía no se mueve a ninguna parte: la bodega deja de aparecer '
          'para recibir y su stock queda congelado donde está.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.destructive,
            ),
            child: const Text('Desactivar'),
          ),
        ],
      ),
    );
  }

  void _openWarehouse(WarehouseOverview w, {String? tab}) {
    final query = tab == null ? '' : '?tab=$tab';
    context.push('${AppRoutes.inventoryWarehouses}/${w.warehouse.id}$query');
  }

  Future<void> _openTransfer() async {
    final sent = await showDialog<bool>(
      context: context,
      builder: (_) => const TransferSendDialog(),
    );
    if (sent == true) await _refresh();
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final currency = currentBusinessCurrencyOrFallback(ref);
    final session = ref.watch(sessionProvider.notifier);
    final canTransfer = session.hasPermission('inventario.transferencias.crear');

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxWidth < 600;
            final padding = EdgeInsets.all(isCompact ? 16 : 24);
            final contentWidth = constraints.maxWidth - padding.horizontal;

            if (_error != null && _overview.warehouses.isEmpty) {
              return _errorState();
            }

            return RefreshIndicator(
              onRefresh: _refresh,
              color: AppColors.primary,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: padding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(
                      currency: currency,
                      isCompact: isCompact,
                      canTransfer: canTransfer,
                    ),
                    if (_awaitingFresh || _refreshing) ...[
                      const SizedBox(height: 12),
                      _refreshingBar(),
                    ],
                    const SizedBox(height: 20),
                    if (_loading)
                      _skeleton(contentWidth, isCompact)
                    else ...[
                      _grid(contentWidth, currency, isCompact),
                      const SizedBox(height: 16),
                      _transitStrip(currency, isCompact),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _refreshingBar() => ClipRRect(
    borderRadius: BorderRadius.circular(AppRadius.full),
    child: LinearProgressIndicator(
      minHeight: 3,
      backgroundColor: AppColors.muted,
      color: AppColors.primary,
    ),
  );

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

  Widget _header({
    required BusinessCurrency currency,
    required bool isCompact,
    required bool canTransfer,
  }) {
    final count = _overview.warehouses.length;
    final subtitle = _loading
        ? 'Almacenes físicos del negocio'
        : '$count ${count == 1 ? 'almacén' : 'almacenes'} · '
              '${currency.formatAmount(_overview.totalValue)} en existencias';

    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Bodegas',
          style: TextStyle(
            fontSize: isCompact ? 20 : 28,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
            color: AppColors.foreground,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: isCompact ? 12 : 14,
            color: AppColors.mutedForeground,
          ),
        ),
      ],
    );

    if (isCompact) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: InventoryBackButton(),
          ),
          const SizedBox(width: 2),
          Expanded(child: title),
          IconButton(
            tooltip: 'Nueva bodega',
            onPressed: _loading ? null : () => _openForm(),
            icon: Icon(Icons.add_circle, color: AppColors.primary),
          ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: InventoryBackButton(),
        ),
        const SizedBox(width: 4),
        Expanded(child: title),
        if (canTransfer) ...[
          OutlinedButton.icon(
            onPressed: _loading ? null : _openTransfer,
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: const Text('Transferir'),
          ),
          const SizedBox(width: 12),
        ],
        FilledButton.icon(
          onPressed: _loading ? null : () => _openForm(),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Nueva bodega'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          ),
        ),
      ],
    );
  }

  // ── Rejilla de tarjetas ─────────────────────────────────────────────────

  int _columnsFor(double width) {
    if (width >= _kThreeColumns) return 3;
    if (width >= _kTwoColumns) return 2;
    return 1;
  }

  Widget _grid(double width, BusinessCurrency currency, bool isCompact) {
    const gap = 16.0;
    final columns = _columnsFor(width);
    final cardWidth = columns == 1
        ? width
        : (width - gap * (columns - 1)) / columns;

    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        for (var i = 0; i < _overview.warehouses.length; i++)
          SizedBox(
            width: cardWidth,
            child: _WarehouseCard(
              overview: _overview.warehouses[i],
              accent: warehouseAccent(
                index: i,
                isMain: _overview.warehouses[i].isMain,
                isActive: _overview.warehouses[i].isActive,
              ),
              currency: currency,
              isCompact: isCompact,
              onOpen: () => _openWarehouse(_overview.warehouses[i]),
              onMovements: () =>
                  _openWarehouse(_overview.warehouses[i], tab: 'movimientos'),
              onEdit: () => _openForm(edit: _overview.warehouses[i]),
              onToggleActive: () => _toggleActive(_overview.warehouses[i]),
            ),
          ),
        SizedBox(
          width: cardWidth,
          child: _NewWarehouseCard(onTap: () => _openForm()),
        ),
      ],
    );
  }

  // ── Tránsito: no es un almacén, es un estado ────────────────────────────

  Widget _transitStrip(BusinessCurrency currency, bool isCompact) {
    final transit = _overview.inTransit;
    final pending = _overview.transfersInTransit;
    // Sin bodega virtual y sin nada en camino no hay nada que explicar.
    if (transit == null && pending == 0) return const SizedBox.shrink();

    final value = transit?.stockValue ?? 0;
    final detail = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                'En tránsito',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _Badge(
              text: 'VIRTUAL · AUTOMÁTICA',
              color: AppColors.reserved,
              dense: true,
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          'Mercancía que salió de una bodega y todavía no se recibió en la '
          'otra. No se edita ni se ajusta: se vacía sola al confirmar la '
          'recepción.',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.45,
            color: AppColors.mutedForeground,
          ),
        ),
      ],
    );

    final counter = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$pending',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: AppColors.foreground,
          ),
        ),
        Text(
          pending == 1 ? 'transferencia' : 'transferencias',
          style: TextStyle(fontSize: 11, color: AppColors.mutedForeground),
        ),
        if (value > 0)
          Text(
            currency.formatAmount(value),
            style: TextStyle(fontSize: 11, color: AppColors.mutedForeground),
          ),
      ],
    );

    final cta = OutlinedButton.icon(
      onPressed: () => context.push(AppRoutes.inventoryTransfers),
      icon: const Icon(Icons.arrow_forward, size: 16),
      iconAlignment: IconAlignment.end,
      label: const Text('Ver en camino'),
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: AppColors.reserved.withValues(alpha: 0.35),
          style: BorderStyle.solid,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.reserved.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(AppRadius.iconBox),
            ),
            child: Icon(
              Icons.local_shipping_outlined,
              size: 19,
              color: AppColors.reserved,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(child: detail),
          if (!isCompact) ...[
            const SizedBox(width: 14),
            counter,
            const SizedBox(width: 14),
            cta,
          ],
        ],
      ),
    );
  }

  // ── Esqueleto ───────────────────────────────────────────────────────────

  Widget _skeleton(double width, bool isCompact) {
    const gap = 16.0;
    final columns = _columnsFor(width);
    final cardWidth = columns == 1
        ? width
        : (width - gap * (columns - 1)) / columns;
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: List.generate(
        columns == 1 ? 2 : columns,
        (_) => SizedBox(
          width: cardWidth,
          child: Container(
            height: 236,
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: AppColors.border),
            ),
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Row(
                  children: [
                    SkeletonBox(width: 40, height: 40, borderRadius: 10),
                    SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SkeletonBox(width: 130, height: 14, borderRadius: 6),
                          SizedBox(height: 8),
                          SkeletonBox(width: 90, height: 10, borderRadius: 6),
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 22),
                SkeletonBox(width: 120, height: 22, borderRadius: 6),
                SizedBox(height: 18),
                SkeletonBox(height: 26, borderRadius: 8),
                Spacer(),
                SkeletonBox(height: 40, borderRadius: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Tarjeta de bodega ─────────────────────────────────────────────────────

class _WarehouseCard extends StatelessWidget {
  final WarehouseOverview overview;
  final Color accent;
  final BusinessCurrency currency;
  final bool isCompact;
  final VoidCallback onOpen;
  final VoidCallback onMovements;
  final VoidCallback onEdit;
  final VoidCallback onToggleActive;

  const _WarehouseCard({
    required this.overview,
    required this.accent,
    required this.currency,
    required this.isCompact,
    required this.onOpen,
    required this.onMovements,
    required this.onEdit,
    required this.onToggleActive,
  });

  @override
  Widget build(BuildContext context) {
    final inactive = !overview.isActive;
    final w = overview.warehouse;

    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        // La tarjeta ENTERA abre la bodega: el botón es el refuerzo visual,
        // no el único blanco. La inactiva no abre — su acción es reactivar.
        onTap: inactive ? onToggleActive : onOpen,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Ink(
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
              color: inactive ? AppColors.muted : AppColors.border,
            ),
            boxShadow: inactive ? AppShadows.soft : AppShadows.cardElevated,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 4,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(AppRadius.lg),
                  ),
                ),
              ),
              Opacity(
                opacity: inactive ? 0.62 : 1,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _identity(w.name),
                      const SizedBox(height: 14),
                      _stats(),
                      const SizedBox(height: 14),
                      ConstrainedBox(
                        // Mínimo, no fijo: reserva el sitio de los chips para
                        // que las tarjetas de una fila queden parejas, pero
                        // deja crecer si el sistema tiene el texto agrandado.
                        constraints: const BoxConstraints(
                          minHeight: kWarehouseFlagMinHeight,
                        ),
                        child: _flags(),
                      ),
                      const SizedBox(height: 14),
                      Divider(color: AppColors.border, height: 1),
                      const SizedBox(height: 14),
                      _actions(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _identity(String name) {
    final badge = overview.isActive
        ? (overview.isMain
              ? _Badge(text: 'PRINCIPAL', color: AppColors.primary, dense: true)
              : null)
        : _Badge(
            text: 'INACTIVA',
            color: AppColors.mutedForeground,
            dense: true,
          );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(AppRadius.iconBox),
          ),
          child: Icon(warehouseIcon(name), size: 21, color: accent),
        ),
        const SizedBox(width: 10),
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
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: AppColors.foreground,
                      ),
                    ),
                  ),
                  if (badge != null) ...[const SizedBox(width: 7), badge],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                overview.warehouse.address.isEmpty
                    ? 'Sin dirección'
                    : overview.warehouse.address,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
        _menu(),
      ],
    );
  }

  Widget _menu() {
    return SizedBox(
      width: 32,
      height: 32,
      child: PopupMenuButton<String>(
        tooltip: 'Más acciones',
        padding: EdgeInsets.zero,
        icon: Icon(Icons.more_vert, size: 18, color: AppColors.mutedForeground),
        onSelected: (value) {
          switch (value) {
            case 'edit':
              onEdit();
            case 'movements':
              onMovements();
            case 'toggle':
              onToggleActive();
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: 'edit',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.edit_outlined, size: 18),
              title: Text('Editar bodega'),
            ),
          ),
          const PopupMenuItem(
            value: 'movements',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.receipt_long_outlined, size: 18),
              title: Text('Ver movimientos'),
            ),
          ),
          PopupMenuItem(
            value: 'toggle',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                overview.isActive
                    ? Icons.block_outlined
                    : Icons.play_circle_outline,
                size: 18,
              ),
              title: Text(overview.isActive ? 'Desactivar' : 'Reactivar'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stats() {
    Widget block(String label, String value, {bool expanded = true}) {
      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
              color: AppColors.mutedForeground,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: AppColors.foreground,
            ),
          ),
        ],
      );
      return expanded ? Expanded(child: content) : content;
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        block('Existencias', currency.formatAmount(overview.stockValue)),
        const SizedBox(width: 16),
        block('Insumos', '${overview.itemsWithStock}', expanded: false),
      ],
    );
  }

  /// Los chips que hacen que la tarjeta valga la pena mirarla. Se muestran
  /// como mucho dos: el tercero desplaza al que importa.
  Widget _flags() {
    final flags = <Widget>[];

    if (!overview.isActive) {
      flags.add(
        const WarehouseFlag(
          icon: Icons.block,
          label: 'No recibe mercancía',
          color: AppColors.mutedForeground,
        ),
      );
    } else {
      if (overview.lowStockCount > 0) {
        flags.add(
          WarehouseFlag(
            icon: Icons.warning_amber_rounded,
            label:
                '${overview.lowStockCount} bajo '
                'mínimo',
            color: AppColors.warning,
          ),
        );
      } else if (overview.minimumsConfigured > 0) {
        flags.add(
          const WarehouseFlag(
            icon: Icons.check_circle,
            label: 'Todo sobre mínimo',
            color: AppColors.success,
          ),
        );
      } else {
        // Sin mínimos aplicables no hay nada contra qué comparar: decir
        // "todo sobre mínimo" sería inventar una tranquilidad que no existe.
        flags.add(
          const WarehouseFlag(
            icon: Icons.tune,
            label: 'Sin mínimos definidos',
            color: AppColors.mutedForeground,
          ),
        );
      }

      if (overview.incomingTransfers > 0) {
        flags.add(
          WarehouseFlag(
            icon: Icons.inbox_outlined,
            label: '${overview.incomingTransfers} por recibir',
            color: AppColors.reserved,
          ),
        );
      } else {
        final days = overview.daysSinceCount();
        if (days == null && overview.itemsWithStock > 0) {
          flags.add(
            const WarehouseFlag(
              icon: Icons.schedule,
              label: 'Nunca contada',
              color: AppColors.mutedForeground,
            ),
          );
        } else if (days != null && days >= 30) {
          flags.add(
            WarehouseFlag(
              icon: Icons.schedule,
              label: 'Sin contar $days días',
              color: AppColors.mutedForeground,
            ),
          );
        }
      }
    }

    return Row(
      children: [
        for (var i = 0; i < flags.length && i < 2; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Flexible(child: flags[i]),
        ],
      ],
    );
  }

  Widget _actions() {
    final inactive = !overview.isActive;
    final primary = inactive
        ? OutlinedButton(
            onPressed: onToggleActive,
            child: const Text('Reactivar'),
          )
        : (overview.isMain
              ? FilledButton.icon(
                  onPressed: onOpen,
                  icon: const Icon(Icons.arrow_forward, size: 16),
                  iconAlignment: IconAlignment.end,
                  label: const Text('Abrir bodega'),
                )
              : OutlinedButton.icon(
                  onPressed: onOpen,
                  icon: const Icon(Icons.arrow_forward, size: 16),
                  iconAlignment: IconAlignment.end,
                  label: const Text('Abrir bodega'),
                ));

    return Row(
      children: [
        Expanded(child: SizedBox(height: 40, child: primary)),
        if (!isCompact) ...[
          const SizedBox(width: 8),
          _SquareAction(
            icon: Icons.edit_outlined,
            tooltip: 'Editar bodega',
            onTap: onEdit,
          ),
          const SizedBox(width: 8),
          _SquareAction(
            icon: Icons.receipt_long_outlined,
            tooltip: 'Ver movimientos',
            onTap: onMovements,
          ),
        ],
      ],
    );
  }
}

class _NewWarehouseCard extends StatelessWidget {
  final VoidCallback onTap;
  const _NewWarehouseCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: DottedBorderBox(
        child: SizedBox(
          height: 236,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.add_business_outlined,
                size: 30,
                color: AppColors.mutedForeground,
              ),
              const SizedBox(height: 8),
              Text(
                'Nueva bodega',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Marco punteado. Flutter no tiene `border-style: dashed`, así que el
/// contorno se pinta a mano: es la única forma de que el hueco de "todavía
/// no existe" se lea distinto de una tarjeta real.
class DottedBorderBox extends StatelessWidget {
  final Widget child;
  const DottedBorderBox({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(
        color: AppColors.border,
        radius: AppRadius.lg,
      ),
      child: child,
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double radius;
  const _DashedBorderPainter({required this.color, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rect);
    const dash = 6.0;
    const gap = 5.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = (distance + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}

class _SquareAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _SquareAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(icon, size: 18, color: AppColors.foreground),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  final bool dense;
  const _Badge({required this.text, required this.color, this.dense = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 7 : 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: dense ? 10 : 11,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}
