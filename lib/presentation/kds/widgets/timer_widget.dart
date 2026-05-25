import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Tick global compartido para todos los `TimerWidget` del KDS.
///
/// PRD 8 Fase 2 fix #2 — antes, cada `TimerWidget` instanciaba su propio
/// `Timer.periodic(1s)` con `setState`. Con 20 órdenes activas en KDS
/// eso son 20 timers + 20 `setState` por segundo + 20 rebuilds completos
/// del subtree (Container → Row → Icon + Text). CPU spike sostenido.
///
/// Ahora: 1 timer global compartido, N rebuilds aislados al
/// `ValueListenableBuilder`. El timer se pausa automáticamente cuando
/// no hay listeners (cero costo si KDS está vacío o cerrado).
class _TimerTickService {
  _TimerTickService._();
  static final _TimerTickService _instance = _TimerTickService._();

  /// `ValueNotifier` con el `now` tickeado cada segundo. Los widgets se
  /// suscriben via `ValueListenableBuilder` y reciben rebuild aislado.
  final ValueNotifier<DateTime> _tick = ValueNotifier<DateTime>(DateTime.now());
  ValueListenable<DateTime> get tick => _tick;

  Timer? _timer;
  int _listenerCount = 0;

  /// Llamado por cada `TimerWidget` en `initState`. Idempotente: el
  /// timer arranca con el primer subscriber, no se duplica.
  void subscribe() {
    _listenerCount++;
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      _tick.value = DateTime.now();
    });
  }

  /// Llamado en `dispose`. Cuando llega a 0 listeners, el timer se
  /// cancela — cero CPU si no hay nada que mostrar.
  void unsubscribe() {
    _listenerCount = (_listenerCount - 1).clamp(0, 1 << 30);
    if (_listenerCount == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }
}

/// ⏱️ Widget de timer
class TimerWidget extends StatefulWidget {
  final DateTime startTime;

  const TimerWidget({super.key, required this.startTime});

  @override
  State<TimerWidget> createState() => _TimerWidgetState();
}

class _TimerWidgetState extends State<TimerWidget> {
  final _ticker = _TimerTickService._instance;

  @override
  void initState() {
    super.initState();
    _ticker.subscribe();
  }

  @override
  void dispose() {
    _ticker.unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ValueListenableBuilder solo rebuilds este subtree, no el padre.
    // El widget padre del KDS (lista de tickets) NO rebuild cada segundo.
    return ValueListenableBuilder<DateTime>(
      valueListenable: _ticker.tick,
      builder: (context, now, _) {
        final elapsed = now.difference(widget.startTime);
        final minutes = elapsed.inMinutes;
        final seconds = elapsed.inSeconds % 60;
        final isUrgent = minutes >= 15;
        final isWarning = minutes >= 10;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: isUrgent
                ? Colors.red
                : isWarning
                ? const Color(0xFFF97316)
                : Colors.grey[700],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.timer,
                size: 16,
                color: isUrgent || isWarning ? Colors.white : Colors.grey[300],
              ),
              const SizedBox(width: 4),
              Text(
                '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}',
                style: TextStyle(
                  color: isUrgent || isWarning
                      ? Colors.white
                      : Colors.grey[300],
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
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
