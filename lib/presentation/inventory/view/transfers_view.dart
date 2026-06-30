import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/core/utils/app_toast.dart';

import '../../../services/session/session_controller.dart';
import '../state/transfers_state.dart';
import '../viewmodel/transfers_viewmodel.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import 'widgets/inventory_back_button.dart';
import 'transfer_send_dialog.dart';
import 'transfer_receive_dialog.dart';

class TransfersView extends ConsumerStatefulWidget {
  const TransfersView({super.key});

  @override
  ConsumerState<TransfersView> createState() => _TransfersViewState();
}

class _TransfersViewState extends ConsumerState<TransfersView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    // 4 tabs: pending_approval, en tránsito (sent), recibidas, canceladas.
    _tabController = TabController(length: 4, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(transfersViewModelProvider).init();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  List<StockTransfer> _filter(
    List<StockTransfer> all,
    StockTransferStatus status,
  ) {
    return all.where((t) => t.status == status).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(transfersViewModelProvider);
    final state = vm.state;
    final pendingApproval =
        _filter(state.transfers, StockTransferStatus.pendingApproval);
    final pending = _filter(state.transfers, StockTransferStatus.sent);
    final received = _filter(state.transfers, StockTransferStatus.received);
    final cancelled = _filter(state.transfers, StockTransferStatus.cancelled);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: const InventoryBackButton(),
        title: const Text('Transferencias entre bodegas'),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.mutedForeground,
          indicatorColor: AppColors.primary,
          isScrollable: true,
          tabs: [
            Tab(text: 'Por aprobar (${pendingApproval.length})'),
            Tab(text: 'En tránsito (${pending.length})'),
            Tab(text: 'Recibidas (${received.length})'),
            Tab(text: 'Canceladas (${cancelled.length})'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: state.loading ? null : () => vm.refresh(),
            tooltip: 'Refrescar',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: state.saving
            ? null
            : () => _openSendDialog(context),
        icon: const Icon(Icons.send_rounded),
        label: const Text('Nueva transferencia'),
      ),
      body: state.loading && state.transfers.isEmpty
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : Column(
              children: [
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
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _TransferList(
                        transfers: pendingApproval,
                        emptyText: 'No hay transferencias pendientes de aprobación',
                        activeBusinessId: state.businessId,
                        onTapPending: (t) => _showDetail(context, t),
                        onApprove: (t) => _confirmApprove(context, t),
                        onCancel: (t) => _confirmCancel(context, t),
                        hasMore: state.hasMore,
                        loadingMore: state.loadingMore,
                        onLoadMore: () => vm.loadMore(),
                      ),
                      _TransferList(
                        transfers: pending,
                        emptyText: 'No hay transferencias en tránsito',
                        activeBusinessId: state.businessId,
                        onTapPending: (t) {
                          // Solo el destinatario abre el receive dialog.
                          // El emisor solo ve el detalle.
                          final isSourceOnly =
                              t.isCrossBusiness &&
                              t.fromBusinessId == state.businessId &&
                              t.toBusinessId != state.businessId;
                          if (isSourceOnly) {
                            _showDetail(context, t);
                          } else {
                            _openReceiveDialog(context, t);
                          }
                        },
                        onCancel: (t) => _confirmCancel(context, t),
                        hasMore: state.hasMore,
                        loadingMore: state.loadingMore,
                        onLoadMore: () => vm.loadMore(),
                      ),
                      _TransferList(
                        transfers: received,
                        emptyText: 'Sin transferencias recibidas',
                        activeBusinessId: state.businessId,
                        onTapPending: (t) => _showDetail(context, t),
                        hasMore: state.hasMore,
                        loadingMore: state.loadingMore,
                        onLoadMore: () => vm.loadMore(),
                      ),
                      _TransferList(
                        transfers: cancelled,
                        emptyText: 'Sin transferencias canceladas',
                        activeBusinessId: state.businessId,
                        onTapPending: (t) => _showDetail(context, t),
                        hasMore: state.hasMore,
                        loadingMore: state.loadingMore,
                        onLoadMore: () => vm.loadMore(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _openSendDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const TransferSendDialog(),
    );
  }

  Future<void> _openReceiveDialog(
    BuildContext context,
    StockTransfer transfer,
  ) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => TransferReceiveDialog(transfer: transfer),
    );
  }

  Future<void> _confirmApprove(
    BuildContext context,
    StockTransfer transfer,
  ) async {
    // Validar permiso antes de mostrar el diálogo. El backend lo va a
    // re-validar, pero el feedback inmediato es mejor UX.
    final canApprove = ref
        .read(sessionProvider.notifier)
        .hasPermission('inventario.transferencias.aprobar');
    if (!canApprove) {
      AppToast.info(
        context,
        'No tienes permiso para aprobar transferencias.',
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Aprobar ${transfer.transferNumber}'),
        content: Text(
          'Al aprobarla, el stock se mueve desde ${transfer.fromWarehouseName} '
          'a IN_TRANSIT y queda lista para recibir en ${transfer.toWarehouseName}.',
          style: TextStyle(color: AppColors.mutedForeground),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.green.shade700,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sí, aprobar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(transfersViewModelProvider).approveTransfer(
            transferId: transfer.id,
          );
      if (!mounted) return;
      AppToast.info(context, '${transfer.transferNumber} aprobada');
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Error: $e');
    }
  }

  Future<void> _confirmCancel(
    BuildContext context,
    StockTransfer transfer,
  ) async {
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cancelar ${transfer.transferNumber}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'La mercancía en tránsito volverá a ${transfer.fromWarehouseName}.',
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
      await ref.read(transfersViewModelProvider).cancelTransfer(
            transferId: transfer.id,
            reason: reasonController.text.trim().isEmpty
                ? null
                : reasonController.text.trim(),
          );
      if (!mounted) return;
      AppToast.info(context, '${transfer.transferNumber} cancelada');
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Error: $e');
    }
  }

  Future<void> _showDetail(
    BuildContext context,
    StockTransfer transfer,
  ) async {
    final items = await ref
        .read(transfersViewModelProvider)
        .loadItems(transfer.id);
    if (!mounted) return;
    await showDialog<void>(
      context: this.context,
      builder: (ctx) => _TransferDetailDialog(
        transfer: transfer.copyWith(items: items),
      ),
    );
  }
}

class _TransferList extends StatelessWidget {
  final List<StockTransfer> transfers;
  final String emptyText;
  final void Function(StockTransfer) onTapPending;
  final void Function(StockTransfer)? onCancel;
  final void Function(StockTransfer)? onApprove;
  final String? activeBusinessId;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback onLoadMore;

  const _TransferList({
    required this.transfers,
    required this.emptyText,
    required this.onTapPending,
    required this.activeBusinessId,
    required this.hasMore,
    required this.loadingMore,
    required this.onLoadMore,
    this.onCancel,
    this.onApprove,
  });

  @override
  Widget build(BuildContext context) {
    if (transfers.isEmpty) {
      return Center(
        child: Text(
          emptyText,
          style: TextStyle(color: AppColors.mutedForeground, fontSize: 14),
        ),
      );
    }
    final showFooter = hasMore || loadingMore;
    return ListView.separated(
      padding: const EdgeInsets.all(24),
      itemCount: transfers.length + (showFooter ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (index == transfers.length) {
          return _LoadMoreFooter(
            loading: loadingMore,
            onPressed: loadingMore ? null : onLoadMore,
          );
        }
        final t = transfers[index];
        // En tab Pendientes, si la transfer es cross-business y el activo
        // es el destinatario (no el emisor), no se le permite cancelar.
        final isIncomingPending =
            t.isCrossBusiness &&
            activeBusinessId != null &&
            t.toBusinessId == activeBusinessId &&
            t.fromBusinessId != activeBusinessId;
        return _TransferCard(
          transfer: t,
          activeBusinessId: activeBusinessId,
          onTap: () => onTapPending(t),
          onCancel: (onCancel == null || isIncomingPending)
              ? null
              : () => onCancel!(t),
          onApprove: (onApprove == null ||
                  t.status != StockTransferStatus.pendingApproval)
              ? null
              : () => onApprove!(t),
        );
      },
    );
  }
}

class _LoadMoreFooter extends StatelessWidget {
  final bool loading;
  final VoidCallback? onPressed;

  const _LoadMoreFooter({required this.loading, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: loading
            ? SizedBox(
                height: 32,
                width: 32,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: AppColors.primary,
                ),
              )
            : OutlinedButton.icon(
                onPressed: onPressed,
                icon: const Icon(Icons.expand_more_rounded, size: 18),
                label: const Text('Cargar más'),
              ),
      ),
    );
  }
}

class _TransferCard extends StatelessWidget {
  final StockTransfer transfer;
  final VoidCallback onTap;
  final VoidCallback? onCancel;
  final VoidCallback? onApprove;
  final String? activeBusinessId;

  const _TransferCard({
    required this.transfer,
    required this.onTap,
    this.activeBusinessId,
    this.onCancel,
    this.onApprove,
  });

  /// El activo es el destinatario de una transferencia cross-business
  /// recibida desde otra sucursal.
  bool get _isIncoming =>
      transfer.isCrossBusiness &&
      activeBusinessId != null &&
      transfer.toBusinessId == activeBusinessId &&
      transfer.fromBusinessId != activeBusinessId;

  Color _statusColor() {
    switch (transfer.status) {
      case StockTransferStatus.pendingApproval:
        return Colors.amber.shade800;
      case StockTransferStatus.sent:
        return Colors.orange.shade700;
      case StockTransferStatus.received:
        return Colors.green.shade700;
      case StockTransferStatus.cancelled:
        return Colors.grey;
      case StockTransferStatus.unknown:
        return AppColors.mutedForeground;
    }
  }

  String _statusLabel() {
    switch (transfer.status) {
      case StockTransferStatus.pendingApproval:
        return 'POR APROBAR';
      case StockTransferStatus.sent:
        return 'EN TRÁNSITO';
      case StockTransferStatus.received:
        return 'RECIBIDA';
      case StockTransferStatus.cancelled:
        return 'CANCELADA';
      case StockTransferStatus.unknown:
        return '—';
    }
  }

  String _date() {
    final d = transfer.sentAt;
    if (d == null) return '';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _statusColor();
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.border),
            boxShadow: AppShadows.cardElevated,
          ),
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
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                  if (transfer.isCrossBusiness) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isIncoming
                                ? Icons.south_east_rounded
                                : Icons.north_east_rounded,
                            size: 12,
                            color: AppColors.primary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _isIncoming ? 'ENTRANTE' : 'INTER-SUCURSAL',
                            style: TextStyle(
                              color: AppColors.primary,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  Text(
                    transfer.transferNumber,
                    style: TextStyle(
                      color: AppColors.foreground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _date(),
                    style: TextStyle(
                      color: AppColors.mutedForeground,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          transfer.isCrossBusiness
                              ? 'Desde · ${transfer.fromBusinessName ?? "Otra sucursal"}'
                              : 'Desde',
                          style: TextStyle(
                            color: AppColors.mutedForeground,
                            fontSize: 11,
                          ),
                        ),
                        Text(
                          transfer.fromWarehouseName,
                          style: TextStyle(
                            color: AppColors.foreground,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward_rounded,
                    color: AppColors.mutedForeground,
                    size: 18,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          transfer.isCrossBusiness
                              ? 'Hacia · ${transfer.toBusinessName ?? "Otra sucursal"}'
                              : 'Hacia',
                          style: TextStyle(
                            color: AppColors.mutedForeground,
                            fontSize: 11,
                          ),
                        ),
                        Text(
                          transfer.toWarehouseName,
                          style: TextStyle(
                            color: AppColors.foreground,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.inventory_2_outlined,
                    size: 14,
                    color: AppColors.mutedForeground,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${transfer.itemCount} ítem(s) · ${transfer.totalSent.toStringAsFixed(2)} enviado',
                    style: TextStyle(
                      color: AppColors.mutedForeground,
                      fontSize: 12,
                    ),
                  ),
                  if (transfer.hasVariance) ...[
                    const SizedBox(width: 10),
                    Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.red.shade600,
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Merma: ${(transfer.totalSent - transfer.totalReceived).toStringAsFixed(2)}',
                      style: TextStyle(
                        color: Colors.red.shade700,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (onApprove != null)
                    FilledButton.icon(
                      onPressed: onApprove,
                      icon: const Icon(Icons.check_circle_outline, size: 16),
                      label: const Text('Aprobar'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                    ),
                  if (onApprove != null && onCancel != null)
                    const SizedBox(width: 8),
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
    );
  }
}

class _TransferDetailDialog extends StatelessWidget {
  final StockTransfer transfer;
  const _TransferDetailDialog({required this.transfer});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      title: Text(
        '${transfer.transferNumber}  ·  ${transfer.fromWarehouseName} → ${transfer.toWarehouseName}',
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (transfer.notes != null && transfer.notes!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  transfer.notes!,
                  style: TextStyle(color: AppColors.mutedForeground),
                ),
              ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                child: Column(
                  children: transfer.items
                      .map(
                        (i) => Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          margin: const EdgeInsets.only(bottom: 6),
                          decoration: BoxDecoration(
                            color: AppColors.background,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      i.itemName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      'Enviado: ${i.quantitySent.toStringAsFixed(2)} ${i.unit}'
                                      '${i.quantityReceived != null ? '  ·  Recibido: ${i.quantityReceived!.toStringAsFixed(2)}' : ''}',
                                      style: TextStyle(
                                        color: AppColors.mutedForeground,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (i.varianceReason != null)
                                Icon(
                                  Icons.warning_amber_rounded,
                                  color: Colors.red.shade600,
                                  size: 18,
                                ),
                            ],
                          ),
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
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
