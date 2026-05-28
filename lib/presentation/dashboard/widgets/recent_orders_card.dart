// Widget "Recent Orders" del dashboard. Tabla compacta con las últimas N
// órdenes del business (hora, cliente, ID, items, total, status). Cada
// fila es clickeable y enruta según `origin` + estado:
//   - dine_in activa (open/sent_to_kitchen/partially_paid) y con tableId
//     → /sales/table/:tableId?code=…&zone=… (la mesa abre con su sesión).
//   - dine_in cerrada (paid/void) o cualquier otro origin → /cashier/history
//     (lista universal de órdenes recientes con filtros).
//
// Datos vienen del provider `dashboardRecentOrdersProvider(limit)`. El
// total respeta el `BusinessCurrency` configurado (no hardcoded RD$).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/router/routes.dart';
import '../../../core/currency/business_currency_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/dashboard_models.dart';
import '../providers/dashboard_providers.dart';
import 'dashboard_card_frame.dart';

class RecentOrdersCard extends ConsumerWidget {
  /// Cantidad de órdenes a mostrar. Default 10.
  final int limit;

  const RecentOrdersCard({super.key, this.limit = 10});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncOrders = ref.watch(dashboardRecentOrdersProvider(limit));
    final currency = currentBusinessCurrencyOrFallback(ref);
    return DashboardCardFrame(
      title: 'Órdenes recientes',
      subtitle: '$limit órdenes',
      child: asyncOrders.when(
        loading: () => const _LoadingSkeleton(),
        error: (e, _) => DashboardErrorBox(
          message: 'No se pudo cargar las órdenes recientes.',
          onRetry: () => ref.invalidate(dashboardRecentOrdersProvider(limit)),
        ),
        data: (orders) {
          if (orders.isEmpty) {
            return const DashboardEmptyState(
              icon: Icons.receipt_long_outlined,
              message: 'Aún no hay órdenes registradas.',
            );
          }
          return _OrdersTable(orders: orders, currency: currency.formatter);
        },
      ),
    );
  }
}

class _OrdersTable extends StatelessWidget {
  final List<DashboardRecentOrder> orders;
  final NumberFormat currency;

  const _OrdersTable({required this.orders, required this.currency});

  @override
  Widget build(BuildContext context) {
    final timeFmt = DateFormat('HH:mm');
    return Column(
      children: [
        // Header
        const _RowFrame(
          children: [
            _HeaderCell('Hora', flex: 2),
            _HeaderCell('Cliente', flex: 3),
            _HeaderCell('Orden', flex: 2),
            _HeaderCell('Productos', flex: 4),
            _HeaderCell('Total', flex: 2, align: TextAlign.right),
            _HeaderCell('Estado', flex: 2, align: TextAlign.center),
          ],
        ),
        const Divider(height: 1, color: AppColors.border),
        for (final order in orders) ...[
          _OrderRow(
            order: order,
            timeFmt: timeFmt,
            currency: currency,
          ),
          const Divider(height: 1, color: AppColors.border),
        ],
      ],
    );
  }
}

class _OrderRow extends StatelessWidget {
  final DashboardRecentOrder order;
  final DateFormat timeFmt;
  final NumberFormat currency;

  const _OrderRow({
    required this.order,
    required this.timeFmt,
    required this.currency,
  });

  /// Cliente visible: nombre real → mesa → label de origen → "—".
  String _customerOrFallback() {
    final name = order.customerName;
    if (name != null && name.isNotEmpty) return name;
    final table = order.tableCode;
    if (table != null && table.isNotEmpty) return 'Mesa $table';
    return _originLabel(order.origin);
  }

  /// Si el fallback es origen genérico ("Para llevar", etc.) en vez de
  /// un nombre real → muteamos el texto para que el lector entienda
  /// que es un placeholder.
  bool _customerIsFallback() {
    final name = order.customerName;
    return name == null || name.isEmpty;
  }

  /// Destino del tap. Reglas en el doc del archivo.
  void _onTap(BuildContext context) {
    if (!order.isClosed &&
        order.origin == 'dine_in' &&
        order.tableId != null &&
        order.tableCode != null) {
      final qp = <String, String>{
        'code': order.tableCode!,
        if (order.zoneId != null) 'zone': order.zoneId!,
      };
      final uri = Uri(
        path: '${AppRoutes.salesTable}/${order.tableId}',
        queryParameters: qp,
      );
      context.go(uri.toString());
      return;
    }
    context.go(AppRoutes.cashierHistory);
  }

  @override
  Widget build(BuildContext context) {
    final customerText = _customerOrFallback();
    final customerMuted = _customerIsFallback();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _onTap(context),
        child: _RowFrame(
          children: [
            _Cell(timeFmt.format(order.createdAt.toLocal()), flex: 2),
            _Cell(
              customerText,
              flex: 3,
              muted: customerMuted,
            ),
            _Cell('#${order.orderNumber}',
                flex: 2, style: _orderNumberStyle),
            _Cell(
              order.itemsSummary ?? '—',
              flex: 4,
              maxLines: 1,
              muted: order.itemsSummary == null,
            ),
            _Cell(
              currency.format(order.total),
              flex: 2,
              align: TextAlign.right,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.foreground,
              ),
            ),
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.center,
                child: _StatusBadge(status: order.status),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Etiqueta human-readable del enum `order_origin`. Devuelve "—" si
/// el origen es null o desconocido — significa que la fila viene de
/// data legacy o un origin nuevo no mapeado.
String _originLabel(String? origin) {
  switch (origin) {
    case 'dine_in':
      return 'Mesa';
    case 'takeout':
      return 'Para llevar';
    case 'delivery':
      return 'Delivery';
    case 'quick':
    case 'quick_sale':
      return 'Venta rápida';
    case 'manual':
      return 'Venta manual';
    case 'self_service':
      return 'Self service';
    default:
      return '—';
  }
}

const TextStyle _orderNumberStyle = TextStyle(
  fontSize: 12,
  fontFamily: 'monospace',
  fontWeight: FontWeight.w600,
  color: AppColors.mutedForeground,
  fontFeatures: [FontFeature.tabularFigures()],
);

class _RowFrame extends StatelessWidget {
  final List<Widget> children;
  const _RowFrame({required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: children,
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  final String text;
  final int flex;
  final TextAlign align;
  const _HeaderCell(this.text,
      {required this.flex, this.align = TextAlign.left});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        textAlign: align,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppColors.mutedForeground,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  final String text;
  final int flex;
  final TextAlign align;
  final bool muted;
  final int maxLines;
  final TextStyle? style;

  const _Cell(
    this.text, {
    required this.flex,
    this.align = TextAlign.left,
    this.muted = false,
    this.maxLines = 1,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        textAlign: align,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: style ??
            TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: muted
                  ? AppColors.mutedForeground
                  : AppColors.foreground,
            ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final cfg = _configFor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: cfg.bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: cfg.fg,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            cfg.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: cfg.fg,
            ),
          ),
        ],
      ),
    );
  }

  /// Mapeo status → (label legible, colores). Single source de mapeo
  /// para mantener consistencia. El dashboard lee `orders.status_ext`
  /// (enum `order_status`), cuyos valores son:
  ///   open | sent_to_kitchen | partially_paid | paid | void
  /// Las variantes legacy del text status (`sent`, `served`, `canceled`)
  /// se mapean también por compatibilidad histórica.
  static _StatusBadgeConfig _configFor(String status) {
    switch (status) {
      case 'paid':
        return const _StatusBadgeConfig(
          label: 'Pagada',
          fg: Color(0xFF059669),
          bg: Color(0xFFD1FAE5),
        );
      case 'partially_paid':
        return const _StatusBadgeConfig(
          label: 'Pago parcial',
          fg: Color(0xFF2563EB),
          bg: Color(0xFFDBEAFE),
        );
      case 'sent_to_kitchen':
      case 'sent':
      case 'served':
        return const _StatusBadgeConfig(
          label: 'En cocina',
          fg: Color(0xFFD97706),
          bg: Color(0xFFFEF3C7),
        );
      case 'void':
      case 'canceled':
        return const _StatusBadgeConfig(
          label: 'Anulada',
          fg: Color(0xFFDC2626),
          bg: Color(0xFFFEE2E2),
        );
      case 'open':
        return const _StatusBadgeConfig(
          label: 'Abierta',
          fg: Color(0xFF6B7280),
          bg: Color(0xFFF3F4F6),
        );
      default:
        // Status nuevo no mapeado — caemos al neutro pero formateamos
        // (sin underscores, primera mayúscula) para que no salga como
        // "Sent_to_kitchen" si en el futuro agregan un valor al enum.
        final pretty = status
            .replaceAll('_', ' ')
            .split(' ')
            .where((w) => w.isNotEmpty)
            .map((w) => w[0].toUpperCase() + w.substring(1))
            .join(' ');
        return _StatusBadgeConfig(
          label: pretty.isEmpty ? status : pretty,
          fg: const Color(0xFF6B7280),
          bg: const Color(0xFFF3F4F6),
        );
    }
  }
}

class _StatusBadgeConfig {
  final String label;
  final Color fg;
  final Color bg;
  const _StatusBadgeConfig({
    required this.label,
    required this.fg,
    required this.bg,
  });
}

class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 5; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          Container(
            height: 18,
            color: AppColors.secondary,
          ),
        ],
      ],
    );
  }
}
