// Aviso de pedido entrante por canal externo (Pincer, y mañana Uber Eats).
//
// POR QUÉ EXISTE
//   Un pedido de delivery llega sin que nadie lo digite: si nadie está mirando
//   la pantalla, se entera la cocina cuando sale el papel — y si la impresora
//   falla, no se entera nadie. Los agregadores resuelven esto con ruido y un
//   aviso que no se va solo, y eso es lo que se copia acá.
//
// DECISIONES
//   - Suena y avisa en las tablets de QUIEN ATIENDE el pedido: cajero,
//     supervisor, administrador y propietario. En la del mesero NUNCA suena —
//     él sirve mesas, el pedido de delivery no es suyo y el ruido lo distrae.
//     El corte lo da el permiso `ventas.ordenes.ver`, que no está en el preset
//     de Mesero. Si un negocio quiere otra cosa, lo cambia en Roles y permisos
//     sin tocar código.
//   - Dentro de los que sí avisan, suena en TODAS sus tablets, no solo en la
//     que imprime: el aviso es para enterarse, la impresión es otra cosa.
//   - El aviso NO se va solo: se queda hasta que alguien lo cierre. Un toast de
//     4 segundos no sirve para un pedido que hay que preparar (por eso esto no
//     usa `AppToast`, que a propósito se descarta solo y no se acumula).
//   - Solo pedidos de `production`: los de sandbox no hacen ruido en el local.
//   - Al arrancar se marca el ahora como punto de partida: abrir la app no
//     puede disparar el sonido de los pedidos de hace tres horas.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/services/session/session_controller.dart';

@immutable
class ExternalOrderAlert {
  const ExternalOrderAlert({
    required this.id,
    required this.channel,
    required this.number,
    required this.serviceType,
    required this.customerName,
    required this.total,
    required this.paid,
    required this.createdAt,
  });

  final String id;
  final String channel;
  final String? number;
  final String serviceType;
  final String? customerName;
  final double? total;
  final bool paid;
  final DateTime createdAt;

  /// 'Pincer' en vez de 'pincer'; 'Uber Eats' en vez de 'uber_eats'.
  String get channelLabel => switch (channel) {
    'pincer' => 'Pincer',
    'uber_eats' => 'Uber Eats',
    'pedidos_ya' => 'Pedidos Ya',
    _ =>
      channel.isEmpty
          ? 'Canal externo'
          : channel[0].toUpperCase() + channel.substring(1),
  };

  String get serviceLabel =>
      serviceType == 'pickup' ? 'Para llevar' : 'Delivery';
}

class ExternalOrderAlertsNotifier extends Notifier<List<ExternalOrderAlert>> {
  Timer? _timer;
  bool _tickInFlight = false;
  DateTime? _since;
  Player? _player;

  // 10s. El worker de impresión va a 12s; este va un poco más rápido para que
  // el aviso llegue antes que el papel, no después.
  static const Duration _interval = Duration(seconds: 10);

  @override
  List<ExternalOrderAlert> build() {
    ref.onDispose(stop);
    return const [];
  }

  void start() {
    if (_timer != null) return;
    // El punto de partida es AHORA: lo que entró antes de abrir la app ya
    // pasó por otra pantalla o por el papel.
    _since ??= DateTime.now().toUtc();
    _timer = Timer.periodic(_interval, (_) => _safeTick());
    Future.microtask(_safeTick);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _player?.dispose();
    _player = null;
  }

  /// Quita un aviso de la esquina. Lo llama el usuario al cerrarlo.
  void dismiss(String id) {
    state = state.where((a) => a.id != id).toList(growable: false);
  }

  void dismissAll() => state = const [];

  Future<void> _safeTick() async {
    if (_tickInFlight) return;
    _tickInFlight = true;
    try {
      await _tick();
    } catch (e) {
      debugPrint('[ExtOrderAlert] tick error: $e');
    } finally {
      _tickInFlight = false;
    }
  }

  Future<void> _tick() async {
    final supabase = Supabase.instance.client;
    if (supabase.auth.currentUser == null) return;

    // El equipo del mesero no suena ni muestra la tarjeta. Se comprueba en cada
    // tick, no solo al arrancar: en una tablet compartida el turno cambia sin
    // cerrar la app.
    if (!ref
        .read(sessionProvider.notifier)
        .hasPermission('ventas.ordenes.ver')) {
      if (state.isNotEmpty) state = const [];
      return;
    }

    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) return;

    final since = _since;
    if (since == null) return;

    final List<dynamic> rows;
    try {
      rows = await supabase
          .from('external_orders')
          .select(
            'id, channel, external_number, service_type, customer_name, '
            'external_total, paid_externally, created_at',
          )
          .eq('business_id', businessId)
          .eq('environment', 'production')
          .gt('created_at', since.toIso8601String())
          .order('created_at', ascending: true)
          .limit(20);
    } catch (e) {
      // Sin la tabla (migración sin aplicar) o sin red: no avisamos este tick.
      // Nunca rompemos la pantalla por un aviso.
      debugPrint('[ExtOrderAlert] no se pudo consultar: $e');
      return;
    }
    if (rows.isEmpty) return;

    final nuevos = <ExternalOrderAlert>[];
    for (final raw in rows) {
      final m = raw as Map<String, dynamic>;
      final id = (m['id'] as String?)?.trim();
      final createdAt = DateTime.tryParse(
        (m['created_at'] as String?) ?? '',
      )?.toUtc();
      if (id == null || createdAt == null) continue;
      if (state.any((a) => a.id == id)) continue;

      nuevos.add(
        ExternalOrderAlert(
          id: id,
          channel: (m['channel'] as String?) ?? '',
          number: (m['external_number'] as String?)?.trim(),
          serviceType: (m['service_type'] as String?) ?? 'delivery',
          customerName: (m['customer_name'] as String?)?.trim(),
          total: (m['external_total'] as num?)?.toDouble(),
          paid: (m['paid_externally'] as bool?) ?? false,
          createdAt: createdAt,
        ),
      );
      // Avanzar el corte SIEMPRE, aunque el aviso se descarte: si no, el mismo
      // pedido volvería a sonar en cada tick.
      if (createdAt.isAfter(since)) _since = createdAt;
    }

    if (nuevos.isEmpty) return;
    state = [...nuevos.reversed, ...state];
    unawaited(_sonar());
  }

  Future<void> _sonar() async {
    try {
      final player = _player ??= Player();
      await player.open(
        Media('asset:///assets/sounds/new_order.wav'),
        play: true,
      );
    } catch (e) {
      // Sin audio en esta plataforma o sin salida de sonido: el aviso visual
      // igual quedó en pantalla. Nunca tumbamos el aviso por el sonido.
      debugPrint('[ExtOrderAlert] no se pudo reproducir el aviso: $e');
    }
  }
}

final externalOrderAlertsProvider =
    NotifierProvider<ExternalOrderAlertsNotifier, List<ExternalOrderAlert>>(
      ExternalOrderAlertsNotifier.new,
    );
