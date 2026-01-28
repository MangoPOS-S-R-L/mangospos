import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../data/models/payment_models.dart';
import '../../../data/models/sales_models.dart';
import '../state/payment_state.dart';
import '../viewmodel/payment_viewmodel.dart';
import '../../cashier/viewmodel/cashier_viewmodel.dart';

class PaymentModal extends ConsumerStatefulWidget {
  final Order order;
  final OrderCheck? check;
  final VoidCallback onPaymentSuccess;

  const PaymentModal({
    super.key,
    required this.order,
    this.check,
    required this.onPaymentSuccess,
  });

  @override
  ConsumerState<PaymentModal> createState() => _PaymentModalState();
}

class _PaymentModalState extends ConsumerState<PaymentModal> {
  bool _handledPayment = false;

  bool _needsCashSession(PaymentState state) {
    final message = state.error?.toLowerCase();
    if (message == null) return false;
    return message.contains('sesion de caja') ||
        message.contains('sesiA3n de caja');
  }

  void _goToCashier(BuildContext context) {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    context.go(AppRoutes.cashier);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.check != null) {
        ref
            .read(paymentViewModelProvider.notifier)
            .initializeForCheck(widget.order, widget.check!);
      } else {
        ref
            .read(paymentViewModelProvider.notifier)
            .initializeForOrder(widget.order);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(paymentViewModelProvider);
    final viewModel = ref.read(paymentViewModelProvider.notifier);
    final needsCashSession = _needsCashSession(state);
    final totalToPay = state.totalToPay;

    if (state.paymentProcessed && !_handledPayment) {
      _handledPayment = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
        try {
          final cashierVM = ref.read(cashierViewModelProvider.notifier);
          unawaited(cashierVM.refreshSilently());
        } catch (_) {}
        widget.onPaymentSuccess();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Pago procesado exitosamente${state.fiscalDocument != null ? " - NCF: ${state.fiscalDocument!.ncfNumber}" : ""}',
            ),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
      });
    }

    return Dialog(
      backgroundColor: Colors.grey[50], // Fondo sutil
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 1100,
        height: 850,
        padding: const EdgeInsets.all(24),
        child: state.loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  _buildHeader(context, totalToPay),
                  const Divider(height: 32),
                  const SizedBox(height: 8),

                  // Tabs de División (Opcional, si aplica)
                  Row(
                    children: [
                      Expanded(
                        child: _TabButton(
                          label: 'Pago Completo',
                          active: widget.check == null,
                          onTap: () {}, // Lógica de tabs
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _TabButton(
                          label: 'Dividir Cuenta',
                          active: widget.check != null,
                          onTap: () {}, // Lógica de tabs
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Mensajes de Error
                  if (state.error != null)
                    Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 20),
                      constraints: const BoxConstraints(maxHeight: 100),
                      decoration: BoxDecoration(
                        color: Colors.red[50],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red[200]!),
                      ),
                      child: SingleChildScrollView(
                        child: Row(
                          children: [
                            Icon(Icons.error_outline, color: Colors.red[700]),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _cleanErrorMessage(state.error!),
                                style: TextStyle(
                                  color: Colors.red[900],
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            if (needsCashSession) ...[
                              const SizedBox(width: 12),
                              TextButton(
                                onPressed: () => _goToCashier(context),
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.red[900],
                                ),
                                child: const Text('IR A CAJA'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                  // Contenido Principal
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Columna Izquierda: Métodos y Totales
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildPaymentMethods(state, viewModel),
                              const Spacer(),
                              _buildTotalsSummary(state),
                            ],
                          ),
                        ),

                        const VerticalDivider(width: 48),

                        // Columna Derecha: Entrada de Datos y Numpad
                        Expanded(
                          flex: 2,
                          child: _buildRightSide(state, viewModel),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Botones de Acción
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 56,
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: Colors.grey[300]!),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              foregroundColor: Colors.grey[800],
                            ),
                            child: const Text(
                              'Cancelar',
                              style: TextStyle(fontSize: 16),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 2,
                        child: SizedBox(
                          height: 56,
                          child: ElevatedButton(
                            onPressed: state.canProcessPayment
                                ? () => viewModel.processPayment()
                                : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFF26900),
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: Colors.grey[300],
                              elevation: 2,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text(
                              'COMPLETAR PAGO',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1,
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
    );
  }

  String _cleanErrorMessage(String error) {
    if (error.contains('fn_process_payment')) {
      return 'Error de configuración: Función de pago no encontrada en base de datos.';
    }
    return error;
  }

  Widget _buildHeader(BuildContext context, double totalToPay) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF26900).withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.wallet,
                color: Color(0xFFF26900),
                size: 28,
              ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Procesar Pago',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  ),
                ),
                Text(
                  'Orden #${widget.order.id.substring(0, 8)}',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[500],
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(30),
          ),
          child: Text(
            'RD\$ ${totalToPay.toStringAsFixed(2)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPaymentMethods(PaymentState state, PaymentViewModel viewModel) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'MÉTODOS DE PAGO',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Colors.grey[500],
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 16),
        if (state.paymentMethods.isEmpty)
          const Center(child: Text('No hay métodos disponibles')),

        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: state.paymentMethods.map((method) {
            final isSelected = state.selectedMethod?.id == method.id;
            return _PaymentMethodButton(
              method: method,
              isSelected: isSelected,
              onTap: () => viewModel.selectPaymentMethod(method),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildTotalsSummary(PaymentState state) {
    final total = state.totalToPay;
    final paid = state.selectedMethod == null
        ? 0.0
        : (state.isCashPayment ? state.amountReceived : total);
    final pending = (total - paid).clamp(0.0, total).toDouble();
    final change = state.change;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: Colors.grey.shade100),
      ),
      child: Column(
        children: [
          _SummaryRow(label: 'Total General', value: total, isMain: true),
          const Divider(height: 24),
          _SummaryRow(label: 'Recibido', value: paid, color: Colors.green[700]),
          const SizedBox(height: 8),
          if (pending > 0)
            _SummaryRow(
              label: 'Pendiente',
              value: pending,
              color: Colors.red[700],
              isBold: true,
            ),
          if (change > 0)
            _SummaryRow(
              label: 'Cambio',
              value: change,
              color: const Color(0xFFF26900),
              isBold: true,
            ),
        ],
      ),
    );
  }

  Widget _buildRightSide(PaymentState state, PaymentViewModel viewModel) {
    if (state.selectedMethod == null) {
      return Center(
        child: Text(
          'Selecciona un método',
          style: TextStyle(color: Colors.grey[400]),
        ),
      );
    }

    if (!state.isCashPayment) {
      if (state.requiresReference) {
        return Column(
          children: [
            Text(
              'REFERENCIA DE PAGO',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.grey[500],
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              decoration: InputDecoration(
                hintText: 'Número de autorización / referencia',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.all(20),
              ),
              style: const TextStyle(fontSize: 18),
              onChanged: (value) => viewModel.setReference(value),
            ),
          ],
        );
      }
      return const SizedBox();
    }

    // Lógica para Efectivo: Display + Chips + Numpad
    return Column(
      children: [
        // Display del Monto
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFF26900), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFF26900).withOpacity(0.05),
                blurRadius: 15,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Monto Recibido',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[600],
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                'RD\$ ${state.amountReceived.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF2D3142),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Chips de Montos Rápidos
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _QuickAmountButton(
                amount: 50,
                onTap: () => viewModel.addToAmountReceived(50),
              ),
              const SizedBox(width: 8),
              _QuickAmountButton(
                amount: 100,
                onTap: () => viewModel.addToAmountReceived(100),
              ),
              const SizedBox(width: 8),
              _QuickAmountButton(
                amount: 500,
                onTap: () => viewModel.addToAmountReceived(500),
              ),
              const SizedBox(width: 8),
              _QuickAmountButton(
                amount: 1000,
                onTap: () => viewModel.addToAmountReceived(1000),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Numpad
        Expanded(
          child: Center(
            child: _Numpad(
              onNumberTap: (num) {
                final current = state.amountReceived;
                // Evitar decimales extraños o longitud excesiva
                if (current > 999999) return;

                final isDec = current % 1 != 0;
                final str = isDec
                    ? current.toString()
                    : current.toInt().toString();

                // Simple concat logic
                if (str == '0') {
                  viewModel.setAmountReceived(double.parse(num));
                } else {
                  final newStr = '$str$num';
                  viewModel.setAmountReceived(
                    double.tryParse(newStr) ?? current,
                  );
                }
              },
              onClear: () => viewModel.clearAmountReceived(),
              onBackspace: () {
                final str = state.amountReceived.toString();
                // Lógica simple de borrado (truncado)
                // Nota: Manejo robusto de decimales requeriría gestión de estado de string
                if (str.length > 1) {
                  // Hack rápido para borrado visual
                  final s = str.endsWith('.0')
                      ? str.substring(0, str.length - 2)
                      : str;
                  if (s.length > 1) {
                    viewModel.setAmountReceived(
                      double.tryParse(s.substring(0, s.length - 1)) ?? 0,
                    );
                  } else {
                    viewModel.clearAmountReceived();
                  }
                } else {
                  viewModel.clearAmountReceived();
                }
              },
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// SUB-WIDGETS (ESTILIZADOS)
// =============================================================================

class _PaymentMethodButton extends StatelessWidget {
  final PaymentMethod method;
  final bool isSelected;
  final VoidCallback onTap;

  const _PaymentMethodButton({
    required this.method,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 140,
        height: 100,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFFF3E0) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? const Color(0xFFF26900) : Colors.grey.shade200,
            width: isSelected ? 2 : 1.5,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: const Color(0xFFF26900).withOpacity(0.15),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ]
              : [],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _getIcon(),
              size: 32,
              color: isSelected ? const Color(0xFFF26900) : Colors.grey[600],
            ),
            const SizedBox(height: 8),
            Text(
              method.name,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? const Color(0xFFF26900) : Colors.grey[700],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  IconData _getIcon() {
    if (method.isCash) return Icons.payments_outlined;
    if (method.isCard) return Icons.credit_card_outlined;
    if (method.isTransfer) return Icons.account_balance_outlined;
    return Icons.payment_outlined;
  }
}

class _QuickAmountButton extends StatelessWidget {
  final double amount;
  final VoidCallback onTap;

  const _QuickAmountButton({required this.amount, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(30),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(30),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Text(
            '+${amount.toInt()}',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.grey[700],
            ),
          ),
        ),
      ),
    );
  }
}

class _Numpad extends StatelessWidget {
  final Function(String) onNumberTap;
  final VoidCallback onClear;
  final VoidCallback onBackspace;

  const _Numpad({
    required this.onNumberTap,
    required this.onClear,
    required this.onBackspace,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 3,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.6,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        _NumpadButton(label: '1', onTap: () => onNumberTap('1')),
        _NumpadButton(label: '2', onTap: () => onNumberTap('2')),
        _NumpadButton(label: '3', onTap: () => onNumberTap('3')),
        _NumpadButton(label: '4', onTap: () => onNumberTap('4')),
        _NumpadButton(label: '5', onTap: () => onNumberTap('5')),
        _NumpadButton(label: '6', onTap: () => onNumberTap('6')),
        _NumpadButton(label: '7', onTap: () => onNumberTap('7')),
        _NumpadButton(label: '8', onTap: () => onNumberTap('8')),
        _NumpadButton(label: '9', onTap: () => onNumberTap('9')),
        _NumpadButton(label: 'C', onTap: onClear, isAction: true),
        _NumpadButton(label: '0', onTap: () => onNumberTap('0')),
        _NumpadButton(label: '⌫', onTap: onBackspace, isAction: true),
      ],
    );
  }
}

class _NumpadButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool isAction;

  const _NumpadButton({
    required this.label,
    required this.onTap,
    this.isAction = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isAction ? Colors.grey[100] : Colors.white,
      borderRadius: BorderRadius.circular(16),
      elevation: isAction ? 0 : 1,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: isAction ? null : Border.all(color: Colors.grey.shade200),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 24,
              fontWeight: isAction ? FontWeight.w600 : FontWeight.w500,
              color: isAction ? Colors.red[400] : Colors.grey[800],
            ),
          ),
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final double value;
  final Color? color;
  final bool isBold;
  final bool isMain;

  const _SummaryRow({
    required this.label,
    required this.value,
    this.color,
    this.isBold = false,
    this.isMain = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: isMain ? 18 : 15,
            fontWeight: (isBold || isMain) ? FontWeight.bold : FontWeight.w500,
            color: isMain ? Colors.black : Colors.grey[600],
          ),
        ),
        Text(
          'RD\$ ${value.toStringAsFixed(2)}',
          style: TextStyle(
            fontSize: isMain ? 20 : 16,
            fontWeight: FontWeight.bold,
            color: color ?? Colors.black,
          ),
        ),
      ],
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 50,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? Colors.black : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? Colors.black : Colors.grey.shade300,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : Colors.grey[600],
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}
