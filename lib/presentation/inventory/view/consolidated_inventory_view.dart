import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../state/consolidated_inventory_state.dart';
import '../viewmodel/consolidated_inventory_viewmodel.dart';

final _currency = NumberFormat.currency(
  locale: 'en_US',
  symbol: 'RD\$ ',
  decimalDigits: 2,
);

String _qty(double v) {
  if ((v - v.roundToDouble()).abs() < 0.001) return v.toStringAsFixed(0);
  if ((v * 10 - (v * 10).roundToDouble()).abs() < 0.001) {
    return v.toStringAsFixed(1);
  }
  return v.toStringAsFixed(2);
}

/// 🏬 Panel de inventario multisucursal ("almacén principal"): stock total de
/// cada producto en todas las sucursales del mismo dueño, con desglose por
/// sucursal. Solo lectura — el inventario de cada sucursal no se toca.
class ConsolidatedInventoryView extends ConsumerStatefulWidget {
  const ConsolidatedInventoryView({super.key});

  @override
  ConsumerState<ConsolidatedInventoryView> createState() =>
      _ConsolidatedInventoryViewState();
}

class _ConsolidatedInventoryViewState
    extends ConsumerState<ConsolidatedInventoryView> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(consolidatedInventoryViewModelProvider).init(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(consolidatedInventoryViewModelProvider);
    final state = vm.state;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () => context.go(AppRoutes.inventoryHome),
        ),
        title: const Text(
          'Inventario multisucursal',
          style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            onPressed: state.loading ? null : () => vm.refresh(),
            icon: const Icon(Icons.refresh, color: Colors.black87),
            tooltip: 'Actualizar',
          ),
        ],
      ),
      body: SafeArea(
        child: state.loading && state.products.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : state.error != null
                ? _ErrorView(message: state.error!, onRetry: () => vm.refresh())
                : _buildBody(context, state),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ConsolidatedInventoryState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: _SummaryHeader(state: state),
        ),
        if (state.branches.length < 2)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _InfoBanner(
              'Esta vista consolida el stock de tus sucursales (negocios del '
              'mismo dueño). Detecté ${state.branches.length} sucursal'
              '${state.branches.length == 1 ? '' : 'es'} con acceso; al tener '
              'más de una verás el desglose lado a lado.',
            ),
          ),
        Expanded(
          child: state.products.isEmpty
              ? const _EmptyView()
              : _StockTable(state: state),
        ),
      ],
    );
  }
}

class _SummaryHeader extends StatelessWidget {
  final ConsolidatedInventoryState state;
  const _SummaryHeader({required this.state});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _Chip(
          icon: Icons.store_mall_directory_outlined,
          label: '${state.branches.length} sucursales',
          color: AppColors.info,
        ),
        _Chip(
          icon: Icons.inventory_2_outlined,
          label: '${state.products.length} productos',
          color: AppColors.primary,
        ),
        _Chip(
          icon: Icons.payments_outlined,
          label: 'Valor total ${_currency.format(state.totalValue)}',
          color: AppColors.success,
        ),
        const Spacer(),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
          ),
          onPressed: () => context.go(AppRoutes.inventoryTransfers),
          icon: const Icon(Icons.swap_horiz, size: 18),
          label: const Text('Transferir entre sucursales'),
        ),
      ],
    );
  }
}

class _StockTable extends StatelessWidget {
  final ConsolidatedInventoryState state;
  const _StockTable({required this.state});

  @override
  Widget build(BuildContext context) {
    final branches = state.branches;
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: DataTable(
          headingRowColor: WidgetStateProperty.all(AppColors.muted),
          border: TableBorder.all(color: AppColors.border, width: 1),
          columnSpacing: 28,
          columns: [
            const DataColumn(label: _HeadText('Producto')),
            for (final b in branches)
              DataColumn(label: _HeadText(b.name), numeric: true),
            const DataColumn(label: _HeadText('Total'), numeric: true),
          ],
          rows: [
            for (final p in state.products)
              DataRow(
                cells: [
                  DataCell(_ProductCell(product: p)),
                  for (final b in branches)
                    DataCell(_QtyCell(product: p, businessId: b.businessId)),
                  DataCell(
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        _qty(p.totalQty),
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppColors.foreground,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ProductCell extends StatelessWidget {
  final ConsolidatedProduct product;
  const _ProductCell({required this.product});

  @override
  Widget build(BuildContext context) {
    final meta = <String>[
      if (product.sku != null) product.sku!,
      if (product.unit != null) product.unit!,
    ].join(' · ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Text(
            product.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.foreground,
            ),
          ),
        ),
        if (meta.isNotEmpty)
          Text(
            meta,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.mutedForeground,
            ),
          ),
      ],
    );
  }
}

class _QtyCell extends StatelessWidget {
  final ConsolidatedProduct product;
  final String businessId;
  const _QtyCell({required this.product, required this.businessId});

  @override
  Widget build(BuildContext context) {
    final qty = product.qtyFor(businessId);
    final low = product.isLowAt(businessId);
    return Align(
      alignment: Alignment.centerRight,
      child: Text(
        _qty(qty),
        style: TextStyle(
          fontWeight: low ? FontWeight.w800 : FontWeight.w500,
          color: low
              ? AppColors.destructive
              : (qty == 0 ? AppColors.mutedForeground : AppColors.foreground),
        ),
      ),
    );
  }
}

class _HeadText extends StatelessWidget {
  final String text;
  const _HeadText(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontWeight: FontWeight.w800,
        color: AppColors.foreground,
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _Chip({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  final String message;
  const _InfoBanner(this.message);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.info.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.info.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: AppColors.info),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12.5, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inventory_outlined, size: 48, color: AppColors.border),
          const SizedBox(height: 12),
          const Text(
            'Sin stock para consolidar',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Cuando haya existencias en tus sucursales aparecerán aquí.',
            style: TextStyle(fontSize: 13, color: AppColors.mutedForeground),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: AppColors.destructive),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.foreground),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Reintentar')),
          ],
        ),
      ),
    );
  }
}
