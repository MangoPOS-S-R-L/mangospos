import 'dart:async';

import 'package:http/http.dart' as http;

/// Error que lanza [ResilientHttpClient] cuando NO intenta la red porque el
/// detector de conectividad ya confirmó que no hay internet.
///
/// Extiende [TimeoutException] a propósito: todo el código que ya maneja la
/// caída de red (`on TimeoutException`, `OfflinePosService.isTransportError`,
/// `FriendlyError`) lo reconoce sin cambios y toma su camino offline.
class OfflineShortCircuitException extends TimeoutException {
  OfflineShortCircuitException(String path)
      : super('Sin conexión a internet (no se intentó $path)');
}

/// Cliente HTTP que se le pasa a `Supabase.initialize`.
///
/// Sin él, el cliente de Supabase no tiene NINGÚN timeout: con el WiFi arriba
/// pero sin internet, una petición sobre un socket keep-alive muerto se queda
/// esperando para siempre, y cada pantalla que la espera se congela. Esto le
/// pone dos límites a las rutas de base de datos y de auth:
///
/// 1. **Fallo inmediato** cuando [isKnownOffline] dice que un sondeo reciente
///    ya confirmó la caída: la petición ni sale, y el llamador cae a su camino
///    offline (caché / cola) al instante en vez de esperar su timeout.
/// 2. **Timeout duro** por petición (y por silencio del cuerpo) para la
///    ventana en que la red ya murió pero el detector todavía no se enteró.
///    Al vencer avisa con [onTransportFailure] para que el detector sondee YA.
///
/// Storage y Edge Functions pasan sin tocar: subidas grandes y funciones que
/// emiten documentos fiscales no deben cortarse por un límite pensado para
/// consultas del POS.
class ResilientHttpClient extends http.BaseClient {
  ResilientHttpClient({
    http.Client? inner,
    bool Function()? isKnownOffline,
    void Function()? onTransportFailure,
    this.restTimeout = const Duration(seconds: 30),
    this.authTimeout = const Duration(seconds: 20),
    this.bodyIdleTimeout = const Duration(seconds: 30),
  })  : _inner = inner ?? http.Client(),
        _isKnownOffline = isKnownOffline ?? _never,
        _onTransportFailure = onTransportFailure ?? _noop;

  final http.Client _inner;
  final bool Function() _isKnownOffline;
  final void Function() _onTransportFailure;

  /// PostgREST (tablas y RPC).
  final Duration restTimeout;

  /// GoTrue (login, refresco del token).
  final Duration authTimeout;

  /// Máximo silencio entre trozos del cuerpo de la respuesta.
  final Duration bodyIdleTimeout;

  static bool _never() => false;
  static void _noop() {}

  Duration? _timeoutFor(Uri url) {
    final path = url.path;
    if (path.startsWith('/rest/v1')) return restTimeout;
    if (path.startsWith('/auth/v1')) return authTimeout;
    return null;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final timeout = _timeoutFor(request.url);
    if (timeout == null) return _inner.send(request);

    if (_isKnownOffline()) {
      throw OfflineShortCircuitException(request.url.path);
    }

    final pending = _inner.send(request);
    final http.StreamedResponse response;
    try {
      response = await pending.timeout(timeout);
    } on TimeoutException {
      // Si la respuesta llega tarde nadie la va a leer: se descarta para que
      // no retenga la conexión.
      unawaited(
        pending.then(
          (late) => late.stream.listen(null).cancel(),
          onError: (_) {},
        ),
      );
      _onTransportFailure();
      rethrow;
    } catch (e) {
      if (isTransportFailure(e)) _onTransportFailure();
      rethrow;
    }

    final body = response.stream.timeout(
      bodyIdleTimeout,
      onTimeout: (sink) {
        _onTransportFailure();
        sink.addError(
          TimeoutException(
            'La respuesta de ${request.url.path} dejó de llegar',
            bodyIdleTimeout,
          ),
        );
        sink.close();
      },
    );

    return http.StreamedResponse(
      body,
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  /// Errores que indican que la RED falló (no el servidor ni la consulta).
  /// Por texto y no por tipo porque `SocketException` no existe en web.
  static bool isTransportFailure(Object e) {
    if (e is TimeoutException) return true;
    final msg = e.toString().toLowerCase();
    return msg.contains('socketexception') ||
        msg.contains('clientexception') ||
        msg.contains('failed host lookup') ||
        msg.contains('connection refused') ||
        msg.contains('connection closed') ||
        msg.contains('connection reset') ||
        msg.contains('connection timed out') ||
        msg.contains('network is unreachable') ||
        msg.contains('no route to host') ||
        msg.contains('software caused connection abort');
  }

  @override
  void close() => _inner.close();
}
