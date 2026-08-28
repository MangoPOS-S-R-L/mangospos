// Detalle de UNA factura de compra.
//
// El listado de Compras solo mostraba el total de cada orden: para revisar
// una factura contra el papel del proveedor —qué productos entraron, a qué
// costo, con cuánto ITBIS y cuánto descuento— había que ir a la base de
// datos. Esta pantalla abre la orden completa: cabecera, líneas y desglose.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/router/routes.dart';
import '../../../core/currency/business_currency.dart';
import '../../../core/currency/business_currency_provider.dart';
import '../../../core/inventory/pack_conversion.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../services/session/session_controller.dart';
import '../state/goods_receipt.dart';
import '../state/purchases_state.dart';
import '../utils/purchase_status.dart';
import '../viewmodel/purchases_viewmodel.dart';
import '../utils/goods_receipt_printing.dart';
import 'goods_receipt_dialog.dart';

class PurchaseOrderDetailView extends ConsumerStatefulWidget {
  final String orderId;

  const PurchaseOrderDetailView({super.key, required this.orderId});

  @override
  ConsumerState<PurchaseOrderDetailView> createState() =>
      _PurchaseOrderDetailViewState();
}

class _PurchaseOrderDetailViewState
    extends ConsumerState<PurchaseOrderDetailView> {
  static final _dateFormat = DateFormat('dd/MM/yyyy');

  bool _loading = true;
  String? _error;
  PurchaseOrderDetail? _detail;

  /// Conduces emitidos por esta orden. Una OC recibida en tres viajes tiene
  /// tres conduces, y cada uno se reimprime por separado.
  List<GoodsReceipt> _receipts = const [];
  bool _loadingReceipts = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await ref
          .read(purchasesViewModelProvider)
          .loadOrderDetail(widget.orderId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
      await _loadReceipts();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'No se pudo cargar la factura: $e';
        _loading = false;
      });
    }
  }

  void _goBack() {
    // La pantalla se abre con `context.go` desde el listado, que REEMPLAZA el
    // stack: sin este fallback el botón de atrás no tendría a dónde volver.
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.purchasesList);
    }
  }

  /// Best-effort: la orden se ve igual sin la lista de conduces (un servidor
  /// sin la migración simplemente no tiene ninguno), así que un fallo acá no
  /// puede tumbar el detalle.
  Future<void> _loadReceipts() async {
    if (!mounted) return;
    setState(() => _loadingReceipts = true);
    try {
      final receipts = await ref
          .read(purchasesViewModelProvider)
          .loadGoodsReceiptsForOrder(widget.orderId);
      if (!mounted) return;
      setState(() {
        _receipts = receipts;
        _loadingReceipts = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _receipts = const [];
        _loadingReceipts = false;
      });
    }
  }

  Future<void> _openReceiveDialog(PurchaseOrderSummary order) async {
    await showPurchaseReceiveFlow(context, ref, order);
    if (!mounted) return;
    // La recepción cambia cantidades y estado: el detalle se relee para no
    // quedar mostrando lo de antes.
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final currency = currentBusinessCurrencyOrFallback(ref);
    final detail = _detail;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 860;
          return SingleChildScrollView(
            padding: EdgeInsets.all(wide ? 24 : 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(detail, wide),
                const SizedBox(height: 20),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 64),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_error != null)
                  _errorCard(_error!)
                else if (detail != null) ...[
                  _metaCard(detail, currency, wide),
                  const SizedBox(height: 16),
                  _linesCard(detail, currency, wide),
                  const SizedBox(height: 16),
                  _totalsCard(detail, currency, wide),
                  if (_receipts.isNotEmpty || _loadingReceipts) ...[
                    const SizedBox(height: 16),
                    _receiptsCard(currency),
                  ],
                  if (detail.order.notes.trim().isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _notesCard(detail.order),
                  ],
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  // ── Encabezado ───────────────────────────────────────────────────────────

  Widget _header(PurchaseOrderDetail? detail, bool wide) {
    final order = detail?.order;
    final sessionCtrl = ref.watch(sessionProvider.notifier);
    final canReceive = sessionCtrl.hasPermission('compras.ordenes.recibir');
    final receivable =
        order != null &&
        order.status != 'received' &&
        order.status != 'cancelled';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconButton(
          onPressed: _goBack,
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Volver a Compras',
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                order == null ? 'Factura de compra' : order.orderNumber,
                style: TextStyle(
                  fontSize: wide ? 28 : 22,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                order == null
                    ? 'Detalle de la orden'
                    : '${order.supplierName} · ${_invoiceCaption(order)}',
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
        if (order != null) ...[
          const SizedBox(width: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              IconButton.filledTonal(
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh),
                tooltip: 'Actualizar',
              ),
              if (canReceive && receivable)
                FilledButton.icon(
                  onPressed: () => _openReceiveDialog(order),
                  icon: const Icon(Icons.inventory_2_outlined),
                  label: Text(
                    order.status == 'partial' ? 'Recibir resto' : 'Recibir',
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  String _invoiceCaption(PurchaseOrderSummary order) {
    final parts = <String>[
      if (order.invoiceNumber.isNotEmpty) 'Factura ${order.invoiceNumber}',
      if (order.ncf.isNotEmpty) 'NCF ${order.ncf}',
    ];
    return parts.isEmpty ? 'Sin factura registrada' : parts.join(' · ');
  }

  // ── Cabecera de la orden ─────────────────────────────────────────────────

  Widget _metaCard(
    PurchaseOrderDetail detail,
    BusinessCurrency currency,
    bool wide,
  ) {
    final order = detail.order;
    final fields = <(String, String)>[
      ('Proveedor', order.supplierName),
      ('Almacén', order.warehouseName),
      ('Registrada', _dateFormat.format(order.createdAt)),
      (
        'Esperada',
        order.expectedDate == null
            ? '—'
            : _dateFormat.format(order.expectedDate!),
      ),
      (
        'Recibida',
        order.receivedDate == null
            ? 'Sin recepción registrada'
            : _dateFormat.format(order.receivedDate!),
      ),
      (
        'Factura del proveedor',
        order.invoiceNumber.isEmpty ? '—' : order.invoiceNumber,
      ),
      ('NCF', order.ncf.isEmpty ? '—' : order.ncf),
    ];

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StatusPill(status: order.status),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  currency.formatAmount(order.total),
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppColors.foreground,
                  ),
                ),
              ),
            ],
          ),
          if (order.payablePending) ...[
            const SizedBox(height: 12),
            _noticeBox(
              color: AppColors.destructive,
              background: const Color(0xFFFEF2F2),
              icon: Icons.report_problem_outlined,
              text:
                  'La compra se registró a crédito pero la cuenta por pagar no '
                  'llegó a crearse. Regístrala en Créditos → Cuentas por Pagar.',
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 24,
            runSpacing: 14,
            children: [
              for (final field in fields)
                SizedBox(
                  width: wide ? 220 : double.infinity,
                  child: _FieldValue(label: field.$1, value: field.$2),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Líneas de la factura ─────────────────────────────────────────────────

  Widget _linesCard(
    PurchaseOrderDetail detail,
    BusinessCurrency currency,
    bool wide,
  ) {
    final lines = detail.lines;
    return _card(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Productos comprados',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppColors.foreground,
                    ),
                  ),
                ),
                Text(
                  '${lines.length} ${lines.length == 1 ? 'línea' : 'líneas'}',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          if (lines.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              child: Text(
                'Esta orden no tiene líneas registradas.',
                style: TextStyle(color: AppColors.mutedForeground),
              ),
            )
          else if (wide) ...[
            const _LinesTableHeader(),
            const Divider(height: 1),
            for (var i = 0; i < lines.length; i++) ...[
              _LineRow(line: lines[i], currency: currency),
              if (i < lines.length - 1) const Divider(height: 1),
            ],
          ] else ...[
            const Divider(height: 1),
            for (var i = 0; i < lines.length; i++) ...[
              _LineCompactRow(line: lines[i], currency: currency),
              if (i < lines.length - 1) const Divider(height: 1),
            ],
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ── Desglose ─────────────────────────────────────────────────────────────

  Widget _totalsCard(
    PurchaseOrderDetail detail,
    BusinessCurrency currency,
    bool wide,
  ) {
    final rows = <Widget>[
      _TotalRow(
        label: 'Subtotal (sin ITBIS)',
        value: currency.formatAmount(detail.subtotal),
      ),
      if (detail.lineDiscounts > 0)
        _TotalRow(
          label: 'Descuento del proveedor en líneas',
          value: '− ${currency.formatAmount(detail.lineDiscounts)}',
          // Informativo: el costo de cada línea ya viene descontado, así que
          // restarlo otra vez del total sería contarlo dos veces.
          hint: 'ya aplicado en los costos',
        ),
      _TotalRow(label: 'ITBIS', value: currency.formatAmount(detail.tax)),
      if (detail.discount > 0)
        _TotalRow(
          label: 'Descuento de la orden',
          value: '− ${currency.formatAmount(detail.discount)}',
        ),
    ];

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Desglose de la factura',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: wide ? 380 : double.infinity,
              child: Column(
                children: [
                  ...rows,
                  const Divider(height: 22),
                  _TotalRow(
                    label: 'Total',
                    value: currency.formatAmount(detail.order.total),
                    emphasized: true,
                  ),
                ],
              ),
            ),
          ),
          if (!detail.totalsAgree) ...[
            const SizedBox(height: 14),
            _noticeBox(
              color: AppColors.warning,
              background: const Color(0xFFFFFBF4),
              icon: Icons.info_outline,
              text:
                  'Las líneas suman ${currency.formatAmount(detail.linesGrossTotal)} '
                  'y el total guardado es ${currency.formatAmount(detail.order.total)}. '
                  'Suele pasar en órdenes creadas antes de que se guardara este '
                  'desglose; el total guardado es el que manda.',
            ),
          ],
        ],
      ),
    );
  }

  Widget _notesCard(PurchaseOrderSummary order) {
    // El aviso de CxP pendiente ya tiene su propia caja arriba: dejarlo
    // también acá solo ensucia la nota que escribió el usuario.
    final notes = order.notes.replaceAll(kPendingPayableTag, '').trim();
    if (notes.isEmpty) return const SizedBox.shrink();
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Notas',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            notes,
            style: TextStyle(fontSize: 14, color: AppColors.mutedForeground),
          ),
        ],
      ),
    );
  }

  // ── Conduces de recepción ────────────────────────────────────────────────

  /// Lo que de verdad ENTRÓ al almacén, con su documento. La orden dice lo
  /// que se compró; el conduce dice lo que llegó, y son cosas distintas en
  /// cuanto hay una entrega parcial.
  Widget _receiptsCard(BusinessCurrency currency) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Recepciones en almacén',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
              ),
              if (_loadingReceipts)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Cada entrega genera su conduce. Se reimprime desde aquí.',
            style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
          ),
          const SizedBox(height: 10),
          for (final receipt in _receipts)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.md),
                onTap: () => showGoodsReceiptDialog(
                  context,
                  ref,
                  receipt: receipt,
                  isReprint: true,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.receipt_long_rounded,
                        size: 18,
                        color: AppColors.mutedForeground,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              receipt.number.isEmpty
                                  ? 'Recepción sin número'
                                  : receipt.number,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13.5,
                              ),
                            ),
                            Text(
                              '${_dateFormat.format(receipt.date)} · '
                              '${receipt.lines.length} renglones'
                              '${receipt.isPartial ? " · parcial" : ""}',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.mutedForeground,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        currency.formatAmount(receipt.total),
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: 'Reimprimir conduce',
                        icon: const Icon(Icons.print_outlined, size: 18),
                        onPressed: () => GoodsReceiptPrinting.printThermal(
                          context,
                          ref,
                          receipt: receipt,
                          isReprint: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _errorCard(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: const TextStyle(color: Color(0xFF991B1B))),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Reintentar'),
              ),
              const SizedBox(width: 10),
              TextButton(onPressed: _goBack, child: const Text('Volver')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _noticeBox({
    required Color color,
    required Color background,
    required IconData icon,
    required String text,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
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

  Widget _card({required Widget child, EdgeInsets? padding}) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }
}

// ── Presentación de una línea ──────────────────────────────────────────────

/// Cómo se muestra una línea: cantidades y costos en la unidad en que se
/// COMPRÓ (caja, botella) cuando el insumo tiene empaque, con la equivalencia
/// en unidad base debajo. Guardar en base y mostrar en compra es la regla de
/// todo el módulo de inventario.
class _LineDisplay {
  final PurchaseOrderLine line;

  _LineDisplay(this.line);

  bool get _packed =>
      hasPack(line.packSize, line.purchaseUnit, baseUnit: line.unit);

  String get name =>
      line.itemName.trim().isNotEmpty ? line.itemName.trim() : 'Sin nombre';

  String? get subtitle {
    final parts = <String>[
      if (line.sku.trim().isNotEmpty) line.sku.trim(),
      if (line.description.trim().isNotEmpty &&
          line.description.trim() != line.itemName.trim())
        line.description.trim(),
      if (!line.tracksInventory) 'No afecta inventario',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// Cantidad en la unidad de compra (o base si no hay empaque).
  String get quantity {
    if (!_packed) return '${_formatQty(line.quantityOrdered)} ${line.unit}';
    return '${_formatQty(baseToPack(line.quantityOrdered, line.packSize))} '
        '${line.purchaseUnit}';
  }

  /// Equivalencia en unidad base — solo cuando la compra fue por empaque.
  String? get quantityBase =>
      _packed ? '${_formatQty(line.quantityOrdered)} ${line.unit}' : null;

  /// Cuánto de lo pedido llegó. `null` cuando ya está completa: no hace falta
  /// repetir la cantidad para decir que no falta nada.
  String? get receivedNote {
    if (line.quantityReceived >= line.quantityOrdered) return null;
    final received = _packed
        ? baseToPack(line.quantityReceived, line.packSize)
        : line.quantityReceived;
    final ordered = _packed
        ? baseToPack(line.quantityOrdered, line.packSize)
        : line.quantityOrdered;
    return 'Recibido ${_formatQty(received)} de ${_formatQty(ordered)}';
  }

  /// Costo en la unidad en que se compró (el costo guardado es por unidad
  /// base, así que se multiplica por el empaque para mostrarlo).
  double get unitCostDisplay =>
      _packed ? line.unitCost * line.packSize : line.unitCost;

  /// Costo por unidad base, solo si difiere del mostrado arriba.
  String? costPerBase(BusinessCurrency currency) =>
      _packed ? '${currency.formatAmount(line.unitCost)} / ${line.unit}' : null;

  /// Precio de lista por unidad de compra, antes del descuento.
  double get listUnitCostDisplay =>
      _packed ? line.listUnitCost * line.packSize : line.listUnitCost;

  String? discountNote(BusinessCurrency currency) {
    if (line.discount <= 0) return null;
    return 'Descuento ${currency.formatAmount(line.discount)} · '
        'lista ${currency.formatAmount(listUnitCostDisplay)}';
  }

  /// ITBIS de la línea, con su tasa efectiva para poder contrastarla con la
  /// factura de papel.
  String taxLabel(BusinessCurrency currency) {
    final value = currency.formatAmount(line.taxValue);
    if (line.taxRate <= 0) return '$value (exento)';
    return '$value (${_formatQty(line.taxRate)}%)';
  }
}

/// Cantidad sin ceros sobrantes: 6, 6.5, 4500 — no "6.00".
String _formatQty(double value) {
  final fixed = value.toStringAsFixed(2);
  if (fixed.endsWith('.00')) {
    return NumberFormat('#,##0').format(double.parse(fixed));
  }
  return NumberFormat('#,##0.##').format(double.parse(fixed));
}

class _LinesTableHeader extends StatelessWidget {
  const _LinesTableHeader();

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: AppColors.mutedForeground,
      letterSpacing: 0.3,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
      child: Row(
        children: [
          Expanded(flex: 5, child: Text('PRODUCTO', style: style)),
          Expanded(
            flex: 2,
            child: Text('CANTIDAD', style: style, textAlign: TextAlign.right),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'COSTO UNIT.',
              style: style,
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text('ITBIS', style: style, textAlign: TextAlign.right),
          ),
          Expanded(
            flex: 2,
            child: Text('TOTAL', style: style, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  final PurchaseOrderLine line;
  final BusinessCurrency currency;

  const _LineRow({required this.line, required this.currency});

  @override
  Widget build(BuildContext context) {
    final d = _LineDisplay(line);
    final subtitle = d.subtitle;
    final discount = d.discountNote(currency);
    final received = d.receivedNote;
    final costPerBase = d.costPerBase(currency);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  d.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.foreground,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                if (discount != null)
                  Text(
                    discount,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF059669),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (received != null)
                  Text(
                    received,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.warning,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(flex: 2, child: _stack(d.quantity, d.quantityBase)),
          Expanded(
            flex: 2,
            child: _stack(
              currency.formatAmount(d.unitCostDisplay),
              costPerBase,
            ),
          ),
          Expanded(flex: 2, child: _stack(d.taxLabel(currency), null)),
          Expanded(
            flex: 2,
            child: _stack(
              currency.formatAmount(line.grossTotal),
              'neto ${currency.formatAmount(line.netTotal)}',
              bold: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _stack(String main, String? sub, {bool bold = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          main,
          textAlign: TextAlign.right,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            color: AppColors.foreground,
          ),
        ),
        if (sub != null)
          Text(
            sub,
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 11.5, color: AppColors.mutedForeground),
          ),
      ],
    );
  }
}

/// Misma línea en pantallas angostas (tablet vertical / ventana chica): la
/// tabla de 5 columnas no cabe sin cortar los nombres, así que cada línea se
/// apila.
class _LineCompactRow extends StatelessWidget {
  final PurchaseOrderLine line;
  final BusinessCurrency currency;

  const _LineCompactRow({required this.line, required this.currency});

  @override
  Widget build(BuildContext context) {
    final d = _LineDisplay(line);
    final subtitle = d.subtitle;
    final discount = d.discountNote(currency);
    final received = d.receivedNote;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  d.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.foreground,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                currency.formatAmount(line.grossTotal),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.foreground,
                ),
              ),
            ],
          ),
          if (subtitle != null)
            Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
            ),
          const SizedBox(height: 6),
          Text(
            '${d.quantity} × ${currency.formatAmount(d.unitCostDisplay)}'
            '${d.quantityBase == null ? '' : ' (${d.quantityBase})'}',
            style: TextStyle(fontSize: 12.5, color: AppColors.mutedForeground),
          ),
          Text(
            'ITBIS ${d.taxLabel(currency)} · neto '
            '${currency.formatAmount(line.netTotal)}',
            style: TextStyle(fontSize: 12.5, color: AppColors.mutedForeground),
          ),
          if (discount != null)
            Text(
              discount,
              style: const TextStyle(
                fontSize: 12.5,
                color: Color(0xFF059669),
                fontWeight: FontWeight.w600,
              ),
            ),
          if (received != null)
            Text(
              received,
              style: TextStyle(
                fontSize: 12.5,
                color: AppColors.warning,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}

class _FieldValue extends StatelessWidget {
  final String label;
  final String value;

  const _FieldValue({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
            color: AppColors.mutedForeground,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.foreground,
          ),
        ),
      ],
    );
  }
}

class _TotalRow extends StatelessWidget {
  final String label;
  final String value;
  final String? hint;
  final bool emphasized;

  const _TotalRow({
    required this.label,
    required this.value,
    this.hint,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: emphasized ? 16 : 14,
                    fontWeight: emphasized ? FontWeight.w800 : FontWeight.w500,
                    color: emphasized
                        ? AppColors.foreground
                        : AppColors.mutedForeground,
                  ),
                ),
                if (hint != null)
                  Text(
                    hint!,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppColors.mutedForeground,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            style: TextStyle(
              fontSize: emphasized ? 18 : 14,
              fontWeight: emphasized ? FontWeight.w800 : FontWeight.w600,
              color: AppColors.foreground,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String status;

  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = purchaseStatusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        purchaseStatusLabel(status).toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
          color: color,
        ),
      ),
    );
  }
}
