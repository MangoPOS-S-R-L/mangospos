import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Cliente del feed en vivo del Hub (F3c-2). Se conecta a `ws://hub/hub/events`,
/// se suscribe a su negocio y expone las ops como un Stream. Reconecta con
/// backoff si la conexión se cae (Hub reiniciado, red intermitente).
///
/// Lo consume el KDS (y, más adelante, otros terminales) en modo hub para
/// recibir cambios en vivo sin el Realtime de Supabase.
class HubEventStream {
  HubEventStream({required this.baseUrl, required this.businessId});

  final String baseUrl;
  final String businessId;

  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  bool _disposed = false;
  int _attempt = 0;

  /// Ops aplicadas que llegan del Hub (cada una incluye su `seq`).
  Stream<Map<String, dynamic>> get ops => _controller.stream;

  /// Convierte la baseUrl HTTP del Hub en la URL WebSocket del feed.
  static Uri wsUrlFor(String baseUrl) {
    final trimmed =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final ws = trimmed.replaceFirst(RegExp(r'^http'), 'ws');
    return Uri.parse('$ws/hub/events');
  }

  void connect() {
    if (_disposed) return;
    try {
      _channel = WebSocketChannel.connect(wsUrlFor(baseUrl));
      // Mensaje de suscripción: el servidor lo usa para enrutar el feed del
      // negocio a este socket.
      _channel!.sink.add(jsonEncode({'subscribe': businessId}));
      _sub = _channel!.stream.listen(
        (message) {
          try {
            final data = jsonDecode(message as String);
            if (data is Map) {
              _attempt = 0; // recibimos algo → conexión sana
              _controller.add(Map<String, dynamic>.from(data));
            }
          } catch (_) {
            // Mensaje no-JSON: ignorar.
          }
        },
        onDone: _scheduleReconnect,
        onError: (_) => _scheduleReconnect(),
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('[HubEventStream] connect falló: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _sub?.cancel();
    _sub = null;
    _channel = null;
    _attempt = (_attempt + 1).clamp(1, 6);
    // Backoff acotado: 1s, 2s, 4s … hasta 32s.
    final delay = Duration(seconds: 1 << (_attempt - 1));
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, connect);
  }

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    await _controller.close();
  }
}
