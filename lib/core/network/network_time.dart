// lib/core/network/network_time.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

/// Hora real tomada de la red, independiente del reloj del equipo.
///
/// ## Por que existe
///
/// Un POS con la fecha corrida (tablet que se quedo sin bateria, RTC muerto,
/// Windows sin servicio de hora) rompe TLS antes de que la app alcance a
/// mostrar nada: BoringSSL compara `notBefore`/`notAfter` del certificado
/// contra `DateTime.now()`, y si el equipo cree que estamos en 2019 el
/// certificado "todavia no es valido". Ningun almacen de confianza arregla eso.
///
/// La salida es no preguntarle la hora al equipo. Este modulo la pide por
/// **HTTP plano** (puerto 80, sin TLS, o sea sin validacion de fechas) y lee el
/// header `Date` que todo servidor HTTP obliga a mandar. Con eso:
///
/// * [MangoHttpOverrides] puede aceptar un certificado que solo falla porque el
///   reloj local esta mal, verificando que SI este vigente contra la hora real.
/// * La app puede avisar el desfase exacto en vez de un "revisa la fecha".
///
/// ## Precision
///
/// El header `Date` tiene resolucion de 1 segundo y no compensa latencia. Sirve
/// para decidir si el equipo esta corrido por dias u horas, que es el caso real;
/// no sirve como fuente de hora contable.
///
/// El desfase se guarda junto a un [Stopwatch], que es monotonico y por lo tanto
/// inmune a que alguien mueva el reloj del sistema despues del sondeo.
class NetworkTime {
  const NetworkTime._();

  /// Desfase que se considera ruido y no amerita tratarse como reloj roto.
  static const Duration tolerance = Duration(minutes: 5);

  static const Duration _probeTimeout = Duration(seconds: 6);

  static DateTime? _serverInstantAtSync;
  static Duration? _skewAtSync;
  static Stopwatch? _since;

  /// `true` cuando ya se pudo leer la hora de la red al menos una vez.
  static bool get isSynced => _serverInstantAtSync != null;

  /// Cuanto se desvia el reloj del equipo respecto de la red.
  ///
  /// Positivo = el equipo esta **adelantado**. Negativo = **atrasado**.
  /// `null` mientras no haya sondeo exitoso.
  static Duration? get skew => _skewAtSync;

  /// `true` si el reloj del equipo esta fuera de [tolerance].
  static bool get isDeviceClockWrong {
    final s = skew;
    return s != null && s.abs() > tolerance;
  }

  /// Instante UTC real, o `null` si todavia no hay hora de red confiable.
  ///
  /// Nunca cae de vuelta en `DateTime.now()`: quien llama necesita saber que no
  /// hay dato, porque el punto entero es no confiar en el reloj local.
  static DateTime? instantOrNull() {
    final anchor = _serverInstantAtSync;
    final since = _since;
    if (anchor == null || since == null) return null;
    // Se avanza con el cronometro monotonico, no con `DateTime.now()`: si
    // alguien corrige (o descuadra) el reloj despues del sondeo, esta hora
    // sigue siendo la buena.
    return anchor.add(since.elapsed);
  }

  /// Sondea la hora de la red. Best-effort: nunca lanza.
  ///
  /// [origin] es el backend en https; se degrada a `http://` a proposito para
  /// que el sondeo funcione justamente cuando TLS esta fallando.
  static Future<bool> sync(String origin) async {
    if (kIsWeb) return false;

    final probe = _plainHttpProbe(origin);
    if (probe == null) return false;

    HttpClient? client;
    try {
      // Cliente propio y crudo: sin overrides, sin redirecciones. El 307 a
      // https ya trae el header `Date`, que es lo unico que se necesita.
      client = HttpClient()..connectionTimeout = _probeTimeout;

      final request = await client.headUrl(probe).timeout(_probeTimeout);
      // El 307 a https ya trae el header `Date`; seguir el redirect solo
      // volveria a meter TLS en el camino, que es lo que se esta evitando.
      request.followRedirects = false;
      final response = await request.close().timeout(_probeTimeout);
      await response.drain<void>();

      final raw = response.headers.value(HttpHeaders.dateHeader);
      if (raw == null) return false;

      final serverNow = HttpDate.parse(raw).toUtc();
      _serverInstantAtSync = serverNow;
      _skewAtSync = DateTime.now().toUtc().difference(serverNow);
      _since = Stopwatch()..start();
      return true;
    } catch (_) {
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  /// Deriva el sondeo en claro a partir del origin del backend.
  static Uri? _plainHttpProbe(String origin) {
    var raw = origin.trim();
    if (raw.isEmpty) return null;
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      raw = 'https://$raw';
    }
    final parsed = Uri.tryParse(raw);
    if (parsed == null || parsed.host.isEmpty) return null;
    return Uri(scheme: 'http', host: parsed.host, path: '/');
  }

  /// Solo para tests: finge un sondeo con el desfase dado.
  ///
  /// [skew] positivo = el equipo esta adelantado respecto de la red.
  /// `null` devuelve el estado a "sin hora de red".
  static void debugSetSkew(Duration? skew) {
    if (skew == null) {
      _serverInstantAtSync = null;
      _skewAtSync = null;
      _since = null;
      return;
    }
    _serverInstantAtSync = DateTime.now().toUtc().subtract(skew);
    _skewAtSync = skew;
    _since = Stopwatch()..start();
  }
}
