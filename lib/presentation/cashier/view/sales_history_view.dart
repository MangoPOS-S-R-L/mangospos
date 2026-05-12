import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/app/widgets/date_range_modal.dart';
import 'package:mangopos/core/utils/app_time.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/core/tax/tax_engine.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';
import 'package:mangopos/data/repositories/business_profile_repository.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';
import 'package:mangopos/services/printing/qr_esc_pos_builder.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:mangopos/presentation/sales/widgets/pin_verification_modal.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _formatQty(double qty) {
  if ((qty - qty.roundToDouble()).abs() < 0.001) {
    return qty.toStringAsFixed(0);
  }
  if ((qty * 10 - (qty * 10).roundToDouble()).abs() < 0.001) {
    return qty.toStringAsFixed(1);
  }
  return qty.toStringAsFixed(2);
}

class SalesHistoryView extends ConsumerStatefulWidget {
  const SalesHistoryView({super.key});

  @override
  ConsumerState<SalesHistoryView> createState() => _SalesHistoryViewState();
}

class _SalesHistoryViewState extends ConsumerState<SalesHistoryView> {
  _SalesHistoryData? _data;
  bool _loading = false;
  String? _error;

  int _currentPage = 1;
  static const int _pageSize = 15;
  String? _searchQuery;
  DateTime? _fromDate;
  DateTime? _toDate;

  final _searchController = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (businessId == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final repository = ref.read(cashierRepositoryProvider);
      final result = await repository.getGlobalSalesHistoryPaged(
        businessId: businessId,
        page: _currentPage,
        pageSize: _pageSize,
        from: _fromDate,
        to: _toDate,
        searchTerm: _searchQuery,
      );

      if (mounted) {
        setState(() {
          _data = _SalesHistoryData(
            payments: result.payments,
            totalCount: result.totalCount,
          );
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _reload() => _load();

  void _changePage(int page) {
    if (_currentPage == page) return;
    _currentPage = page;
    _load();
  }

  Future<void> _selectDateRange() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: SizedBox(
          width: 400,
          child: DateRangeModal(
            initialFrom: _fromDate,
            initialTo: _toDate,
            onApply: (from, to) {
              setState(() {
                _fromDate = DateTime(from.year, from.month, from.day);
                _toDate = DateTime(to.year, to.month, to.day, 23, 59, 59);
                _currentPage = 1;
              });
              _load();
            },
            onClear: () {
              setState(() {
                _fromDate = null;
                _toDate = null;
                _currentPage = 1;
              });
              _load();
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Historial de venta'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go(AppRoutes.cashier),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _data == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _data == null) {
      return _CashierInfoState(
        icon: Icons.error_outline,
        title: 'No se pudo cargar el historial',
        subtitle: _error!,
      );
    }

    final data = _data;
    if (data == null || (data.payments.isEmpty && _currentPage == 1 && _searchQuery == null && _fromDate == null)) {
      return const _CashierInfoState(
        icon: Icons.receipt_long_outlined,
        title: 'No hay ventas registradas',
        subtitle: 'Procesa ventas para ver movimientos en el historial.',
      );
    }

    final currency = NumberFormat.currency(
      symbol: 'RD\$',
      decimalDigits: 2,
    );

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: (val) {
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 400), () {
                      setState(() {
                        _searchQuery = val.trim().isEmpty ? null : val.trim();
                        _currentPage = 1;
                      });
                      _load();
                    });
                  },
                  decoration: InputDecoration(
                    hintText: 'Buscar por comprobante o cliente',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              _debounce?.cancel();
                              setState(() {
                                _searchQuery = null;
                                _currentPage = 1;
                              });
                              _load();
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: MangoColors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                        color: MangoColors.cardBorder,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              InkWell(
                onTap: _selectDateRange,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: MangoColors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: MangoColors.cardBorder),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.calendar_today_outlined, size: 18),
                      const SizedBox(width: 12),
                      Text(
                        _fromDate == null || _toDate == null
                            ? 'Filtrar por fecha'
                            : '${DateFormat('dd MMM.').format(_fromDate!)} → ${DateFormat('dd MMM.').format(_toDate!)}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (_fromDate != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: InkWell(
                            onTap: () {
                              setState(() {
                                _fromDate = null;
                                _toDate = null;
                                _currentPage = 1;
                              });
                              _load();
                            },
                            child: const Icon(Icons.close, size: 16),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: MangoColors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: MangoColors.cardBorder),
              ),
              child: Column(
                children: [
                  _buildTableHeader(),
                  const Divider(height: 1),
                  Expanded(
                    child: data.payments.isEmpty
                        ? Center(
                            child: Text(
                              _searchQuery != null || _fromDate != null
                                  ? 'No se encontraron resultados para los filtros aplicados.'
                                  : 'No hay ventas registradas.',
                            ),
                          )
                        : ListView.separated(
                            itemCount: data.payments.length,
                            separatorBuilder: (_, _) => const Divider(height: 1),
                            itemBuilder: (context, index) => _PaymentTableRow(
                              payment: data.payments[index],
                              currency: currency,
                              onRefresh: _reload,
                            ),
                          ),
                  ),
                  _buildTableFooter(data.totalCount),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      color: MangoColors.sidebarBg.withValues(alpha: 0.5),
      child: const Row(
        children: [
          Expanded(flex: 2, child: _HeaderText('Fecha')),
          Expanded(flex: 2, child: _HeaderText('Comprobante')),
          Expanded(flex: 2, child: _HeaderText('Mesero')),
          Expanded(flex: 2, child: _HeaderText('Cliente')),
          Expanded(flex: 2, child: _HeaderText('N° de documento')),
          Expanded(flex: 2, child: _HeaderText('Total')),
          SizedBox(
            width: 120,
            child: _HeaderText('Opciones', textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }

  Widget _buildTableFooter(int totalCount) {
    if (totalCount <= _pageSize) return const SizedBox.shrink();

    final totalPages = (totalCount / _pageSize).ceil();
    final start = (_currentPage - 1) * _pageSize + 1;
    final end = (_currentPage * _pageSize) > totalCount
        ? totalCount
        : (_currentPage * _pageSize);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Text(
            'Mostrando $start - $end de $totalCount ventas',
            style: const TextStyle(color: MangoColors.muted, fontSize: 13),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.first_page),
            onPressed: _currentPage > 1 ? () => _changePage(1) : null,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: _currentPage > 1 ? () => _changePage(_currentPage - 1) : null,
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: MangoColors.primaryOrange,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '$_currentPage',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed:
                _currentPage < totalPages ? () => _changePage(_currentPage + 1) : null,
          ),
          IconButton(
            icon: const Icon(Icons.last_page),
            onPressed:
                _currentPage < totalPages ? () => _changePage(totalPages) : null,
          ),
        ],
      ),
    );
  }
}

class _HeaderText extends StatelessWidget {
  final String text;
  final TextAlign textAlign;
  const _HeaderText(this.text, {this.textAlign = TextAlign.left});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: textAlign,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        color: MangoColors.muted,
      ),
    );
  }
}

class _PaymentTableRow extends ConsumerWidget {
  final Map<String, dynamic> payment;
  final NumberFormat currency;
  final VoidCallback onRefresh;

  const _PaymentTableRow({
    required this.payment,
    required this.currency,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final amount =
        (payment['net_amount'] as num?)?.toDouble() ??
        ((payment['amount'] as num?)?.toDouble() ?? 0);
    final createdAt = AppTime.tryParseServerToAst(payment['created_at']);
    final dateStr = createdAt == null
        ? '-'
        : DateFormat('dd/MM/yyyy').format(createdAt);
    final timeStr = createdAt == null
        ? '-'
        : DateFormat('hh:mm a').format(createdAt);

    final customerName =
        payment['customer_name']?.toString() ?? 'Público General';
    final ncf = payment['ncf_number']?.toString() ?? 'Ticket';
    final ncfType = payment['ncf_type_name']?.toString() ?? 'Boleta';
    final taxId = payment['customer_tax_id']?.toString() ?? '';
    final waiterName = payment['waiter_name']?.toString() ?? 'Servicio';
    final paymentId = payment['id']?.toString() ?? '';
    final orderId = payment['order_id']?.toString() ?? '';
    final checkId = payment['check_id']?.toString();
    final isVoided =
        payment['status'] == 'void' || payment['status'] == 'cancelled';

    return Container(
      color: isVoided ? Colors.red.withValues(alpha: 0.05) : null,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dateStr,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    decoration: isVoided ? TextDecoration.lineThrough : null,
                  ),
                ),
                Text(
                  timeStr,
                  style: const TextStyle(
                    fontSize: 12,
                    color: MangoColors.muted,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ncfType,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    decoration: isVoided ? TextDecoration.lineThrough : null,
                    color: isVoided ? Colors.red : null,
                  ),
                ),
                Text(
                  ncf,
                  style: const TextStyle(
                    fontSize: 12,
                    color: MangoColors.muted,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              waiterName,
              style: TextStyle(
                decoration: isVoided ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              customerName,
              style: TextStyle(
                decoration: isVoided ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          Expanded(flex: 2, child: Text(taxId.isEmpty ? '-' : taxId)),
          Expanded(
            flex: 2,
            child: Text(
              currency.format(amount),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: isVoided ? Colors.red : null,
                decoration: isVoided ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          SizedBox(
            width: 120,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.visibility_outlined, size: 20),
                  onPressed: () => _showDetailDialog(context, ref, payment),
                  tooltip: 'Ver detalle',
                  color: MangoColors.muted,
                ),
                if (!isVoided) ...[
                  IconButton(
                    icon: const Icon(Icons.print_outlined, size: 20),
                    onPressed: () => _reprintInvoice(
                      context,
                      ref,
                      payment,
                    ),
                    tooltip: 'Reimprimir',
                    color: Colors.blue,
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.cancel_outlined,
                      size: 20,
                      color: Colors.redAccent,
                    ),
                    onPressed: () => _voidSale(
                      context,
                      ref,
                      paymentId,
                      orderId,
                      checkId: checkId,
                    ),
                    tooltip: 'Anular',
                  ),
                ] else
                  const Padding(
                    padding: EdgeInsets.only(right: 8.0),
                    child: Text(
                      'ANULADA',
                      style: TextStyle(
                        color: Colors.red,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
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

  void _reprintInvoice(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> payment,
  ) async {
    final orderId = payment['order_id']?.toString() ?? '';
    if (orderId.isEmpty) return;

    // El scope del fd: si tiene check_id, la factura es de una sub-cuenta;
    // si es NULL, es full-order (puede ser cobro simple sin split, o el
    // remainder de una orden con sub-cuentas ya cobradas).
    final fdCheckId = payment['check_id']?.toString();
    final fdId = payment['fiscal_document_id']?.toString();

    try {
      final scaffold = ScaffoldMessenger.of(context);
      scaffold.showSnackBar(
        const SnackBar(content: Text('Generando impresión...')),
      );

      final salesRepo = ref.read(salesRepositoryProvider);
      final businessId = ref.read(sessionProvider).activeBusinessId;
      final bundle = await salesRepo.getOrderBundle(
        orderId,
        businessId: businessId,
      );
      if (bundle.order == null) throw Exception('No se encontró la orden.');

      // Para historial/reimpresión necesitamos TODOS los productos de la venta,
      // incluidos los ya pagados. El bundle del order detail excluye items paid
      // para no reinyectar subcuentas cerradas en la UI de la mesa.
      final allItems = await salesRepo.getOrderItems(
        orderId,
        includeModifiers: true,
        onlyOpen: false,
        businessId: businessId,
      );

      // Fetch payments for this order
      final paymentsRaw = await Supabase.instance.client
          .from('payments')
          .select('*, payment_methods(name, code)')
          .eq('order_id', orderId)
          .inFilter('status', ['completed', 'void', 'cancelled'])
          .order('created_at', ascending: false);

      final payments = List<Map<String, dynamic>>.from(paymentsRaw).map((p) {
        final map = p;
        final method = map['payment_methods'] as Map<String, dynamic>?;
        return Payment.fromMap({
          ...map,
          'payment_method_name': method?['name'],
          'payment_method_code': method?['code'],
        });
      }).toList();

      // FILTRO POR SCOPE DEL FD:
      //   - fd.check_id != NULL (sub-cuenta): items y payments del check.
      //   - fd.check_id == NULL (full-order o remainder): items con
      //     check_id IS NULL O items en sub-cuentas SIN fd propio (caso:
      //     sub-cuenta auto-cerrada por items que pasaron a paid via un
      //     cobro full-order, donde el check no emitió fd propio).
      List<OrderItem> printItems;
      List<Payment> printPayments;
      Order printOrder;

      if (fdCheckId != null && fdCheckId.isNotEmpty) {
        printItems = allItems
            .where((item) => item.checkId == fdCheckId)
            .toList(growable: false);
        printPayments = payments
            .where((payment) => payment.checkId == fdCheckId)
            .toList(growable: false);
        try {
          final check = bundle.checks.firstWhere((c) => c.id == fdCheckId);
          printOrder = check.toOrder(createdAt: bundle.order!.createdAt);
        } catch (_) {
          printOrder = bundle.order!;
        }
      } else {
        // Full-order: cargar otros fds de la orden para saber qué checks
        // ya tienen su propio fd. Items de esos checks NO pertenecen a
        // este fd full-order; el resto (check_id NULL o checks sin fd) sí.
        final allFdsRaw = await Supabase.instance.client
            .from('fiscal_documents')
            .select('check_id, status')
            .eq('order_id', orderId);
        final otherCheckFdIds = List<Map<String, dynamic>>.from(allFdsRaw)
            .where((f) => f['check_id'] != null && f['status'] == 'active')
            .map((f) => f['check_id'].toString())
            .toSet();

        printItems = allItems.where((item) {
          if (item.status == 'void') return false;
          if (item.checkId == null) return true;
          return !otherCheckFdIds.contains(item.checkId);
        }).toList(growable: false);

        printPayments = payments
            .where((payment) => payment.checkId == null)
            .toList(growable: false);

        // Construir un "printOrder" cuyos totales reflejen el fd, no la
        // orden completa. Usamos los campos del payment Map (que vienen
        // del JOIN con fiscal_documents en getGlobalSalesHistoryPaged).
        final fdSubtotal = (payment['subtotal'] as num?)?.toDouble() ?? 0;
        final fdItbis = (payment['itbis_amount'] as num?)?.toDouble() ?? 0;
        final fdServiceFee = (payment['service_fee'] as num?)?.toDouble() ?? 0;
        final fdTotal = (payment['total'] as num?)?.toDouble() ?? 0;
        printOrder = bundle.order!.copyWith(
          subtotal: fdSubtotal,
          tax: fdItbis,
          serviceFee: fdServiceFee,
          total: fdTotal,
        );
      }

      // Loading business profile (simplified, usually from a provider)
      if (businessId == null || businessId.isEmpty) {
        throw Exception('No se pudo resolver el negocio activo.');
      }

      final profileRaw = await Supabase.instance.client
          .from('businesses')
          .select()
          .eq('id', businessId)
          .maybeSingle();

      final waiterName = _waiterNameFromPayment ?? 'Servicio';

      final printRepo = ref.read(printingPrintersRepositoryProvider);
      final assignedPrinter = await printRepo.getAssignedPrinterForType(
        businessId: businessId,
        preferredAreaCodes: const ['fiscal', 'cashier'],
        printsReceipts: true,
      );

      if (assignedPrinter == null) {
        throw Exception('No hay impresora configurada para recibos.');
      }

      final receiptItemDisplayMode = await ref
          .read(posSettingsRepositoryProvider)
          .getReceiptItemDisplayMode(businessId);

      // Build per-tax breakdown for the reprint receipt
      final reprintTaxBreakdown = <({String label, double amount})>[];
      try {
        final taxRows = await Supabase.instance.client
            .from('taxes')
            .select(
              'name,rate,is_active,is_service_fee,apply_on_zone,apply_on_manual,apply_on_quick,apply_on_delivery',
            )
            .eq('business_id', businessId)
            .eq('is_active', true);
        final taxes = (taxRows as List)
            .map((r) => TaxDef.fromMap(r as Map<String, dynamic>))
            .toList();
        final origin = parseSaleOrigin(payment['origin']?.toString());
        final printSummary = summarizeOrderPricing(printOrder, printItems);
        final base = printSummary.subtotal;
        final configuredBreakdown = <({String label, double amount})>[];
        for (final tx in taxes) {
          if (!tx.isActive || tx.rate <= 0) continue;
          if (!tx.appliesTo(origin)) continue;
          final pctLabel = tx.rate.truncateToDouble() == tx.rate
              ? '${tx.rate.toInt()}%'
              : '${tx.rate}%';
          final amount = double.parse(
            (base * tx.rateDecimal).toStringAsFixed(2),
          );
          configuredBreakdown.add((
            label: '${tx.name} ($pctLabel)',
            amount: amount,
          ));
        }
        reprintTaxBreakdown.addAll(
          buildOrderTaxBreakdown(
            printOrder,
            printItems,
            configuredBreakdown: configuredBreakdown,
          ),
        );
      } catch (_) {
        // Fallback: the ticket will use the summary-level ITBIS/SERVICIO lines
      }

      // e-CF: fresh fetch del fiscal_document. Crítico en re-impresión porque
      // el estado puede haber cambiado desde el cobro original (sent → accepted
      // vía webhook DGII async). NO usamos los datos históricos del payment;
      // siempre consultamos el estado más actual antes de imprimir.
      List<int>? ecfQrBytes;
      String? ecfStatusMsg;
      bool isElectronicCf = false;
      String? ecfSecurityCode;
      DateTime? ecfSignedAt;
      try {
        // Cargar el fd EXACTO del payment, no "el último de la orden".
        // En split bill una orden tiene N fds; getOrderFiscalDocument
        // devolvería cualquiera. Usar el id del fd (el `payment['id']`
        // del listado, que es el fd.id, no payment.id).
        final fiscalDoc = fdId != null && fdId.isNotEmpty
            ? await salesRepo.getFiscalDocumentById(fdId)
            : await salesRepo.getOrderFiscalDocument(orderId);
        if (fiscalDoc != null && fiscalDoc.isElectronic) {
          isElectronicCf = true;
          ecfSecurityCode = fiscalDoc.ecfSecurityCode;
          ecfSignedAt = fiscalDoc.ecfSignedAt;
          if (fiscalDoc.hasQrData) {
            // Preferimos publicUrl si Alanube/DGII ya nos lo dio. Si aún
            // estamos en estado `sent` (publicUrl null), construimos la
            // URL DGII localmente con security_code + RNC + NCF + fecha
            // + total — el QR sigue siendo válido.
            //
            // RNC del emisor: source of truth es fiscal_settings.rnc.
            // businesses puede tener tax_id en lugar de rnc, o estar
            // vacio en setups legacy. Cascade: businesses.rnc →
            // businesses.tax_id → fiscal_settings.rnc.
            String emitterRnc = (profileRaw?['rnc'] as String?)?.trim() ?? '';
            if (emitterRnc.isEmpty) {
              emitterRnc = (profileRaw?['tax_id'] as String?)?.trim() ?? '';
            }
            if (emitterRnc.isEmpty) {
              try {
                final fs = await Supabase.instance.client
                    .from('fiscal_settings')
                    .select('rnc')
                    .eq('business_id', businessId)
                    .maybeSingle();
                emitterRnc = ((fs?['rnc'] as String?)?.trim()) ?? '';
              } catch (_) {}
            }

            final qrUrl = fiscalDoc.publicUrl?.isNotEmpty == true
                ? fiscalDoc.publicUrl!
                : (fiscalDoc.buildDgiiVerifyUrl(
                      emitterRnc: emitterRnc,
                      sandbox: true,
                    ) ??
                    '');
            if (qrUrl.isNotEmpty) {
              ecfQrBytes = await QrEscPosBuilder.build(data: qrUrl);
            } else {
              ecfStatusMsg = fiscalDoc.ecfStatusMessage;
            }
          } else {
            ecfStatusMsg = fiscalDoc.ecfStatusMessage;
          }
        }
      } catch (_) {
        // Fail-soft: si la consulta o el QR fallan, imprimimos sin ellos.
      }

      // BusinessProfile (slogan, footer, toggles) + logo pre-rasterizado.
      // Si el negocio no configuro logo o printLogoOnInvoice=false,
      // logoBytes viene null y no se imprime nada de logo.
      final businessProfileRepo = BusinessProfileRepository(
        Supabase.instance.client,
      );
      final profileForPrint =
          await businessProfileRepo.prepareForInvoicePrinting(businessId);

      final ticket = PrintTicketService.generateInvoice(
        order: printOrder,
        items: printItems,
        payments: printPayments,
        tableName: payment['table_code']?.toString() ?? 'Mesa',
        waiterName: waiterName,
        businessName: profileRaw?['name'] ?? profileRaw?['business_name'],
        legalName: profileRaw?['legal_name'],
        businessAddress: profileRaw?['address'],
        businessPhone: profileRaw?['phone'],
        businessRnc: profileRaw?['rnc'],
        fiscalNcf: payment['ncf_number']?.toString(),
        fiscalType: payment['ncf_type_name']?.toString(),
        customerName: payment['customer_name']?.toString(),
        customerTaxId: payment['customer_tax_id']?.toString(),
        title: '*** REIMPRESION ***',
        receiptItemDisplayMode: receiptItemDisplayMode,
        taxBreakdown: reprintTaxBreakdown,
        preferStoredOrderTotals: true,
        // Branding desde BusinessProfile.
        logoBytes: profileForPrint.logoEscPosBytes,
        slogan: profileForPrint.profile?.slogan,
        branchName: profileForPrint.profile?.branchName,
        businessEmail: profileForPrint.profile?.email,
        footerMessage: profileForPrint.profile?.ticketFooterMessage,
        headerBlocks: profileForPrint.profile?.effectiveHeaderBlocks,
        footerBlocks: profileForPrint.profile?.effectiveFooterBlocks,
        preferStoredItemTotals: true,
        qrBytes: ecfQrBytes,
        ecfStatusMessage: ecfStatusMsg,
        isElectronicCf: isElectronicCf,
        ecfSecurityCode: ecfSecurityCode,
        ecfSignedAt: ecfSignedAt,
      );

      await printRepo.printEscPos(
        printer: assignedPrinter,
        data: ticket.escPosCommands,
      );

      if (context.mounted) {
        scaffold.showSnackBar(
          const SnackBar(content: Text('Impresión enviada correctamente.')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Error de Impresión'),
            content: Text(e.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }

  void _voidSale(
    BuildContext context,
    WidgetRef ref,
    String paymentId,
    String orderId, {
    String? checkId,
  }) async {
    if (paymentId.isEmpty || orderId.isEmpty) return;

    final session = ref.read(sessionProvider);
    final currentRole = session.activeRole;
    // Si el usuario ya es Administrador o Supervisor, no necesita PIN otra vez.
    final bool isManager =
        currentRole == PosRole.administrador ||
        currentRole == PosRole.supervisor;

    // Confirmación inicial
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Anular Venta'),
        content: const Text(
          '¿Está seguro que desea anular esta venta? Esta acción no se puede deshacer y ajustará el balance de caja.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No, volver'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Sí, anular'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    if (!context.mounted) return;

    // 1. Verificación de Autorización
    if (!isManager) {
      // Para roles que no son Admin/Super, pedimos el PIN de un supervisor.
      final authorized = await showPinVerificationModal(
        context,
        ref,
        level: PinAccessLevel.supervisor,
        title: 'Autorización Requerida',
        subtitle: 'Ingrese PIN de Supervisor para anular la venta',
      );
      if (!authorized) return;
    }

    if (!context.mounted) return;

    // 2. Pedir motivo de anulación (Requerido por el usuario)
    final reason = await _showAnulacionReasonDialog(context);
    if (reason == null) {
      return; // El usuario canceló o cerró el diálogo de nota.
    }

    // 3. Ejecutar anulación
    try {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Anulando venta...')));

      final salesRepo = ref.read(salesRepositoryProvider);
      await salesRepo.annulPayment(
        paymentId: paymentId,
        orderId: orderId,
        checkId: checkId,
        reason: reason.isEmpty ? 'Anulación desde historial' : reason,
      );

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Venta anulada correctamente.'),
          backgroundColor: Colors.green,
        ),
      );

      onRefresh();
    } catch (e) {
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Error al anular'),
          content: Text(e.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      );
    }
  }

  Future<String?> _showAnulacionReasonDialog(BuildContext context) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.report_problem_rounded,
                  color: MangoColors.primaryOrange,
                  size: 44,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Nota de Anulación',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: MangoColors.darkGray,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Esta acción es definitiva. Deja una nota explicando brevemente el motivo de la anulación.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: MangoColors.muted,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 28),
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 3,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
                decoration: InputDecoration(
                  hintText: 'Escriba el motivo aquí...',
                  hintStyle: const TextStyle(
                    color: MangoColors.muted,
                    fontWeight: FontWeight.w400,
                  ),
                  filled: true,
                  fillColor: const Color(0xFFF7F8FA),
                  contentPadding: const EdgeInsets.all(20),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: const BorderSide(
                      color: MangoColors.primaryOrange,
                      width: 2,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Text(
                        'Cancelar',
                        style: TextStyle(
                          color: MangoColors.muted,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: MangoColors.primaryOrange.withValues(
                              alpha: 0.3,
                            ),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ElevatedButton(
                        onPressed: () =>
                            Navigator.pop(context, controller.text.trim()),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: MangoColors.primaryOrange,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: const Text(
                          'Anular Venta',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
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

  void _showDetailDialog(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> payment,
  ) async {
    final orderId = payment['order_id']?.toString() ?? '';
    if (orderId.isEmpty) return;

    // check_id del fd asociado al payment. Si != null, el fd corresponde a
    // una sub-cuenta y solo mostramos los items de ese check. Si es null,
    // el fd es full-order y mostramos items con check_id IS NULL (los que
    // se cobraron en el pago full-order final).
    final fdCheckId = payment['check_id']?.toString();

    final ncf = payment['ncf_number']?.toString() ?? 'Sin NCF';
    final ncfType = payment['ncf_type']?.toString() ?? '';
    final customerName =
        payment['customer_name']?.toString().trim().isNotEmpty == true
        ? payment['customer_name']!.toString()
        : 'Consumidor Final';
    final customerRnc = payment['customer_rnc']?.toString() ?? '';
    final createdAt = AppTime.tryParseServerToAst(payment['created_at']);
    final dateStr = createdAt == null
        ? '-'
        : DateFormat('dd/MM/yyyy hh:mm a').format(createdAt);

    final subtotal = (payment['subtotal'] as num?)?.toDouble() ?? 0;
    final itbis = (payment['itbis_amount'] as num?)?.toDouble() ?? 0;
    final serviceFee = (payment['service_fee'] as num?)?.toDouble() ?? 0;
    final total = (payment['total'] as num?)?.toDouble() ?? 0;

    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 720),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // --- ENCABEZADO ESTILO FACTURA ---
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'FACTURA',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          ncf,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: MangoColors.muted,
                          ),
                        ),
                        if (ncfType.isNotEmpty)
                          Text(
                            'Tipo: $ncfType',
                            style: const TextStyle(
                              fontSize: 11,
                              color: MangoColors.muted,
                            ),
                          ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          dateStr,
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Orden #${orderId.substring(0, 8).toUpperCase()}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: MangoColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Divider(),
                // --- CLIENTE ---
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Cliente: $customerName',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (customerRnc.isNotEmpty)
                      Text(
                        'RNC/Cédula: $customerRnc',
                        style: const TextStyle(
                          fontSize: 12,
                          color: MangoColors.muted,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                const Divider(),
                const SizedBox(height: 4),
                // --- ITEMS ---
                const Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: Text(
                        'Producto',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: MangoColors.muted,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text(
                        'Cant.',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: MangoColors.muted,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 90,
                      child: Text(
                        'Total',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: MangoColors.muted,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Flexible(
                  child: FutureBuilder<
                      ({List<OrderItem> items, Set<String> otherFdCheckIds})>(
                    future: () async {
                      final businessIdLocal =
                          ref.read(sessionProvider).activeBusinessId;
                      final itemsFuture = ref
                          .read(salesRepositoryProvider)
                          .getOrderItems(
                            orderId,
                            businessId: businessIdLocal,
                          );
                      // Cargar los OTROS fds de la orden para saber qué
                      // checks ya tienen su propio fd. Esto es clave para
                      // que el fd full-order remainder muestre los items
                      // que NO están en sub-cuentas con fd propio.
                      final otherFdsFuture = Supabase.instance.client
                          .from('fiscal_documents')
                          .select('check_id, status')
                          .eq('order_id', orderId);
                      final results = await Future.wait<dynamic>([
                        itemsFuture,
                        otherFdsFuture,
                      ]);
                      final loadedItems = results[0] as List<OrderItem>;
                      final fds = List<Map<String, dynamic>>.from(
                        results[1] as List,
                      );
                      final otherFdCheckIds = fds
                          .where((f) =>
                              f['check_id'] != null &&
                              f['status'] == 'active')
                          .map((f) => f['check_id'].toString())
                          .toSet();
                      return (
                        items: loadedItems,
                        otherFdCheckIds: otherFdCheckIds,
                      );
                    }(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState ==
                          ConnectionState.waiting) {
                        return const SizedBox(
                          height: 100,
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      if (snapshot.hasError) {
                        return SizedBox(
                          height: 80,
                          child: Center(
                            child: Text(
                              'Error: ${snapshot.error}',
                              style: const TextStyle(color: Colors.red),
                            ),
                          ),
                        );
                      }
                      final data = snapshot.data;
                      final all = data?.items ?? const <OrderItem>[];
                      final otherFdCheckIds =
                          data?.otherFdCheckIds ?? const <String>{};
                      // Filtro por scope del fd:
                      //   - fd.check_id != NULL → solo items del check.
                      //   - fd.check_id == NULL (full-order o remainder):
                      //     items con check_id NULL (cobro directo al
                      //     principal) O items en sub-cuentas que NO
                      //     tienen su propio fd (caso: sub-cuenta cerrada
                      //     por auto-close cuando sus items pasaron a paid
                      //     vía cobro full-order).
                      final items = all.where((i) {
                        if (i.status == 'void') return false;
                        if (fdCheckId != null && fdCheckId.isNotEmpty) {
                          return i.checkId == fdCheckId;
                        }
                        if (i.checkId == null) return true;
                        return !otherFdCheckIds.contains(i.checkId);
                      }).toList();

                      if (items.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'No se encontraron productos para esta factura.',
                            style: TextStyle(color: MangoColors.muted),
                          ),
                        );
                      }

                      return ListView.separated(
                        shrinkWrap: true,
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const Divider(height: 12),
                        itemBuilder: (context, i) {
                          final item = items[i];
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 5,
                                child: Text(
                                  item.productName,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 40,
                                child: Text(
                                  _formatQty(item.quantity),
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              SizedBox(
                                width: 90,
                                child: Text(
                                  currency.format(item.total),
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(),
                // --- TOTALES ---
                _invoiceTotalRow('Subtotal', subtotal, currency),
                if (itbis > 0)
                  _invoiceTotalRow('ITBIS', itbis, currency),
                if (serviceFee > 0)
                  _invoiceTotalRow('Servicio (10%)', serviceFee, currency),
                const SizedBox(height: 4),
                _invoiceTotalRow('TOTAL', total, currency, isTotal: true),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        _reprintInvoice(context, ref, payment);
                      },
                      icon: const Icon(Icons.print_outlined, size: 18),
                      label: const Text('Reimprimir'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: MangoColors.successGreen,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: MangoColors.primaryOrange,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 10,
                        ),
                      ),
                      child: const Text('Cerrar'),
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

  Widget _invoiceTotalRow(
    String label,
    double amount,
    NumberFormat currency, {
    bool isTotal = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: isTotal ? 14 : 12,
              fontWeight: isTotal ? FontWeight.w800 : FontWeight.w500,
              color: isTotal ? null : MangoColors.muted,
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 100,
            child: Text(
              currency.format(amount),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: isTotal ? 16 : 12,
                fontWeight: isTotal ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String? get _waiterNameFromPayment => payment['waiter_name']?.toString();
}

class _SalesHistoryData {
  final List<Map<String, dynamic>> payments;
  final int totalCount;

  const _SalesHistoryData({
    required this.payments,
    required this.totalCount,
  });
}

class _CashierInfoState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _CashierInfoState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }
}

