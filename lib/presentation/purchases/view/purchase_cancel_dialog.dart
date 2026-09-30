// Anular una compra registrada.
//
// Antes de pedir la confirmación, el diálogo le pregunta al servidor qué va a
// pasar (vista previa de `fn_purchase_order_cancel`, sin escribir nada): qué
// se devuelve de cada almacén, qué insumos quedan en negativo porque ya se
// vendieron, cuántos conduces se anulan y qué pasa con la cuenta por pagar.
// Anular mueve inventario y deuda: nadie debería confirmarlo a ciegas.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/currency/business_currency.dart';
import '../../../core/currency/business_currency_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/utils/friendly_error.dart';
import '../state/purchases_state.dart';
import '../viewmodel/purchases_viewmodel.dart';

/// Abre el diálogo de anulación. Devuelve lo que hizo el servidor, o `null`
/// si se cerró sin anular.
Future<PurchaseOrderCancelResult?> showPurchaseCancelDialog(
  BuildContext context, {
  required PurchaseOrderSummary order,
}) {
  return showDialog<PurchaseOrderCancelResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PurchaseCancelDialog(order: order),
  );
}

/// Motivos frecuentes: un toque llena el campo (se puede editar después).
const kPurchaseCancelReasons = <String>[
  'Factura registrada dos veces',
  'Registrada por error',
  'Mercancía devuelta al proveedor',
  'Compra de otro local',
];

class PurchaseCancelDialog extends ConsumerStatefulWidget {
  const PurchaseCancelDialog({super.key, required this.order});

  final PurchaseOrderSummary order;

  @override
  ConsumerState<PurchaseCancelDialog> createState() =>
      _PurchaseCancelDialogState();
}

class _PurchaseCancelDialogState extends ConsumerState<PurchaseCancelDialog> {
  final _reasonCtrl = TextEditingController();

  /// Una llave por diálogo: si la red se cae y se reintenta, el servidor
  /// reconoce que es la misma anulación.
  final String _key = const Uuid().v4();

  PurchaseOrderCancelPreview? _preview;
  String? _loadError;
  String? _submitError;
  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _reasonCtrl.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPreview());
  }

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPreview() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final preview = await ref
          .read(purchasesViewModelProvider)
          .previewCancelPurchaseOrder(widget.order.id);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = FriendlyError.humanize('$e');
        _loading = false;
      });
    }
  }

  bool get _reasonValid => _reasonCtrl.text.trim().length >= 3;

  bool get _canSubmit {
    final preview = _preview;
    return !_submitting &&
        preview != null &&
        !preview.blocked &&
        !preview.alreadyCancelled &&
        _reasonValid;
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      final result = await ref
          .read(purchasesViewModelProvider)
          .cancelPurchaseOrder(
            orderId: widget.order.id,
            reason: _reasonCtrl.text.trim(),
            idempotencyKey: _key,
          );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = FriendlyError.humanize('$e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final currency = currentBusinessCurrencyOrFallback(ref);
    return AlertDialog(
      title: Text('Anular compra ${widget.order.orderNumber}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(child: _body(currency)),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
        FilledButton.icon(
          key: const Key('purchase-cancel-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.destructive,
            foregroundColor: Colors.white,
          ),
          onPressed: _canSubmit ? _submit : null,
          icon: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.block, size: 18),
          label: const Text('Anular compra'),
        ),
      ],
    );
  }

  Widget _body(BusinessCurrency currency) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final loadError = _loadError;
    if (loadError != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _notice(
            color: AppColors.destructive,
            icon: Icons.error_outline,
            text: loadError,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _loadPreview,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Reintentar'),
          ),
        ],
      );
    }
    final preview = _preview!;
    if (preview.alreadyCancelled) {
      return _notice(
        color: AppColors.info,
        icon: Icons.info_outline,
        text: 'Esta compra ya está anulada.',
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'La compra quedará como «Cancelada» y no se puede deshacer. '
          'Las líneas y los conduces se conservan como registro.',
          style: TextStyle(fontSize: 13, color: AppColors.mutedForeground),
        ),
        const SizedBox(height: 16),
        _sectionTitle('Se devuelve del inventario'),
        const SizedBox(height: 8),
        if (preview.lines.isEmpty)
          Text(
            'Esta compra no metió mercancía al inventario: el stock no se '
            'mueve.',
            style: TextStyle(fontSize: 13, color: AppColors.foreground),
          )
        else
          for (final line in preview.lines) _LineTile(line: line),
        if (preview.negativeItems > 0) ...[
          const SizedBox(height: 10),
          _notice(
            color: AppColors.warning,
            icon: Icons.warning_amber_rounded,
            text:
                '${preview.negativeItems == 1 ? 'Un insumo quedará' : '${preview.negativeItems} insumos quedarán'} '
                'en negativo: esa mercancía ya se vendió o se consumió. Se '
                'anula igual; corrige la existencia con un conteo si hace '
                'falta.',
          ),
        ],
        if (preview.receptionsToCancel > 0) ...[
          const SizedBox(height: 10),
          Text(
            preview.receptionsToCancel == 1
                ? 'Se anula 1 conduce de recepción.'
                : 'Se anulan ${preview.receptionsToCancel} conduces de '
                      'recepción.',
            style: TextStyle(fontSize: 13, color: AppColors.foreground),
          ),
        ],
        if (preview.blocked) ...[
          const SizedBox(height: 12),
          _notice(
            color: AppColors.destructive,
            icon: Icons.lock_outline,
            text:
                'No se puede anular: la cuenta por pagar de esta compra ya '
                'tiene abonos por ${currency.formatAmount(preview.payablePaid)}. '
                'Resuélvela en Créditos → Cuentas por Pagar primero.',
          ),
        ] else if (preview.hasPayable) ...[
          const SizedBox(height: 10),
          Text(
            'La cuenta por pagar de '
            '${currency.formatAmount(preview.payableAmount)} se cancela.',
            style: TextStyle(fontSize: 13, color: AppColors.foreground),
          ),
        ],
        if (!preview.blocked) ...[
          const SizedBox(height: 18),
          _sectionTitle('Motivo'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final reason in kPurchaseCancelReasons)
                ActionChip(
                  label: Text(reason, style: const TextStyle(fontSize: 12)),
                  onPressed: _submitting
                      ? null
                      : () {
                          _reasonCtrl.text = reason;
                          _reasonCtrl.selection = TextSelection.collapsed(
                            offset: reason.length,
                          );
                        },
                ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('purchase-cancel-reason'),
            controller: _reasonCtrl,
            enabled: !_submitting,
            maxLength: 300,
            maxLines: 2,
            minLines: 1,
            decoration: const InputDecoration(
              labelText: 'Motivo de la anulación (obligatorio)',
              border: OutlineInputBorder(),
            ),
          ),
        ],
        if (_submitError != null) ...[
          const SizedBox(height: 8),
          _notice(
            color: AppColors.destructive,
            icon: Icons.error_outline,
            text: _submitError!,
          ),
        ],
      ],
    );
  }

  Widget _sectionTitle(String text) => Text(
    text,
    style: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w700,
      color: AppColors.foreground,
    ),
  );

  Widget _notice({
    required Color color,
    required IconData icon,
    required String text,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: AppColors.foreground),
            ),
          ),
        ],
      ),
    );
  }
}

/// Cantidad sin ceros de relleno: 12 → «12», 1.5 → «1.5», 0.125 → «0.13».
String formatCancelQty(double value) {
  final fixed = value.toStringAsFixed(2);
  return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
}

class _LineTile extends StatelessWidget {
  const _LineTile({required this.line});

  final PurchaseCancelLine line;

  @override
  Widget build(BuildContext context) {
    final unit = line.unit.isEmpty ? '' : ' ${line.unit}';
    final negative = line.goesNegative;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.itemName,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.foreground,
                  ),
                ),
                Text(
                  '${line.warehouseName} · existencia '
                  '${formatCancelQty(line.stockBefore)} → '
                  '${formatCancelQty(line.stockAfter)}$unit',
                  style: TextStyle(
                    fontSize: 12,
                    color: negative
                        ? AppColors.destructive
                        : AppColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '−${formatCancelQty(line.quantity)}$unit',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.foreground,
            ),
          ),
        ],
      ),
    );
  }
}
