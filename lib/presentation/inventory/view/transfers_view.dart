import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/transfers_state.dart';
import '../viewmodel/transfers_viewmodel.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
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
    _tabController = TabController(length: 3, vsync: this);
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
    final pending = _filter(state.transfers, StockTransferStatus.sent);
    final received = _filter(state.transfers, StockTransferStatus.received);
    final cancelled = _filter(state.transfers, StockTransferStatus.cancelled);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Transferencias entre bodegas'),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.mutedForeground,
          indicatorColor: AppColors.primary,
          tabs: [
            Tab(text: 'Pendientes (${pending.length})'),
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
                        transfers: pending,
                        emptyText: 'No hay transferencias pendientes',
                        onTap: (t) => _openReceiveDialog(context, t),
                        onCancel: (t) => _confirmCancel(context, t),
                      ),
                      _TransferList(
                        transfers: received,
                        emptyText: 'Sin transferencias recibidas',
                        onTap: (t) => _showDetail(context, t),
                      ),
                      _TransferList(
                        transfers: cancelled,
                        emptyText: 'Sin transferencias canceladas',
                        onTap: (t) => _showDetail(context, t),
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

  Future<void> _confirmCancel(
    BuildContext context,
    StockTransfer transfer,
  ) async {
    final reasonController = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
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
      messenger.showSnackBar(
        SnackBar(content: Text('${transfer.transferNumber} cancelada')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
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
  final void Function(StockTransfer) onTap;
  final void Function(StockTransfer)? onCancel;

  const _TransferList({
    required this.transfers,
    required this.emptyText,
    required this.onTap,
    this.onCancel,
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
    return ListView.separated(
      padding: const EdgeInsets.all(24),
      itemCount: transfers.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final t = transfers[index];
        return _TransferCard(
          transfer: t,
          onTap: () => onTap(t),
          onCancel: onCancel == null ? null : () => onCancel!(t),
        );
      },
    );
  }
}

class _TransferCard extends StatelessWidget {
  final StockTransfer transfer;
  final VoidCallback onTap;
  final VoidCallback? onCancel;

  const _TransferCard({
    required this.transfer,
    required this.onTap,
    this.onCancel,
  });

  Color _statusColor() {
    switch (transfer.status) {
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
            boxShadow: AppShadows.soft,
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
                          'Desde',
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
                          'Hacia',
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
