import 'dart:async';

import 'package:flutter/material.dart';

import '../fiscal/payment_stage.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// Overlay de progreso del cobro, con las etapas nombradas.
///
/// Reemplaza al spinner mudo con "Procesando pago...". Ese texto alcanzaba
/// cuando el cobro era un solo RPC de milisegundos, pero con la emisión e-CF
/// el flujo pasó a bloquear hasta 8 segundos esperando a la DGII. Sin decir
/// qué se está esperando, esos segundos se leen como app colgada y el cajero
/// vuelve a tocar Cobrar.
///
/// Las etapas se pintan como una lista vertical: la cumplida con check, la
/// activa con spinner y en negrita, la pendiente en gris. Es la misma lectura
/// que un envío de paquete — se ve de un vistazo dónde va y cuánto falta.
///
/// Lo consumen los dos flujos de cobro (modal simple y split por mesa), por
/// eso vive en `core/widgets` y no dentro de un módulo de presentación.
class PaymentProgressOverlay extends StatelessWidget {
  const PaymentProgressOverlay({
    super.key,
    required this.stage,
    required this.isElectronic,
    this.dgiiContingency = false,
  });

  /// Etapa en curso.
  final PaymentStage stage;

  /// Si el comprobante es electrónico. Cuando es NCF de papel la etapa de
  /// DGII no se dibuja: no existe esa espera y listarla como "pendiente"
  /// haría creer que el cobro va a tardar más de lo que tarda.
  final bool isElectronic;

  /// La emisión e-CF no completó a tiempo (timeout de `emit-document`) y el
  /// ticket sale en contingencia: el cron de respaldo + el webhook lo
  /// reenvían después. El cobro NO falla — se pinta ámbar, no rojo, porque
  /// para el cajero la venta sí se cerró y el cliente sí se lleva su
  /// comprobante. Rojo lo mandaría a reintentar un cobro ya hecho.
  final bool dgiiContingency;

  @override
  Widget build(BuildContext context) {
    final steps = <_Step>[
      const _Step(PaymentStage.registrando, 'Registrando el cobro'),
      if (isElectronic)
        const _Step(PaymentStage.dgii, 'Consultando con la DGII'),
      const _Step(PaymentStage.imprimiendo, 'Imprimiendo comprobante'),
    ];

    final activeIdx = steps.indexWhere((s) => s.stage == stage);

    // Devuelve un widget normal, NO un `Positioned`: el call site decide cómo
    // superponerlo (`Positioned.fill` dentro de su Stack, envuelto en el
    // ClipRRect que le corresponda a SU radio de esquina). Si el Positioned
    // viviera aquí, envolverlo en un ClipRRect para redondear las esquinas
    // rompería con "Incorrect use of ParentDataWidget" — el Positioned
    // dejaría de ser hijo directo del Stack.
    return ColoredBox(
    color: AppColors.background.withValues(alpha: 0.92),
    child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(
                  left: 44,
                  bottom: AppSpacing.xl,
                ),
                child: Text(
                  'Cobrando',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
              ),
              for (var i = 0; i < steps.length; i++)
                _StepRow(
                  label: _labelFor(steps[i]),
                  // activeIdx es -1 mientras stage sigue en idle (el frame
                  // entre el tap y el primer copyWith): ahí nada va hecho.
                  done: activeIdx >= 0 && i < activeIdx,
                  active: i == activeIdx,
                  // El aviso se ancla a la fila de DGII aunque la etapa ya
                  // haya avanzado a imprimiendo: es el resultado de ESE
                  // paso, y moverlo a la fila activa lo haría ilegible.
                  warned:
                      dgiiContingency && steps[i].stage == PaymentStage.dgii,
                  isLast: i == steps.length - 1,
                ),
              if (isElectronic && stage == PaymentStage.dgii)
                const Padding(
                  padding: EdgeInsets.only(left: 44, top: AppSpacing.lg),
                  child: _DgiiHint(),
                ),
              if (dgiiContingency && stage != PaymentStage.dgii)
                const Padding(
                  padding: EdgeInsets.only(left: 44, top: AppSpacing.lg),
                  child: _ContingencyHint(),
                ),
            ],
        ),
      ),
    ),
    );
  }

  String _labelFor(_Step step) {
    if (dgiiContingency && step.stage == PaymentStage.dgii) {
      return 'DGII no respondió a tiempo';
    }
    return step.label;
  }
}

class _Step {
  const _Step(this.stage, this.label);
  final PaymentStage stage;
  final String label;
}

/// Una fila: indicador + etiqueta + el riel que la une con la siguiente.
class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.label,
    required this.done,
    required this.active,
    required this.isLast,
    this.warned = false,
  });

  final String label;
  final bool done;
  final bool active;
  final bool isLast;
  final bool warned;

  @override
  Widget build(BuildContext context) {
    final color = warned
        ? AppColors.warning
        : (done || active ? AppColors.primary : AppColors.mutedForeground);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: _StepIndicator(
                  done: done,
                  active: active,
                  warned: warned,
                ),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    color: done || warned
                        ? (warned ? AppColors.warning : AppColors.primary)
                            .withValues(alpha: 0.35)
                        : AppColors.mutedForeground.withValues(alpha: 0.2),
                  ),
                ),
            ],
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                top: 4,
                bottom: isLast ? 0 : AppSpacing.lg,
              ),
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: active || warned
                      ? FontWeight.w700
                      : FontWeight.w500,
                  color: color,
                ),
                child: Text(label),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Círculo de estado: check si ya pasó, spinner si está en curso, punto
/// hueco si falta, admiración ámbar si pasó pero con aviso.
class _StepIndicator extends StatelessWidget {
  const _StepIndicator({
    required this.done,
    required this.active,
    this.warned = false,
  });

  final bool done;
  final bool active;
  final bool warned;

  @override
  Widget build(BuildContext context) {
    // El aviso gana sobre done/active: si la DGII no respondió, esa fila no
    // puede seguir mostrando un check verde mientras el resto avanza.
    if (warned) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.warning,
          shape: BoxShape.circle,
        ),
        child: const Center(
          child: Icon(
            Icons.priority_high_rounded,
            size: 16,
            color: Colors.white,
          ),
        ),
      );
    }

    if (done) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.primary,
          shape: BoxShape.circle,
        ),
        child: const Center(
          child: Icon(Icons.check, size: 16, color: Colors.white),
        ),
      );
    }

    if (active) {
      return Padding(
        padding: const EdgeInsets.all(2),
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: AppColors.primary,
        ),
      );
    }

    return Center(
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: AppColors.mutedForeground.withValues(alpha: 0.45),
            width: 2,
          ),
        ),
      ),
    );
  }
}

/// Nota bajo la etapa de DGII. Aparece a los 2 segundos, no de una: en la
/// mayoría de los cobros Alanube responde en 1-3s y mostrarla siempre
/// sugeriría que la espera es larga cuando no lo es.
class _DgiiHint extends StatefulWidget {
  const _DgiiHint();

  @override
  State<_DgiiHint> createState() => _DgiiHintState();
}

class _DgiiHintState extends State<_DgiiHint> {
  bool _visible = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Timer cancelable, no Future.delayed: el cobro suele resolverse antes de
    // los 2s y el overlay se desmonta. Un delayed sin cancelar sigue vivo
    // hasta que dispara, lo que deja timers colgando por cada cobro.
    _timer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 300),
      child: Text(
        'Estamos firmando la factura electrónica.\nNo cierres esta ventana.',
        style: TextStyle(
          fontSize: 12.5,
          height: 1.45,
          color: AppColors.mutedForeground,
        ),
      ),
    );
  }
}

/// Nota cuando la emisión se fue a contingencia. Dice las dos cosas que el
/// cajero necesita saber para no detener la fila: que la venta quedó hecha y
/// que él no tiene que reenviar nada.
class _ContingencyHint extends StatelessWidget {
  const _ContingencyHint();

  @override
  Widget build(BuildContext context) {
    return Text(
      'El cobro quedó registrado y el ticket se imprime igual.\n'
      'La factura se le envía a la DGII automáticamente.',
      style: TextStyle(
        fontSize: 12.5,
        height: 1.45,
        color: AppColors.mutedForeground,
      ),
    );
  }
}
