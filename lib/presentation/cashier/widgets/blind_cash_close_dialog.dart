import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/cashier/services/print_service.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:mangopos/presentation/cashier/state/cash_close_formatters.dart';
import 'package:mangopos/presentation/cashier/viewmodel/blind_cash_close_viewmodel.dart';
import 'package:mangopos/presentation/cashier/widgets/close_summary_table.dart';
import 'package:mangopos/presentation/cashier/widgets/denomination_counter_row.dart';
import 'package:mangopos/presentation/cashier/detailed_wizard/widgets/zoom_control.dart';
import 'package:mangopos/presentation/cashier/widgets/numpad_widget.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/core/storage/storage_service.dart';

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
  // Una vez que el DB save tuvo éxito en `_onConfirmCount`, disparamos
  // un auto-print al entrar al step `result`. Este flag evita reintentos en
  // cada rebuild — el usuario reimprime con el botón "Reimprimir".
  bool _autoPrintTried = false;
  double _zoomFactor = 1.0;
  late final FocusNode _dialogFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadZoomFactor();
  }

  Future<void> _loadZoomFactor() async {
    try {
      final storage = await StorageService.getInstance();
      final savedZoom = await storage.read('system_zoom_factor_blind_close');
      if (savedZoom != null && mounted) {
        setState(() {
          _zoomFactor = double.tryParse(savedZoom) ?? 1.0;
        });
      }
    } catch (e) {
      debugPrint('Error loading zoom factor: $e');
    }
  }

  Future<void> _saveZoomFactor(double factor) async {
    try {
      final storage = await StorageService.getInstance();
      await storage.write('system_zoom_factor_blind_close', factor.toString());
    } catch (e) {
      debugPrint('Error saving zoom factor: $e');
    }
  }

  @override
  void dispose() {
    _dialogFocusNode.dispose();
    super.dispose();
  }

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

    // Auto-print al entrar al step `result`. El DB save ya ocurrió en
    // `_onConfirmCount`; aquí imprimimos automáticamente una sola vez y
    // dejamos el botón "Reimprimir" disponible si el cajero lo necesita.
    // El botón "Cerrar" del result step solo hace pop del modal — no
    // imprime ni reescribe en BD.
    if (state.step == BlindCashCloseStep.result && !_autoPrintTried) {
      _autoPrintTried = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _printResult(state, silent: true);
      });
    }

    final mq = MediaQuery.of(context);
    return PopScope(
      canPop: canCloseDialog,
      child: Focus(
        focusNode: _dialogFocusNode,
        autofocus: true,
        onKeyEvent: (node, event) =>
            _handleKeyEvent(event, state, vm, canCloseDialog),
        child: Builder(
          builder: (context) => MediaQuery(
            data: mq.copyWith(
              textScaler: mq.textScaler.clamp(
                minScaleFactor: _zoomFactor,
                maxScaleFactor: _zoomFactor,
              ),
            ),
            child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: ((MediaQuery.of(context).size.width < 1200
                        ? MediaQuery.of(context).size.width - 48
                        : 1180.0) *
                    _zoomFactor)
                .clamp(0.0, MediaQuery.of(context).size.width - 48),
            maxHeight: ((MediaQuery.of(context).size.height < 880
                        ? MediaQuery.of(context).size.height - 40
                        : 860.0) *
                    _zoomFactor)
                .clamp(0.0, MediaQuery.of(context).size.height - 40),
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
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(context, state),
                  const SizedBox(height: 14),
                  const Divider(height: 1, color: MangoColors.cardBorder),
                  const SizedBox(height: 14),
                  Flexible(
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
        if (MediaQuery.of(context).size.width >= 600) ...[
          ZoomControl(
            factor: _zoomFactor,
            onChanged: (v) {
              setState(() => _zoomFactor = v);
              _saveZoomFactor(v);
            },
          ),
          const SizedBox(width: 10),
        ],
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
    final isTall = MediaQuery.of(context).size.height >= 700;
    final useExpanded = isWide && isTall;
    
    final summaryCard = _countSummary(state);
    final countPanel = _countPanel(state, vm);
    final paymentPanel = _paymentPanel(state, vm);

    Widget content;
    if (isWide) {
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 6, child: countPanel),
          const SizedBox(width: 16),
          Expanded(
            flex: 5,
            child: useExpanded
                ? SingleChildScrollView(
                    child: Column(
                      children: [
                        paymentPanel,
                        const SizedBox(height: 12),
                        summaryCard,
                      ],
                    ),
                  )
                : Column(
                    children: [
                      paymentPanel,
                      const SizedBox(height: 12),
                      summaryCard,
                    ],
                  ),
          ),
        ],
      );
    } else {
      content = Column(
        children: [
          countPanel,
          const SizedBox(height: 12),
          paymentPanel,
          const SizedBox(height: 12),
          summaryCard,
        ],
      );
    }

    if (!useExpanded) {
      content = SingleChildScrollView(child: content);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: content),
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
    final isWide = MediaQuery.of(context).size.width >= 1040;
    final isTall = MediaQuery.of(context).size.height >= 700;
    final useExpanded = isWide && isTall;
    
    final listView = ListView.builder(
      shrinkWrap: !useExpanded,
      physics: !useExpanded ? const NeverScrollableScrollPhysics() : null,
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
    );
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
            if (useExpanded)
              Expanded(child: listView)
            else
              listView,
          ],
        ),
      ),
    );
  }

  Widget _paymentPanel(BlindCashCloseState state, BlindCashCloseViewModel vm) {
    String formatInputString(String value) {
      if (value.isEmpty) return 'RD\$ 0.00';
      final parts = value.split('.');
      final intPart = parts[0].replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
        (Match m) => '${m[1]},',
      );
      if (parts.length == 1) {
        return 'RD\$ $intPart.00';
      } else {
        return 'RD\$ $intPart.${parts[1]}';
      }
    }

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
                formatInputString(value),
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
              onTap: () {
                _dialogFocusNode.requestFocus();
                vm.setActiveInput(BlindCashInputTarget.card);
              },
            ),
            const SizedBox(height: 10),
            amountField(
              label: 'Total Transferencias',
              value: state.transferInput,
              active: state.activeInput == BlindCashInputTarget.transfer,
              onTap: () {
                _dialogFocusNode.requestFocus();
                vm.setActiveInput(BlindCashInputTarget.transfer);
              },
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
      ('Efectivo', state.totalCounted, false),
      ('Tarjetas', state.numericCard, true),
      ('Transferencias', state.numericTransfer, true),
      ('Total reportado', state.totalReported, true),
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
                      e.$3 ? formatRDigital(e.$2) : formatRD(e.$2),
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
              'Valida que los montos sean correctos. Una vez confirmado se '
              'cierra la caja y se imprime el ticket automáticamente.',
            ),
            const SizedBox(height: 12),
            Text('Efectivo contado: ${formatRD(state.totalCounted)}'),
            Text('Total tarjetas: ${formatRDigital(state.numericCard)}'),
            Text('Total transferencias: ${formatRDigital(state.numericTransfer)}'),
            const Divider(),
            Text(
              'TOTAL REPORTADO: ${formatRDigital(state.totalReported)}',
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

    if (confirm != true) return;

    // Cierre formal en BD ANTES de avanzar al result step. Si falla,
    // mostramos error y nos quedamos en el step de conteo. La impresión
    // automática se dispara cuando `build()` detecta que entramos a
    // `result` con `_autoPrintTried == false`.
    if (widget.onCloseConfirmed == null) {
      vm.goToResult();
      return;
    }
    setState(() => _processingClose = true);
    try {
      await widget.onCloseConfirmed!(state.result);
      if (!mounted) return;
      vm.goToResult();
    } catch (e) {
      if (!mounted) return;
      await _showCloseErrorModal(state, e);
    } finally {
      if (mounted) setState(() => _processingClose = false);
    }
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
        : '${result.hasSurplus ? 'A favor' : 'En contra'}: ${formatRDigital(result.totalDifference.abs())}';

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
              _statCard('Total ventas', formatRDigital(state.input.totalSales)),
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
                  label: const Text('Reimprimir'),
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

  /// "Cerrar" del result step: simplemente descarta el modal. La BD y la
  /// impresión ya ocurrieron en `_onConfirmCount` + auto-print, así que
  /// este botón no debe disparar nada más para evitar duplicados.
  void _closeSession(BlindCashCloseState state) {
    ref.read(blindCashCloseProvider(widget.input).notifier).reset();
    Navigator.of(context).pop();
  }

  /// Maneja key events del dialog con tres reglas, en orden:
  ///
  ///   1. Esc/F2/Ctrl+Enter siempre disparan acción y retornan `handled`,
  ///      sin importar el foco — son atajos globales del flujo.
  ///   2. Si el foco está en una TextField (e.g., una denominación), las
  ///      teclas pasan al campo retornando `ignored` — el IME procesa el
  ///      dígito y actualiza el text controller.
  ///   3. Si NO hay TextField enfocado y hay un input activo (Tarjeta o
  ///      Transferencia), digit/period/backspace se reenvían a
  ///      `vm.appendNumpad` y retornan `handled`.
  ///
  /// Esto asegura paridad: tanto denominaciones (TextField) como
  /// Tarjeta/Transferencia (display + activeInput) responden al teclado
  /// físico sin pisarse.
  KeyEventResult _handleKeyEvent(
    KeyEvent event,
    BlindCashCloseState state,
    BlindCashCloseViewModel vm,
    bool canCloseDialog,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;

    // 1) Atajos globales (siempre fire, ignoran foco de TextField).
    if (key == LogicalKeyboardKey.escape) {
      if (canCloseDialog) {
        ref
            .read(blindCashCloseProvider(widget.input).notifier)
            .reset();
        Navigator.of(context).pop();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final isCtrl = HardwareKeyboard.instance.isControlPressed;
    final isConfirmKey = key == LogicalKeyboardKey.f2 ||
        ((key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.numpadEnter) &&
            isCtrl);
    if (isConfirmKey) {
      if (state.step == BlindCashCloseStep.count &&
          !_processingClose &&
          !_processingPrint) {
        _onConfirmCount(state, vm);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // 2) Si hay TextField con foco, dejar pasar las teclas al IME.
    if (_hasFocusedTextField()) {
      return KeyEventResult.ignored;
    }

    // 3) Reenvío al input activo (Tarjeta o Transferencia).
    if (state.step != BlindCashCloseStep.count ||
        state.activeInput == null) {
      return KeyEventResult.ignored;
    }
    final char = _digitOrSymbolFromKey(key);
    if (char == null) return KeyEventResult.ignored;
    vm.appendNumpad(char);
    return KeyEventResult.handled;
  }

  /// True si el `primaryFocus` actual está dentro de un `EditableText`
  /// (i.e., una `TextField` está siendo editada).
  bool _hasFocusedTextField() {
    final focused = FocusManager.instance.primaryFocus;
    final ctx = focused?.context;
    if (ctx == null) return false;
    if (ctx.widget is EditableText) return true;
    return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// Mapea una `LogicalKeyboardKey` a su carácter '0'..'9', '.' o
  /// 'backspace'. Retorna null si la tecla no aplica al numpad.
  String? _digitOrSymbolFromKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.backspace) return 'backspace';
    if (key == LogicalKeyboardKey.period ||
        key == LogicalKeyboardKey.numpadDecimal) {
      return '.';
    }
    // Top-row digits.
    if (key == LogicalKeyboardKey.digit0) return '0';
    if (key == LogicalKeyboardKey.digit1) return '1';
    if (key == LogicalKeyboardKey.digit2) return '2';
    if (key == LogicalKeyboardKey.digit3) return '3';
    if (key == LogicalKeyboardKey.digit4) return '4';
    if (key == LogicalKeyboardKey.digit5) return '5';
    if (key == LogicalKeyboardKey.digit6) return '6';
    if (key == LogicalKeyboardKey.digit7) return '7';
    if (key == LogicalKeyboardKey.digit8) return '8';
    if (key == LogicalKeyboardKey.digit9) return '9';
    // Numpad digits.
    if (key == LogicalKeyboardKey.numpad0) return '0';
    if (key == LogicalKeyboardKey.numpad1) return '1';
    if (key == LogicalKeyboardKey.numpad2) return '2';
    if (key == LogicalKeyboardKey.numpad3) return '3';
    if (key == LogicalKeyboardKey.numpad4) return '4';
    if (key == LogicalKeyboardKey.numpad5) return '5';
    if (key == LogicalKeyboardKey.numpad6) return '6';
    if (key == LogicalKeyboardKey.numpad7) return '7';
    if (key == LogicalKeyboardKey.numpad8) return '8';
    if (key == LogicalKeyboardKey.numpad9) return '9';
    return null;
  }

  Future<void> _printResult(
    BlindCashCloseState state, {
    bool silent = false,
  }) async {
    setState(() => _processingPrint = true);
    try {
      final service = CashClosePrintService(Supabase.instance.client);
      await service.printCloseTicket(
        input: state.input,
        result: state.result,
        denominations: state.denominations,
        printedAt: DateTime.now(),
      );
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cierre reimpreso correctamente'),
            backgroundColor: MangoColors.successGreen,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No se pudo imprimir: $e'),
            backgroundColor: Colors.red.shade600,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _processingPrint = false);
      }
    }
  }
}
