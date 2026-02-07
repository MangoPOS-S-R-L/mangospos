import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../viewmodel/payment_split_viewmodel.dart';

const _kPrimary = Color(0xFFF7941A);
const _kSurface = Colors.white;
const _kSelection = Color(0xFFFFF3E5);
const _kPositive = Color(0xFF22C55E);
const _kDanger = Color(0xFFE11D48);
const _kBorder = Color(0xFFEEEEEE);

class PaymentSplitDialog extends ConsumerStatefulWidget {
  final String orderId;
  final double totalAmount;
  final String tableName;
  final String? checkId;

  const PaymentSplitDialog({
    super.key,
    required this.orderId,
    required this.totalAmount,
    required this.tableName,
    this.checkId,
  });

  @override
  ConsumerState<PaymentSplitDialog> createState() => _PaymentSplitDialogState();
}

class _PaymentSplitDialogState extends ConsumerState<PaymentSplitDialog> {
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 920;

    final provider = paymentSplitProvider((
      widget.orderId,
      widget.totalAmount,
      widget.checkId,
    ));
    final state = ref.watch(provider);
    final vm = ref.read(provider.notifier);

    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: isMobile ? 12 : 36,
        vertical: isMobile ? 16 : 36,
      ),
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 1150,
          maxHeight: isMobile ? double.infinity : 820,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: _kSurface,
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(
                color: Color(0x22000000),
                blurRadius: 20,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            children: [
              _buildHeader(context),
              const Divider(height: 1, color: _kBorder),
              Expanded(
                child: isMobile
                    ? SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: _MobileLayout(state: state, vm: vm),
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.all(28),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: _LeftPanel(state: state, vm: vm),
                            ),
                            Container(width: 1, color: _kBorder),
                            Expanded(
                              flex: 2,
                              child: _RightPanel(
                                state: state,
                                vm: vm,
                                onClose: () => Navigator.pop(context),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
              if (state.validationError != null || state.error != null)
                _ErrorBar(
                  message: state.validationError ?? state.error!,
                  isDanger: state.error != null,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Color.fromRGBO(247, 148, 26, 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.credit_card, color: _kPrimary, size: 22),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pago - Mesa ${widget.tableName}',
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                'Total: RD\$ ${widget.totalAmount.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 13,
                  color: Colors.grey,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.black54),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// LAYOUTS
// ---------------------------------------------------------------------------

class _LeftPanel extends StatelessWidget {
  final PaymentSplitState state;
  final PaymentSplitViewModel vm;

  final bool compact;

  const _LeftPanel({
    required this.state,
    required this.vm,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final canAdd = state.inputAmount > 0 && !state.isProcessing;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Método de pago',
          style: TextStyle(fontWeight: FontWeight.w700, color: Colors.black87),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _MethodCard(
              label: 'Efectivo',
              icon: Icons.payments_outlined,
              isSelected: state.activeMethod == PaymentMethodType.cash,
              onTap: () => vm.setMethod(PaymentMethodType.cash),
            ),
            const SizedBox(width: 10),
            _MethodCard(
              label: 'Tarjeta',
              icon: Icons.credit_card,
              isSelected: state.activeMethod == PaymentMethodType.card,
              onTap: () => vm.setMethod(PaymentMethodType.card),
            ),
            const SizedBox(width: 10),
            _MethodCard(
              label: 'Transferencia',
              icon: Icons.qr_code_2,
              isSelected: state.activeMethod == PaymentMethodType.transfer,
              onTap: () => vm.setMethod(PaymentMethodType.transfer),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Montos rápidos',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.black87,
              ),
            ),
            Text(
              'Restante: RD\$ ${state.remaining.toStringAsFixed(2)}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: state.remaining > 0 ? _kPrimary : Colors.green[700],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final amount in const [100, 200, 500, 1000, 2000, 5000])
              _QuickAmountChip(
                label: 'RD\$ ${amount.toStringAsFixed(0)}',
                onTap: () => vm.setQuickAmount(amount.toDouble()),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: state.remaining <= 0
                    ? null
                    : () => vm.setExactAmount(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.black87,
                  side: const BorderSide(color: _kBorder),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.bolt, color: _kPrimary),
                label: Text(
                  'Monto exacto (${state.remaining.toStringAsFixed(2)})',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              onPressed: state.currentInput.isEmpty ? null : vm.clearInput,
              icon: const Icon(Icons.clear_outlined),
              tooltip: 'Limpiar monto',
            ),
          ],
        ),
        const SizedBox(height: 16),
        _InputDisplay(state: state),
        const SizedBox(height: 16),
        compact
            ? Column(
                children: [
                  SizedBox(height: 300, child: _NumericKeypad(vm: vm)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: _AddPaymentButton(
                      enabled: canAdd,
                      isLoading: state.isProcessing,
                      onTap: vm.addTransaction,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _InfoCard(state: state),
                ],
              )
            : Expanded(
                child: Row(
                  children: [
                    Expanded(child: _NumericKeypad(vm: vm)),
                    const SizedBox(width: 14),
                    SizedBox(
                      width: 170,
                      child: Column(
                        children: [
                          Expanded(
                            child: _AddPaymentButton(
                              enabled: canAdd,
                              isLoading: state.isProcessing,
                              onTap: vm.addTransaction,
                            ),
                          ),
                          const SizedBox(height: 10),
                          _InfoCard(state: state),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ],
    );
  }
}

class _RightPanel extends StatelessWidget {
  final PaymentSplitState state;
  final PaymentSplitViewModel vm;
  final VoidCallback onClose;

  const _RightPanel({
    required this.state,
    required this.vm,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final canConfirm =
        state.transactions.isNotEmpty &&
        state.isComplete &&
        !state.isProcessing;

    return Padding(
      padding: const EdgeInsets.only(left: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TotalsCard(state: state),
          const SizedBox(height: 16),
          Expanded(
            child: _PaymentList(
              transactions: state.transactions,
              onDelete: vm.removeTransaction,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton.icon(
              onPressed: canConfirm
                  ? () async {
                      final ok = await vm.confirmPayment(context);
                      if (ok && context.mounted) Navigator.pop(context, true);
                    }
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: _kPositive,
                foregroundColor: Colors.white,
                disabledBackgroundColor: _kBorder,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: state.isProcessing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.check_circle_outline),
              label: Text(
                state.isProcessing ? 'Procesando...' : 'Confirmar pago',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton(
              onPressed: onClose,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: _kBorder),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                'Cancelar',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: TextButton.icon(
              onPressed: () => Navigator.pop(context, false),
              style: TextButton.styleFrom(
                foregroundColor: Colors.black87,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.arrow_back_ios_new, size: 18),
              label: const Text(
                'Volver a la mesa',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileLayout extends StatelessWidget {
  final PaymentSplitState state;
  final PaymentSplitViewModel vm;

  const _MobileLayout({required this.state, required this.vm});

  @override
  Widget build(BuildContext context) {
    final canConfirm =
        state.transactions.isNotEmpty &&
        state.isComplete &&
        !state.isProcessing;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TotalsCard(state: state, compact: true),
        const SizedBox(height: 16),
        _LeftPanel(state: state, vm: vm, compact: true),
        const SizedBox(height: 16),
        _PaymentList(
          transactions: state.transactions,
          onDelete: vm.removeTransaction,
          allowScrolling: false,
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: ElevatedButton.icon(
            onPressed: canConfirm
                ? () async {
                    final ok = await vm.confirmPayment(context);
                    if (ok && context.mounted) Navigator.pop(context, true);
                  }
                : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: _kPositive,
              foregroundColor: Colors.white,
              disabledBackgroundColor: _kBorder,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: state.isProcessing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.check),
            label: Text(
              state.isProcessing ? 'Procesando...' : 'Confirmar pago',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton(
            onPressed: () => Navigator.pop(context),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: _kBorder),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'Cancelar',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          height: 46,
          child: TextButton.icon(
            onPressed: () => Navigator.pop(context, false),
            style: TextButton.styleFrom(
              foregroundColor: Colors.black87,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            label: const Text(
              'Volver a la mesa',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// SUB WIDGETS
// ---------------------------------------------------------------------------

class _InputDisplay extends StatelessWidget {
  final PaymentSplitState state;
  const _InputDisplay({required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F8F8),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            'Monto a ingresar',
            style: TextStyle(
              color: Colors.grey[700],
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'RD\$ ${state.currentInput.isEmpty ? "0" : state.currentInput}',
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _NumericKeypad extends StatelessWidget {
  final PaymentSplitViewModel vm;
  const _NumericKeypad({required this.vm});

  @override
  Widget build(BuildContext context) {
    final keys = ['7', '8', '9', '4', '5', '6', '1', '2', '3', '0', '00', '⌫'];

    return LayoutBuilder(
      builder: (context, constraints) {
        return GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          itemCount: keys.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.4,
          ),
          itemBuilder: (context, index) {
            final label = keys[index];
            final isBack = label == '⌫';
            return OutlinedButton(
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: _kBorder),
                backgroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () => isBack ? vm.backspace() : vm.appendInput(label),
              child: isBack
                  ? const Icon(Icons.backspace_outlined)
                  : Text(
                      label,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            );
          },
        );
      },
    );
  }
}

class _MethodCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _MethodCard({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 84,
          decoration: BoxDecoration(
            color: isSelected ? _kSelection : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isSelected ? _kPrimary : _kBorder,
              width: isSelected ? 2 : 1.5,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: isSelected ? _kPrimary : Colors.black87),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: isSelected ? _kPrimary : Colors.black87,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickAmountChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _QuickAmountChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        side: const BorderSide(color: _kBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  final PaymentSplitState state;
  final bool compact;
  const _TotalsCard({required this.state, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final remaining = state.remaining;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F8F8),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SummaryRow(
            'Total a pagar',
            state.totalAmount,
            isBold: true,
            fontSize: compact ? 16 : 18,
          ),
          const SizedBox(height: 8),
          _SummaryRow(
            'Pagado',
            state.totalPaid,
            color: Colors.green[700],
            isBold: true,
          ),
          const SizedBox(height: 8),
          _SummaryRow(
            remaining > 0 ? 'Restante' : 'Cambio',
            remaining > 0 ? remaining : state.change,
            color: remaining > 0 ? _kPrimary : Colors.redAccent,
            isBold: true,
            fontSize: compact ? 18 : 20,
          ),
          if (remaining > 0 && state.transactions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3CD),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFFEEBA)),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.orange[800],
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Este es un pago parcial. El restante deberá cobrarse con otro método.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.orange[900],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final double value;
  final Color? color;
  final bool isBold;
  final double fontSize;
  const _SummaryRow(
    this.label,
    this.value, {
    this.color,
    this.isBold = false,
    this.fontSize = 16,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
        Text(
          'RD\$ ${value.toStringAsFixed(2)}',
          style: TextStyle(
            fontWeight: isBold ? FontWeight.w800 : FontWeight.w700,
            color: color ?? Colors.black,
            fontSize: fontSize,
          ),
        ),
      ],
    );
  }
}

class _PaymentList extends StatelessWidget {
  final List<PaymentTransaction> transactions;
  final void Function(String id) onDelete;
  final bool allowScrolling;

  const _PaymentList({
    required this.transactions,
    required this.onDelete,
    this.allowScrolling = true,
  });

  @override
  Widget build(BuildContext context) {
    if (transactions.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFFCFCFC),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _kBorder),
        ),
        child: const Text(
          'Aún no has agregado pagos.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFCFCFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder),
      ),
      child: ListView.separated(
        shrinkWrap: !allowScrolling,
        physics: allowScrolling
            ? const AlwaysScrollableScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        itemCount: transactions.length,
        separatorBuilder: (context, _) =>
            const Divider(height: 1, color: _kBorder),
        itemBuilder: (context, index) {
          final tx = transactions[index];
          return ListTile(
            dense: true,
            title: Text(
              tx.methodLabel,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              'Hora: ${tx.timestamp.hour.toString().padLeft(2, '0')}:${tx.timestamp.minute.toString().padLeft(2, '0')}',
              style: const TextStyle(color: Colors.grey),
            ),
            trailing: SizedBox(
              width: 150,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    'RD\$ ${tx.amount.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () => onDelete(tx.id),
                    splashRadius: 18,
                    icon: const Icon(Icons.close, color: _kDanger, size: 20),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AddPaymentButton extends StatelessWidget {
  final bool enabled;
  final bool isLoading;
  final VoidCallback onTap;

  const _AddPaymentButton({
    required this.enabled,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: enabled ? onTap : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: _kPrimary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: _kBorder,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      ),
      child: isLoading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Text(
              'Agregar pago',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final PaymentSplitState state;
  const _InfoCard({required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFBF7F3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Detalle',
            style: TextStyle(fontWeight: FontWeight.w800, color: _kPrimary),
          ),
          const SizedBox(height: 6),
          Text(
            'Pagado: RD\$ ${state.totalPaid.toStringAsFixed(2)}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(
            'Restante: RD\$ ${state.remaining.toStringAsFixed(2)}',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: state.remaining > 0 ? _kPrimary : Colors.green[700],
            ),
          ),
          if (state.change > 0)
            Text(
              'Cambio: RD\$ ${state.change.toStringAsFixed(2)}',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.redAccent,
              ),
            ),
        ],
      ),
    );
  }
}

class _ErrorBar extends StatelessWidget {
  final String message;
  final bool isDanger;

  const _ErrorBar({required this.message, this.isDanger = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: isDanger
            ? Color.fromRGBO(225, 29, 72, 0.12)
            : Color.fromRGBO(247, 148, 26, 0.12),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
        border: Border(top: BorderSide(color: isDanger ? _kDanger : _kPrimary)),
      ),
      child: Row(
        children: [
          Icon(
            isDanger ? Icons.error_outline : Icons.info_outline,
            color: isDanger ? _kDanger : _kPrimary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: isDanger ? _kDanger : Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
