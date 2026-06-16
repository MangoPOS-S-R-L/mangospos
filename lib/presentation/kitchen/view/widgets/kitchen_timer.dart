import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_radius.dart';

/// Urgencia de una comanda según el tiempo que lleva en cocina.
///
/// Umbrales alineados con el KDS histórico: aviso a los 10 min, urgente a
/// los 15. La cocina necesita ver de un vistazo qué órdenes se están
/// atrasando sin leer cada reloj.
enum KitchenUrgency { normal, warning, urgent }

KitchenUrgency kitchenUrgencyFor(Duration elapsed) {
  final minutes = elapsed.inMinutes;
  if (minutes >= 15) return KitchenUrgency.urgent;
  if (minutes >= 10) return KitchenUrgency.warning;
  return KitchenUrgency.normal;
}

/// Color de acento de la urgencia. Reusa los tokens del design system para
/// no introducir colores nuevos (verde ok, ámbar aviso, rojo urgente).
Color kitchenUrgencyColor(KitchenUrgency urgency) {
  switch (urgency) {
    case KitchenUrgency.urgent:
      return AppColors.destructive;
    case KitchenUrgency.warning:
      return AppColors.warning;
    case KitchenUrgency.normal:
      return AppColors.success;
  }
}

/// Tick global compartido: un único `Timer.periodic(1s)` alimenta a TODOS los
/// timers del tablero. Cada [KitchenTimer] se suscribe vía `ValueListenable`
/// y recibe un rebuild aislado — el board completo NO se reconstruye cada
/// segundo. Es el mismo patrón que el `TimerWidget` del KDS para evitar el
/// spike de CPU con muchas comandas activas.
class _KitchenTick {
  _KitchenTick._();
  static final _KitchenTick instance = _KitchenTick._();

  final ValueNotifier<DateTime> _now = ValueNotifier<DateTime>(DateTime.now());
  ValueListenable<DateTime> get now => _now;

  Timer? _timer;
  int _listeners = 0;

  void subscribe() {
    _listeners++;
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      _now.value = DateTime.now();
    });
  }

  void unsubscribe() {
    _listeners = (_listeners - 1).clamp(0, 1 << 30);
    if (_listeners == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }
}

/// ⏱️ Pastilla `MM:SS` que sube de tono con la urgencia de la comanda.
/// Se rellena de color sólido al entrar en aviso/urgente para que destaque.
class KitchenTimer extends StatefulWidget {
  final DateTime startTime;
  final bool compact;

  const KitchenTimer({
    super.key,
    required this.startTime,
    this.compact = false,
  });

  @override
  State<KitchenTimer> createState() => _KitchenTimerState();
}

class _KitchenTimerState extends State<KitchenTimer> {
  final _tick = _KitchenTick.instance;

  @override
  void initState() {
    super.initState();
    _tick.subscribe();
  }

  @override
  void dispose() {
    _tick.unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DateTime>(
      valueListenable: _tick.now,
      builder: (context, now, _) {
        final raw = now.difference(widget.startTime);
        final elapsed = raw.isNegative ? Duration.zero : raw;
        final minutes = elapsed.inMinutes;
        final seconds = elapsed.inSeconds % 60;
        final urgency = kitchenUrgencyFor(elapsed);
        final color = kitchenUrgencyColor(urgency);
        final filled = urgency != KitchenUrgency.normal;

        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 8 : 10,
            vertical: widget.compact ? 4 : 6,
          ),
          decoration: BoxDecoration(
            color: filled ? color : color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.full),
            border: Border.all(
              color: filled ? color : color.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                urgency == KitchenUrgency.urgent
                    ? Icons.local_fire_department_rounded
                    : Icons.schedule_rounded,
                size: widget.compact ? 13 : 15,
                color: filled ? Colors.white : color,
              ),
              const SizedBox(width: 5),
              Text(
                '${minutes.toString().padLeft(2, '0')}:'
                '${seconds.toString().padLeft(2, '0')}',
                style: TextStyle(
                  color: filled ? Colors.white : color,
                  fontSize: widget.compact ? 12 : 13.5,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
