// Sprint 4 Inventario — Vista de recepciones directas.
//
// Lista las recepciones registradas (status received / cancelled) con
// header de totales, filtro por status, buscador (número de recepción,
// proveedor o bodega) y botón para crear una nueva.
// Tap en una card abre el detail dialog con el desglose de líneas.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/core/utils/app_toast.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../state/direct_receipts_state.dart';
import '../viewmodel/direct_receipts_viewmodel.dart';
import 'direct_receipt_dialog.dart';
import 'widgets/inventory_back_button.dart';

class InventoryDirectReceiptsView extends ConsumerStatefulWidget {
  const InventoryDirectReceiptsView({super.key});

  @override
  ConsumerState<InventoryDirectReceiptsView> createState() =>
      _InventoryDirectReceiptsViewState();
}

class _InventoryDirectReceiptsViewState
    extends ConsumerState<InventoryDirectReceiptsView> {
  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(directReceiptsViewModelProvider).init();
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Debounce para no disparar una consulta por tecla.
  void _onSearchChanged(String text) {
    setState(() {}); // refresca la X de limpiar
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      ref.read(directReceiptsViewModelProvider).applySearch(text);
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(directReceiptsViewModelProvider);
    final state = vm.state;

    return Scaffold(
      backgroundColor: AppColors.background,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: state.saving ? null : () => _openCreateDialog(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nueva recepción'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            count: state.receipts.length,
            onRefresh: state.loading ? null : () => vm.refresh(),
          ),
          _FiltersBar(
            currentFilter: state.statusFilter,
            onChanged: (s) => vm.applyStatusFilter(s),
            searchController: _searchCtrl,
            onSearchChanged: _onSearchChanged,
            onSearchCleared: () {
              _searchDebounce?.cancel();
              _searchCtrl.clear();
              setState(() {});
              vm.applySearch(null);
            },
          ),
          if (state.error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: Colors.red.shade50,
              child: Text(
                state.error!,
                style: TextStyle(color: Colors.red.shade700),
              ),
            ),
          Expanded(
            child: state.loading && state.receipts.isEmpty
                ? Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  )
                : state.receipts.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(40),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.move_to_inbox_outlined,
                            size: 56,
                            color: AppColors.mutedForeground,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            (state.statusFilter != null || state.hasSearch)
                                ? 'Sin recepciones que coincidan con el filtro o la búsqueda'
                                : 'Aún no hay recepciones directas',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppColors.foreground,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Usa el botón "Nueva recepción" para registrar mercancía '
                            'que entró sin OC formal.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.mutedForeground,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : _ReceiptsList(
                    receipts: state.receipts,
                    hasMore: state.hasMore,
                    loadingMore: state.loadingMore,
                    onLoadMore: () => vm.loadMore(),
                    onTap: (r) => _openDetail(r),
                    onCancel: (r) => _confirmCancel(r),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _openCreateDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const DirectReceiptDialog(),
    );
  }

  Future<void> _openDetail(DirectReceipt receipt) async {
    final items = await ref
        .read(directReceiptsViewModelProvider)
        .loadItems(receipt.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) =>
          _ReceiptDetailDialog(receipt: receipt.copyWith(items: items)),
    );
  }

  Future<void> _confirmCancel(DirectReceipt receipt) async {
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cancelar ${receipt.receiptNumber}'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Se revertirá el stock ingresado en ${receipt.warehouseName} '
                'mediante ajustes negativos. El header queda marcado como '
                'cancelado para auditoría.',
                style: TextStyle(color: AppColors.mutedForeground),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: reasonController,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Motivo (opcional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('No'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sí, cancelar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(directReceiptsViewModelProvider)
          .cancelReceipt(
            receiptId: receipt.id,
            reason: reasonController.text.trim().isEmpty
                ? null
                : reasonController.text.trim(),
          );
      if (!mounted) return;
      AppToast.info(context, '${receipt.receiptNumber} cancelada');
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Error: $e');
    }
  }
}

class _Header extends StatelessWidget {
  final int count;
  final VoidCallback? onRefresh;
  const _Header({required this.count, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: InventoryBackButton(),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Recepciones',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: AppColors.foreground,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Ingreso directo de mercancía sin orden de compra formal.',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.mutedForeground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$count recepción(es) mostradas',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          IconButton.filledTonal(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refrescar',
          ),
        ],
      ),
    );
  }
}

class _FiltersBar extends StatelessWidget {
  final String? currentFilter;
  final ValueChanged<String?> onChanged;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchCleared;

  const _FiltersBar({
    required this.currentFilter,
    required this.onChanged,
    required this.searchController,
    required this.onSearchChanged,
    required this.onSearchCleared,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 300,
            child: TextField(
              controller: searchController,
              decoration: InputDecoration(
                hintText: 'Buscar por número, proveedor o bodega…',
                border: const OutlineInputBorder(),
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        tooltip: 'Limpiar búsqueda',
                        onPressed: onSearchCleared,
                      ),
              ),
              onChanged: onSearchChanged,
            ),
          ),
          _Chip(
            label: 'Todas',
            selected: currentFilter == null,
            onTap: () => onChanged(null),
          ),
          _Chip(
            label: 'Recibidas',
            selected: currentFilter == 'received',
            color: const Color(0xFF059669),
            onTap: () => onChanged('received'),
          ),
          _Chip(
            label: 'Canceladas',
            selected: currentFilter == 'cancelled',
            color: const Color(0xFFDC2626),
            onTap: () => onChanged('cancelled'),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color? color;
  final VoidCallback onTap;
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final accent = color ?? AppColors.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.12) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? accent.withValues(alpha: 0.4) : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: selected ? accent : AppColors.foreground,
          ),
        ),
      ),
    );
  }
}

class _ReceiptsList extends StatelessWidget {
  final List<DirectReceipt> receipts;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback onLoadMore;
  final void Function(DirectReceipt) onTap;
  final void Function(DirectReceipt) onCancel;

  const _ReceiptsList({
    required this.receipts,
    required this.hasMore,
    required this.loadingMore,
    required this.onLoadMore,
    required this.onTap,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final showFooter = hasMore || loadingMore;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 88),
      itemCount: receipts.length + (showFooter ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == receipts.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: loadingMore
                  ? SizedBox(
                      height: 28,
                      width: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: AppColors.primary,
                      ),
                    )
                  : OutlinedButton.icon(
                      onPressed: onLoadMore,
                      icon: const Icon(Icons.expand_more_rounded, size: 18),
                      label: const Text('Cargar más'),
                    ),
            ),
          );
        }
        return _ReceiptCard(
          receipt: receipts[index],
          onTap: () => onTap(receipts[index]),
          onCancel: receipts[index].isCancellable
              ? () => onCancel(receipts[index])
              : null,
        );
      },
    );
  }
}

class _ReceiptCard extends StatelessWidget {
  final DirectReceipt receipt;
  final VoidCallback onTap;
  final VoidCallback? onCancel;
  const _ReceiptCard({
    required this.receipt,
    required this.onTap,
    this.onCancel,
  });

  Color _statusColor() {
    switch (receipt.status) {
      case DirectReceiptStatus.received:
        return const Color(0xFF059669);
      case DirectReceiptStatus.cancelled:
        return const Color(0xFFDC2626);
      case DirectReceiptStatus.unknown:
        return AppColors.mutedForeground;
    }
  }

  String _statusLabel() {
    switch (receipt.status) {
      case DirectReceiptStatus.received:
        return 'RECIBIDA';
      case DirectReceiptStatus.cancelled:
        return 'CANCELADA';
      case DirectReceiptStatus.unknown:
        return '—';
    }
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );
    final dateFmt = DateFormat('dd/MM/yyyy HH:mm');
    final statusColor = _statusColor();
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.cardElevated,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _statusLabel(),
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      receipt.receiptNumber,
                      style: TextStyle(
                        color: AppColors.foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    if (receipt.createdAt != null)
                      Text(
                        dateFmt.format(receipt.createdAt!.toLocal()),
                        style: TextStyle(
                          color: AppColors.mutedForeground,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.warehouse_outlined,
                      size: 14,
                      color: AppColors.mutedForeground,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      receipt.warehouseName,
                      style: TextStyle(
                        color: AppColors.foreground,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    if (receipt.supplierName != null &&
                        receipt.supplierName!.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      Icon(
                        Icons.local_shipping_outlined,
                        size: 14,
                        color: AppColors.mutedForeground,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          receipt.supplierName!,
                          style: TextStyle(
                            color: AppColors.mutedForeground,
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ] else
                      const Spacer(),
                    Text(
                      currency.format(receipt.total),
                      style: TextStyle(
                        color: AppColors.foreground,
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      Icons.inventory_2_outlined,
                      size: 13,
                      color: AppColors.mutedForeground,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${receipt.itemCount} ítem(s) · ${receipt.totalQuantity.toStringAsFixed(2)} unidad(es)',
                      style: TextStyle(
                        color: AppColors.mutedForeground,
                        fontSize: 12,
                      ),
                    ),
                    const Spacer(),
                    if (onCancel != null)
                      TextButton.icon(
                        onPressed: onCancel,
                        icon: const Icon(Icons.cancel_outlined, size: 16),
                        label: const Text('Cancelar'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red.shade600,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
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
}

class _ReceiptDetailDialog extends StatelessWidget {
  final DirectReceipt receipt;
  const _ReceiptDetailDialog({required this.receipt});

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );
    final qtyFmt = NumberFormat.decimalPattern('es_DO');
    return AlertDialog(
      title: Text(
        '${receipt.receiptNumber}  ·  ${receipt.warehouseName}',
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      content: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (receipt.supplierName != null &&
                receipt.supplierName!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'Proveedor: ${receipt.supplierName}',
                  style: TextStyle(color: AppColors.mutedForeground),
                ),
              ),
            if (receipt.createdByName != null)
              Text(
                'Registrado por: ${receipt.createdByName}',
                style: TextStyle(color: AppColors.mutedForeground),
              ),
            if (receipt.status == DirectReceiptStatus.cancelled)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Cancelada${receipt.cancelledByName != null ? ' por ${receipt.cancelledByName}' : ''}'
                  '${receipt.cancelReason != null ? ' — ${receipt.cancelReason}' : ''}',
                  style: const TextStyle(color: Color(0xFFDC2626)),
                ),
              ),
            if (receipt.notes != null && receipt.notes!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  receipt.notes!,
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ),
            const Divider(height: 16),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                child: Column(
                  children: receipt.items
                      .map(
                        (line) => Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.background,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      line.itemName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      '${qtyFmt.format(line.quantity)} ${line.unit}'
                                      '${line.unitCost != null ? '  ·  ${currency.format(line.unitCost)} c/u' : ''}',
                                      style: TextStyle(
                                        color: AppColors.mutedForeground,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                currency.format(line.lineTotal),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
            ),
            const Divider(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  'Total: ',
                  style: TextStyle(color: AppColors.mutedForeground),
                ),
                Text(
                  currency.format(receipt.total),
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: AppColors.foreground,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }
}
