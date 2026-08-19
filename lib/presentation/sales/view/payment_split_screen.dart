import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mangopos/app/widgets/mango_modal.dart';
import 'package:mangopos/data/models/bank_account.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/presentation/settings/payment_methods/viewmodel/bank_accounts_viewmodel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/fiscal/ncf_types.dart';
import '../../../core/widgets/payment_progress_inline.dart';
import '../viewmodel/payment_split_viewmodel.dart';

const _kPrimary = Color(0xFFF97316);
const _kPrimaryTint = Color(0xFFFFE4CC);
const _kSurface = Colors.white;
const _kPositive = Color(0xFF22C55E);
const _kDanger = Color(0xFFE11D48);
const _kBorder = Color(0xFFEEEEEE);

class PaymentSplitDialog extends ConsumerStatefulWidget {
  final String orderId;
  final double totalAmount;
  final String tableName;
  final String? checkId;
  final String? customerId;
  final String? customerName;
  final String? customerRnc;
  final String? fiscalType;

  /// Hook que corre DESPUÉS de que el pago fue confirmado pero ANTES de
  /// que este dialog se cierre. Sirve para mostrar UI encima del modal
  /// de pago (e.g. popup de "Imprimir copia") sin que el usuario vea el
  /// dialog desaparecer y reaparecer. Cuando el Future resuelve, el
  /// dialog hace pop con la lista de payments para que el caller
  /// continúe el flujo normal.
  /// [offlineNcf]: F4 — si el cobro se hizo offline y el Hub asignó un NCF de
  /// papel, llega aquí para que el caller imprima el comprobante con ese
  /// número en el acto (en vez de la precuenta). Null = sin NCF offline.
  final Future<void> Function(List<Payment> payments, {String? offlineNcf})?
      onConfirmed;

  const PaymentSplitDialog({
    super.key,
    required this.orderId,
    required this.totalAmount,
    required this.tableName,
    this.checkId,
    this.customerId,
    this.customerName,
    this.customerRnc,
    this.fiscalType,
    this.onConfirmed,
  });

  @override
  ConsumerState<PaymentSplitDialog> createState() => _PaymentSplitDialogState();
}

class _PaymentSplitDialogState extends ConsumerState<PaymentSplitDialog> {
  late FocusNode _focusNode;

  /// Cierre del dialog con la lista de payments. Si el caller pasó
  /// `onConfirmed`, lo awaitamos PRIMERO — esto mantiene el modal de
  /// pago montado mientras corre el callback (e.g. el popup
  /// "Imprimir copia" que el caller monta encima). Solo después
  /// hacemos pop, devolviendo los payments al .then() del caller.
  ///
  /// Mientras corre el callback, marcamos `isPrinting=true` en el
  /// viewmodel para que la UI bloquee los botones de cerrar/cancelar y
  /// muestre estado "Imprimiendo...". El cajero NO debe poder liberar
  /// la mesa antes de ver el ticket: si el callback falla, su propio
  /// dialog de reintentar se encarga; cuando ese dialog resuelve,
  /// recien aqui hacemos pop.
  Future<void> _finishWithPayments(List<Payment> payments) async {
    final hook = widget.onConfirmed;
    final key = (
      widget.orderId,
      widget.totalAmount,
      widget.checkId,
      widget.customerId,
      widget.fiscalType,
      widget.customerRnc,
    );
    final vm = ref.read(paymentSplitProvider(key).notifier);

    if (hook != null) {
      // F4: NCF asignado offline (si lo hubo) para imprimir el comprobante.
      final offlineNcf = ref.read(paymentSplitProvider(key)).offlineNcf;
      vm.setPrinting(true);
      try {
        await hook(payments, offlineNcf: offlineNcf);
      } finally {
        if (mounted) vm.markFinished();
      }
    } else {
      // Sin hook no hay impresion, pero el cobro igual cerro: el cajero
      // merece la misma confirmacion.
      vm.markFinished();
    }
    if (!mounted) return;

    // Sostenemos el estado final antes de cerrar. Sin esta pausa el modal se
    // va en el mismo frame en que termina de imprimir y el cajero nunca ve
    // que la emision cerro bien — ve desaparecer el modal, que es exactamente
    // lo que veria si algo hubiera fallado.
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    Navigator.pop(context, payments);
  }

  /// Tecla físicamente presionada en este momento, mapeada al label
  /// visual del keypad ('0'..'9', '⌫'). Se usa para sincronizar el
  /// highlight visual con el teclado físico.
  final ValueNotifier<String?> _pressedKeyVN = ValueNotifier<String?>(null);

  /// Mapeo de teclas físicas → labels del keypad. Cubre fila numérica
  /// y numpad. No incluye '00' ni '.' porque no tienen tecla física
  /// estándar y no aportan valor visual significativo.
  static final Map<LogicalKeyboardKey, String> _digitMap = {
    LogicalKeyboardKey.digit0: '0',
    LogicalKeyboardKey.digit1: '1',
    LogicalKeyboardKey.digit2: '2',
    LogicalKeyboardKey.digit3: '3',
    LogicalKeyboardKey.digit4: '4',
    LogicalKeyboardKey.digit5: '5',
    LogicalKeyboardKey.digit6: '6',
    LogicalKeyboardKey.digit7: '7',
    LogicalKeyboardKey.digit8: '8',
    LogicalKeyboardKey.digit9: '9',
    LogicalKeyboardKey.numpad0: '0',
    LogicalKeyboardKey.numpad1: '1',
    LogicalKeyboardKey.numpad2: '2',
    LogicalKeyboardKey.numpad3: '3',
    LogicalKeyboardKey.numpad4: '4',
    LogicalKeyboardKey.numpad5: '5',
    LogicalKeyboardKey.numpad6: '6',
    LogicalKeyboardKey.numpad7: '7',
    LogicalKeyboardKey.numpad8: '8',
    LogicalKeyboardKey.numpad9: '9',
    LogicalKeyboardKey.backspace: '⌫',
  };

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _pressedKeyVN.dispose();
    super.dispose();
  }

  /// Handler de teclado del modal de cobro.
  ///
  /// Shortcuts (PRD 6 § 4.7 — patrones POS profesional):
  ///   - Dígitos / `.` / Backspace → input de monto.
  ///   - **Enter**: Si hay monto en input → agrega transacción.
  ///                Si input vacío y la orden ya cuadra → confirma pago.
  ///   - **Esc** → cancela y cierra el modal.
  ///   - **F1** o tecla `*` → atajo "Exacto" (setea monto restante).
  ///   - **e** → método Efectivo, **t** → Tarjeta, **r** → Transferencia.
  ///   - **+** → agrega transacción (alias de Enter cuando hay monto).
  Future<void> _handleKeyEvent(
    KeyEvent event,
    PaymentSplitViewModel vm,
    PaymentSplitState state,
  ) async {
    final logicalKey = event.logicalKey;

    // ─── Tracking visual del keypad (KeyDown + KeyUp) ─────────
    // Esto debe ejecutarse ANTES del filtro `if (event is! KeyDownEvent)`
    // para que también capturemos el KeyUpEvent y limpiemos el highlight.
    // Repeats (KeyRepeatEvent) se ignoran intencionalmente — el highlight
    // ya está activo desde el KeyDown inicial.
    final mapped = _digitMap[logicalKey];
    if (mapped != null) {
      if (event is KeyDownEvent) {
        _pressedKeyVN.value = mapped;
      } else if (event is KeyUpEvent && _pressedKeyVN.value == mapped) {
        _pressedKeyVN.value = null;
      }
    }

    if (event is! KeyDownEvent) return;

    // Mientras se imprime, ignoramos TODA tecla. El pago ya esta grabado
    // y la mesa se libera al cerrar; si dejamos pasar dígitos / Enter / *
    // el cajero podria editar montos visualmente o disparar una segunda
    // confirmPayment (que el servidor rechazaria con ORDER_ALREADY_CLOSED
    // pero genera un toast de error confuso). El feedback de "Imprimiendo..."
    // ya esta en el boton — no hay nada util que el cajero pueda teclear.
    if (state.isPrinting) return;

    final char = event.character?.toLowerCase();

    if (logicalKey == LogicalKeyboardKey.escape) {
      if (mounted) Navigator.pop(context, false);
      return;
    }

    if (logicalKey == LogicalKeyboardKey.f1 || char == '*') {
      if (state.remaining > 0) vm.setExactAmount();
      return;
    }

    if (logicalKey == LogicalKeyboardKey.backspace) {
      vm.backspace();
      return;
    }

    if (logicalKey == LogicalKeyboardKey.enter ||
        logicalKey == LogicalKeyboardKey.numpadEnter ||
        char == '+') {
      // Enter inteligente: si hay monto pendiente lo agrega como
      // transacción; si no hay monto y la orden ya cuadra, confirma.
      if (state.currentInput.isNotEmpty && state.inputAmount > 0) {
        vm.addTransaction();
        return;
      }
      final canConfirm =
          state.transactions.isNotEmpty && state.isComplete && !state.isBusy;
      if (canConfirm) {
        final List<Payment>? payments = await vm.confirmPayment(context);
        if (payments != null && mounted) {
          await _finishWithPayments(payments);
        }
      }
      return;
    }

    if (logicalKey == LogicalKeyboardKey.period ||
        logicalKey == LogicalKeyboardKey.numpadDecimal) {
      vm.appendInput('.');
      return;
    }

    // Dígitos directos al input.
    if (event.character != null &&
        RegExp(r'[0-9]').hasMatch(event.character!)) {
      vm.appendInput(event.character!);
      return;
    }

    // Letra de método de pago. Solo aplica si el input está vacío para no
    // bloquear posibles caracteres no esperados durante captura de monto.
    if (state.currentInput.isEmpty && char != null) {
      switch (char) {
        case 'e':
          vm.setMethod(PaymentMethodType.cash);
          return;
        case 't':
          vm.setMethod(PaymentMethodType.card);
          return;
        case 'r':
          vm.setMethod(PaymentMethodType.transfer);
          return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // PRD 6 F2.2a: el sizing del contenedor (insetPadding, max width/height
    // y comportamiento fullscreen en compact) lo maneja MangoModal.wrap.
    // La anatomía interna (header, body en columnas, footer) se mantiene
    // idéntica entre breakpoints — el cajero entrenado en 1366 reconoce
    // todo en 1280.
    // Layout interno (mobile vertical vs desktop columnas) sigue su propia
    // regla: width <920 muestra layout vertical optimizado para celular.
    // Esto NO depende del breakpoint del modal; es la anatomía interna
    // que se preserva entre breakpoints (ver PRD 6 § 4.4).
    final isMobile = MediaQuery.sizeOf(context).width < 920;

    final provider = paymentSplitProvider((
      widget.orderId,
      widget.totalAmount,
      widget.checkId,
      widget.customerId,
      widget.fiscalType,
      widget.customerRnc,
    ));
    final state = ref.watch(provider);
    final vm = ref.read(provider.notifier);

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        _handleKeyEvent(event, vm, state);
        return KeyEventResult.handled;
      },
      child: MangoModal.wrap(
        context: context,
        type: MangoModalType.form,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: isMobile ? double.infinity : 880,
                maxHeight: isMobile ? double.infinity : 680,
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
              _buildHeader(context, isPrinting: state.isPrinting),
              const Divider(height: 1, color: _kBorder),
              Expanded(
                child: isMobile
                    ? SingleChildScrollView(
                        child: Padding(
                          padding: EdgeInsets.all(
                            MediaQuery.sizeOf(context).width < 600 ? 12 : 16,
                          ),
                          child: _MobileLayout(
                            state: state,
                            vm: vm,
                            pressedKey: _pressedKeyVN,
                            onConfirm: _finishWithPayments,
                          ),
                        ),
                      )
                    : Padding(
                        // Padding interno reducido para que todo el contenido
                        // entre sin scroll en el modal de 680px.
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: _LeftPanel(
                                state: state,
                                vm: vm,
                                pressedKey: _pressedKeyVN,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Container(width: 1, color: _kBorder),
                            const SizedBox(width: 16),
                            Expanded(
                              flex: 2,
                              child: _RightPanel(
                                state: state,
                                vm: vm,
                                onClose: () => Navigator.pop(context),
                                onConfirm: _finishWithPayments,
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
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, {required bool isPrinting}) {
    final isPhone = MediaQuery.sizeOf(context).width < 600;
    final title = widget.customerName?.trim().isNotEmpty == true
        ? (isPhone
            ? widget.customerName!
            : 'Pago - ${widget.customerName}')
        : 'Pago - Mesa ${widget.tableName}';
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isPhone ? 12 : 16,
        vertical: isPhone ? 8 : 10,
      ),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(isPhone ? 8 : 10),
            decoration: BoxDecoration(
              color: const Color.fromRGBO(247, 148, 26, 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.credit_card,
              color: _kPrimary,
              size: isPhone ? 18 : 22,
            ),
          ),
          SizedBox(width: isPhone ? 8 : 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: isPhone ? 15 : 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        'Total: RD\$ ${widget.totalAmount.toStringAsFixed(2)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: isPhone ? 11 : 12,
                          color: Colors.grey,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    // Que serie se va a emitir, visible ANTES de cobrar. En
                    // B01 (credito fiscal) es cuando el cajero todavia esta a
                    // tiempo de revisar el RNC; despues de emitido ya hay que
                    // anular y volver a facturar.
                    if (_ncfBadgeLabel(widget.fiscalType) != null) ...[
                      SizedBox(width: isPhone ? 6 : 8),
                      _NcfBadge(
                        label: _ncfBadgeLabel(widget.fiscalType)!,
                        electronic: _isElectronicSeries(widget.fiscalType),
                        compact: isPhone,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.close,
              color: isPrinting ? Colors.black26 : Colors.black54,
            ),
            onPressed: isPrinting ? null : () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

bool _isElectronicSeries(String? fiscalType) => isElectronicNcf(fiscalType);

/// Texto del chip de comprobante: `e-CF - E32` o `NCF - B02`.
///
/// Repone la letra de la serie con `fullNcfCode`: dentro del modulo de ventas
/// el tipo viaja pelado ('32'), y un chip que diga "NCF - 32" no es un codigo
/// que exista en ningun lado.
///
/// Devuelve null cuando la serie no vino resuelta, en vez de inventar un
/// valor por defecto: un chip con la serie equivocada es peor que sin chip.
String? _ncfBadgeLabel(String? fiscalType) {
  final code = fullNcfCode(fiscalType);
  if (code == null) return null;
  return '${isElectronicNcf(code) ? 'e-CF' : 'NCF'} \u00b7 $code';
}

/// Chip con la serie del comprobante, al lado del total.
class _NcfBadge extends StatelessWidget {
  const _NcfBadge({
    required this.label,
    required this.electronic,
    required this.compact,
  });

  final String label;
  final bool electronic;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    // Azul para e-CF, gris para papel: son dos flujos con tiempos distintos y
    // conviene que se distingan de un vistazo, sin tener que leer el codigo.
    final bg = electronic ? const Color(0xFFE0E7FF) : const Color(0xFFF1F5F9);
    final fg = electronic ? const Color(0xFF3730A3) : const Color(0xFF475569);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: compact ? 9.5 : 10.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
          color: fg,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// LAYOUTS
// ---------------------------------------------------------------------------

class _LeftPanel extends ConsumerWidget {
  final PaymentSplitState state;
  final PaymentSplitViewModel vm;
  final ValueListenable<String?> pressedKey;
  final bool compact;

  const _LeftPanel({
    required this.state,
    required this.vm,
    required this.pressedKey,
    this.compact = false,
  });

  /// Altura del keypad en modo compact (mobile/tablet portrait). Escala con
  /// la altura disponible. En celular real (<600 px ancho) bajamos los
  /// bounds para que no domine la pantalla.
  double _resolveCompactKeypadHeight(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isPhone = size.width < 600;
    final pct = isPhone ? 0.28 : 0.36;
    final min = isPhone ? 180.0 : 240.0;
    final max = isPhone ? 230.0 : 340.0;
    return (size.height * pct).clamp(min, max);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canAdd = state.inputAmount > 0 && !state.isProcessing;
    final screenWidth = MediaQuery.sizeOf(context).width;
    // True mobile (celular). En mobile partimos los chips en 2 filas y
    // achicamos labels de los métodos para que entren en ~380 px.
    final isPhone = screenWidth < 600;

    Widget quickAmountChips() {
      final amounts = const [100, 200, 500, 1000, 2000];
      if (isPhone) {
        // Mobile: fila 1 = "Exacto" full width; fila 2 = 5 chips iguales.
        return Column(
          children: [
            if (state.remaining > 0) ...[
              SizedBox(
                width: double.infinity,
                child: _QuickAmountChip(
                  label: 'Monto Exacto',
                  primary: true,
                  onTap: () => vm.setExactAmount(),
                ),
              ),
              const SizedBox(height: 6),
            ],
            Row(
              children: [
                for (var i = 0; i < amounts.length; i++) ...[
                  Expanded(
                    child: _QuickAmountChip(
                      label: amounts[i].toString(),
                      onTap: () =>
                          vm.setQuickAmount(amounts[i].toDouble()),
                    ),
                  ),
                  if (i != amounts.length - 1) const SizedBox(width: 4),
                ],
              ],
            ),
          ],
        );
      }
      return Row(
        children: [
          if (state.remaining > 0) ...[
            Expanded(
              flex: 3,
              child: _QuickAmountChip(
                label: 'Monto Exacto',
                primary: true,
                onTap: () => vm.setExactAmount(),
              ),
            ),
            const SizedBox(width: 6),
          ],
          for (final amount in amounts) ...[
            Expanded(
              child: _QuickAmountChip(
                label: amount.toString(),
                onTap: () => vm.setQuickAmount(amount.toDouble()),
              ),
            ),
            if (amount != amounts.last) const SizedBox(width: 6),
          ],
        ],
      );
    }

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Método de pago',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: Colors.black87,
            fontSize: isPhone ? 12 : 14,
          ),
        ),
        SizedBox(height: isPhone ? 4 : 6),
        Row(
          children: [
            _MethodCard(
              label: 'Efectivo',
              icon: Icons.payments_outlined,
              isSelected: state.activeMethod == PaymentMethodType.cash,
              onTap: () => vm.setMethod(PaymentMethodType.cash),
              compact: isPhone,
            ),
            SizedBox(width: isPhone ? 6 : 8),
            _MethodCard(
              label: 'Tarjeta',
              icon: Icons.credit_card,
              isSelected: state.activeMethod == PaymentMethodType.card,
              onTap: () => vm.setMethod(PaymentMethodType.card),
              compact: isPhone,
            ),
            SizedBox(width: isPhone ? 6 : 8),
            _MethodCard(
              label: isPhone ? 'Transfer.' : 'Transferencia',
              icon: Icons.qr_code_2,
              isSelected: state.activeMethod == PaymentMethodType.transfer,
              onTap: () async {
                vm.setMethod(PaymentMethodType.transfer);
                await _openBankAccountPicker(context, ref);
              },
              compact: isPhone,
            ),
          ],
        ),
        if (state.activeMethod == PaymentMethodType.transfer) ...[
          SizedBox(height: isPhone ? 6 : 8),
          _SelectedBankBanner(
            account: state.selectedBankAccount,
            onChange: () => _openBankAccountPicker(context, ref),
          ),
        ],
        SizedBox(height: isPhone ? 8 : 10),
        quickAmountChips(),
        SizedBox(height: isPhone ? 6 : 8),
        _InputDisplay(state: state),
        SizedBox(height: isPhone ? 6 : 8),
        if (compact)
          SizedBox(
            height: _resolveCompactKeypadHeight(context),
            child: _NumericKeypad(vm: vm, pressedKey: pressedKey),
          )
        else
          Expanded(
            child: _NumericKeypad(vm: vm, pressedKey: pressedKey),
          ),
        SizedBox(height: isPhone ? 10 : 20),
        SizedBox(
          width: double.infinity,
          height: compact ? 52 : 48,
          child: _AddPaymentButton(
            enabled: canAdd,
            isLoading: state.isProcessing,
            onTap: vm.addTransaction,
          ),
        ),
      ],
    );

    return content;
  }

  /// Abre un dialog con la lista de cuentas bancarias activas del
  /// negocio. Al seleccionar, llama `vm.setBankAccount(...)` y cierra.
  /// Si el negocio no tiene cuentas, muestra empty state invitando al
  /// admin a configurarlas.
  Future<void> _openBankAccountPicker(
    BuildContext context,
    WidgetRef ref,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return Consumer(
          builder: (innerCtx, innerRef, _) {
            final asyncAccounts =
                innerRef.watch(activeBankAccountsProvider('auto'));
            return AlertDialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
              contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    'Cuenta que recibió',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF111827),
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Selecciona a cuál cuenta llegó la transferencia.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.normal,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 480,
                child: asyncAccounts.when(
                  loading: () => const SizedBox(
                    height: 120,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (e, _) => SizedBox(
                    height: 120,
                    child: Center(
                      child: Text(
                        'No se pudieron cargar las cuentas: $e',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  ),
                  data: (accounts) {
                    if (accounts.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.account_balance_outlined,
                              size: 40,
                              color: Colors.black38,
                            ),
                            SizedBox(height: 10),
                            Text(
                              'No hay cuentas bancarias configuradas.',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            SizedBox(height: 6),
                            Text(
                              'Pide al administrador agregar al menos '
                              'una cuenta desde Ajustes → Tipos de Pago.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.black54,
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    return ListView.separated(
                      shrinkWrap: true,
                      itemCount: accounts.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (rowCtx, i) {
                        final acc = accounts[i];
                        final isSelected =
                            state.selectedBankAccount?.id == acc.id;
                        return _BankAccountPickerCard(
                          account: acc,
                          isSelected: isSelected,
                          onTap: () {
                            vm.setBankAccount(acc);
                            Navigator.pop(ctx);
                          },
                        );
                      },
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cerrar'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Card de cuenta bancaria dentro del picker. Layout multi-línea con
/// jerarquía clara: alias destacado, número de cuenta en monospace
/// grande, banco y meta-info (tipo · moneda · titular) en sub-líneas
/// secundarias. Fondo siempre blanco; la selección se marca solo con
/// borde naranja + check (para que el contraste del texto se mantenga).
class _BankAccountPickerCard extends StatelessWidget {
  final BankAccount account;
  final bool isSelected;
  final VoidCallback onTap;

  const _BankAccountPickerCard({
    required this.account,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const orange = Color(0xFFF97316);
    final borderColor = isSelected ? orange : const Color(0xFFE5E7EB);
    final aliasOrBank =
        (account.alias?.trim().isNotEmpty ?? false)
            ? account.alias!.trim()
            : account.bankName;
    final showBankUnderAlias =
        (account.alias?.trim().isNotEmpty ?? false) &&
        account.bankName.trim().isNotEmpty;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: borderColor,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Avatar circular del banco
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: orange.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.account_balance,
                color: orange,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            // Info principal
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Alias o banco como título
                  Text(
                    aliasOrBank,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: Color(0xFF111827),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (showBankUnderAlias) ...[
                    const SizedBox(height: 2),
                    Text(
                      account.bankName,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF6B7280),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 8),
                  // Número de cuenta en monospace (lectura clara para
                  // el cajero al verificar contra la app del banco).
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: Text(
                      account.accountNumber,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        letterSpacing: 0.5,
                        color: Color(0xFF111827),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Meta: tipo · moneda · titular como pills
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _Pill(
                        label: account.accountType.displayName,
                        color: const Color(0xFF6B7280),
                      ),
                      _Pill(
                        label: account.currency,
                        color: const Color(0xFF3B82F6),
                      ),
                      if ((account.accountHolder ?? '').trim().isNotEmpty)
                        _Pill(
                          label: account.accountHolder!.trim(),
                          color: const Color(0xFF6B7280),
                          icon: Icons.person_outline,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Check de selección a la derecha (24x24 fijo para que
            // todas las cards alineen aunque solo una esté marcada).
            SizedBox(
              width: 24,
              height: 24,
              child: isSelected
                  ? const Icon(
                      Icons.check_circle,
                      color: orange,
                      size: 24,
                    )
                  : Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFFD1D5DB)),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pill compacto reutilizado en la card del picker. Estilo subtle
/// con fondo translúcido del color y borde matching.
class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;

  const _Pill({required this.label, required this.color, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Banner que muestra la cuenta bancaria seleccionada (o invita a
/// elegir una) cuando el método activo es transferencia. Click → abre
/// el picker.
class _SelectedBankBanner extends StatelessWidget {
  final BankAccount? account;
  final VoidCallback onChange;
  const _SelectedBankBanner({required this.account, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final hasAccount = account != null;
    return InkWell(
      onTap: onChange,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: hasAccount
              ? const Color(0xFFFFF7ED)
              : const Color(0xFFFFEDD5),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: hasAccount
                ? const Color(0xFFF97316)
                : const Color(0xFFFFA94D),
            width: hasAccount ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              hasAccount
                  ? Icons.check_circle
                  : Icons.warning_amber_rounded,
              color: const Color(0xFFF97316),
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: hasAccount
                  ? Text(
                      '${account!.displayLabel} · ${account!.bankName} · '
                      '#${account!.accountNumber}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF7C2D12),
                      ),
                      overflow: TextOverflow.ellipsis,
                    )
                  : const Text(
                      'Selecciona la cuenta que recibió la transferencia',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF7C2D12),
                      ),
                    ),
            ),
            const SizedBox(width: 6),
            const Text(
              'Cambiar',
              style: TextStyle(
                fontSize: 12,
                color: Color(0xFFF97316),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RightPanel extends StatelessWidget {
  final PaymentSplitState state;
  final PaymentSplitViewModel vm;
  final VoidCallback onClose;
  final Future<void> Function(List<Payment>) onConfirm;

  const _RightPanel({
    required this.state,
    required this.vm,
    required this.onClose,
    required this.onConfirm,
  });

  /// PRD 6 § 4.7 — explica al cajero por qué "Confirmar pago" está disabled.
  /// Si está procesando o imprimiendo, no mostramos nada (el botón ya
  /// muestra el estado en su label). Si está habilitado, retorna null.
  static String? _resolveDisabledReason(PaymentSplitState state) {
    if (state.isBusy) return null;
    if (state.transactions.isEmpty) {
      return 'Agrega al menos un pago para confirmar';
    }
    if (!state.isComplete) {
      return 'Falta RD\$ ${state.remaining.toStringAsFixed(2)} por pagar';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final canConfirm =
        state.transactions.isNotEmpty && state.isComplete && !state.isBusy;
    final isBusy = state.isBusy;

    // PRD 6 § 4.7 — razón por la que el botón está disabled, mostrada
    // inline al lado para que el cajero sepa qué falta sin adivinar.
    final disabledReason = _resolveDisabledReason(state);

    return Padding(
      // Sin padding lateral — el modal ya tiene padding general y la
      // separación con el panel izquierdo viene del Container divider.
      padding: EdgeInsets.zero,
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
          // Las etapas del cobro se cuentan aqui, en el hueco que deja la
          // lista de pagos, en vez de tapar el modal con un velo: el cajero
          // sigue viendo el total y los pagos agregados mientras espera, que
          // es lo que suele estar mirando cuando el cliente le pregunta.
          PaymentStepsPanel(
            stage: state.stage,
            isElectronic: vm.isElectronicFiscal,
            dgiiContingency: state.dgiiContingency,
            accent: _kPrimary,
            positive: _kPositive,
          ),
          const SizedBox(height: 16),
          ConfirmPaymentProgressButton(
            stage: state.stage,
            isElectronic: vm.isElectronicFiscal,
            dgiiContingency: state.dgiiContingency,
            ncf: state.emittedNcf,
            // null mientras corre: es lo que impide el doble-tap que
            // duplicaria la venta.
            onPressed: canConfirm
                ? () async {
                    final List<Payment>? payments = await vm.confirmPayment(
                      context,
                    );
                    if (payments != null && context.mounted) {
                      await onConfirm(payments);
                    }
                  }
                : null,
          ),
          if (disabledReason != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(
                  Icons.info_outline,
                  size: 14,
                  color: Color(0xFF6B7280),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    disabledReason,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF6B7280),
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton(
              // Mientras se imprime, no se puede cancelar — el pago ya
              // esta grabado y la mesa se libera al cerrar el modal.
              onPressed: isBusy ? null : onClose,
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
              onPressed: isBusy ? null : () => Navigator.pop(context, false),
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
  final ValueListenable<String?> pressedKey;
  final Future<void> Function(List<Payment>) onConfirm;

  const _MobileLayout({
    required this.state,
    required this.vm,
    required this.pressedKey,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final canConfirm =
        state.transactions.isNotEmpty && state.isComplete && !state.isBusy;
    final isBusy = state.isBusy;
    final isPhone = MediaQuery.sizeOf(context).width < 600;
    final gap = isPhone ? 10.0 : 16.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TotalsCard(state: state, compact: true),
        SizedBox(height: gap),
        _LeftPanel(state: state, vm: vm, pressedKey: pressedKey, compact: true),
        // Lista de pagos: solo mostramos si hay transacciones — en
        // celular el "Aún no has agregado pagos" ocupa espacio inútil.
        if (state.transactions.isNotEmpty) ...[
          SizedBox(height: gap),
          _PaymentList(
            transactions: state.transactions,
            onDelete: vm.removeTransaction,
            allowScrolling: false,
          ),
        ],
        // Mismo stepper que en escritorio. En telefono va justo encima del
        // boton, que es el ultimo sitio donde el cajero tenia el dedo.
        PaymentStepsPanel(
          stage: state.stage,
          isElectronic: vm.isElectronicFiscal,
          dgiiContingency: state.dgiiContingency,
          accent: _kPrimary,
          positive: _kPositive,
        ),
        SizedBox(height: gap),
        ConfirmPaymentProgressButton(
          stage: state.stage,
          isElectronic: vm.isElectronicFiscal,
          dgiiContingency: state.dgiiContingency,
          ncf: state.emittedNcf,
          height: isPhone ? 48 : 54,
          fontSize: isPhone ? 14 : 15,
          onPressed: canConfirm
              ? () async {
                  final List<Payment>? payments = await vm.confirmPayment(
                    context,
                  );
                  if (payments != null && context.mounted) {
                    await onConfirm(payments);
                  }
                }
              : null,
        ),
        if (_RightPanel._resolveDisabledReason(state) != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(
                Icons.info_outline,
                size: 14,
                color: Color(0xFF6B7280),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _RightPanel._resolveDisabledReason(state)!,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF6B7280),
                  ),
                ),
              ),
            ],
          ),
        ],
        SizedBox(height: isPhone ? 8 : 10),
        SizedBox(
          width: double.infinity,
          height: isPhone ? 42 : 48,
          child: OutlinedButton(
            onPressed: isBusy ? null : () => Navigator.pop(context),
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
    final input = state.currentInput.isEmpty ? '0' : state.currentInput;
    final entered = state.inputAmount;
    final showChange = entered > state.remaining && state.remaining > 0;
    final preview = entered - state.remaining;
    final isPhone = MediaQuery.sizeOf(context).width < 600;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'MONTO A INGRESAR',
          style: TextStyle(
            color: Colors.grey[600],
            fontWeight: FontWeight.w700,
            fontSize: isPhone ? 9 : 10,
            letterSpacing: 1.2,
          ),
        ),
        SizedBox(height: isPhone ? 4 : 6),
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: isPhone ? 12 : 14,
            vertical: isPhone ? 8 : 12,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFFF6F7F9),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _kBorder),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: RichText(
                    text: TextSpan(
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Colors.black87,
                        letterSpacing: -0.5,
                      ),
                      children: [
                        TextSpan(
                          text: 'RD\$ ',
                          style: TextStyle(
                            fontSize: isPhone ? 13 : 15,
                            color: Colors.grey,
                          ),
                        ),
                        TextSpan(
                          text: input,
                          style: TextStyle(fontSize: isPhone ? 20 : 25),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (showChange) ...[
                const SizedBox(width: 10),
                Text(
                  'Cambio: RD\$ ${preview.toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: _kPositive,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (state.validationError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              state.validationError!,
              style: const TextStyle(
                color: _kDanger,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// KEYPAD — responsive + sincronizado con teclado físico
// ---------------------------------------------------------------------------

/// Numeric keypad responsive.
///
/// Reglas de sizing (PRD 6 § 4.5 — touch + denso al mismo tiempo):
///   - Spacing y fontSize escalan con el ancho del propio keypad
///     (NO con el ancho de pantalla). Esto le permite funcionar igual
///     embebido en una columna angosta de desktop o en mobile vertical.
///   - Si el padre da altura finita (modo desktop dentro de Expanded),
///     el aspect ratio se calcula EXACTO para que las 4 filas llenen el
///     espacio disponible. Si la altura es ilimitada (mobile, dentro de
///     SingleChildScrollView), cae a un ratio cómodo para touch (1.7).
///   - El highlight visual responde tanto a tap (mouse/touch) como a la
///     tecla física correspondiente, vía `pressedKey`.
class _NumericKeypad extends StatelessWidget {
  final PaymentSplitViewModel vm;
  final ValueListenable<String?> pressedKey;

  const _NumericKeypad({required this.vm, required this.pressedKey});

  static const List<String> _keys = [
    '7',
    '8',
    '9',
    '4',
    '5',
    '6',
    '1',
    '2',
    '3',
    '0',
    '00',
    '⌫',
  ];
  static const int _cols = 3;
  static const int _rows = 4;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;

        // Spacing escala con el ancho del propio keypad. Breakpoints
        // basados en el ANCHO del componente, no de la pantalla — así
        // funciona idénticamente embebido en cualquier layout.
        final double spacing;
        if (w < 240) {
          spacing = 4;
        } else if (w < 360) {
          spacing = 6;
        } else {
          spacing = 10;
        }

        final keyW = (w - spacing * (_cols - 1)) / _cols;

        // Aspect ratio: clamp min en 1.6 para que las celdas siempre sean
        // más anchas que altas (botones rectangulares al estilo POS).
        // Esto evita que en columnas altas el teclado crezca tanto que
        // la última fila desborde el modal.
        final double aspectRatio;
        if (h.isFinite && h > 0) {
          final keyH = (h - spacing * (_rows - 1)) / _rows;
          aspectRatio = (keyW / keyH).clamp(1.85, 3.0);
        } else {
          aspectRatio = 2.0;
        }

        // Tipografía e íconos: tamaños reducidos para botones más compactos.
        final fontSize = (keyW * 0.22).clamp(16.0, 22.0);
        final iconSize = (keyW * 0.18).clamp(15.0, 20.0);

        return GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _keys.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _cols,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
            childAspectRatio: aspectRatio,
          ),
          itemBuilder: (context, index) {
            final label = _keys[index];
            final isBack = label == '⌫';

            // ValueListenableBuilder POR CELDA: solo la tecla cuyo
            // estado cambia se rebuilda (la presionada y la liberada).
            // Las otras 10 quedan intactas — clave para responsividad
            // durante secuencias rápidas de tecleo.
            return ValueListenableBuilder<String?>(
              valueListenable: pressedKey,
              builder: (context, pressed, _) {
                return _KeypadKey(
                  label: label,
                  isBack: isBack,
                  isPressed: pressed == label,
                  fontSize: fontSize,
                  iconSize: iconSize,
                  onTap: () => isBack ? vm.backspace() : vm.appendInput(label),
                );
              },
            );
          },
        );
      },
    );
  }
}

/// Una sola tecla del keypad.
///
/// Maneja tres estados visuales independientes:
///   1. `isPressed` (externo): tecla física correspondiente está abajo.
///   2. `_tapping` (interno): el usuario tiene el dedo/click abajo.
///   3. `_hovering` (interno, solo desktop): mouse encima.
///
/// La unión de (1)+(2) genera el estado `highlighted` con fondo naranja
/// claro y borde primary. Hover es un fondo gris sutil (solo desktop;
/// MouseRegion ignora touch).
class _KeypadKey extends StatefulWidget {
  final String label;
  final bool isBack;
  final bool isPressed;
  final double fontSize;
  final double iconSize;
  final VoidCallback onTap;

  const _KeypadKey({
    required this.label,
    required this.isBack,
    required this.isPressed,
    required this.fontSize,
    required this.iconSize,
    required this.onTap,
  });

  @override
  State<_KeypadKey> createState() => _KeypadKeyState();
}

class _KeypadKeyState extends State<_KeypadKey> {
  bool _hovering = false;
  bool _tapping = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = widget.isPressed || _tapping;

    final Color bg;
    if (highlighted) {
      bg = _kPrimaryTint;
    } else if (_hovering) {
      bg = const Color(0xFFFAFAFA);
    } else {
      bg = Colors.white;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _tapping = true),
        onTapUp: (_) => setState(() => _tapping = false),
        onTapCancel: () => setState(() => _tapping = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: highlighted ? _kPrimary : _kBorder,
              width: highlighted ? 1.2 : 1,
            ),
            boxShadow: _tapping
                ? null
                : const [
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 4,
                      offset: Offset(0, 2),
                    ),
                  ],
          ),
          alignment: Alignment.center,
          child: widget.isBack
              ? Icon(
                  Icons.backspace_outlined,
                  color: highlighted ? _kPrimary : Colors.grey[700],
                  size: widget.iconSize,
                )
              : Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: widget.fontSize,
                    fontWeight: FontWeight.w600,
                    color: highlighted ? _kPrimary : Colors.black87,
                  ),
                ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _MethodCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;
  final bool compact;

  const _MethodCard({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final fgColor = isSelected ? _kPrimary : Colors.grey[600];
    final bgColor = isSelected ? _kPrimaryTint : const Color(0xFFF8F8F8);

    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: compact ? 56 : 64,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? _kPrimary : _kBorder,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: fgColor, size: compact ? 18 : 20),
              SizedBox(height: compact ? 2 : 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isSelected ? _kPrimary : Colors.black87,
                  fontWeight: FontWeight.w700,
                  fontSize: compact ? 10 : 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickAmountChip extends StatefulWidget {
  final String label;
  final VoidCallback onTap;

  /// PRD 6 § 4.7 — chip "Exacto" se distingue visualmente del resto:
  /// fill con primary color y texto blanco.
  final bool primary;

  const _QuickAmountChip({
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  State<_QuickAmountChip> createState() => _QuickAmountChipState();
}

class _QuickAmountChipState extends State<_QuickAmountChip> {
  bool _hovering = false;
  bool _tapping = false;

  @override
  Widget build(BuildContext context) {
    final pressed = _tapping;
    final Color bg;
    final Color fg;
    if (widget.primary) {
      bg = pressed
          ? const Color(0xFFE56710)
          : (_hovering ? const Color(0xFFFB8429) : _kPrimary);
      fg = Colors.white;
    } else {
      bg = pressed
          ? _kPrimaryTint
          : (_hovering ? const Color(0xFFEDEEF1) : const Color(0xFFF6F7F9));
      fg = pressed ? _kPrimary : Colors.black87;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _tapping = true),
        onTapUp: (_) => setState(() => _tapping = false),
        onTapCancel: () => setState(() => _tapping = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.visible,
            softWrap: false,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 12,
              color: fg,
            ),
          ),
        ),
      ),
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
    final progress = state.totalAmount <= 0
        ? 0.0
        : (state.totalPaid / state.totalAmount).clamp(0.0, 1.0);
    final isComplete = remaining <= 0;
    final isPhone = MediaQuery.sizeOf(context).width < 600;
    // En celular bajamos paddings y fuentes para que la card no domine la
    // pantalla. En desktop/tablet conservamos el look original.
    final pad = isPhone ? 10.0 : (compact ? 14.0 : 18.0);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(pad),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F8F8),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Total a pagar',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                  fontSize: isPhone ? 13 : 14,
                ),
              ),
              Text(
                'RD\$ ${state.totalAmount.toStringAsFixed(2)}',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: isPhone ? 16 : (compact ? 18 : 20),
                ),
              ),
            ],
          ),
          SizedBox(height: isPhone ? 6 : 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: isPhone ? 4 : 6,
              backgroundColor: _kBorder,
              valueColor: AlwaysStoppedAnimation<Color>(_kPositive),
            ),
          ),
          SizedBox(height: isPhone ? 6 : 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Pagado RD\$ ${state.totalPaid.toStringAsFixed(2)}',
                style: TextStyle(
                  color: _kPositive,
                  fontWeight: FontWeight.w700,
                  fontSize: isPhone ? 11 : 12,
                ),
              ),
              Text(
                isComplete
                    ? 'Cambio RD\$ ${state.change.toStringAsFixed(2)}'
                    : 'Restante RD\$ ${remaining.toStringAsFixed(2)}',
                style: TextStyle(
                  color: isComplete
                      ? Colors.redAccent
                      : Colors.grey[700],
                  fontWeight: FontWeight.w700,
                  fontSize: isPhone ? 11 : 12,
                ),
              ),
            ],
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
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: Color(0xFFF97316),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Pago parcial. El restante deberá cobrarse con otro método.',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFFF97316),
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

class _PaymentList extends StatelessWidget {
  final List<PaymentTransaction> transactions;
  final void Function(String id) onDelete;
  final bool allowScrolling;

  const _PaymentList({
    required this.transactions,
    required this.onDelete,
    this.allowScrolling = true,
  });

  static IconData _iconFor(PaymentMethodType method) {
    switch (method) {
      case PaymentMethodType.cash:
        return Icons.payments_outlined;
      case PaymentMethodType.card:
        return Icons.credit_card;
      case PaymentMethodType.transfer:
        return Icons.qr_code_2;
      case PaymentMethodType.other:
        return Icons.attach_money;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'PAGOS AGREGADOS',
          style: TextStyle(
            color: Colors.grey[600],
            fontWeight: FontWeight.w700,
            fontSize: 10,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        if (transactions.isEmpty)
          Container(
            width: double.infinity,
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
          )
        else if (allowScrolling)
          Expanded(child: _buildList())
        else
          _buildList(),
      ],
    );
  }

  Widget _buildList() {
    return ListView.separated(
      shrinkWrap: !allowScrolling,
      physics: allowScrolling
          ? const AlwaysScrollableScrollPhysics()
          : const NeverScrollableScrollPhysics(),
      itemCount: transactions.length,
      separatorBuilder: (context, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final tx = transactions[index];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFFCFCFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _kBorder),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _kPrimaryTint,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _iconFor(tx.method),
                  color: _kPrimary,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tx.methodLabel,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${tx.timestamp.hour.toString().padLeft(2, '0')}:${tx.timestamp.minute.toString().padLeft(2, '0')}',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'RD\$ ${tx.amount.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: () => onDelete(tx.id),
                splashRadius: 16,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
                icon: const Icon(
                  Icons.delete_outline,
                  color: Colors.grey,
                  size: 18,
                ),
              ),
            ],
          ),
        );
      },
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
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
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
            ? const Color.fromRGBO(225, 29, 72, 0.12)
            : const Color.fromRGBO(247, 148, 26, 0.12),
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
