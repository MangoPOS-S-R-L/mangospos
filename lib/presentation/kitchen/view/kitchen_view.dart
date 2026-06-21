import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/presentation/kitchen/viewmodel/kitchen_viewmodel.dart';
import 'package:mangopos/presentation/kitchen/view/widgets/kitchen_ticket_card.dart';
import 'package:mangopos/data/models/kitchen_models.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:mangopos/app/theme/mango_tokens.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_radius.dart';
import 'package:mangopos/core/theme/app_shadows.dart';

String _formatQty(double qty) {
  if ((qty - qty.roundToDouble()).abs() < 0.001) {
    return qty.toStringAsFixed(0);
  }
  if ((qty * 10 - (qty * 10).roundToDouble()).abs() < 0.001) {
    return qty.toStringAsFixed(1);
  }
  return qty.toStringAsFixed(2);
}

class KitchenView extends ConsumerStatefulWidget {
  const KitchenView({super.key});

  @override
  ConsumerState<KitchenView> createState() => _KitchenViewState();
}

class _KitchenViewState extends ConsumerState<KitchenView> {
  bool autoUpdate = true;
  String? _lastBusinessId;

  /// Poll periódico del tablero. El KDS depende de Realtime sobre
  /// `order_items`, pero esa tabla puede no estar en la publicación
  /// `supabase_realtime` (o el evento llegar filtrado por RLS). Este timer
  /// es el fallback que garantiza que el tablero se refresque solo aunque
  /// Realtime no entregue nada. Se controla con el switch "Auto-refresh".
  Timer? _pollTimer;
  static const Duration _pollInterval = Duration(seconds: 10);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(kitchenViewModelProvider).init();
    });
    if (autoUpdate) _startPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) {
      if (mounted && autoUpdate) {
        ref.read(kitchenViewModelProvider).refresh();
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Maneja el switch "Auto-refresh": arranca/para el poll y, al encender,
  /// hace un refresh inmediato para no esperar el primer tick.
  void _setAutoUpdate(bool val) {
    setState(() => autoUpdate = val);
    if (val) {
      _startPolling();
      ref.read(kitchenViewModelProvider).refresh();
    } else {
      _stopPolling();
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final vm = ref.watch(kitchenViewModelProvider);

    if (session.activeBusinessId != null &&
        session.activeBusinessId != _lastBusinessId) {
      _lastBusinessId = session.activeBusinessId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(kitchenViewModelProvider).init();
        }
      });
    }

    final activeOrders = _activeOrders(
      vm.visibleActiveItems,
      vm.completeOnPayment,
    );
    final queueItems = activeOrders.fold<int>(
      0,
      (sum, o) => sum + o.items.where((i) => i.status != 'ready').length,
    );
    // "Completados Hoy" sale de la cocina (ready_at de hoy), no del tablero
    // vivo: así sigue contando aunque la comanda ya se haya pagado/despachado.
    final completedTodayItems = vm.completedTodayItems;
    final completedToday = _groupOrdersFromItems(completedTodayItems).length;

    final isMobile = ResponsiveHelper.isMobile(context);
    final padding = isMobile ? 12.0 : 24.0;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Padding(
        padding: EdgeInsets.all(padding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context),
            SizedBox(height: isMobile ? 12 : 20),
            _buildStatsRow(
              activeCount: activeOrders.length,
              queueItems: queueItems,
              completedToday: completedToday,
              completedItems: completedTodayItems,
            ),
            SizedBox(height: isMobile ? 12 : 18),
            Expanded(
              child: vm.isLoading && activeOrders.isEmpty
                  ? Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    )
                  : _buildBoard(activeOrders),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }

  // ============================================================
  // TABLERO
  // ============================================================

  /// Agrupa los ítems activos por orden.
  ///
  /// - Modo "sale al pagar" ([completeOnPayment] true): solo se muestran las
  ///   comandas con trabajo pendiente (pending/preparing). Al cocinarlas o
  ///   pagarlas salen solas del tablero.
  /// - Modo "esperar al cocinero" ([completeOnPayment] false): la fuente ya es
  ///   `kds_open_orders` (órdenes sin sello de cocina), así que se muestran
  ///   TODAS — incluso pagadas — hasta que el cocinero presione "Marcar todo
  ///   listo".
  List<KitchenOrder> _activeOrders(
    List<KitchenItem> items,
    bool completeOnPayment,
  ) {
    final map = <String, List<KitchenItem>>{};
    for (final item in items) {
      map.putIfAbsent(item.orderId, () => []).add(item);
    }

    final orders = <KitchenOrder>[];
    for (final entry in map.entries) {
      final list = entry.value;
      final hasOpen = list.any(
        (i) => i.status == 'pending' || i.status == 'preparing',
      );
      // En modo "sale al pagar", una comanda sin trabajo pendiente ya está
      // cocinada/pagada → fuera del tablero.
      if (completeOnPayment && !hasOpen) continue;

      // No-listos primero; dentro de cada grupo, por antigüedad.
      list.sort((a, b) {
        final ad = a.status == 'ready' ? 1 : 0;
        final bd = b.status == 'ready' ? 1 : 0;
        if (ad != bd) return ad - bd;
        return a.createdAt.compareTo(b.createdAt);
      });

      final first = list.reduce(
        (a, b) => a.createdAt.isBefore(b.createdAt) ? a : b,
      );
      orders.add(
        KitchenOrder(
          orderId: entry.key,
          orderNumber: first.orderNumber,
          tableName: first.tableName,
          waiterName: first.waiterName,
          createdAt: first.createdAt,
          items: list,
        ),
      );
    }

    // Con trabajo pendiente primero (y entre ellas, las más viejas/urgentes
    // arriba); las que ya están listas esperando despacho, al final.
    orders.sort((a, b) {
      final ao = a.items.any((i) => i.status != 'ready') ? 0 : 1;
      final bo = b.items.any((i) => i.status != 'ready') ? 0 : 1;
      if (ao != bo) return ao - bo;
      return a.createdAt.compareTo(b.createdAt);
    });
    return orders;
  }

  Widget _buildBoard(List<KitchenOrder> orders) {
    if (orders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.done_all_rounded,
                size: 32,
                color: AppColors.success,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'No hay comandas activas',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.foreground,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Las nuevas órdenes aparecerán aquí automáticamente.',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.mutedForeground,
              ),
            ),
          ],
        ),
      );
    }

    final isMobile = ResponsiveHelper.isMobile(context);
    final gap = isMobile ? 12.0 : 16.0;

    // Masonry por columnas: cada card crece según su contenido (sin recortes
    // ni scroll interno). Repartimos las comandas en columnas balanceadas y
    // hacemos scroll vertical del tablero completo.
    return LayoutBuilder(
      builder: (context, constraints) {
        const targetWidth = 360.0;
        final columnCount = isMobile
            ? 1
            : ((constraints.maxWidth + gap) / (targetWidth + gap))
                .floor()
                .clamp(1, 6);

        final columns = List.generate(columnCount, (_) => <KitchenOrder>[]);
        for (var i = 0; i < orders.length; i++) {
          columns[i % columnCount].add(orders[i]);
        }

        return SingleChildScrollView(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var c = 0; c < columnCount; c++) ...[
                if (c > 0) SizedBox(width: gap),
                Expanded(
                  child: Column(
                    children: [
                      for (final order in columns[c]) ...[
                        KitchenTicketCard(
                          order: order,
                          onBumpItem: (itemId) => ref
                              .read(kitchenViewModelProvider)
                              .markReady(itemId),
                          onCompleteOrder: (orderId) => ref
                              .read(kitchenViewModelProvider)
                              .markOrderReady(orderId),
                        ),
                        SizedBox(height: gap),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  // ============================================================
  // HEADER / TOOLBAR
  // ============================================================

  Widget _buildHeader(BuildContext context) {
    final isMobile = ResponsiveHelper.isMobile(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Cocina (KDS)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: isMobile ? 17 : 22,
                  fontWeight: FontWeight.bold,
                  color: AppColors.foreground,
                ),
              ),
              if (!isMobile) ...[
                const SizedBox(height: 2),
                Text(
                  'Sistema de visualizacion de comandas',
                  style: TextStyle(
                    color: AppColors.mutedForeground,
                    fontSize: 13,
                  ),
                ),
              ],
            ],
          ),
        ),
        // En móvil sólo dejamos el switch (compacto) + botón refresh icon.
        if (isMobile) ...[
          Switch(
            value: autoUpdate,
            onChanged: _setAutoUpdate,
            activeThumbColor: Colors.white,
            activeTrackColor: AppColors.primary,
            inactiveThumbColor: Colors.white,
            inactiveTrackColor: const Color(0xFFD1D5DB),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: () => ref.read(kitchenViewModelProvider).refresh(),
            icon: const Icon(Icons.refresh, size: 22),
            color: AppColors.foreground,
            tooltip: 'Actualizar',
            visualDensity: VisualDensity.compact,
          ),
        ] else ...[
          // Toolbar normalizado: todos los chips/botones a 44 de alto, mismo
          // borde y border-radius.
          _ToolbarChip(
            child: Row(
              children: [
                const Text(
                  'Auto-refresh',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 10),
                Transform.scale(
                  scale: 0.85,
                  child: Switch(
                    value: autoUpdate,
                    onChanged: _setAutoUpdate,
                    activeThumbColor: AppColors.primary,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Filtro por área de producción. Solo aparece si el comercio tiene
          // áreas configuradas (Cocina, Bar, etc.). Si no, este selector no
          // tiene sentido y queda escondido.
          _buildAreaFilter(context),
          _ToolbarChip(
            onTap: () => ref.read(kitchenViewModelProvider).refresh(),
            child: Row(
              children: [
                const Icon(Icons.refresh, size: 18),
                const SizedBox(width: 8),
                const Text(
                  'Actualizar',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Dropdown "Filtrar por área" — al lado del Auto-refresh, mismo
  /// chip que el resto del toolbar para alineación visual.
  /// - Si el comercio no tiene `print_areas`, devuelve `SizedBox.shrink()`.
  /// - "Todos" siempre presente como primera opción (selectedAreaCode == null).
  /// - Cada área aparece con su `name` legible (ej. "Cocina", "Bar").
  Widget _buildAreaFilter(BuildContext context) {
    final vm = ref.watch(kitchenViewModelProvider);
    final areas = vm.availableAreas;
    if (areas.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: _ToolbarChip(
        child: Row(
          children: [
            Icon(
              Icons.filter_alt_outlined,
              size: 18,
              color: AppColors.mutedForeground,
            ),
            const SizedBox(width: 8),
            const Text(
              'Área',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 10),
            DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                value: vm.selectedAreaCode,
                isDense: true,
                borderRadius: BorderRadius.circular(AppRadius.card),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Todos'),
                  ),
                  ...areas.map(
                    (a) => DropdownMenuItem<String?>(
                      value: a.code,
                      child: Text(a.name),
                    ),
                  ),
                ],
                onChanged: (code) => ref
                    .read(kitchenViewModelProvider)
                    .setSelectedAreaCode(code),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // STATS
  // ============================================================

  Widget _buildStatsRow({
    required int activeCount,
    required int queueItems,
    required int completedToday,
    required List<KitchenItem> completedItems,
  }) {
    final isMobile = ResponsiveHelper.isMobile(context);
    final gap = isMobile ? 8.0 : 16.0;
    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            color: AppColors.warning,
            icon: Icons.receipt_long_outlined,
            title: activeCount.toString(),
            subtitle: isMobile ? 'Activas' : 'Comandas activas',
          ),
        ),
        SizedBox(width: gap),
        Expanded(
          child: _buildStatCard(
            color: AppColors.info,
            icon: Icons.restaurant_menu,
            title: queueItems.toString(),
            subtitle: isMobile ? 'En cola' : 'Ítems en cola',
          ),
        ),
        SizedBox(width: gap),
        Expanded(
          child: _buildStatCard(
            color: AppColors.success,
            icon: Icons.check_circle_outline,
            title: completedToday.toString(),
            subtitle: isMobile ? 'Hoy' : 'Completados Hoy',
            onTap: () => _showCompletedTodayDialog(context, completedItems),
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required Color color,
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
  }) {
    final isMobile = ResponsiveHelper.isMobile(context);
    final iconBox = isMobile ? 32.0 : 42.0;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Container(
        padding: EdgeInsets.all(isMobile ? 10 : 16),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.border),
          boxShadow: AppShadows.cardElevated,
        ),
        child: Row(
          children: [
            Container(
              width: iconBox,
              height: iconBox,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: Icon(
                icon,
                color: color,
                size: isMobile ? 18 : 24,
              ),
            ),
            SizedBox(width: isMobile ? 8 : 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: isMobile ? 16 : 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.mutedForeground,
                      fontSize: isMobile ? 10.5 : 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showCompletedTodayDialog(
    BuildContext context,
    List<KitchenItem> completedItems,
  ) {
    // `completedItems` ya viene acotado a "hoy" por la vista kds_completed_today
    // (día local de RD), así que solo agrupamos por comanda.
    final orders = _groupOrdersFromItems(completedItems);

    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 700),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: MangoTokens.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Icon(
                        Icons.checklist_rounded,
                        color: MangoTokens.primary,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Completados hoy', style: MangoTokens.h1()),
                          const SizedBox(height: 6),
                          Text(
                            '${orders.length} comandas completadas en el día.',
                            style: MangoTokens.subtitle(),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: orders.isEmpty
                      ? Center(
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: MangoTokens.border),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.inbox_outlined,
                                  size: 28,
                                  color: MangoTokens.mutedForeground,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'No hay comandas completadas hoy.',
                                  style: MangoTokens.body(
                                    color: MangoTokens.mutedForeground,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: orders.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final order = orders[index];
                            final completedAt = order.items
                                .map((e) => e.readyAt ?? e.createdAt)
                                .reduce((a, b) => a.isAfter(b) ? a : b);
                            return Container(
                              padding: const EdgeInsets.all(18),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(color: MangoTokens.border),
                                boxShadow: MangoTokens.shadowCard,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          color: MangoTokens.secondary,
                                          borderRadius: BorderRadius.circular(14),
                                        ),
                                        child: const Icon(
                                          Icons.receipt_long_outlined,
                                          color: MangoTokens.primary,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Orden ${order.orderNumber.isNotEmpty ? order.orderNumber : order.orderId.substring(0, 8).toUpperCase()}',
                                              style: MangoTokens.body().copyWith(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 16,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              'Mesa: ${order.tableName ?? 'N/A'} · Mesero: ${order.waiterName ?? 'N/A'}',
                                              style: MangoTokens.label(),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: MangoTokens.secondary,
                                          borderRadius: BorderRadius.circular(999),
                                        ),
                                        child: Text(
                                          '${completedAt.hour.toString().padLeft(2, '0')}:${completedAt.minute.toString().padLeft(2, '0')}',
                                          style: MangoTokens.label(
                                            color: MangoTokens.foreground,
                                          ).copyWith(fontWeight: FontWeight.w700),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 14),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: MangoTokens.secondary,
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Items completados',
                                          style: MangoTokens.label(
                                            color: MangoTokens.foreground,
                                          ).copyWith(fontWeight: FontWeight.w700),
                                        ),
                                        const SizedBox(height: 10),
                                        ...order.items.map(
                                          (item) => Padding(
                                            padding: const EdgeInsets.only(bottom: 8),
                                            child: Row(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  '${_formatQty(item.quantity)}x',
                                                  style: MangoTokens.body().copyWith(
                                                    fontWeight: FontWeight.w800,
                                                    color: MangoTokens.primary,
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                  child: Text(
                                                    item.productName,
                                                    style: MangoTokens.body().copyWith(
                                                      fontWeight: FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: MangoTokens.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('Cerrar'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<KitchenOrder> _groupOrdersFromItems(List<KitchenItem> items) {
    final map = <String, List<KitchenItem>>{};
    for (final item in items) {
      map.putIfAbsent(item.orderId, () => []).add(item);
    }
    return map.entries.map((entry) {
      final list = entry.value;
      list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final first = list.first;
      return KitchenOrder(
        orderId: entry.key,
        orderNumber: first.orderNumber,
        tableName: first.tableName,
        waiterName: first.waiterName,
        createdAt: first.createdAt,
        items: list,
      );
    }).toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }
}

/// Chip estándar del toolbar del KDS: altura fija 44, mismo borde y radius
/// que el resto. Sirve como wrapper para Auto-refresh, filtro de área,
/// botón Actualizar — alinearlos en una sola línea con look idéntico.
///
/// Si se pasa `onTap`, el chip se vuelve clickable con ripple (mismo
/// border radius). Sin `onTap` es decorativo.
class _ToolbarChip extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;

  const _ToolbarChip({required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    final decoration = BoxDecoration(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.card),
      border: Border.all(color: AppColors.border),
    );
    final padded = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: child,
    );
    final inner = SizedBox(height: 44, child: Center(child: padded));

    if (onTap == null) {
      return DecoratedBox(decoration: decoration, child: inner);
    }
    return Material(
      color: AppColors.card,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: inner,
      ),
    );
  }
}
