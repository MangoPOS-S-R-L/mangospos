import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/models/payment_models.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';

class CashClosuresView extends ConsumerStatefulWidget {
  const CashClosuresView({super.key});

  @override
  ConsumerState<CashClosuresView> createState() => _CashClosuresViewState();
}

class _CashClosuresViewState extends ConsumerState<CashClosuresView> {
  late Future<List<CashRegisterSession>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<CashRegisterSession>> _load() async {
    final vm = ref.read(cashierViewModelProvider);
    final registerId = vm.currentRegisterId;
    if (registerId == null || registerId.isEmpty) {
      return [];
    }
    return ref
        .read(cashierRepositoryProvider)
        .getSessionsByRegister(registerId);
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
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Cierre ${session.id.substring(0, 8).toUpperCase()}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Monto inicial: ${currency.format((summary["start_amount"] as num?)?.toDouble() ?? 0)}',
              ),
              Text('Ventas: ${currency.format(totalSales)}'),
              Text('Depósitos: ${currency.format(totalDeposits)}'),
              Text('Retiros: ${currency.format(totalWithdrawals)}'),
              Text('Gastos: ${currency.format(totalExpenses)}'),
              Text('Esperado: ${currency.format(expectedAmount)}'),
              Text('Monto final: ${currency.format(session.endAmount ?? 0)}'),
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
                final closedAt = session.closedAt != null
                    ? DateFormat(
                        'dd/MM/yyyy HH:mm',
                      ).format(session.closedAt!.toLocal())
                    : 'Pendiente';

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
                          'Apertura: ${DateFormat('dd/MM/yyyy HH:mm').format(session.openedAt.toLocal())}',
                        ),
                        Text('Cierre: $closedAt'),
                        Text(
                          'Inicio: RD\$ ${session.startAmount.toStringAsFixed(2)} · Final: RD\$ ${(session.endAmount ?? 0).toStringAsFixed(2)}',
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
