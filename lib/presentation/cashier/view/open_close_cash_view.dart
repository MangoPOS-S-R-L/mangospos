import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';

class OpenCloseCashView extends ConsumerStatefulWidget {
  const OpenCloseCashView({super.key});

  static const _brandOrange = Color(0xFFF7941A);
  static const _brandGreen = Color(0xFF66BB6A);

  @override
  ConsumerState<OpenCloseCashView> createState() => _OpenCloseCashViewState();
}

class _OpenCloseCashViewState extends ConsumerState<OpenCloseCashView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(cashierViewModelProvider).init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(cashierViewModelProvider);
    final isActive =
        vm.lastSession != null && vm.lastSession!['status'] == 'open';

    return Scaffold(
      backgroundColor: Colors.white,
      body: vm.isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Apertura y cierre',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: OpenCloseCashView._brandOrange,
                        ),
                      ),
                      if (!isActive)
                        ElevatedButton.icon(
                          onPressed: () {
                            showDialog(
                              context: context,
                              builder: (c) => const _OpenCashDialog(),
                            );
                          },
                          icon: const Icon(
                            Icons.point_of_sale,
                            color: Colors.white,
                          ),
                          label: const Text(
                            'Aperturar tu caja',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: OpenCloseCashView._brandGreen,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 16,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        )
                      else
                        ElevatedButton.icon(
                          onPressed: () {
                            // Implement Close Box Dialog
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Caja ya está abierta'),
                              ),
                            );
                          },
                          icon: const Icon(Icons.lock, color: Colors.white),
                          label: const Text(
                            'Cerrar Caja',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 16,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 32),

                  // Cards Row
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final isWide = constraints.maxWidth > 800;
                      return Flex(
                        direction: isWide ? Axis.horizontal : Axis.vertical,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Last Close Card
                          SizedBox(
                            width: isWide ? 400 : double.infinity,
                            child: const _LastCloseCard(),
                          ),
                          if (isWide)
                            const SizedBox(width: 24)
                          else
                            const SizedBox(height: 24),
                          // Pending Tables Card
                          SizedBox(
                            width: isWide ? 400 : double.infinity,
                            child: const _PendingTablesCard(),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
    );
  }
}

class _LastCloseCard extends ConsumerWidget {
  const _LastCloseCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(cashierViewModelProvider);
    final session = vm.lastSession;

    // Fallback if no session
    if (session == null) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(child: Text("No hay registros de caja")),
      );
    }

    final isClosed = session['status'] == 'closed';
    final amount = isClosed
        ? (session['end_amount'] ?? 0)
        : (session['start_amount'] ?? 0);
    final date = session['closed_at'] ?? session['opened_at'];
    final dateStr = date != null
        ? DateFormat('dd/MM/yyyy - HH:mm:ss').format(DateTime.parse(date))
        : '-';
    // User name ideally comes from a join or separate fetch. Using ID for now or placeholder
    final userId = session['user_id'] ?? 'Unknown';

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF5F5), // Light pinkish background
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(
            isClosed ? 'ÚLTIMO CIERRE DE CAJA' : 'CAJA ACTUAL (ABIERTA)',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            NumberFormat.currency(symbol: 'RD\$').format(amount),
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: Color(0xFFE57373), // Redish color
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.calendar_today, size: 16, color: Colors.grey),
              const SizedBox(width: 8),
              Text(
                'Fecha: $dateStr',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.person, size: 16, color: Colors.grey),
              const SizedBox(width: 8),
              Text(
                'Usuario ID: ${userId.toString().substring(0, 8)}...',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PendingTablesCard extends ConsumerWidget {
  const _PendingTablesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // You might want to bind this to SalesViewModel or CashierViewModel if it fetches open orders
    final vm = ref.watch(cashierViewModelProvider);
    final count = vm.pendingTables;

    return Stack(
      children: [
        Container(
          height: 180,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '$count',
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'mesas',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.arrow_forward, size: 16),
                label: const Text('Ir a mesas'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: OpenCloseCashView._brandOrange,
                  side: const BorderSide(color: OpenCloseCashView._brandOrange),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (count > 0)
          Positioned(
            top: 16,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: const BoxDecoration(
                color: OpenCloseCashView._brandOrange,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(4),
                  bottomLeft: Radius.circular(4),
                ),
              ),
              child: const Text(
                'Te falta por cobrar',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Dialog for Opening Cash
class _OpenCashDialog extends ConsumerStatefulWidget {
  const _OpenCashDialog();

  @override
  ConsumerState<_OpenCashDialog> createState() => _OpenCashDialogState();
}

class _OpenCashDialogState extends ConsumerState<_OpenCashDialog> {
  String _amount = '0';

  @override
  void initState() {
    super.initState();
    initializeDateFormatting('es');
  }

  void _onKeyTap(String value) {
    setState(() {
      if (value == 'backspace') {
        if (_amount.length > 1) {
          _amount = _amount.substring(0, _amount.length - 1);
        } else {
          _amount = '0';
        }
      } else if (value == '00') {
        if (_amount != '0') _amount += '00';
      } else {
        if (_amount == '0') {
          _amount = value;
        } else {
          _amount += value;
        }
      }
    });
  }

  Future<void> _submit() async {
    final double val = double.tryParse(_amount) ?? 0;
    try {
      await ref.read(cashierViewModelProvider).openBox(val);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final double val = double.tryParse(_amount) ?? 0;
    final formatted = NumberFormat.currency(symbol: 'RD\$').format(val);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 400,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Apertura de caja',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Ingresa un monto para iniciar tu caja.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: OpenCloseCashView._brandOrange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                DateFormat('d MMMM, yyyy', 'es').format(DateTime.now()),
                style: const TextStyle(
                  color: OpenCloseCashView._brandOrange,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              formatted,
              style: const TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 24),

            // Numpad + OK Button
            SizedBox(
              height: 320,
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Column(
                      children: [
                        _numpadRow(['1', '2', '3']),
                        _numpadRow(['4', '5', '6']),
                        _numpadRow(['7', '8', '9']),
                        _numpadRow(['00', '0', 'backspace']),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 1,
                    child: SizedBox(
                      height: double.infinity,
                      child: ElevatedButton(
                        onPressed: _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: OpenCloseCashView._brandOrange,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text(
                          'OK',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Footer Buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      side: BorderSide(color: Colors.grey.shade300),
                      foregroundColor: Colors.black87,
                    ),
                    child: const Text('Cancelar'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _amount = '0';
                      });
                      _submit();
                    },
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      side: const BorderSide(
                        color: OpenCloseCashView._brandOrange,
                      ),
                      foregroundColor: OpenCloseCashView._brandOrange,
                    ),
                    child: const Text('Abrir con RD\$0.00'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _numpadRow(List<String> keys) {
    return Expanded(
      child: Row(
        children: keys.map((key) {
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.all(4.0),
              child: OutlinedButton(
                onPressed: () => _onKeyTap(key),
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  side: BorderSide(color: Colors.grey.shade300),
                ),
                child: key == 'backspace'
                    ? const Icon(
                        Icons.backspace_outlined,
                        color: Colors.black87,
                      )
                    : Text(
                        key,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
