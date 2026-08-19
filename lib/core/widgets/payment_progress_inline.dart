import 'package:flutter/material.dart';

import '../fiscal/payment_stage.dart';

/// Progreso del cobro contado *dentro* del flujo, sin tapar la pantalla.
///
/// Alternativa al `PaymentProgressOverlay`: en vez de cubrir el modal con un
/// velo, la lista de etapas ocupa el hueco que el panel de cobro ya tiene
/// libre y el propio boton de confirmar hace de barra de progreso. El cajero
/// sigue viendo el ticket y los pagos agregados mientras el cobro corre — que
/// es justo lo que suele estar mirando cuando el cliente pregunta.
///
/// Las dos piezas leen la misma `PaymentStage` que el overlay, asi que el
/// viewmodel no cambia segun cual se use.

// =============================================================================
// Etapas visibles
// =============================================================================

/// Las etapas de un cobro, en orden, para el tipo de comprobante dado.
///
/// Con NCF de papel (B01/B02) la etapa de DGII no existe: el numero sale de la
/// secuencia local. Listarla como pendiente le haria creer al cajero que el
/// cobro va a tardar mas de lo que tarda.
List<PaymentStage> paymentStagesFor({
  required bool isElectronic,
  PaymentStage? current,
}) => [
  PaymentStage.registrando,
  // `current` es la red de seguridad: si el flujo esta parado en la DGII, esa
  // fila se dibuja aunque hubieramos clasificado el comprobante como papel.
  // Sin esto `indexOf(stage)` devuelve -1, ninguna fila queda del lado done
  // ni active, y el panel entero se pinta en gris mientras el boton dice
  // "Consultando con la DGII" — exactamente lo que no puede pasar.
  if (isElectronic || current == PaymentStage.dgii) PaymentStage.dgii,
  PaymentStage.imprimiendo,
];

String _labelFor(PaymentStage stage) {
  switch (stage) {
    case PaymentStage.registrando:
      return 'Procesando pago';
    case PaymentStage.dgii:
      return 'Consultando con la DGII';
    case PaymentStage.imprimiendo:
      return 'Imprimiendo';
    case PaymentStage.listo:
    case PaymentStage.idle:
      return '';
  }
}

/// Texto de apoyo bajo cada etapa: dice el detalle, no repite el titulo.
String _detailFor(PaymentStage stage, {required bool done}) {
  switch (stage) {
    case PaymentStage.registrando:
      return done ? 'Pago registrado' : 'Registrando el cobro...';
    case PaymentStage.dgii:
      return done ? 'Comprobante aceptado' : 'Firmando y enviando el e-CF...';
    case PaymentStage.imprimiendo:
      return done ? 'Ticket impreso' : 'Enviando a la impresora...';
    case PaymentStage.listo:
    case PaymentStage.idle:
      return '';
  }
}

/// Fraccion completada (0..1) para pintar barras de progreso.
double paymentProgressFor(PaymentStage stage, {required bool isElectronic}) {
  if (stage == PaymentStage.idle) return 0;
  if (stage == PaymentStage.listo) return 1;
  final stages = paymentStagesFor(isElectronic: isElectronic, current: stage);
  final i = stages.indexOf(stage);
  if (i < 0) return 0;
  // +0.65 y no +1: la etapa en curso todavia no termino. Llenar la barra al
  // 100% al ENTRAR al ultimo paso deja al cajero mirando una barra llena que
  // no avanza, que se lee peor que una a medias que sigue moviendose.
  return ((i + 0.65) / stages.length).clamp(0.0, 1.0);
}

// =============================================================================
// Panel de etapas
// =============================================================================

/// Lista vertical de etapas, pensada para vivir en el hueco del panel de
/// cobro. Crece y se encoge sola: mide 0 cuando no hay cobro en vuelo.
class PaymentStepsPanel extends StatelessWidget {
  const PaymentStepsPanel({
    super.key,
    required this.stage,
    required this.isElectronic,
    this.dgiiContingency = false,
    this.accent = const Color(0xFFF97316),
    this.positive = const Color(0xFF22C55E),
    this.warning = const Color(0xFFF59E0B),
  });

  final PaymentStage stage;
  final bool isElectronic;

  /// La emision e-CF no completo a tiempo: el ticket sale igual y el
  /// documento se reenvia solo. Se pinta ambar, no rojo — la venta se cerro.
  final bool dgiiContingency;

  final Color accent;
  final Color positive;
  final Color warning;

  @override
  Widget build(BuildContext context) {
    final visible = stage != PaymentStage.idle;
    final stages = paymentStagesFor(isElectronic: isElectronic, current: stage);
    // `listo` no es una fila de la lista, es el estado en que ya no queda
    // ninguna: lo empujamos mas alla del ultimo indice para que todas las
    // filas caigan del lado `done` y el panel quede entero en verde.
    final finished = stage == PaymentStage.listo;
    final activeIdx = finished ? stages.length : stages.indexOf(stage);

    // AnimatedSize en vez de un if: el panel aparece empujando el boton hacia
    // abajo con una transicion, no de un salto. Sin esto el layout da un
    // brinco justo cuando el cajero acaba de tocar Confirmar.
    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: !visible
          ? const SizedBox(width: double.infinity, height: 0)
          : Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: const Color(0xFFEEEEEE)),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < stages.length; i++)
                    _StepRow(
                      label: _stepLabel(stages[i], i, activeIdx),
                      detail: _stepDetail(stages[i], i, activeIdx),
                      done: i < activeIdx,
                      active: i == activeIdx,
                      warned:
                          dgiiContingency && stages[i] == PaymentStage.dgii,
                      isLast: i == stages.length - 1,
                      accent: accent,
                      positive: positive,
                      warning: warning,
                    ),
                  const SizedBox(height: 4),
                  _Track(
                    value: paymentProgressFor(
                      stage,
                      isElectronic: isElectronic,
                    ),
                    // Verde solo al cerrar: mientras corre la barra es
                    // naranja para que el verde signifique una sola cosa.
                    color: dgiiContingency
                        ? warning
                        : (finished ? positive : accent),
                  ),
                ],
              ),
            ),
    );
  }

  String _stepLabel(PaymentStage s, int i, int activeIdx) {
    if (dgiiContingency && s == PaymentStage.dgii) {
      return 'DGII no respondio a tiempo';
    }
    return _labelFor(s);
  }

  String _stepDetail(PaymentStage s, int i, int activeIdx) {
    if (dgiiContingency && s == PaymentStage.dgii) {
      return 'Se emite en contingencia, se reenvia solo';
    }
    if (i > activeIdx) return '';
    return _detailFor(s, done: i < activeIdx);
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.label,
    required this.detail,
    required this.done,
    required this.active,
    required this.warned,
    required this.isLast,
    required this.accent,
    required this.positive,
    required this.warning,
  });

  final String label;
  final String detail;
  final bool done;
  final bool active;
  final bool warned;
  final bool isLast;
  final Color accent;
  final Color positive;
  final Color warning;

  @override
  Widget build(BuildContext context) {
    // Las etapas que faltan van atenuadas, no ocultas: el cajero ve de
    // entrada cuantos pasos son, asi sabe cuanto le queda.
    final dim = !done && !active && !warned;

    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: _Indicator(
              done: done,
              active: active,
              warned: warned,
              accent: accent,
              positive: positive,
              warning: warning,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 240),
              opacity: dim ? 0.4 : 1,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: warned ? warning : const Color(0xFF1F2937),
                    ),
                  ),
                  if (detail.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        detail,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF9CA3AF),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Indicator extends StatelessWidget {
  const _Indicator({
    required this.done,
    required this.active,
    required this.warned,
    required this.accent,
    required this.positive,
    required this.warning,
  });

  final bool done;
  final bool active;
  final bool warned;
  final Color accent;
  final Color positive;
  final Color warning;

  @override
  Widget build(BuildContext context) {
    // El aviso gana sobre done: si la DGII no respondio, esa fila no puede
    // seguir mostrando un check verde mientras el resto avanza.
    if (warned) {
      return _Filled(color: warning, icon: Icons.priority_high_rounded);
    }
    if (done) return _Filled(color: positive, icon: Icons.check_rounded);
    if (active) {
      return Padding(
        padding: const EdgeInsets.all(1),
        child: CircularProgressIndicator(strokeWidth: 2.4, color: accent),
      );
    }
    return Center(
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFD1D5DB), width: 2),
        ),
      ),
    );
  }
}

class _Filled extends StatelessWidget {
  const _Filled({required this.color, required this.icon});
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.4, end: 1),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Transform.scale(scale: t, child: child),
      child: DecoratedBox(
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Center(child: Icon(icon, size: 14, color: Colors.white)),
      ),
    );
  }
}

class _Track extends StatelessWidget {
  const _Track({required this.value, required this.color});
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: value),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        builder: (context, t, _) => LinearProgressIndicator(
          value: t,
          minHeight: 4,
          backgroundColor: const Color(0xFFF1F2F4),
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      ),
    );
  }
}

// =============================================================================
// Boton de confirmar con progreso
// =============================================================================

/// El boton de confirmar cobro haciendo tambien de barra de progreso.
///
/// Mientras el cobro corre se rellena de izquierda a derecha con un verde mas
/// oscuro y su texto va cambiando de etapa. La idea es que el movimiento
/// ocurra en el mismo sitio donde el cajero acaba de tocar y donde tiene la
/// vista puesta, en vez de mandarlo a leer a otra parte de la pantalla.
class ConfirmPaymentProgressButton extends StatelessWidget {
  const ConfirmPaymentProgressButton({
    super.key,
    required this.stage,
    required this.isElectronic,
    required this.onPressed,
    this.dgiiContingency = false,
    this.ncf,
    this.idleLabel = 'Confirmar pago',
    this.height = 54,
    this.fontSize = 15,
    this.base = const Color(0xFF22C55E),
    this.fill = const Color(0xFF15803D),
    this.warning = const Color(0xFFF59E0B),
    this.warningFill = const Color(0xFFB45309),
    this.disabled = const Color(0xFFEEEEEE),
  });

  final PaymentStage stage;
  final bool isElectronic;
  final bool dgiiContingency;

  /// Numero de comprobante emitido, para mostrarlo en el estado final. Si
  /// viene null el boton dice solo "Facturado" — mejor eso que inventar un
  /// numero o dejar un guion donde el cajero espera leer el NCF.
  final String? ncf;

  /// `null` deshabilita el boton. Mientras el cobro corre debe venir null
  /// tambien: es lo que impide el doble-tap que duplicaria la venta.
  final VoidCallback? onPressed;

  final String idleLabel;
  final double height;
  final double fontSize;
  final Color base;
  final Color fill;
  final Color warning;
  final Color warningFill;
  final Color disabled;

  bool get _busy => stage != PaymentStage.idle;
  bool get _finished => stage == PaymentStage.listo;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    // Al cerrar el boton se asienta en el verde oscuro completo: es la senal
    // de "esto ya esta", distinta del verde claro de "puedes tocar aqui".
    final bg = _finished
        ? (dgiiContingency ? warning : fill)
        : (!enabled && !_busy ? disabled : (dgiiContingency ? warning : base));
    final fg = !enabled && !_busy ? const Color(0xFF9CA3AF) : Colors.white;

    return SizedBox(
      width: double.infinity,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              color: bg,
            ),
            // El relleno solo existe durante el cobro. Se ancla a la
            // izquierda para que se lea como avance y no como un fundido.
            if (_busy)
              // LayoutBuilder y no FractionallySizedBox: aqui hace falta un
              // ancho medido y anclado a la izquierda. FractionallySizedBox
              // centra su hijo por defecto, y el relleno se leia como una
              // barra flotando en medio del boton en vez de como avance.
              LayoutBuilder(
                builder: (context, c) => TweenAnimationBuilder<double>(
                  tween: Tween(
                    begin: 0,
                    end: paymentProgressFor(
                      stage,
                      isElectronic: isElectronic,
                    ),
                  ),
                  duration: const Duration(milliseconds: 450),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, _) => Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: c.maxWidth * t.clamp(0.0, 1.0),
                      height: c.maxHeight,
                      color: dgiiContingency ? warningFill : fill,
                    ),
                  ),
                ),
              ),
            Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                // Sube el texto viejo y entra el nuevo por abajo: lee como
                // una lista que avanza, no como un parpadeo.
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.45),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: _Label(
                  // La key es lo que dispara la transicion: sin ella
                  // AnimatedSwitcher considera que es el mismo widget y el
                  // texto cambiaria de golpe.
                  key: ValueKey('$stage-$dgiiContingency'),
                  stage: stage,
                  dgiiContingency: dgiiContingency,
                  ncf: ncf,
                  idleLabel: idleLabel,
                  color: fg,
                  fontSize: fontSize,
                ),
              ),
            ),
            // El Material va ENCIMA del relleno para que el ripple se vea, y
            // con color transparente para no tapar lo pintado abajo.
            Material(
              color: Colors.transparent,
              child: InkWell(onTap: onPressed, child: const SizedBox.expand()),
            ),
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label({
    super.key,
    required this.stage,
    required this.dgiiContingency,
    required this.ncf,
    required this.idleLabel,
    required this.color,
    required this.fontSize,
  });

  final PaymentStage stage;
  final bool dgiiContingency;
  final String? ncf;
  final String idleLabel;
  final Color color;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: color,
      fontWeight: FontWeight.w700,
      fontSize: fontSize,
    );

    if (stage == PaymentStage.idle) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline, size: 18, color: color),
          const SizedBox(width: 8),
          Text(idleLabel, style: style),
        ],
      );
    }

    if (stage == PaymentStage.listo) {
      final n = ncf?.trim();
      final text = dgiiContingency
          ? 'Impreso en contingencia'
          : (n == null || n.isEmpty ? 'Facturado' : 'Facturado \u00b7 $n');
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            dgiiContingency ? Icons.error_outline : Icons.check_rounded,
            size: 19,
            color: color,
          ),
          const SizedBox(width: 9),
          Flexible(
            child: Text(
              text,
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    final label = dgiiContingency && stage == PaymentStage.imprimiendo
        ? 'Imprimiendo en contingencia...'
        : '${_labelFor(stage)}...';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2.2, color: color),
        ),
        const SizedBox(width: 9),
        Flexible(
          child: Text(
            label,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
