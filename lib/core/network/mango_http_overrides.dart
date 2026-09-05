// lib/core/network/mango_http_overrides.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;

import '../utils/logger.dart';
import 'network_time.dart';

/// Politica TLS propia de la app, instalada como [HttpOverrides.global].
///
/// Resuelve las dos formas en que un POS se queda sin poder hablar con el
/// backend aunque el servidor este perfecto:
///
/// ### 1. El almacen de confianza del equipo esta incompleto
///
/// El certificado de `mangopos.do` ancla en **ISRG Root X1** (cadena nueva de
/// Let's Encrypt: `YE1 -> Root YE -> ISRG Root X2 -> ISRG Root X1`). Windows no
/// trae todas las raices preinstaladas: las baja de Windows Update **bajo
/// demanda**, y ese mecanismo lo dispara CryptoAPI, no Dart. Resultado tipico:
/// Edge abre el sitio sin problema y la app Flutter en el mismo equipo falla
/// con `CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate`.
///
/// Se corrige empacando las raices en `assets/certs/roots.pem` y sumandolas al
/// contexto. Es **aditivo** (`withTrustedRoots: true`): el almacen del sistema
/// se sigue consultando, asi que un proxy corporativo con su propia raiz
/// instalada sigue funcionando igual.
///
/// ### 2. El reloj del equipo esta corrido
///
/// TLS compara `notBefore`/`notAfter` contra `DateTime.now()`. Un equipo con la
/// fecha mal rechaza un certificado impecable por "todavia no es valido" (el
/// certificado se renueva cada ~90 dias, asi que basta con estar unos dias
/// atrasado). Empacar raices no arregla esto: la fecha se valida igual.
///
/// La salida es sacar el reloj local de la ecuacion. [_acceptOnlyClockFailure]
/// acepta el certificado unicamente cuando se cumple **todo** esto:
///
/// 1. es nuestro backend (host exacto, nada mas);
/// 2. hay hora real de la red ([NetworkTime], que viaja por HTTP plano y por lo
///    tanto no depende de TLS);
/// 3. el certificado **si** esta vigente medido contra esa hora real;
/// 4. el reloj del equipo **si** cae fuera de la ventana de validez.
///
/// El punto (4) es la garantia de seguridad: en un equipo con la hora correcta
/// el callback devuelve `false` siempre, y una cadena no confiable se sigue
/// rechazando exactamente como hoy. La relajacion solo se activa en un equipo
/// con el reloj demostrablemente roto, donde la alternativa no era "TLS
/// estricto" sino "la app no abre".
class MangoHttpOverrides extends HttpOverrides {
  MangoHttpOverrides._(this._context, this._backendOrigin, this._backendHost);

  static const String _rootsAsset = 'assets/certs/roots.pem';

  final SecurityContext? _context;
  final String _backendOrigin;
  final String _backendHost;

  /// Evita disparar varios sondeos de hora en paralelo cuando llueven fallos.
  static bool _resyncInFlight = false;

  /// `true` si en algun momento se acepto un certificado saltando el reloj.
  /// La UI lo usa para avisar que la fecha del equipo esta mal.
  static bool clockBypassUsed = false;

  /// Instala la politica. Best-effort: si algo falla, la app arranca con el
  /// comportamiento de siempre en vez de no arrancar.
  static Future<void> install({required String backendOrigin}) async {
    if (kIsWeb) return; // el navegador maneja TLS por su cuenta

    final host = _hostOf(backendOrigin);
    if (host == null) {
      AppLogger.w('[TLS] Origin del backend ilegible: $backendOrigin');
      return;
    }

    final context = await _buildContext();
    HttpOverrides.global = MangoHttpOverrides._(context, backendOrigin, host);
    AppLogger.i(
      '[TLS] Politica instalada para $host '
      '(raices propias: ${context != null ? "si" : "no"})',
    );
  }

  /// Contexto con las raices del sistema **mas** las empacadas.
  static Future<SecurityContext?> _buildContext() async {
    try {
      final pem = await rootBundle.load(_rootsAsset);
      final context = SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificatesBytes(pem.buffer.asUint8List());
      return context;
    } catch (e) {
      // Sin las raices empacadas se sigue con las del sistema. Peor, pero no
      // peor que antes de este archivo.
      AppLogger.w('[TLS] No se pudieron cargar las raices empacadas: $e');
      return null;
    }
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context ?? _context);
    client.badCertificateCallback = _acceptOnlyClockFailure;
    return client;
  }

  bool _acceptOnlyClockFailure(X509Certificate cert, String host, int port) {
    // (1) Solo nuestro backend. Cualquier otro host se rechaza igual que antes.
    if (host.toLowerCase() != _backendHost) return false;

    // (2) Sin hora de red no hay con que comparar: no se asume nada.
    final networkNow = NetworkTime.instantOrNull();
    if (networkNow == null) {
      // Caso tipico de POS: la app arranco antes de que el wifi levantara, el
      // sondeo del arranque fallo y sin el la tolerancia al reloj nunca puede
      // activarse. Se vuelve a sondear en segundo plano para que el proximo
      // intento (el reintento de Supabase, o el usuario tocando de nuevo) ya
      // tenga con que comparar. Este callback es sincrono, asi que no se puede
      // esperar aqui.
      _scheduleResync();
      return false;
    }

    final start = cert.startValidity.toUtc();
    final end = cert.endValidity.toUtc();

    // (3) Contra la hora real el certificado tiene que estar vigente. Uno
    //     vencido de verdad se rechaza.
    if (!networkNow.isAfter(start) || !networkNow.isBefore(end)) return false;

    // (4) Y el reloj del equipo tiene que ser el que se sale de la ventana. Si
    //     la hora local esta bien, el fallo era otro (cadena rota, MITM) y no
    //     se perdona.
    final deviceNow = DateTime.now().toUtc();
    final deviceOutOfWindow =
        deviceNow.isBefore(start) || deviceNow.isAfter(end);
    if (!deviceOutOfWindow) return false;

    if (!clockBypassUsed) {
      clockBypassUsed = true;
      AppLogger.w(
        '[TLS] Certificado de $host aceptado ignorando el reloj del equipo. '
        'Desfase medido: ${_describe(NetworkTime.skew)}. '
        'El certificado esta vigente ($start -> $end) segun la hora de red. '
        'CORREGIR LA FECHA DEL EQUIPO: las ventas se estan guardando con fecha '
        'equivocada.',
      );
    }
    return true;
  }

  /// Reintenta el sondeo de hora sin bloquear a quien nos llamo.
  void _scheduleResync() {
    if (_resyncInFlight || NetworkTime.isSynced) return;
    _resyncInFlight = true;
    unawaited(
      NetworkTime.sync(_backendOrigin)
          .catchError((_) => false)
          .whenComplete(() => _resyncInFlight = false),
    );
  }

  static String _describe(Duration? skew) {
    if (skew == null) return 'desconocido';
    final abs = skew.abs();
    final sentido = skew.isNegative ? 'atrasado' : 'adelantado';
    if (abs.inDays > 0) return '$sentido ${abs.inDays} dia(s)';
    if (abs.inHours > 0) return '$sentido ${abs.inHours} hora(s)';
    return '$sentido ${abs.inMinutes} minuto(s)';
  }

  static String? _hostOf(String origin) {
    var raw = origin.trim();
    if (raw.isEmpty) return null;
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      raw = 'https://$raw';
    }
    final host = Uri.tryParse(raw)?.host;
    return (host == null || host.isEmpty) ? null : host.toLowerCase();
  }

  /// Solo para tests.
  static MangoHttpOverrides debugFor(String backendHost) => MangoHttpOverrides._(
    null,
    'https://$backendHost',
    backendHost.toLowerCase(),
  );

  /// Solo para tests: ejercita la politica sin montar un servidor TLS.
  bool debugEvaluate(X509Certificate cert, String host, int port) =>
      _acceptOnlyClockFailure(cert, host, port);
}
