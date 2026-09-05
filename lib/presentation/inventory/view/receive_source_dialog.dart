// "Recibir orden de compra": la puerta única para meter mercancía al almacén.
//
// Antes había dos caminos sin relación entre sí — la recepción manual vivía
// acá, en Recepciones, y recibir una OC había que ir a buscarla en Compras.
// Quien recibe no piensa en dos módulos: piensa "llegó mercancía". Este
// diálogo pregunta lo único que de verdad cambia, de dónde viene:
//
//   · Registro de compras → hay una OC registrada; se recibe contra ella y la
//     orden queda saldada. Emite conduce numerado.
//   · Compra manual       → entró sin OC (compra de contado, urgencia). Va por
//     la recepción directa de siempre.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/currency/business_currency_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../purchases/state/goods_receipt.dart';
import '../../purchases/state/purchases_state.dart';
import '../../purchases/utils/goods_receipt_printing.dart';
import '../../purchases/utils/purchase_status.dart';
import '../../purchases/view/goods_receipt_dialog.dart';
import '../../purchases/viewmodel/purchases_viewmodel.dart';
import 'direct_receipt_dialog.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

/// Abre el selector de origen. Devuelve `true` si entró mercancía (para que
/// la pantalla que lo abrió recargue su listado).
Future<bool> showReceiveSourceDialog(BuildContext context, WidgetRef ref) async {
  final source = await showDialog<_ReceiveSource>(
    context: context,
    builder: (_) => const _ReceiveSourceDialog(),
  );
  if (source == null || !context.mounted) return false;

  switch (source) {
    case _ReceiveSource.purchaseOrder:
      return showPurchaseOrderPicker(context, ref);
    case _ReceiveSource.manual:
      final receipt = await showDialog<GoodsReceipt>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const DirectReceiptDialog(),
      );
      if (receipt == null) return false;
      if (!context.mounted) return true;
      // Igual que al recibir contra una OC: el papel sale solo y después
      // queda en pantalla, con PDF y reimpresión a mano.
      await GoodsReceiptPrinting.printThermal(
        context,
        ref,
        receipt: receipt,
        fallbackOnScreen: false,
      );
      if (!context.mounted) return true;
      await showGoodsReceiptDialog(context, ref, receipt: receipt);
      return true;
  }
}

enum _ReceiveSource { purchaseOrder, manual }

class _ReceiveSourceDialog extends StatelessWidget {
  const _ReceiveSourceDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(
        'Recibir orden de compra',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '¿De dónde viene la mercancía?',
              style: TextStyle(fontSize: 13, color: AppColors.mutedForeground),
            ),
            const SizedBox(height: 14),
            _SourceCard(
              icon: Icons.receipt_long_rounded,
              title: 'Registro de compras',
              subtitle:
                  'Hay una orden de compra registrada. Se recibe contra ella, '
                  'la orden queda saldada y sale el conduce numerado.',
              onTap: () =>
                  Navigator.of(context).pop(_ReceiveSource.purchaseOrder),
            ),
            const SizedBox(height: 10),
            _SourceCard(
              icon: Icons.move_to_inbox_rounded,
              title: 'Compra manual',
              subtitle:
                  'Entró sin orden de compra previa (compra de contado, '
                  'urgencia). Se registra la mercancía directo al almacén.',
              onTap: () => Navigator.of(context).pop(_ReceiveSource.manual),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}

class _SourceCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SourceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 26, color: AppColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.mutedForeground,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: AppColors.mutedForeground,
            ),
          ],
        ),
      ),
    );
  }
}

/// Lista de órdenes pendientes de recibir. Al escoger una arranca el flujo
/// completo: cantidades → recepción → conduce impreso.
Future<bool> showPurchaseOrderPicker(
  BuildContext context,
  WidgetRef ref,
) async {
  final order = await showDialog<PurchaseOrderSummary>(
    context: context,
    builder: (_) => const _PurchaseOrderPickerDialog(),
  );
  if (order == null || !context.mounted) return false;
  return showPurchaseReceiveFlow(context, ref, order);
}

class _PurchaseOrderPickerDialog extends ConsumerStatefulWidget {
  const _PurchaseOrderPickerDialog();

  @override
  ConsumerState<_PurchaseOrderPickerDialog> createState() =>
      _PurchaseOrderPickerDialogState();
}

class _PurchaseOrderPickerDialogState
    extends ConsumerState<_PurchaseOrderPickerDialog> {
  static final _dateFormat = DateFormat('dd/MM/yyyy');

  bool _loading = true;
  String? _error;
  List<PurchaseOrderSummary> _orders = const [];
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final orders = await ref
          .read(purchasesViewModelProvider)
          .loadReceivableOrders();
      if (!mounted) return;
      setState(() {
        _orders = orders;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = FriendlyError.humanize('No se pudieron cargar las órdenes: $e');
        _loading = false;
      });
    }
  }

  List<PurchaseOrderSummary> get _filtered {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _orders;
    return _orders
        .where(
          (o) =>
              o.orderNumber.toLowerCase().contains(q) ||
              o.supplierName.toLowerCase().contains(q) ||
              o.invoiceNumber.toLowerCase().contains(q),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final currency = currentBusinessCurrencyOrFallback(ref);
    final orders = _filtered;

    return AlertDialog(
      title: const Text(
        'Elige la orden de compra',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      content: SizedBox(
        width: 600,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _searchCtrl,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded, size: 20),
                hintText: 'Buscar por número, proveedor o factura',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Color(0xFFB91C1C)),
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: _load,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('Reintentar'),
                          ),
                        ],
                      ),
                    )
                  : orders.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _orders.isEmpty
                              ? 'No hay órdenes de compra pendientes de '
                                    'recibir. Regístrala primero en '
                                    'Compras → Registro de Compras, o usa '
                                    '"Compra manual".'
                              : 'Ninguna orden coincide con la búsqueda.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.mutedForeground),
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: orders.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final order = orders[index];
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          title: Text(
                            order.orderNumber,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          subtitle: Text(
                            '${order.supplierName} · ${order.warehouseName}\n'
                            'Registrada ${_dateFormat.format(order.createdAt)}'
                            '${order.invoiceNumber.isEmpty ? "" : " · Factura ${order.invoiceNumber}"}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          isThreeLine: true,
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                currency.formatAmount(order.total),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                purchaseStatusLabel(order.status),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: purchaseStatusColor(order.status),
                                ),
                              ),
                            ],
                          ),
                          onTap: () => Navigator.of(context).pop(order),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}
