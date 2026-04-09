import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/theme/app_spacing.dart';
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
      HapticFeedback.mediumImpact();
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
              state.offlineQueued
                  ? 'Pago guardado offline. Queda pendiente de sincronizar.'
                  : 'Pago procesado exitosamente${state.fiscalDocument != null ? " - NCF: ${state.fiscalDocument!.ncfNumber}" : ""}',
            ),
            backgroundColor: AppColors.success,
            behavior: SnackBarBehavior.floating,
          ),
        );
      });
    }

    return Dialog(
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg)),
      child: Container(
        width: 1100,
        height: 850,
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: state.loading
            ? Center(
                child: CircularProgressIndicator(color: AppColors.primary))
            : Stack(
                children: [
                  Column(
                children: [
                  _buildHeader(context, totalToPay),
                  const Divider(height: 32),
                  const SizedBox(height: AppSpacing.sm),

                  // Tabs de Divisi\u00f3n
                  Row(
                    children: [
                      Expanded(
                        child: _TabButton(
                          label: 'Pago Completo',
                          active: widget.check == null,
                          onTap: () {},
                        ),
                      ),
                      const SizedBox(width: AppSpacing.lg),
                      Expanded(
                        child: _TabButton(
                          label: 'Dividir Cuenta',
                          active: widget.check != null,
                          onTap: () {},
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xxl),

                  // Mensajes de Error
                  if (state.offlineQueued)
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      margin: const EdgeInsets.only(bottom: AppSpacing.lg),
                      decoration: BoxDecoration(
                        color: AppColors.warningBg,
                        borderRadius: BorderRadius.circular(AppRadius.button),
                        border: Border.all(color: AppColors.warning),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.cloud_off_rounded,
                              color: AppColors.warning),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Text(
                              'Pago guardado localmente. Se sincronizar\u00e1 cuando vuelva la conexi\u00f3n.',
                              style: TextStyle(
                                color: AppColors.warning,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (state.error != null && !state.offlineQueued)
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      margin: const EdgeInsets.only(bottom: AppSpacing.xl),
                      constraints: const BoxConstraints(maxHeight: 100),
                      decoration: BoxDecoration(
                        color: AppColors.destructive.withValues(alpha:0.06),
                        borderRadius: BorderRadius.circular(AppRadius.button),
                        border: Border.all(
                            color: AppColors.destructive.withValues(alpha:0.2)),
                      ),
                      child: SingleChildScrollView(
                        child: Row(
                          children: [
                            Icon(Icons.error_outline,
                                color: AppColors.destructive),
                            const SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: Text(
                                _cleanErrorMessage(state.error!),
                                style: TextStyle(
                                  color: AppColors.destructive,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            if (needsCashSession) ...[
                              const SizedBox(width: AppSpacing.md),
                              TextButton(
                                onPressed: () => _goToCashier(context),
                                style: TextButton.styleFrom(
                                  foregroundColor: AppColors.destructive,
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
                        Expanded(
                          flex: 2,
                          child: _buildRightSide(state, viewModel),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: AppSpacing.xxl),

                  // Botones de Acci\u00f3n
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 56,
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: AppColors.border),
                              shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(AppRadius.lg),
                              ),
                              foregroundColor: AppColors.foreground,
                            ),
                            child: const Text(
                              'Cancelar',
                              style: TextStyle(fontSize: 16),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.lg),
                      Expanded(
                        flex: 2,
                        child: SizedBox(
                          height: 56,
                          child: ElevatedButton(
                            onPressed: state.canProcessPayment
                                ? () => viewModel.processPayment()
                                : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor:
                                  AppColors.muted,
                              elevation: 2,
                              shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(AppRadius.lg),
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
                  // Overlay while payment is processing
                  if (state.processingPayment)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(AppRadius.lg),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CircularProgressIndicator(color: AppColors.primary),
                            const SizedBox(height: 16),
                            Text(
                              'Procesando pago...',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: AppColors.foreground,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  String _cleanErrorMessage(String error) {
    if (error.contains('fn_process_payment')) {
      return 'Error de configuraci\u00f3n: Funci\u00f3n de pago no encontrada en base de datos.';
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
                color: AppColors.primaryBg,
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: Icon(
                Icons.wallet,
                color: AppColors.primary,
                size: 28,
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Procesar Pago',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                    color: AppColors.foreground,
                  ),
                ),
                Text(
                  'Orden #${widget.order.id.substring(0, 8)}',
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.mutedForeground,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.foreground,
            borderRadius: BorderRadius.circular(AppRadius.badge),
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
          'M\u00c9TODOS DE PAGO',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: AppColors.mutedForeground,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        if (state.paymentMethods.isEmpty)
          Center(
            child: Text(
              'No hay m\u00e9todos disponibles',
              style: TextStyle(color: AppColors.mutedForeground),
            ),
          ),
        Wrap(
          spacing: AppSpacing.lg,
          runSpacing: AppSpacing.lg,
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
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        boxShadow: AppShadows.soft,
        border: Border.all(color: AppColors.border.withValues(alpha:0.5)),
      ),
      child: Column(
        children: [
          _SummaryRow(label: 'Total General', value: total, isMain: true),
          const Divider(height: 24),
          _SummaryRow(
              label: 'Recibido', value: paid, color: AppColors.success),
          const SizedBox(height: AppSpacing.sm),
          if (pending > 0)
            _SummaryRow(
              label: 'Pendiente',
              value: pending,
              color: AppColors.destructive,
              isBold: true,
            ),
          if (change > 0)
            _SummaryRow(
              label: 'Cambio',
              value: change,
              color: AppColors.primary,
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
          'Selecciona un m\u00e9todo',
          style: TextStyle(color: AppColors.mutedForeground),
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
                color: AppColors.mutedForeground,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              decoration: InputDecoration(
                hintText: 'N\u00famero de autorizaci\u00f3n / referencia',
                filled: true,
                fillColor: AppColors.card,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.all(AppSpacing.xl),
              ),
              style: const TextStyle(fontSize: 18),
              onChanged: (value) => viewModel.setReference(value),
            ),
          ],
        );
      }
      return const SizedBox();
    }

    // L\u00f3gica para Efectivo: Display + Chips + Numpad
    return Column(
      children: [
        // Display del Monto
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xxl, vertical: AppSpacing.xl),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: AppColors.primary, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha:0.05),
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
                  color: AppColors.mutedForeground,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                'RD\$ ${state.amountReceived.toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),

        // Chips de Montos R\u00e1pidos
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _QuickAmountButton(
                amount: 50,
                onTap: () => viewModel.addToAmountReceived(50),
              ),
              const SizedBox(width: AppSpacing.sm),
              _QuickAmountButton(
                amount: 100,
                onTap: () => viewModel.addToAmountReceived(100),
              ),
              const SizedBox(width: AppSpacing.sm),
              _QuickAmountButton(
                amount: 500,
                onTap: () => viewModel.addToAmountReceived(500),
              ),
              const SizedBox(width: AppSpacing.sm),
              _QuickAmountButton(
                amount: 1000,
                onTap: () => viewModel.addToAmountReceived(1000),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),

        // Numpad
        Expanded(
          child: Center(
            child: _Numpad(
              onNumberTap: (digit) {
                final current = state.amountReceived;
                if (current > 999999) return;

                final isDec = current % 1 != 0;
                final str = isDec
                    ? current.toString()
                    : current.toInt().toString();

                if (str == '0') {
                  viewModel.setAmountReceived(double.parse(digit));
                } else {
                  final newStr = '$str$digit';
                  viewModel.setAmountReceived(
                    double.tryParse(newStr) ?? current,
                  );
                }
              },
              onClear: () => viewModel.clearAmountReceived(),
              onBackspace: () {
                final str = state.amountReceived.toString();
                if (str.length > 1) {
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
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 140,
        height: 100,
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primaryBg : AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.border,
            width: isSelected ? 2 : 1.5,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha:0.15),
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
              color: isSelected ? AppColors.primary : AppColors.mutedForeground,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              method.name,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color:
                    isSelected ? AppColors.primary : AppColors.mutedForeground,
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
      color: AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.badge),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.badge),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.badge),
            border: Border.all(color: AppColors.border),
          ),
          child: Text(
            '+${amount.toInt()}',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.foreground,
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
      mainAxisSpacing: AppSpacing.md,
      crossAxisSpacing: AppSpacing.md,
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
        _NumpadButton(label: '\u232b', onTap: onBackspace, isAction: true),
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
      color: isAction ? AppColors.secondary : AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      elevation: isAction ? 0 : 1,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: isAction ? null : Border.all(color: AppColors.border),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 24,
              fontWeight: isAction ? FontWeight.w600 : FontWeight.w500,
              color: isAction ? AppColors.destructive : AppColors.foreground,
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
            color: isMain ? AppColors.foreground : AppColors.mutedForeground,
          ),
        ),
        Text(
          'RD\$ ${value.toStringAsFixed(2)}',
          style: TextStyle(
            fontSize: isMain ? 20 : 16,
            fontWeight: FontWeight.bold,
            color: color ?? AppColors.foreground,
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
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 50,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? AppColors.foreground : AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(
            color: active ? AppColors.foreground : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : AppColors.mutedForeground,
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}
