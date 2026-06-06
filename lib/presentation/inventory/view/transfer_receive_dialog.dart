import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/core/utils/app_toast.dart';

import '../state/transfers_state.dart';
import '../viewmodel/transfers_viewmodel.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';

class TransferReceiveDialog extends ConsumerStatefulWidget {
  final StockTransfer transfer;
  const TransferReceiveDialog({super.key, required this.transfer});

  @override
  ConsumerState<TransferReceiveDialog> createState() =>
      _TransferReceiveDialogState();
}

class _TransferReceiveDialogState
    extends ConsumerState<TransferReceiveDialog> {
  bool _loading = true;
  bool _submitting = false;
  String? _errorMessage;
  List<StockTransferItem> _items = const [];

  /// transferItemId → cantidad recibida.
  final Map<String, double> _received = {};
  final Map<String, TextEditingController> _controllers = {};
  final TextEditingController _notesController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final items = await ref
          .read(transfersViewModelProvider)
          .loadItems(widget.transfer.id);
      if (!mounted) return;
      setState(() {
        _items = items;
        // Prellenar con quantity_sent (caso feliz: llegó todo).
        for (final item in items) {
          _received[item.id] = item.quantitySent;
          _controllers[item.id] = TextEditingController(
            text: item.quantitySent.toStringAsFixed(2),
          );
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = 'Error cargando ítems: $e';
      });
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _notesController.dispose();
    super.dispose();
  }

  double get _totalSent =>
      _items.fold(0.0, (acc, i) => acc + i.quantitySent);
  double get _totalReceived =>
      _received.values.fold(0.0, (a, b) => a + b);
  double get _totalVariance => _totalSent - _totalReceived;

  String? _validate() {
    if (_items.isEmpty) return 'Sin ítems en la transferencia';
    for (final item in _items) {
      final r = _received[item.id] ?? 0;
      if (r < 0) return '${item.itemName}: cantidad no puede ser negativa';
      if (r > item.quantitySent) {
        return '${item.itemName}: recibido (${r.toStringAsFixed(2)}) excede enviado (${item.quantitySent.toStringAsFixed(2)})';
      }
    }
    if (_totalVariance > 0 &&
        _notesController.text.trim().isEmpty) {
      return 'Hay merma — agrega una nota explicando la diferencia';
    }
    return null;
  }

  Future<void> _submit() async {
    final error = _validate();
    if (error != null) {
      setState(() => _errorMessage = error);
      return;
    }
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    final navigator = Navigator.of(context);
    try {
      final payload = _items
          .map(
            (i) => <String, dynamic>{
              'transfer_item_id': i.id,
              'quantity_received': _received[i.id] ?? 0,
            },
          )
          .toList(growable: false);
      await ref.read(transfersViewModelProvider).receiveTransfer(
            transferId: widget.transfer.id,
            receivedItems: payload,
            varianceNotes: _notesController.text.trim().isEmpty
                ? null
                : _notesController.text.trim(),
          );
      if (!mounted) return;
      navigator.pop();
      AppToast.info(
        context,
        'Transferencia ${widget.transfer.transferNumber} recibida'
        '${_totalVariance > 0 ? ' (merma: ${_totalVariance.toStringAsFixed(2)})' : ''}',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = _humanizeError(e.toString());
      });
    }
  }

  String _humanizeError(String raw) {
    if (raw.contains('INSUFFICIENT_ROLE')) {
      return 'No tienes permisos para recibir transferencias';
    }
    if (raw.contains('TRANSFER_NOT_PENDING')) {
      return 'La transferencia ya no está pendiente';
    }
    if (raw.contains('RECEIVED_EXCEEDS_SENT')) {
      return 'Cantidad recibida excede la enviada';
    }
    return 'Error: $raw';
  }

  @override
  Widget build(BuildContext context) {
    final variance = _totalVariance;
    final varianceColor = variance > 0
        ? Colors.red.shade700
        : (variance < 0 ? Colors.orange.shade700 : Colors.green.shade700);

    return AlertDialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      title: Text(
        'Recibir ${widget.transfer.transferNumber}',
        style: const TextStyle(fontSize: 18),
      ),
      content: SizedBox(
        width: 540,
        height: _loading ? 200 : 520,
        child: _loading
            ? Center(child: CircularProgressIndicator(color: AppColors.primary))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.local_shipping_outlined,
                          color: AppColors.mutedForeground,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${widget.transfer.fromWarehouseName} → ${widget.transfer.toWarehouseName}',
                            style: TextStyle(
                              color: AppColors.foreground,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Confirma la cantidad real recibida por ítem. Si recibiste '
                    'menos de lo enviado, se registrará automáticamente como '
                    'merma en tránsito.',
                    style: TextStyle(
                      color: AppColors.mutedForeground,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _items.length,
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        final received = _received[item.id] ?? 0;
                        final diff = item.quantitySent - received;
                        final exceeds = received > item.quantitySent;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.background,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: exceeds
                                  ? Colors.red.shade300
                                  : (diff > 0
                                      ? Colors.orange.shade300
                                      : AppColors.border),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.itemName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      'Enviado: ${item.quantitySent.toStringAsFixed(2)} ${item.unit}'
                                      '${diff > 0 ? '  ·  Falta: ${diff.toStringAsFixed(2)}' : ''}',
                                      style: TextStyle(
                                        color: diff > 0
                                            ? Colors.orange.shade700
                                            : AppColors.mutedForeground,
                                        fontSize: 12,
                                        fontWeight: diff > 0
                                            ? FontWeight.w600
                                            : FontWeight.normal,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(
                                width: 110,
                                child: TextField(
                                  controller: _controllers[item.id],
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  textAlign: TextAlign.right,
                                  decoration: InputDecoration(
                                    suffixText: item.unit,
                                    border: const OutlineInputBorder(),
                                    isDense: true,
                                    contentPadding:
                                        const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 8,
                                        ),
                                  ),
                                  onChanged: (text) {
                                    final v =
                                        double.tryParse(
                                          text.replaceAll(',', '.'),
                                        ) ??
                                        0;
                                    setState(() => _received[item.id] = v);
                                  },
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: varianceColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          variance == 0
                              ? Icons.check_circle_outline
                              : Icons.warning_amber_rounded,
                          color: varianceColor,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            variance == 0
                                ? 'Todo recibido completo'
                                : 'Merma total: ${variance.toStringAsFixed(2)} (enviado ${_totalSent.toStringAsFixed(2)} / recibido ${_totalReceived.toStringAsFixed(2)})',
                            style: TextStyle(
                              color: varianceColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _notesController,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: variance > 0
                          ? 'Notas sobre la merma (obligatorio)'
                          : 'Notas (opcional)',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.card),
                      ),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(color: Colors.red.shade700),
                      ),
                    ),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submitting || _loading ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Confirmar recepción'),
        ),
      ],
    );
  }
}
