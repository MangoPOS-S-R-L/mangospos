import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/models/payment_models.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';

class IncomeExpenseView extends ConsumerStatefulWidget {
  const IncomeExpenseView({super.key});

  @override
  ConsumerState<IncomeExpenseView> createState() => _IncomeExpenseViewState();
}

class _IncomeExpenseViewState extends ConsumerState<IncomeExpenseView> {
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  String _selectedType = 'deposit';
  bool _isSubmitting = false;
  late Future<_ManualCashData?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<_ManualCashData?> _load() async {
    final repository = ref.read(cashierRepositoryProvider);
    final session = await repository.getCurrentUserActiveSession();
    if (session == null) {
      return null;
    }

    final transactions = await repository.getSessionTransactions(session.id);
    final manualTransactions = transactions
        .where(
          (tx) =>
              tx.type == 'deposit' ||
              tx.type == 'withdrawal' ||
              tx.type == 'expense',
        )
        .toList();

    return _ManualCashData(session: session, transactions: manualTransactions);
  }

  Future<void> _refresh() async {
    await ref.read(cashierViewModelProvider).refreshSilently();
    if (!mounted) return;
    setState(() {
      _future = _load();
    });
  }

  Future<void> _submit(_ManualCashData data) async {
    if (_isSubmitting) return;

    final amount = double.tryParse(_amountController.text.replaceAll(',', '.'));
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ingresa un monto válido')),
      );
      return;
    }

    final description = _descriptionController.text.trim();
    if (description.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Agrega una descripción')),
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      await ref.read(cashierRepositoryProvider).createManualTransaction(
        sessionId: data.session.id,
        amount: amount,
        type: _selectedType,
        description: description,
      );

      _amountController.clear();
      _descriptionController.clear();
      await _refresh();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_labelForType(_selectedType)} registrado correctamente'),
          backgroundColor: MangoColors.successGreen,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No se pudo registrar el movimiento: $e'),
          backgroundColor: Colors.red[600],
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Ingresos y Egresos'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<_ManualCashData?>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return _InfoState(
                icon: Icons.error_outline,
                title: 'No se pudo cargar la caja',
                subtitle: '${snapshot.error}',
              );
            }

            final data = snapshot.data;
            if (data == null) {
              return const _InfoState(
                icon: Icons.lock_outline,
                title: 'No hay una caja abierta',
                subtitle:
                    'Debes aperturar una caja antes de registrar ingresos o egresos.',
              );
            }

            final deposits = data.transactions
                .where((tx) => tx.type == 'deposit')
                .fold<double>(0, (sum, tx) => sum + tx.amount);
            final withdrawals = data.transactions
                .where((tx) => tx.type == 'withdrawal')
                .fold<double>(0, (sum, tx) => sum + tx.amount);
            final expenses = data.transactions
                .where((tx) => tx.type == 'expense')
                .fold<double>(0, (sum, tx) => sum + tx.amount);

            return ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    _MetricCard(
                      title: 'Depósitos',
                      value: deposits,
                      color: Colors.blue,
                    ),
                    _MetricCard(
                      title: 'Retiros',
                      value: withdrawals,
                      color: const Color(0xFFF97316),
                    ),
                    _MetricCard(
                      title: 'Gastos',
                      value: expenses,
                      color: Colors.red,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isWide = constraints.maxWidth > 980;
                    if (isWide) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 5, child: _buildForm(data)),
                          const SizedBox(width: 24),
                          Expanded(flex: 6, child: _buildList(data)),
                        ],
                      );
                    }
                    return Column(
                      children: [
                        _buildForm(data),
                        const SizedBox(height: 24),
                        _buildList(data),
                      ],
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildForm(_ManualCashData data) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Registrar movimiento',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Sesión ${data.session.id.substring(0, 8).toUpperCase()} abierta el ${DateFormat('dd/MM/yyyy HH:mm').format(data.session.openedAt.toLocal())}',
            style: TextStyle(color: Colors.grey[600]),
          ),
          const SizedBox(height: 20),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'deposit',
                label: Text('Ingreso'),
                icon: Icon(Icons.south_west),
              ),
              ButtonSegment(
                value: 'withdrawal',
                label: Text('Retiro'),
                icon: Icon(Icons.north_east),
              ),
              ButtonSegment(
                value: 'expense',
                label: Text('Gasto'),
                icon: Icon(Icons.money_off),
              ),
            ],
            selected: {_selectedType},
            onSelectionChanged: (selection) {
              setState(() {
                _selectedType = selection.first;
              });
            },
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Monto',
              hintText: '0.00',
              prefixText: 'RD\$ ',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _descriptionController,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: 'Descripción',
              hintText: _hintForType(_selectedType),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isSubmitting ? null : () => _submit(data),
              style: ElevatedButton.styleFrom(
                backgroundColor: _colorForType(_selectedType),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              icon: _isSubmitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(_iconForType(_selectedType)),
              label: Text(_isSubmitting
                  ? 'Guardando...'
                  : 'Registrar ${_labelForType(_selectedType)}'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(_ManualCashData data) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Movimientos manuales de la sesión',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          if (data.transactions.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text('Aún no hay ingresos o egresos manuales.'),
              ),
            )
          else
            ...data.transactions.map(
              (tx) => _ManualMovementTile(transaction: tx),
            ),
        ],
      ),
    );
  }

  Color _colorForType(String type) {
    switch (type) {
      case 'deposit':
        return Colors.blue;
      case 'withdrawal':
        return const Color(0xFFF97316);
      case 'expense':
        return Colors.red;
      default:
        return MangoColors.primaryOrange;
    }
  }

  IconData _iconForType(String type) {
    switch (type) {
      case 'deposit':
        return Icons.south_west;
      case 'withdrawal':
        return Icons.north_east;
      case 'expense':
        return Icons.money_off;
      default:
        return Icons.receipt_long;
    }
  }

  String _labelForType(String type) {
    switch (type) {
      case 'deposit':
        return 'ingreso';
      case 'withdrawal':
        return 'retiro';
      case 'expense':
        return 'gasto';
      default:
        return 'movimiento';
    }
  }

  String _hintForType(String type) {
    switch (type) {
      case 'deposit':
        return 'Ej: fondo adicional, reposición de caja';
      case 'withdrawal':
        return 'Ej: retiro parcial, traslado a bóveda';
      case 'expense':
        return 'Ej: compra de hielo, limpieza, mensajería';
      default:
        return 'Describe el movimiento';
    }
  }
}

class _ManualCashData {
  final CashRegisterSession session;
  final List<CashTransaction> transactions;

  const _ManualCashData({
    required this.session,
    required this.transactions,
  });
}

class _MetricCard extends StatelessWidget {
  final String title;
  final double value;
  final Color color;

  const _MetricCard({
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
            NumberFormat.currency(symbol: 'RD\$ ', decimalDigits: 2).format(value),
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

class _ManualMovementTile extends StatelessWidget {
  final CashTransaction transaction;

  const _ManualMovementTile({required this.transaction});

  @override
  Widget build(BuildContext context) {
    final isPositive = transaction.type == 'deposit';
    final color = switch (transaction.type) {
      'deposit' => Colors.blue,
      'withdrawal' => const Color(0xFFF97316),
      'expense' => Colors.red,
      _ => Colors.grey,
    };

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.12),
        child: Icon(
          switch (transaction.type) {
            'deposit' => Icons.south_west,
            'withdrawal' => Icons.north_east,
            'expense' => Icons.money_off,
            _ => Icons.receipt_long,
          },
          color: color,
        ),
      ),
      title: Text(transaction.description ?? 'Movimiento'),
      subtitle: Text(
        '${DateFormat('dd/MM/yyyy HH:mm').format(transaction.createdAt.toLocal())} · ${_typeLabel(transaction.type)}',
      ),
      trailing: Text(
        '${isPositive ? '+' : '-'}RD\$ ${transaction.amount.toStringAsFixed(2)}',
        style: TextStyle(fontWeight: FontWeight.w700, color: color),
      ),
    );
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'deposit':
        return 'Ingreso';
      case 'withdrawal':
        return 'Retiro';
      case 'expense':
        return 'Gasto';
      default:
        return type;
    }
  }
}

class _InfoState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _InfoState({
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
