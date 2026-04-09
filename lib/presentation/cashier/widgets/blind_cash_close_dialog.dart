import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/cashier/services/print_service.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:mangopos/presentation/cashier/state/cash_close_formatters.dart';
import 'package:mangopos/presentation/cashier/viewmodel/blind_cash_close_viewmodel.dart';
import 'package:mangopos/presentation/cashier/widgets/close_summary_table.dart';
import 'package:mangopos/presentation/cashier/widgets/denomination_counter_row.dart';
import 'package:mangopos/presentation/cashier/widgets/numpad_widget.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class BlindCashCloseDialog extends ConsumerStatefulWidget {
  final String sessionId;
  final CashCloseInput input;
  final Future<void> Function(CashCloseResult result)? onCloseConfirmed;

  const BlindCashCloseDialog({
    super.key,
    required this.sessionId,
    required this.input,
    this.onCloseConfirmed,
  });

  @override
  ConsumerState<BlindCashCloseDialog> createState() =>
      _BlindCashCloseDialogState();
}

class _BlindCashCloseDialogState extends ConsumerState<BlindCashCloseDialog> {
  bool _processingClose = false;
  bool _processingPrint = false;

  Future<void> _showCloseErrorModal(
    BlindCashCloseState state,
    Object error,
  ) async {
    final message = error.toString().replaceFirst('Exception: ', '');
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Error al cerrar caja'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = blindCashCloseProvider(widget.input);
    final state = ref.watch(provider);
    final vm = ref.read(provider.notifier);
    final canCloseDialog =
        state.step == BlindCashCloseStep.count &&
        !_processingClose &&
        !_processingPrint;

    return PopScope(
      canPop: canCloseDialog,
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width < 1200
                ? MediaQuery.of(context).size.width - 48
                : 1180,
            maxHeight: MediaQuery.of(context).size.height < 880
                ? MediaQuery.of(context).size.height - 40
                : 860,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: MangoColors.cardBorder),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(context, state),
                  const SizedBox(height: 14),
                  const Divider(height: 1, color: MangoColors.cardBorder),
                  const SizedBox(height: 14),
                  Expanded(
                    child: state.step == BlindCashCloseStep.count
                        ? _buildCountStep(context, state, vm)
                        : _buildResultStep(context, state),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, BlindCashCloseState state) {
    final canCloseDialog =
        state.step == BlindCashCloseStep.count &&
        !_processingClose &&
        !_processingPrint;
    final title = state.step == BlindCashCloseStep.count
        ? 'Cierre de Caja a Ciegas · Conteo'
        : 'Cierre de Caja a Ciegas · Resultado';
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: MangoColors.primaryOrange.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            state.step == BlindCashCloseStep.count
                ? Icons.point_of_sale_rounded
                : Icons.rule_rounded,
            color: MangoColors.primaryOrange,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: MangoColors.darkGray,
                ),
              ),
              Text(
                'Formato dominicano RD\$ · Cierre de turno',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: MangoColors.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        OutlinedButton.icon(
          onPressed: canCloseDialog
              ? () {
                  ref
                      .read(blindCashCloseProvider(widget.input).notifier)
                      .reset();
                  Navigator.of(context).pop();
                }
              : null,
          icon: const Icon(Icons.close_rounded),
          label: const Text('Cerrar'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.grey.shade700,
            side: const BorderSide(color: MangoColors.cardBorder),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCountStep(
    BuildContext context,
    BlindCashCloseState state,
    BlindCashCloseViewModel vm,
  ) {
    final isWide = MediaQuery.of(context).size.width >= 1040;
    final summaryCard = _countSummary(state);
    final countPanel = _countPanel(state, vm);
    final paymentPanel = _paymentPanel(state, vm);

    return Column(
      children: [
        Expanded(
          child: isWide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 6, child: countPanel),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 5,
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            paymentPanel,
                            const SizedBox(height: 12),
                            summaryCard,
                          ],
                        ),
                      ),
                    ),
                  ],
                )
              : SingleChildScrollView(
                  child: Column(
                    children: [
                      countPanel,
                      const SizedBox(height: 12),
                      paymentPanel,
                      const SizedBox(height: 12),
                      summaryCard,
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            icon: const Icon(Icons.check_circle_outline),
            onPressed: () => _onConfirmCount(state, vm),
            label: const Text('Confirmar Conteo'),
            style: FilledButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _countPanel(BlindCashCloseState state, BlindCashCloseViewModel vm) {
    return _panel(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Conteo de efectivo por denominación',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: MangoColors.darkGray,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 420,
              child: ListView.builder(
                itemCount: state.denominations.length,
                itemBuilder: (context, index) {
                  final d = state.denominations[index];
                  return DenominationCounterRow(
                    denomination: d,
                    onIncrement: () => vm.increment(d.value),
                    onDecrement: () => vm.decrement(d.value),
                    onCountChanged: (count) => vm.setCount(d.value, count),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _paymentPanel(BlindCashCloseState state, BlindCashCloseViewModel vm) {
    Widget amountField({
      required String label,
      required String value,
      required bool active,
      required VoidCallback onTap,
    }) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active
                  ? MangoColors.primaryOrange
                  : MangoColors.cardBorder,
              width: active ? 1.8 : 1,
            ),
            color: active
                ? MangoColors.primaryOrange.withValues(alpha: 0.07)
                : MangoColors.bgLight,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: MangoColors.darkGray,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                formatRD(CashCloseCalculator.parseAmount(value)),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: active
                      ? MangoColors.primaryOrange
                      : MangoColors.darkGray,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return _panel(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tarjetas y Transferencias',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: MangoColors.darkGray,
              ),
            ),
            const SizedBox(height: 10),
            amountField(
              label: 'Total Tarjetas',
              value: state.cardInput,
              active: state.activeInput == BlindCashInputTarget.card,
              onTap: () => vm.setActiveInput(BlindCashInputTarget.card),
            ),
            const SizedBox(height: 10),
            amountField(
              label: 'Total Transferencias',
              value: state.transferInput,
              active: state.activeInput == BlindCashInputTarget.transfer,
              onTap: () => vm.setActiveInput(BlindCashInputTarget.transfer),
            ),
            const SizedBox(height: 12),
            const Text(
              'Teclado numérico',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            NumpadWidget(includeClear: true, onTap: vm.appendNumpad),
          ],
        ),
      ),
    );
  }

  Widget _countSummary(BlindCashCloseState state) {
    final items = [
      ('Efectivo', state.totalCounted),
      ('Tarjetas', state.numericCard),
      ('Transferencias', state.numericTransfer),
      ('Total reportado', state.totalReported),
    ];

    return _panel(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Resumen en vivo',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: MangoColors.darkGray,
              ),
            ),
            const SizedBox(height: 10),
            ...items.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Text(e.$1),
                    const Spacer(),
                    Text(
                      formatRD(e.$2),
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: e.$1 == 'Total reportado'
                            ? MangoColors.primaryOrange
                            : MangoColors.darkGray,
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

  Future<void> _onConfirmCount(
    BlindCashCloseState state,
    BlindCashCloseViewModel vm,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: Colors.white,
        title: const Text('Confirmar conteo'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Valida que los montos sean correctos. Una vez confirmado no se vuelve a contar.',
            ),
            const SizedBox(height: 12),
            Text('Efectivo contado: ${formatRD(state.totalCounted)}'),
            Text('Total tarjetas: ${formatRD(state.numericCard)}'),
            Text('Total transferencias: ${formatRD(state.numericTransfer)}'),
            const Divider(),
            Text(
              'TOTAL REPORTADO: ${formatRD(state.totalReported)}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Revisar de nuevo'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
              foregroundColor: Colors.white,
            ),
            child: const Text('Confirmar Conteo'),
          ),
        ],
      ),
    );

    if (confirm == true) vm.goToResult();
  }

  Widget _buildResultStep(BuildContext context, BlindCashCloseState state) {
    final result = state.result;
    final statusColor = result.isBalanced
        ? MangoColors.successGreen
        : (result.hasSurplus ? MangoColors.successGreen : Colors.red.shade700);
    final statusText = result.isBalanced
        ? 'Caja cuadrada'
        : (result.hasSurplus ? 'Sobrante detectado' : 'Faltante detectado');
    final statusDetail = result.isBalanced
        ? 'Efectivo, tarjetas y transferencias coinciden exactamente.'
        : '${result.hasSurplus ? 'A favor' : 'En contra'}: ${formatRD(result.totalDifference.abs())}';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: statusColor.withValues(alpha: 0.30)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  statusText,
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  statusDetail,
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _panel(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: CloseSummaryTable(input: state.input, result: result),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _statCard('Total ventas', formatRD(state.input.totalSales)),
              _statCard(
                'Transacciones',
                state.input.transactionCount.toString(),
              ),
              _statCard('Monto Inicial', formatRD(state.input.startAmount)),
              _statCard(
                'Monto a Depositar',
                formatRD(result.totalCounted - state.input.startAmount),
                color: MangoColors.primaryOrange,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: _processingPrint
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.print_outlined),
                  onPressed: _processingPrint
                      ? null
                      : () => _printResult(state),
                  label: const Text('Imprimir Cierre'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: MangoColors.primaryOrange,
                    side: const BorderSide(color: MangoColors.primaryOrange),
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  icon: _processingClose
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.lock),
                  onPressed: _processingClose
                      ? null
                      : () => _closeSession(state),
                  label: const Text('Cerrar'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red.shade600,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statCard(String title, String value, {Color? color}) {
    return Container(
      width: 220,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MangoColors.bgLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color?.withValues(alpha: 0.3) ?? MangoColors.cardBorder,
          width: color != null ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: color ?? MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 20,
              color: color ?? MangoColors.darkGray,
            ),
          ),
        ],
      ),
    );
  }

  Widget _panel({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MangoColors.cardBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }

  Future<void> _closeSession(BlindCashCloseState state) async {
    if (widget.onCloseConfirmed == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _processingClose = true);
    try {
      // 1. Guardar en BD primero
      await widget.onCloseConfirmed!(state.result);
      if (!mounted) return;
      ref.read(blindCashCloseProvider(widget.input).notifier).reset();
      Navigator.of(context).pop();

      // 2. Imprimir después — si falla, la caja ya está cerrada
      try {
        final service = CashClosePrintService(Supabase.instance.client);
        await service.printCloseTicket(
          input: state.input,
          result: state.result,
          denominations: state.denominations,
          printedAt: DateTime.now(),
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Caja cerrada e impresa correctamente'),
              backgroundColor: MangoColors.successGreen,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Caja cerrada. No se pudo imprimir el ticket.'),
              backgroundColor: Colors.orange,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      await _showCloseErrorModal(state, e);
    } finally {
      if (mounted) {
        setState(() => _processingClose = false);
      }
    }
  }

  Future<void> _printResult(BlindCashCloseState state) async {
    setState(() => _processingPrint = true);
    try {
      final service = CashClosePrintService(Supabase.instance.client);
      await service.printCloseTicket(
        input: state.input,
        result: state.result,
        denominations: state.denominations,
        printedAt: DateTime.now(),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No se pudo imprimir: $e'),
          backgroundColor: Colors.red.shade600,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _processingPrint = false);
      }
    }
  }
}
