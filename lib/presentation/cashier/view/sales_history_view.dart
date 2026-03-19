import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/models/payment_models.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SalesHistoryView extends ConsumerStatefulWidget {
  const SalesHistoryView({super.key});

  @override
  ConsumerState<SalesHistoryView> createState() => _SalesHistoryViewState();
}

class _SalesHistoryViewState extends ConsumerState<SalesHistoryView> {
  late Future<_SessionHistoryData?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_SessionHistoryData?> _load() async {
    final vm = ref.read(cashierViewModelProvider);
    if (vm.lastSession == null) return null;

    final sessionId = vm.lastSession!['id'] as String?;
    if (sessionId == null || sessionId.isEmpty) return null;

    final repository = ref.read(cashierRepositoryProvider);
    final transactions = await repository.getSessionTransactions(sessionId);
    final payments = await repository.getSessionPaymentsDetailed(sessionId);
    final summary = await repository.getSessionSummary(sessionId);

    return _SessionHistoryData(
      sessionId: sessionId,
      transactions: transactions,
      payments: payments,
      summary: summary,
      status: vm.lastSession!['status'] as String? ?? 'unknown',
      openedAt: vm.lastSession!['opened_at'] as String?,
      closedAt: vm.lastSession!['closed_at'] as String?,
    );
  }

  Future<void> _reload() async {
    await ref.read(cashierViewModelProvider).refreshSilently();
    if (!mounted) return;
    setState(() {
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Historial de Caja'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go(AppRoutes.cashier),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: FutureBuilder<_SessionHistoryData?>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return _CashierInfoState(
                icon: Icons.error_outline,
                title: 'No se pudo cargar el historial',
                subtitle: '${snapshot.error}',
              );
            }

            final data = snapshot.data;
            if (data == null) {
              return const _CashierInfoState(
                icon: Icons.receipt_long_outlined,
                title: 'No hay sesiones registradas',
                subtitle: 'Abre una caja y procesa ventas para ver movimientos.',
              );
            }

            final currency = NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
            final totalSales = (data.summary['total_sales'] as num?)?.toDouble() ?? 0.0;
            final totalDeposits = (data.summary['total_deposits'] as num?)?.toDouble() ?? 0.0;
            final totalWithdrawals = (data.summary['total_withdrawals'] as num?)?.toDouble() ?? 0.0;
            final totalExpenses = (data.summary['total_expenses'] as num?)?.toDouble() ?? 0.0;
            final startAmount = (data.summary['start_amount'] as num?)?.toDouble() ?? 0.0;
            final expectedAmount = (data.summary['expected_amount'] as num?)?.toDouble() ??
                (totalSales + totalDeposits - totalWithdrawals - totalExpenses);

            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.history, size: 32),
                      const SizedBox(width: 12),
                      const Text(
                        'Historial de ventas',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: MangoColors.darkGray,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () {},
                        icon: const Icon(Icons.videocam_outlined),
                        label: const Text('¿Cómo realizarlo?'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: InputDecoration(
                            hintText: 'Buscar por comprobante, cliente o número de comprobante',
                            prefixIcon: const Icon(Icons.search),
                            filled: true,
                            fillColor: MangoColors.white,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: MangoColors.cardBorder),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: MangoColors.cardBorder),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                              '${DateFormat('dd MMM. yyyy').format(DateTime.now())} → ${DateFormat('dd MMM. yyyy').format(DateTime.now())}',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ],
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
                                ? const Center(child: Text('No hay ventas registradas.'))
                                : ListView.separated(
                                    itemCount: data.payments.length,
                                    separatorBuilder: (_, __) => const Divider(height: 1),
                                    itemBuilder: (context, index) => _PaymentTableRow(
                                      payment: data.payments[index],
                                      currency: currency,
                                    ),
                                  ),
                          ),
                          _buildTableFooter(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
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
          SizedBox(width: 120, child: _HeaderText('Opciones', textAlign: TextAlign.right)),
        ],
      ),
    );
  }

  Widget _buildTableFooter() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            '«  ‹  ',
            style: TextStyle(color: MangoColors.muted.withValues(alpha: 0.5)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: MangoColors.primaryOrange,
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text('1', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
          const Text('  2  3  4  5  6  7  8  ›  »'),
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

  const _PaymentTableRow({required this.payment, required this.currency});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final amount = (payment['amount'] as num?)?.toDouble() ?? 0;
    final createdAt = DateTime.tryParse(payment['created_at']?.toString() ?? '');
    final dateStr = createdAt == null ? '-' : DateFormat('dd/MM/yyyy').format(createdAt.toLocal());
    final timeStr = createdAt == null ? '-' : DateFormat('hh:mm a').format(createdAt.toLocal());

    final customerName = payment['customer_name']?.toString() ?? 'Público General';
    final ncf = payment['ncf_number']?.toString() ?? 'Ticket';
    final ncfType = payment['ncf_type_name']?.toString() ?? 'Boleta';
    final taxId = payment['customer_tax_id']?.toString() ?? '';
    final waiterName = payment['waiter_name']?.toString() ?? 'Servicio';
    final orderId = payment['order_id']?.toString() ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(dateStr, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(timeStr, style: const TextStyle(fontSize: 12, color: MangoColors.muted)),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ncfType, style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(ncf, style: const TextStyle(fontSize: 12, color: MangoColors.muted)),
              ],
            ),
          ),
          Expanded(flex: 2, child: Text(waiterName)),
          Expanded(flex: 2, child: Text(customerName)),
          Expanded(flex: 2, child: Text(taxId.isEmpty ? '-' : taxId)),
          Expanded(
            flex: 2,
            child: Text(
              currency.format(amount),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          SizedBox(
            width: 120,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.visibility_outlined, size: 20),
                  onPressed: () => _showDetailDialog(context, ref, orderId),
                  tooltip: 'Ver detalle',
                  color: MangoColors.muted,
                ),
                IconButton(
                  icon: const Icon(Icons.print_outlined, size: 20),
                  onPressed: () => _reprintInvoice(context, ref, orderId),
                  tooltip: 'Reimprimir',
                  color: Colors.blue,
                ),
                IconButton(
                  icon: const Icon(Icons.cancel_outlined, size: 20, color: Colors.redAccent),
                  onPressed: () {
                    // Anular (Implementar si es requerido)
                  },
                  tooltip: 'Anular',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _reprintInvoice(BuildContext context, WidgetRef ref, String orderId) async {
    if (orderId.isEmpty) return;

    try {
      final scaffold = ScaffoldMessenger.of(context);
      scaffold.showSnackBar(const SnackBar(content: Text('Generando impresión...')));

      final salesRepo = ref.read(salesRepositoryProvider);
      final bundle = await salesRepo.getOrderBundle(orderId);
      if (bundle.order == null) throw Exception('No se encontró la orden.');

      // Fetch payments for this order
      final paymentsRaw = await Supabase.instance.client
          .from('payments')
          .select('*, payment_methods(name, code)')
          .eq('order_id', orderId)
          .eq('status', 'completed');

      final payments = List<Map<String, dynamic>>.from(paymentsRaw).map((p) {
        final map = p;
        final method = map['payment_methods'];
        return Payment.fromMap({
          ...map,
          'payment_method_name': (method as Map?)?['name'],
          'payment_method_code': (method as Map?)?['code'],
        });
      }).toList();

      // Loading business profile (simplified, usually from a provider)
      final session = ref.read(sessionProvider);
      final businessId = session.activeBusinessId;
      if (businessId == null || businessId.isEmpty) {
        throw Exception('No se pudo resolver el negocio activo.');
      }

      final profileRaw = await Supabase.instance.client
          .from('businesses')
          .select()
          .eq('id', businessId)
          .maybeSingle();

      final waiterName = waiterNameFromPayment ?? 'Servicio';

      final printRepo = ref.read(printingPrintersRepositoryProvider);
      final assignedPrinter = await printRepo.getAssignedPrinterForType(
        businessId: businessId,
        preferredAreaCodes: const ['fiscal', 'cashier'],
        printsReceipts: true,
      );

      if (assignedPrinter == null || assignedPrinter.ipAddress == null) {
        throw Exception('No hay impresora configurada para recibos.');
      }

      final ticket = PrintTicketService.generateInvoice(
        order: bundle.order!,
        items: bundle.items,
        payments: payments,
        tableName: payment['table_code']?.toString() ?? 'Mesa',
        waiterName: waiterName,
        businessName: profileRaw?['name'],
        legalName: profileRaw?['legal_name'],
        businessAddress: profileRaw?['address'],
        businessPhone: profileRaw?['phone'],
        businessRnc: profileRaw?['rnc'],
        fiscalNcf: payment['ncf_number']?.toString(),
        fiscalType: payment['ncf_type_name']?.toString(),
        customerName: payment['customer_name']?.toString(),
        customerTaxId: payment['customer_tax_id']?.toString(),
        title: '*** REIMPRESION ***',
      );

      if (kIsWeb) {
        final up = await printRepo.isAgentUp();
        if (!up) {
           throw Exception('Para imprimir desde la Web necesitas el Agente LAN activo en tu PC.');
        }
        await printRepo.printRawViaAgent(
          ip: assignedPrinter.ipAddress!,
          port: assignedPrinter.port ?? 9100,
          data: ticket.escPosCommands,
        );
      } else {
        await printRepo.printRawDirectTcp(
          ip: assignedPrinter.ipAddress!,
          port: assignedPrinter.port ?? 9100,
          data: ticket.escPosCommands,
        );
      }

      scaffold.showSnackBar(const SnackBar(content: Text('Impresión enviada correctamente.')));
    } catch (e) {
      if (context.mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Error de Impresión'),
            content: Text(e.toString()),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
          ),
        );
      }
    }
  }

  void _showDetailDialog(BuildContext context, WidgetRef ref, String orderId) async {
    if (orderId.isEmpty) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Productos Orden #${orderId.substring(0, 8).toUpperCase()}'),
        content: FutureBuilder<List<OrderItem>>(
          future: ref.read(salesRepositoryProvider).getOrderItems(orderId),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 100, // Fixed height for loading state
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return SizedBox(
                height: 100, // Fixed height for error state
                child: Center(child: Text('Error: ${snapshot.error}')),
              );
            }
            final items = snapshot.data ?? [];
            return SizedBox(
              width: 400,
              child: items.isEmpty
                  ? const Text('No se encontraron productos.')
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const Divider(),
                      itemBuilder: (context, i) {
                        final item = items[i];
                        return ListTile(
                          title: Text(item.productName),
                          trailing: Text('x${item.quantity.toInt()}'),
                          subtitle: Text('Total: ${currency.format(item.total)}'),
                        );
                      },
                    ),
            );
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar')),
        ],
      ),
    );
  }

  String? get waiterNameFromPayment => payment['waiter_name']?.toString();
}

class _SessionHistoryData {
  final String sessionId;
  final List<CashTransaction> transactions;
  final List<Map<String, dynamic>> payments;
  final Map<String, dynamic> summary;
  final String status;
  final String? openedAt;
  final String? closedAt;

  const _SessionHistoryData({
    required this.sessionId,
    required this.transactions,
    required this.payments,
    required this.summary,
    required this.status,
    required this.openedAt,
    required this.closedAt,
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
