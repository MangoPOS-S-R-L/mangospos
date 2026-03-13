import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/models/payment_models.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';

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

            final currency = NumberFormat.currency(symbol: 'RD\$ ', decimalDigits: 2);
            final totalSales =
                (data.summary['total_sales'] as num?)?.toDouble() ?? 0.0;
            final totalDeposits =
                (data.summary['total_deposits'] as num?)?.toDouble() ?? 0.0;
            final totalWithdrawals =
                (data.summary['total_withdrawals'] as num?)?.toDouble() ?? 0.0;
            final totalExpenses =
                (data.summary['total_expenses'] as num?)?.toDouble() ?? 0.0;
            final startAmount =
                (data.summary['start_amount'] as num?)?.toDouble() ?? 0.0;
            final expectedAmount =
                (data.summary['expected_amount'] as num?)?.toDouble() ??
                (totalSales +
                    totalDeposits -
                    totalWithdrawals -
                    totalExpenses);

            return ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    _SummaryCard(
                      title: 'Monto inicial',
                      value: currency.format(startAmount),
                      color: MangoColors.primaryOrange,
                    ),
                    _SummaryCard(
                      title: 'Ventas efectivo',
                      value: currency.format(totalSales),
                      color: MangoColors.successGreen,
                    ),
                    _SummaryCard(
                      title: 'Depósitos',
                      value: currency.format(totalDeposits),
                      color: Colors.blue,
                    ),
                    _SummaryCard(
                      title: 'Retiros',
                      value: currency.format(totalWithdrawals),
                      color: Colors.red,
                    ),
                    _SummaryCard(
                      title: 'Gastos',
                      value: currency.format(totalExpenses),
                      color: const Color(0xFFF97316),
                    ),
                    _SummaryCard(
                      title: 'Esperado',
                      value: currency.format(expectedAmount),
                      color: MangoColors.primaryOrange,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _SessionHeaderCard(data: data),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Movimientos de la sesión',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (data.transactions.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 32),
                          child: Center(
                            child: Text('Esta sesión aún no tiene movimientos.'),
                          ),
                        )
                      else
                        ...data.transactions.map(
                          (tx) => _TransactionTile(transaction: tx),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Cobros de ventas (sesión)',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (data.payments.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: Text('No hay cobros registrados aún.'),
                          ),
                        )
                      else
                        ...data.payments.map(
                          (p) => _PaymentAuditTile(payment: p),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
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

class _SessionHeaderCard extends StatelessWidget {
  final _SessionHistoryData data;

  const _SessionHeaderCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final openedAt = data.openedAt != null
        ? DateFormat('dd/MM/yyyy HH:mm').format(DateTime.parse(data.openedAt!).toLocal())
        : '-';
    final closedAt = data.closedAt != null
        ? DateFormat('dd/MM/yyyy HH:mm').format(DateTime.parse(data.closedAt!).toLocal())
        : 'Abierta';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: data.status == 'open'
                  ? MangoColors.successGreen
                  : MangoColors.primaryOrange,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sesión ${data.sessionId.substring(0, 8).toUpperCase()}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text('Abierta: $openedAt'),
                Text('Cerrada: $closedAt'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String title;
  final String value;
  final Color color;

  const _SummaryCard({
    required this.title,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: Colors.grey[600])),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _TransactionTile extends StatelessWidget {
  final CashTransaction transaction;

  const _TransactionTile({required this.transaction});

  @override
  Widget build(BuildContext context) {
    final isPositive =
        transaction.type == 'sale' || transaction.type == 'deposit';
    final color = isPositive ? MangoColors.successGreen : Colors.red;
    final icon = switch (transaction.type) {
      'sale' => Icons.point_of_sale,
      'deposit' => Icons.south_west,
      'withdrawal' => Icons.north_east,
      'expense' => Icons.money_off,
      _ => Icons.receipt_long,
    };

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.12),
        child: Icon(icon, color: color),
      ),
      title: Text(transaction.description ?? 'Movimiento'),
      subtitle: Text(
        '${_labelForType(transaction.type)} · ${DateFormat('dd/MM/yyyy HH:mm').format(transaction.createdAt.toLocal())}',
      ),
      trailing: Text(
        '${isPositive ? '+' : '-'}RD\$ ${transaction.amount.toStringAsFixed(2)}',
        style: TextStyle(fontWeight: FontWeight.w700, color: color),
      ),
    );
  }

  String _labelForType(String type) {
    switch (type) {
      case 'sale':
        return 'Venta';
      case 'deposit':
        return 'Depósito';
      case 'withdrawal':
        return 'Retiro';
      case 'expense':
        return 'Gasto';
      default:
        return type;
    }
  }
}

class _PaymentAuditTile extends StatelessWidget {
  final Map<String, dynamic> payment;

  const _PaymentAuditTile({required this.payment});

  @override
  Widget build(BuildContext context) {
    final amount = (payment['amount'] as num?)?.toDouble() ?? 0;
    final change = (payment['change_amount'] as num?)?.toDouble() ?? 0;
    final method = payment['method_name']?.toString() ?? 'Metodo';
    final orderId = payment['order_id']?.toString();
    final checkLabel =
        payment['check_label']?.toString() ??
        (payment['check_position'] != null
            ? 'C${payment['check_position']}'
            : null);
    final customerName = payment['customer_name']?.toString();
    final tableCode = payment['table_code']?.toString();
    final createdAt = DateTime.tryParse(payment['created_at']?.toString() ?? '');
    final when = createdAt == null
        ? '-'
        : DateFormat('dd/MM/yyyy HH:mm').format(createdAt.toLocal());

    final subtitleParts = <String>[
      method,
      if (tableCode != null && tableCode.isNotEmpty) 'Mesa $tableCode',
      if (customerName != null && customerName.isNotEmpty) customerName,
      if (checkLabel != null && checkLabel.isNotEmpty) checkLabel,
      when,
    ];

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: MangoColors.primaryOrange.withValues(alpha: 0.12),
        child: const Icon(Icons.payments_outlined, color: MangoColors.primaryOrange),
      ),
      title: Text(
        'Orden ${orderId == null ? '-' : '#${orderId.substring(0, 8).toUpperCase()}'}',
      ),
      subtitle: Text(subtitleParts.join(' · ')),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            'RD\$ ${amount.toStringAsFixed(2)}',
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: MangoColors.successGreen,
            ),
          ),
          if (change > 0)
            Text(
              'Cambio RD\$ ${change.toStringAsFixed(2)}',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[700],
                fontWeight: FontWeight.w500,
              ),
            ),
        ],
      ),
    );
  }
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
    return ListView(
      children: [
        SizedBox(
          height: MediaQuery.of(context).size.height * 0.65,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 64, color: Colors.grey[400]),
                const SizedBox(height: 16),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
