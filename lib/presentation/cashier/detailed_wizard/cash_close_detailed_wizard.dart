import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';

import 'state/detailed_wizard_state.dart';
import 'steps/step_cash_count.dart';
import 'steps/step_card_transfer.dart';
import 'steps/step_result.dart';
import 'steps/step_review_sign.dart';
import 'widgets/confirm_close_dialog.dart';
import 'widgets/wizard_footer.dart';
import 'widgets/wizard_header.dart';
import 'widgets/wizard_stepper.dart';

/// Resultado entregado por el wizard al confirmar el cierre.
///
/// El handler debe escribir en `cash_count_blind` y cerrar la sesión. Cuando
/// retorna OK, el wizard transiciona internamente al paso de resultado
/// (varianza esperado vs reportado). Si throws, el ConfirmDialog muestra el
/// error y el wizard se queda en paso 3 listo para reintentar.
typedef DetailedCloseHandler = Future<void> Function(
  DetailedWizardSnapshot snapshot,
);

/// Wizard de cierre de caja en modo "detallado" (3 pasos: efectivo, tarjeta
/// + transferencia, revisión + firma) más un cuarto paso de resultado
/// post-firma con varianza. Es a ciegas durante el conteo igual que el modo
/// "compacto" (modal único existente); la diferencia es solo estructural.
class CashCloseDetailedWizard extends ConsumerStatefulWidget {
  const CashCloseDetailedWizard({
    super.key,
    required this.cashRegisterSessionId,
    required this.input,
    this.cashierName,
    this.cashRegisterLabel,
    this.openedAt,
    this.onCloseConfirmed,
  });

  final String cashRegisterSessionId;
  final CashCloseInput input;
  final String? cashierName;
  final String? cashRegisterLabel;
  final DateTime? openedAt;
  final DetailedCloseHandler? onCloseConfirmed;

  @override
  ConsumerState<CashCloseDetailedWizard> createState() =>
      _CashCloseDetailedWizardState();
}

class _CashCloseDetailedWizardState
    extends ConsumerState<CashCloseDetailedWizard> {
  int _currentStep = 0;
  CashCloseResult? _signedResult;
  List<DenominationCount>? _signedDenominations;
  double _zoomFactor = 1.0;
  // Toggle de "Permitir recontar" cargado desde business_settings al
  // abrir el wizard. Si es true, después de firmar+imprimir el step
  // de resultado expone un botón "Volver a contar" (máximo 1 vez).
  bool _allowRecount = false;
  // Número del intento actual. Empieza en 1; cuando el cajero pulsa
  // "Volver a contar" en el step de resultado, se incrementa a 2 y se
  // reabre el wizard al paso 0. Después del 2 ya no se permite más.
  int _currentAttempt = 1;

  static const _stepLabels = [
    'Efectivo',
    'Tarjeta y transferencia',
    'Confirmar',
  ];

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadAllowRecount);
  }

  Future<void> _loadAllowRecount() async {
    try {
      final businessId = await BusinessResolver.ensure('auto');
      final repo = ref.read(posSettingsRepositoryProvider);
      final allow = await repo.getAllowRecount(businessId);
      if (!mounted) return;
      setState(() => _allowRecount = allow);
    } catch (_) {
      // Falla silenciosa: si no podemos leer el flag, asumimos `false`
      // (comportamiento legacy sin botón de reconteo).
    }
  }

  /// Acción del botón "Volver a contar" en el step de resultado. Solo
  /// disponible cuando `_allowRecount` está activo y `_currentAttempt < 2`.
  /// Reabre el wizard al paso 0 con los montos en cero; el próximo
  /// firmado insertará una fila nueva en `cash_count_blind` con
  /// `attempt_number = 2` (la original queda intacta como evidencia).
  Future<void> _onRecountAfterSign() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Volver a contar'),
        content: const Text(
          'Se hará un segundo conteo. El primer cierre quedará guardado '
          'como evidencia; el segundo se firma e imprime como cierre '
          'definitivo. Solo se permite un reconteo por turno.\n\n'
          '¿Continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
              foregroundColor: MangoColors.white,
            ),
            child: const Text('Sí, recontar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Audit log: registra el evento con los montos del primer cierre
    // (best-effort, no bloquea el reconteo si falla).
    final result = _signedResult;
    try {
      final businessId = await BusinessResolver.ensure('auto');
      if (mounted && result != null) {
        await ref
            .read(posSettingsRepositoryProvider)
            .recordCashRecount(
              businessId: businessId,
              sessionId: widget.cashRegisterSessionId,
              cashTotal: result.totalCounted.toDouble(),
              cardTotal: result.numericCard,
              transferTotal: result.numericTransfer,
            );
      }
    } catch (_) {
      // Silencioso.
    }
    if (!mounted) return;

    // Reabre el wizard: limpia state, vuelve al paso 0, marca attempt=2.
    ref.read(detailedWizardProvider(widget.input).notifier).resetCounts();
    setState(() {
      _signedResult = null;
      _signedDenominations = null;
      _currentStep = 0;
      _currentAttempt = 2;
    });
  }

  void _goTo(int step) {
    final clamped = step.clamp(0, _stepLabels.length - 1);
    setState(() => _currentStep = clamped);
    ref
        .read(detailedWizardProvider(widget.input).notifier)
        .goToStep(clamped);
  }

  Widget _activeStep() {
    switch (_currentStep) {
      case 0:
        return StepCashCount(input: widget.input);
      case 1:
        return StepCardTransfer(input: widget.input);
      case 2:
      default:
        return StepReviewSign(input: widget.input);
    }
  }

  void _next() => _goTo(_currentStep + 1);
  void _back() => _goTo(_currentStep - 1);

  void _onCancel() {
    Navigator.of(context).pop(_signedResult != null);
  }

  Future<void> _onPrimary() async {
    if (_signedResult != null) {
      // En el step de resultado, primary = Cerrar (mismo que onCancel).
      _onCancel();
      return;
    }
    if (_currentStep < _stepLabels.length - 1) {
      _next();
      return;
    }
    final notifier = ref.read(detailedWizardProvider(widget.input).notifier);
    // Si el cajero ya completó el primer cierre y pulsó "Volver a
    // contar", `_currentAttempt` está en 2 y el snapshot lleva ese
    // attempt para que el INSERT inserte una fila nueva sin colisionar
    // con la primera (UNIQUE en session + attempt).
    final snapshot = notifier.snapshot(attemptNumber: _currentAttempt);
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ConfirmCloseDialog(
        snapshot: snapshot,
        onConfirm: widget.onCloseConfirmed,
      ),
    );
    if (confirmed == true && mounted) {
      setState(() {
        _signedResult = snapshot.result;
        _signedDenominations = ref
            .read(detailedWizardProvider(widget.input))
            .denominations;
      });
    }
  }

  String get _primaryLabel {
    if (_signedResult != null) return 'Cerrar';
    switch (_currentStep) {
      case 0:
        return 'Continuar';
      case 1:
        return 'Revisar y confirmar';
      case 2:
      default:
        return 'Firmar y cerrar caja';
    }
  }

  IconData? get _primaryIcon {
    if (_signedResult != null) return Icons.check_rounded;
    switch (_currentStep) {
      case 0:
      case 1:
        return Icons.arrow_forward_rounded;
      case 2:
      default:
        return Icons.lock_outline;
    }
  }

  String get _secondaryLabel {
    if (_signedResult != null) return '';
    return _currentStep == 0 ? 'Cancelar' : 'Atrás';
  }

  IconData? get _secondaryIcon {
    if (_signedResult != null) return null;
    return _currentStep == 0 ? null : Icons.arrow_back_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final isResult = _signedResult != null;
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(
        textScaler: mq.textScaler.clamp(
          minScaleFactor: _zoomFactor,
          maxScaleFactor: _zoomFactor,
        ),
      ),
      child: _buildBody(isResult),
    );
  }

  Widget _buildBody(bool isResult) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (isResult) {
            _onCancel();
          } else if (_currentStep == 0) {
            _onCancel();
          } else {
            _back();
          }
        },
        const SingleActivator(LogicalKeyboardKey.f2): _onPrimary,
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            _onPrimary,
        const SingleActivator(LogicalKeyboardKey.numpadEnter, control: true):
            _onPrimary,
      },
      child: Focus(
        autofocus: true,
        child: Material(
          color: MangoColors.bgLight,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              WizardHeader(
                cashierName: widget.cashierName,
                cashRegisterLabel: widget.cashRegisterLabel,
                openedAt: widget.openedAt,
                onClose: _onCancel,
                zoomFactor: _zoomFactor,
                onZoomChanged: (v) => setState(() => _zoomFactor = v),
              ),
              WizardStepper(
                labels: _stepLabels,
                currentStep: isResult
                    ? _stepLabels.length - 1
                    : _currentStep,
              ),
              Flexible(
                fit: FlexFit.loose,
                child: isResult
                    ? StepResult(
                        input: widget.input,
                        result: _signedResult!,
                        denominations:
                            _signedDenominations ?? const [],
                        onClose: _onCancel,
                        cashRegisterSessionId:
                            widget.cashRegisterSessionId,
                        // Botón "Volver a contar": solo si el admin
                        // activó la opción y todavía no se usó el
                        // segundo intento (máximo 1 reconteo).
                        canRecount: _allowRecount && _currentAttempt < 2,
                        onRecount: _onRecountAfterSign,
                      )
                    : _activeStep(),
              ),
              if (isResult)
                _ResultFooter(onClose: _onCancel)
              else
                WizardFooter(
                  secondaryLabel: _secondaryLabel,
                  primaryLabel: _primaryLabel,
                  secondaryIcon: _secondaryIcon,
                  primaryIcon: _primaryIcon,
                  onSecondary: _currentStep == 0 ? _onCancel : _back,
                  onPrimary: _onPrimary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultFooter extends StatelessWidget {
  const _ResultFooter({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: const BoxDecoration(
        color: MangoColors.white,
        border: Border(top: BorderSide(color: MangoColors.cardBorder)),
      ),
      child: Row(
        children: [
          const Spacer(),
          ElevatedButton.icon(
            onPressed: onClose,
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('Cerrar'),
            style: ElevatedButton.styleFrom(
              backgroundColor: MangoColors.successGreen,
              foregroundColor: MangoColors.white,
              padding: const EdgeInsets.symmetric(
                horizontal: 22,
                vertical: 12,
              ),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              textStyle: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}
