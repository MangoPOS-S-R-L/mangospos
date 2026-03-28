import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/utils/app_time.dart';
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
      final totalSales = (summary["total_sales"] as num?)?.toDouble() ?? 0;
      final totalDeposits =
          (summary["total_deposits"] as num?)?.toDouble() ?? 0;
      final totalWithdrawals =
          (summary["total_withdrawals"] as num?)?.toDouble() ?? 0;
      final totalExpenses =
          (summary["total_expenses"] as num?)?.toDouble() ?? 0;
      final expectedAmount =
          (summary["expected_amount"] as num?)?.toDouble() ??
          (totalSales + totalDeposits - totalWithdrawals - totalExpenses);
      final expectedCash =
          (summary["expected_cash"] as num?)?.toDouble() ?? expectedAmount;
      final expectedCard = (summary["expected_card"] as num?)?.toDouble() ?? 0;
      final expectedTransfer =
          (summary["expected_transfer"] as num?)?.toDouble() ?? 0;
      final reported = _reportedBreakdown(session);
      final cashierName = _resolveCashierName(session);
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Cierre ${session.id.substring(0, 8).toUpperCase()}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Cajero: $cashierName'),
              const SizedBox(height: 4),
              Text(
                'Monto inicial: ${currency.format((summary["start_amount"] as num?)?.toDouble() ?? 0)}',
              ),
              Text('Ventas: ${currency.format(totalSales)}'),
              Text('Depósitos: ${currency.format(totalDeposits)}'),
              Text('Retiros: ${currency.format(totalWithdrawals)}'),
              Text('Gastos: ${currency.format(totalExpenses)}'),
              const SizedBox(height: 8),
              Text('Esperado efectivo: ${currency.format(expectedCash)}'),
              Text('Esperado tarjeta: ${currency.format(expectedCard)}'),
              Text(
                'Esperado transferencia: ${currency.format(expectedTransfer)}',
              ),
              const SizedBox(height: 8),
              Text('Reportado efectivo: ${currency.format(reported.cash)}'),
              Text('Reportado tarjeta: ${currency.format(reported.card)}'),
              Text(
                'Reportado transferencia: ${currency.format(reported.transfer)}',
              ),
              Text('Esperado: ${currency.format(expectedAmount)}'),
              Text('Monto final: ${currency.format(reported.total)}'),
              Text('Diferencia: ${currency.format(session.difference)}'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No se pudo cargar el resumen del cierre: $e'),
          backgroundColor: Colors.red[600],
        ),
      );
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
