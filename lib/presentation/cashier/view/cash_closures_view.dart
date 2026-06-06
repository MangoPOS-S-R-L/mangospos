import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/utils/app_time.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/models/payment_models.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class CashClosuresView extends ConsumerStatefulWidget {
  const CashClosuresView({super.key});

  @override
  ConsumerState<CashClosuresView> createState() => _CashClosuresViewState();
}

class _CashClosuresViewState extends ConsumerState<CashClosuresView> {
  late Future<List<CashRegisterSession>> _future;
  Map<String, String> _cashierNames = const {};

  ({double cash, double card, double transfer, double total})
  _reportedBreakdown(CashRegisterSession session) {
    final notes = session.notes ?? '';

    double extract(String label) {
      final match = RegExp(
        '$label:\\s*([0-9]+(?:\\.[0-9]+)?)',
      ).firstMatch(notes);
      if (match == null) return 0;
      return double.tryParse(match.group(1) ?? '') ?? 0;
    }

    final cash = extract('Efectivo');
    final card = extract('Tarjetas');
    final transfer = extract('Transferencias');
    final total = extract('Total reportado');

    return (
      cash: cash,
      card: card,
      transfer: transfer,
      total: total > 0 ? total : cash + card + transfer,
    );
  }

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<CashRegisterSession>> _load() async {
    final vm = ref.read(cashierViewModelProvider);
    final registerId = vm.currentRegisterId;
    if (registerId == null || registerId.isEmpty) {
      if (mounted) {
        setState(() => _cashierNames = const {});
      }
      return [];
    }

    final sessions = await ref
        .read(cashierRepositoryProvider)
        .getSessionsByRegister(registerId);
    final names = await _loadCashierNames(sessions);
    if (mounted) {
      setState(() => _cashierNames = names);
    }
    return sessions;
  }

  Future<Map<String, String>> _loadCashierNames(
    List<CashRegisterSession> sessions,
  ) async {
    final userIds = sessions
        .map((session) => session.userId.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (userIds.isEmpty) return const {};

    try {
      final rows = await Supabase.instance.client
          .from('profiles')
          .select('id, full_name')
          .inFilter('id', userIds);

      final map = <String, String>{};
      for (final row in List<Map<String, dynamic>>.from(rows)) {
        final id = row['id']?.toString();
        final name = row['full_name']?.toString().trim();
        if (id == null || id.isEmpty) continue;
        if (name == null || name.isEmpty) continue;
        map[id] = name;
      }
      return map;
    } catch (_) {
      return const {};
    }
  }

  String _resolveCashierName(CashRegisterSession session) {
    final resolved = _cashierNames[session.userId]?.trim();
    if (resolved != null && resolved.isNotEmpty) return resolved;
    if (session.userId.trim().isEmpty) return 'No identificado';
    return 'Usuario ${session.userId.substring(0, 8).toUpperCase()}';
  }

  Future<void> _reload() async {
    await ref.read(cashierViewModelProvider).refreshSilently();
    if (!mounted) return;
    setState(() {
      _future = _load();
    });
  }

  Future<void> _showSummary(CashRegisterSession session) async {
    try {
      final summary = await ref
          .read(cashierRepositoryProvider)
          .getSessionSummary(session.id);
      if (!mounted) return;

      final currency = NumberFormat.currency(symbol: 'RD\$ ', decimalDigits: 2);
      final cashSales = (summary["cash_sales_net"] as num?)?.toDouble() ??
          (summary["total_sales"] as num?)?.toDouble() ?? 0;
      final cardSales = (summary["expected_card"] as num?)?.toDouble() ?? 0;
      final transferSales =
          (summary["expected_transfer"] as num?)?.toDouble() ?? 0;
      final totalSalesAll =
          (summary["total_sales_all_methods"] as num?)?.toDouble() ??
          (cashSales + cardSales + transferSales);
      final totalDeposits =
          (summary["total_deposits"] as num?)?.toDouble() ?? 0;
      final totalWithdrawals =
          (summary["total_withdrawals"] as num?)?.toDouble() ?? 0;
      final totalExpenses =
          (summary["total_expenses"] as num?)?.toDouble() ?? 0;
      final expectedCash =
          (summary["expected_cash"] as num?)?.toDouble() ?? 0;
      final expectedCard = cardSales;
      final expectedTransfer = transferSales;
      final expectedAmount =
          (summary["expected_total"] as num?)?.toDouble() ??
          (expectedCash + expectedCard + expectedTransfer);
      final reported = _reportedBreakdown(session);
      final cashierName = _resolveCashierName(session);
      showDialog<void>(
        context: context,
        builder: (context) {
          final difference = session.difference;
          final diffColor = difference == 0
              ? Colors.grey[700]
              : (difference > 0 ? Colors.green[700] : Colors.red[700]);

          return Dialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 450),
              padding: const EdgeInsets.all(28),
              child: SingleChildScrollView(
                child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: MangoColors.primaryOrange.withValues(
                            alpha: 0.12,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.receipt_long_rounded,
                          color: MangoColors.primaryOrange,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Resumen de Cierre',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: Colors.black87,
                              ),
                            ),
                            Text(
                              'Sesión ${session.id.substring(0, 8).toUpperCase()}',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey[600],
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.grey[100],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _SummarySection(
                    title: 'INFORMACIÓN GENERAL',
                    children: [
                      _SummaryRow(label: 'Cajero', value: cashierName),
                      _SummaryRow(
                        label: 'Abierta',
                        value: DateFormat(
                          'dd/MM/yyyy HH:mm',
                        ).format(AppTime.astFromInstant(session.openedAt)),
                      ),
                      if (session.closedAt != null)
                        _SummaryRow(
                          label: 'Cerrada',
                          value: DateFormat(
                            'dd/MM/yyyy HH:mm',
                          ).format(AppTime.astFromInstant(session.closedAt!)),
                        ),
                    ],
                  ),
                  const Divider(height: 32),
                  _SummarySection(
                    title: 'VENTAS',
                    children: [
                      _SummaryRow(
                        label: 'Efectivo',
                        value: currency.format(cashSales),
                      ),
                      _SummaryRow(
                        label: 'Tarjeta',
                        value: currency.format(cardSales),
                      ),
                      _SummaryRow(
                        label: 'Transferencia',
                        value: currency.format(transferSales),
                      ),
                      _SummaryRow(
                        label: 'Total ventas',
                        value: currency.format(totalSalesAll),
                        isBold: true,
                      ),
                    ],
                  ),
                  const Divider(height: 32),
                  _SummarySection(
                    title: 'FLUJO DE EFECTIVO',
                    children: [
                      _SummaryRow(
                        label: 'Monto inicial',
                        value: currency.format(
                          (summary["start_amount"] as num?)?.toDouble() ?? 0,
                        ),
                        isBold: true,
                      ),
                      _SummaryRow(
                        label: 'Depósitos (+)',
                        value: currency.format(totalDeposits),
                      ),
                      _SummaryRow(
                        label: 'Retiros (-)',
                        value: currency.format(totalWithdrawals),
                      ),
                      _SummaryRow(
                        label: 'Gastos (-)',
                        value: currency.format(totalExpenses),
                      ),
                    ],
                  ),
                  const Divider(height: 32),
                  _SummarySection(
                    title: 'ESPERADO POR MÉTODO',
                    children: [
                      _SummaryRow(
                        label: 'Esperado Efectivo',
                        value: currency.format(expectedCash),
                        color: MangoColors.primaryOrange,
                        isBold: true,
                      ),
                      _SummaryRow(
                        label: 'Esperado Tarjeta',
                        value: currency.format(expectedCard),
                      ),
                      _SummaryRow(
                        label: 'Esperado Transferencia',
                        value: currency.format(expectedTransfer),
                      ),
                    ],
                  ),
                  const Divider(height: 32),
                  _SummarySection(
                    title: 'RESULTADOS DEL CIERRE',
                    children: [
                      _SummaryRow(
                        label: 'Total Esperado',
                        value: currency.format(expectedAmount),
                        isBold: true,
                      ),
                      _SummaryRow(
                        label: 'Total Reportado',
                        value: currency.format(reported.total),
                        isBold: true,
                        color: Colors.black87,
                      ),
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: diffColor?.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: _SummaryRow(
                          label: 'Diferencia',
                          value: currency.format(difference),
                          isBold: true,
                          color: diffColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  if (session.notes != null && session.notes!.isNotEmpty) ...[
                    _SummarySection(
                      title: 'NOTAS',
                      children: [
                        Text(
                          session.notes!,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey[700],
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: MangoColors.primaryOrange,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      'Entendido',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              ),
            ),
          );
        },
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo cargar el resumen del cierre: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Gestión de Cierres'),
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
        child: FutureBuilder<List<CashRegisterSession>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return ListView(
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.65,
                    child: Center(child: Text('Error: ${snapshot.error}')),
                  ),
                ],
              );
            }

            final sessions = snapshot.data ?? const [];
            if (sessions.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 240),
                  Center(child: Text('No hay cierres registrados todavía.')),
                ],
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.all(24),
              itemCount: sessions.length,
              separatorBuilder: (_, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final session = sessions[index];
                final isOpen = session.isOpen;
                final color = isOpen
                    ? MangoColors.successGreen
                    : MangoColors.primaryOrange;
                final reported = _reportedBreakdown(session);
                final reportedTotal = reported.total > 0
                    ? reported.total
                    : (session.endAmount ?? 0);
                final closedAt = session.closedAt != null
                    ? DateFormat(
                        'dd/MM/yyyy HH:mm',
                      ).format(AppTime.astFromInstant(session.closedAt!))
                    : 'Pendiente';
                final cashierName = _resolveCashierName(session);

                return Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: color.withValues(alpha: 0.15)),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(16),
                    leading: CircleAvatar(
                      backgroundColor: color.withValues(alpha: 0.12),
                      child: Icon(
                        isOpen ? Icons.lock_open : Icons.lock,
                        color: color,
                      ),
                    ),
                    title: Text(
                      'Sesión ${session.id.substring(0, 8).toUpperCase()}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 6),
                        Text(
                          'Apertura: ${DateFormat('dd/MM/yyyy HH:mm').format(AppTime.astFromInstant(session.openedAt))}',
                        ),
                        Text('Cierre: $closedAt'),
                        Text('Cajero: $cashierName'),
                        Text(
                          'Inicio: RD\$ ${session.startAmount.toStringAsFixed(2)} · Final: RD\$ ${reportedTotal.toStringAsFixed(2)}',
                        ),
                        if (!isOpen)
                          Text(
                            'Efectivo: RD\$ ${reported.cash.toStringAsFixed(2)} · Tarjeta: RD\$ ${reported.card.toStringAsFixed(2)} · Transferencia: RD\$ ${reported.transfer.toStringAsFixed(2)}',
                          ),
                        if (!isOpen)
                          Text(
                            'Diferencia: RD\$ ${session.difference.toStringAsFixed(2)}',
                            style: TextStyle(
                              color: session.difference == 0
                                  ? Colors.grey[700]
                                  : Colors.red[700],
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                    trailing: TextButton(
                      onPressed: () => _showSummary(session),
                      child: const Text('Ver resumen'),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _SummarySection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SummarySection({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Colors.grey[500],
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 12),
        ...children,
      ],
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isBold;
  final Color? color;

  const _SummaryRow({
    required this.label,
    required this.value,
    this.isBold = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[700],
              fontWeight: isBold ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isBold ? FontWeight.w700 : FontWeight.w600,
              color: color ?? Colors.grey[900],
            ),
          ),
        ],
      ),
    );
  }
}
