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
import 'package:mangopos/core/utils/app_snackbar.dart';

/// Hora corta HH:mm para las tarjetas del KDS. Recibe la fecha ya en la zona
/// que se quiera mostrar (los timestamps vienen en UTC del server).
String _formatClock(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

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

  /// Mismo criterio de "hecho" que la tarjeta: listo/servido, o pagado que
  /// ya se cocinó (`ready_at` sellado).
  bool _itemDoneForCard(KitchenItem item) =>
      item.status == 'ready' ||
      item.status == 'served' ||
      (item.status == 'paid' && item.readyAt != null);

  /// Al completar la comanda marcando círculo por círculo, pregunta si se
  /// quiere imprimir la comanda. Aceptar DESPACHA la tarjeta (igual que
  /// "Marcar todo listo": sus ítems pasan a 'served' y sale del tablero) e
  /// imprime el ticket de LISTO aunque la config "Imprimir al marcar listo"
  /// esté apagada (el usuario ya lo pidió; fallback a las impresoras normales
  /// del área). "No" deja la tarjeta tachada en el tablero, como hasta ahora.
  Future<void> _offerPrintReadyTicket(KitchenOrder order) async {
    final shouldPrint = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Comanda completa'),
        content: const Text(
          'Marcaste todos los productos como listos. '
          '¿Deseas imprimir la comanda y completar el pedido?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('No'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: MangoTokens.primary,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.print_rounded, size: 18),
            label: const Text('Sí, imprimir'),
          ),
        ],
      ),
    );
    if (shouldPrint != true || !mounted) return;

    final notice = await ref.read(kitchenViewModelProvider).markOrderReady(
          order.orderId,
          itemIds: order.items.map((i) => i.id).toList(growable: false),
          forcePrint: true,
        );
    if (notice != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showAppSnackBar(
          SnackBar(
            content: Text(notice),
            duration: const Duration(seconds: 6),
          ),
        );
    }
  }

  // ============================================================
  // TABLERO
  // ============================================================

  /// Agrupa los ítems activos en tarjetas (orden + ronda + área) y deja en el
  /// tablero las que aún NO fueron despachadas.
  ///
  /// Marcar círculos es SOLO PROGRESO en ambos modos: una tarjeta con todos
  /// sus ítems 'ready' se queda visible (tachada, al final del tablero) hasta
  /// que se despache con "Marcar todo listo", que pasa sus ítems a 'served'
  /// —estado terminal persistente— y ahí sí deja de contar y la tarjeta sale.
  /// El despacho es POR TARJETA (una orden puede tener varias rondas/áreas);
  /// el sello por-orden (`kitchen_done_at`) solo se dispara cuando la orden
  /// completa terminó, para sacarla de `kds_open_orders`.
  ///
  /// Además, en modo "sale al pagar" la fuente (`kds_active_items`) excluye
  /// lo pagado, así que cobrar también saca la tarjeta (semántica del modo).
  List<KitchenOrder> _activeOrders(
    List<KitchenItem> items,
    bool completeOnPayment,
  ) {
    // Clave de tarjeta = orden + ronda (kitchen_sent_at) + ÁREA de producción.
    // Cada envío a cocina forma su ronda, y dentro de la ronda cada área
    // (Cocina, Bar, ...) es su PROPIA tarjeta, para que la estación vea solo lo
    // suyo (burrito→Cocina y agua→Bar no se mezclan). El área ya viene resuelta
    // desde el N:M en el repositorio; los ítems sin área caen en '__none__'
    // (una tarjeta "Sin área" que delata productos sin configurar).
    final map = <String, List<KitchenItem>>{};
    for (final item in items) {
      map.putIfAbsent(kitchenCardKey(item), () => []).add(item);
    }

    final orders = <KitchenOrder>[];
    for (final entry in map.entries) {
      final list = entry.value;
      final hasOpen = list.any((i) {
        if (i.status == 'pending' || i.status == 'preparing') return true;
        // Ítem marcado listo por el chef (bump = 'ready') pero AÚN sin
        // despachar: mantiene la comanda visible EN AMBOS MODOS (marcar todos
        // los círculos es solo progreso). Al despachar con "Marcar todo listo"
        // pasan a 'served' → dejan de contar → la comanda sale del tablero de
        // forma PERSISTENTE (sobrevive recargas; no reaparece con otra ronda).
        if (i.status == 'ready') return true;
        if (!completeOnPayment) {
          // Modo "esperar al cocinero": ítem pagado sin cocinar (paid +
          // ready_at null) sigue por cocinar, así que la comanda debe
          // permanecer hasta que la cocina la despache.
          if (i.status == 'paid' && i.readyAt == null) return true;
        }
        // Lo demás ('served' despachado; 'paid' ya cocinado) no la mantiene.
        return false;
      });
      // Sin ítems que la mantengan (todo 'served'/despachado, o cocinado+pagado)
      // → fuera del tablero.
      if (!hasOpen) continue;

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
          orderId: first.orderId,
          roundKey: entry.key,
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
              style: TextStyle(fontSize: 13, color: AppColors.mutedForeground),
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
                          key: ValueKey(order.roundKey),
                          order: order,
                          onBumpItem: (itemId) {
                            // ¿Este círculo completa la tarjeta? Se evalúa
                            // con el snapshot PREVIO al bump: todos los demás
                            // ítems ya estaban hechos.
                            final completesCard = order.items.every(
                              (i) => i.id == itemId || _itemDoneForCard(i),
                            );
                            ref
                                .read(kitchenViewModelProvider)
                                .markReady(itemId);
                            if (completesCard) {
                              _offerPrintReadyTicket(order);
                            }
                          },
                          onCompleteOrder: (orderId) async {
                            // Completa SOLO los ítems de esta ronda/tarjeta.
                            final notice = await ref
                                .read(kitchenViewModelProvider)
                                .markOrderReady(
                                  orderId,
                                  itemIds: order.items
                                      .map((i) => i.id)
                                      .toList(growable: false),
                                );
                            if (notice != null && context.mounted) {
                              ScaffoldMessenger.of(context)
                                ..hideCurrentSnackBar()
                                ..showAppSnackBar(
                                  SnackBar(
                                    content: Text(notice),
                                    duration: const Duration(seconds: 6),
                                  ),
                                );
                            }
                          },
                          onReprint: () => _reprintComanda(order),
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
            const Text('Área', style: TextStyle(fontWeight: FontWeight.w600)),
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
              child: Icon(icon, color: color, size: isMobile ? 18 : 24),
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
    // (día local de RD). Filtros y orden viven en el diálogo (snapshot local).
    final areasByCode = <String, String>{};
    for (final item in completedItems) {
      final code = item.areaCode?.trim() ?? '';
      if (code.isEmpty) continue;
      final name = item.areaName?.trim();
      areasByCode[code] = (name == null || name.isEmpty) ? code : name;
    }
    final areaEntries = areasByCode.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    final totalOrders = _groupOrdersFromItems(completedItems).length;

    var search = '';
    String? areaFilter; // null = todas las áreas
    var takeoutOnly = false;

    // Hora que se muestra y por la que ordena el historial: el DESPACHO de la
    // comanda (ver `kitchenDispatchedAt`), no el último plato bumpeado.
    DateTime completedAtOf(KitchenOrder order) =>
        kitchenDispatchedAt(order.items);

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          // Área y "Para llevar" filtran por ÍTEM (una orden puede mezclar
          // áreas); el texto busca a nivel de comanda (orden, mesa, mesero o
          // producto). Las más recientes van arriba.
          var filteredItems = completedItems;
          if (areaFilter != null) {
            filteredItems = filteredItems
                .where((i) => (i.areaCode?.trim() ?? '') == areaFilter)
                .toList(growable: false);
          }
          if (takeoutOnly) {
            filteredItems = filteredItems
                .where((i) => i.isTakeout)
                .toList(growable: false);
          }
          var orders = _groupOrdersFromItems(filteredItems);
          final q = search.trim().toLowerCase();
          if (q.isNotEmpty) {
            orders = orders
                .where((o) {
                  return o.orderNumber.toLowerCase().contains(q) ||
                      o.orderId.toLowerCase().startsWith(q) ||
                      (o.tableName ?? '').toLowerCase().contains(q) ||
                      (o.waiterName ?? '').toLowerCase().contains(q) ||
                      o.items.any(
                        (i) => i.productName.toLowerCase().contains(q),
                      );
                })
                .toList(growable: false);
          }
          orders.sort((a, b) => completedAtOf(b).compareTo(completedAtOf(a)));

          final hasFilters = q.isNotEmpty || areaFilter != null || takeoutOnly;

          return Dialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
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
                                hasFilters
                                    ? '${orders.length} de $totalOrders comandas · recientes primero'
                                    : '$totalOrders comandas completadas en el día · recientes primero',
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
                    const SizedBox(height: 16),
                    // Búsqueda por texto.
                    SizedBox(
                      height: 44,
                      child: TextField(
                        onChanged: (v) => setDialogState(() => search = v),
                        style: MangoTokens.body(),
                        decoration: InputDecoration(
                          hintText:
                              'Buscar por orden, mesa, mesero o producto…',
                          hintStyle: MangoTokens.body(
                            color: MangoTokens.mutedForeground,
                          ),
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            size: 20,
                            color: MangoTokens.mutedForeground,
                          ),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(
                              color: MangoTokens.border,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(
                              color: MangoTokens.primary,
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Filtros por área + para llevar (solo si aportan algo).
                    if (areaEntries.isNotEmpty ||
                        completedItems.any((i) => i.isTakeout)) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (areaEntries.isNotEmpty) ...[
                            _CompletedFilterPill(
                              label: 'Todas',
                              selected: areaFilter == null,
                              onTap: () =>
                                  setDialogState(() => areaFilter = null),
                            ),
                            for (final entry in areaEntries)
                              _CompletedFilterPill(
                                label: entry.value,
                                selected: areaFilter == entry.key,
                                onTap: () => setDialogState(
                                  () => areaFilter = entry.key,
                                ),
                              ),
                          ],
                          if (completedItems.any((i) => i.isTakeout))
                            _CompletedFilterPill(
                              label: 'Para llevar',
                              icon: Icons.shopping_bag_outlined,
                              selected: takeoutOnly,
                              onTap: () => setDialogState(
                                () => takeoutOnly = !takeoutOnly,
                              ),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 16),
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
                                      hasFilters
                                          ? 'Ninguna comanda coincide con los filtros.'
                                          : 'No hay comandas completadas hoy.',
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
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 12),
                              itemBuilder: (context, index) {
                                final order = orders[index];
                                final completedAt = completedAtOf(order);
                                return _completedOrderCard(order, completedAt);
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
          );
        },
      ),
    );
  }

  /// Reimprime la comanda de una tarjeta (viva o completada) y muestra el
  /// resultado en un snackbar. No toca estados ni crea rondas nuevas.
  Future<void> _reprintComanda(KitchenOrder order) async {
    // Tarjeta viva del tablero (roundKey seteado) = una sola estación: la
    // reimpresión debe salir SOLO por el área de esa tarjeta. Las comandas de
    // "Completados hoy" agrupan la orden completa (roundKey vacío) → todas.
    final cardAreaCode =
        order.roundKey.isEmpty ? null : order.items.first.areaCode;
    final notice = await ref.read(kitchenViewModelProvider).reprintComanda(
          orderId: order.orderId,
          itemIds: order.items.map((i) => i.id).toList(growable: false),
          areaCode: cardAreaCode,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showAppSnackBar(
        SnackBar(
          content: Text(notice ?? 'Comanda reimpresa.'),
          duration: const Duration(seconds: 4),
        ),
      );
  }

  /// Tarjeta de una comanda en el diálogo "Completados hoy".
  Widget _completedOrderCard(KitchenOrder order, DateTime completedAt) {
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
                    // Hora de ENVÍO de la comanda. La píldora de la derecha
                    // muestra el despacho; sin esta línea, dos comandas
                    // distintas de la misma mesa (mismos productos, minutos
                    // de diferencia) se ven idénticas y parecen una sola
                    // comanda partida en dos. Se omite en ítems sin marca de
                    // ronda (legacy / RPC sin `kitchen_sent_at`).
                    if (order.items.first.kitchenSentAt != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Enviada ${_formatClock(order.items.first.kitchenSentAt!.toLocal())}'
                        ' · Despachada ${_formatClock(completedAt.toLocal())}',
                        style: MangoTokens.label(),
                      ),
                    ],
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
                  _formatClock(completedAt.toLocal()),
                  style: MangoTokens.label(
                    color: MangoTokens.foreground,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 6),
              // Pedido del cliente: recuperar una comanda perdida sin
              // scrollear el historial — reimprimir directo desde aquí.
              IconButton(
                tooltip: 'Reimprimir comanda',
                onPressed: () => _reprintComanda(order),
                icon: const Icon(
                  Icons.print_outlined,
                  color: MangoTokens.primary,
                  size: 22,
                ),
                visualDensity: VisualDensity.compact,
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
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.productName,
                                style: MangoTokens.body().copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              // El plato se muestra CON sus modificadores
                              // (igual que en la comanda viva del tablero).
                              if (item.modifiers.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    item.modifiers
                                        .map((m) => m.name)
                                        .join(', '),
                                    style: MangoTokens.label(),
                                  ),
                                ),
                              if ((item.notes ?? '').trim().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    'Nota: ${item.notes!.trim()}',
                                    style: MangoTokens.label(
                                      color: MangoTokens.warning,
                                    ),
                                  ),
                                ),
                            ],
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
  }

  List<KitchenOrder> _groupOrdersFromItems(List<KitchenItem> items) {
    // Una fila por COMANDA, no por orden: si a la mesa le mandaron 4 platos y
    // luego 2 más, el historial muestra las dos comandas por separado igual
    // que el tablero. La clave es orden + ronda (`kitchen_sent_at`), SIN el
    // área: una comanda que se repartió entre cocina y bar sigue siendo una
    // sola comanda para el mesero, aunque el tablero la haya partido en dos
    // tarjetas. Ítems sin marca de ronda (legacy, o entrados por el camino
    // offline) caen juntos en la ronda 'legacy' de su orden — que es el
    // comportamiento anterior, agrupado por orden.
    final map = <String, List<KitchenItem>>{};
    for (final item in items) {
      final round = item.kitchenSentAt?.toIso8601String() ?? 'legacy';
      map.putIfAbsent('${item.orderId}::$round', () => []).add(item);
    }
    DateTime finishedAt(KitchenOrder order) => kitchenDispatchedAt(order.items);

    return map.entries.map((entry) {
      final list = entry.value;
      list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final first = list.first;
      return KitchenOrder(
        // El id real del ítem, NO `entry.key`: la clave del mapa ahora lleva
        // la ronda pegada y `orderId` lo usa la reimpresión para buscar la
        // orden. `roundKey` se deja vacío a propósito — en el historial la
        // reimpresión debe sacar TODAS las áreas de la comanda (ver
        // `_reprintOrder`), no solo la del primer ítem.
        orderId: first.orderId,
        orderNumber: first.orderNumber,
        tableName: first.tableName,
        waiterName: first.waiterName,
        createdAt: first.createdAt,
        items: list,
      );
      // La última comanda DESPACHADA sale de primera (descendente por hora de
      // salida del KDS, no por hora de creación).
    }).toList()..sort((a, b) => finishedAt(b).compareTo(finishedAt(a)));
  }
}

/// Pastilla de filtro del diálogo "Completados hoy" (área / Para llevar).
/// Seleccionada = fondo de marca con texto blanco; normal = borde sutil.
class _CompletedFilterPill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  const _CompletedFilterPill({
    required this.label,
    this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : MangoTokens.foreground;
    return Material(
      color: selected ? MangoTokens.primary : Colors.white,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: selected ? MangoTokens.primary : MangoTokens.border,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: fg),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: MangoTokens.label(
                  color: fg,
                ).copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
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
