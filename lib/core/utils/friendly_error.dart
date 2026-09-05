// lib/core/utils/friendly_error.dart
import 'package:supabase_flutter/supabase_flutter.dart';

/// Traduce cualquier error tecnico a un mensaje que el usuario pueda entender.
///
/// Regla de la app: la UI NUNCA muestra texto crudo de excepciones (URLs,
/// `errno`, `SocketException`, stack traces, codigos SQL). Ese detalle vive en
/// los logs; en pantalla solo va la causa en español.
///
/// ```dart
/// AppToast.error(context, FriendlyError.from(e));      // desde un catch
/// AppToast.error(context, 'No se pudo imprimir: $e');  // AppToast lo limpia solo
/// ```
class FriendlyError {
  const FriendlyError._();

  // ---------------------------------------------------------------------------
  // Mensajes
  // ---------------------------------------------------------------------------
  static const String lanDevice =
      'No se pudo conectar con el equipo en la red. Revisa que esté encendido '
      'y en la misma red.';
  static const String connection =
      'Sin conexión con el servidor. Revisa tu conexión a internet.';
  static const String timeout =
      'El servidor tardó demasiado en responder. Intenta de nuevo.';
  /// Fallo de TLS por la ventana de validez del certificado: el reloj del
  /// equipo esta corrido. Es el UNICO caso donde tiene sentido mandar al
  /// usuario a la fecha y hora.
  static const String tlsClock =
      'La fecha y hora del equipo estan mal, por eso no se pudo validar el '
      'servidor. Actívalas en automático y vuelve a intentar.';

  /// Fallo de TLS por la cadena de confianza: al equipo le faltan certificados
  /// raíz, o alguien en el medio (portal cautivo, proxy, antivirus) está
  /// interceptando la conexión. Cambiar la hora aquí no resuelve nada.
  static const String tlsTrust =
      'No se pudo verificar la identidad del servidor. Revisa la red: un portal '
      'de wifi o un proxy puede estar interceptando la conexión.';

  /// TLS que se cae sin llegar a validar nada. Es red, no certificado.
  static const String tlsCertificate =
      'No se pudo establecer la conexión segura con el servidor. Revisa tu '
      'conexión e intenta de nuevo.';
  static const String badCredentials = 'Correo o contraseña incorrectos.';
  static const String emailNotConfirmed =
      'Tu correo aún no ha sido verificado.';
  static const String expiredSession =
      'Tu sesión venció. Inicia sesión de nuevo.';
  static const String noPermission = 'No tienes permisos para hacer esto.';
  static const String duplicated = 'Ese registro ya existe.';
  static const String inUse = 'No se puede eliminar porque está en uso.';
  static const String tooManyAttempts =
      'Demasiados intentos. Espera un momento e intenta de nuevo.';
  static const String serverUnavailable =
      'El servidor no está disponible en este momento. Intenta de nuevo.';
  static const String corruptedLocalData =
      'Se detectaron datos locales dañados. Cierra la app y vuelve a abrirla.';
  static const String unknown =
      'Ocurrió un error inesperado. Intenta de nuevo.';
  static const String retry = 'Intenta de nuevo.';

  /// Largo maximo del mensaje que llega a pantalla.
  static const int maxLength = 220;

  // ---------------------------------------------------------------------------
  // API publica
  // ---------------------------------------------------------------------------

  /// Convierte un error atrapado en un `catch` a mensaje para el usuario.
  static String from(Object? error) {
    if (error == null) return unknown;
    if (error is FormatException) return corruptedLocalData;

    if (error is PostgrestException) {
      final byCode = _byPostgrestCode(error.code);
      if (byCode != null) return byCode;
    }

    return _classify(error.toString());
  }

  /// Limpia un mensaje ya redactado que puede traer detalle tecnico pegado,
  /// tipico de `'No se pudo guardar: $e'`.
  ///
  /// Conserva la parte escrita a mano y reemplaza la cola tecnica por la causa
  /// en español. Si el mensaje no tiene nada tecnico, lo devuelve igual.
  static String humanize(String message) {
    final clean = _collapse(_stripExceptionPrefix(message));
    if (clean.isEmpty) return unknown;

    final cut = _firstTechnicalIndex(clean);
    if (cut == null) return _cap(clean);

    final prefix = _trimSeparators(clean.substring(0, cut));
    final cause = _classify(
      clean.substring(cut),
      fallback: prefix.isEmpty ? unknown : retry,
    );

    if (prefix.isEmpty || _isEmptyPrefix(prefix)) return _cap(cause);
    return _cap('${_trimSeparators(prefix)}. $cause');
  }

  /// `true` cuando el texto trae señales de ser tecnico (para no mostrarlo).
  static bool isTechnical(String text) =>
      _firstTechnicalIndex(_collapse(text)) != null;

  // ---------------------------------------------------------------------------
  // Interno
  // ---------------------------------------------------------------------------

  /// Firmas ordenadas: la primera que aparezca en el texto define el mensaje.
  static const List<(List<String>, String)> _signatures = [
    (
      [
        'missing destination name oauth_client_id',
        'missing destination name scopes',
        'missing destination name refresh_token_hmac_key',
      ],
      'Tu sesión venció y el servidor no pudo renovarla. Inicia sesión de nuevo.',
    ),
    (
      [
        'failed host lookup',
        'connection timed out',
        'socketexception',
        'clientexception',
        'connection refused',
        'connection closed',
        'connection reset',
        'network is unreachable',
        'no address associated',
        'failed to fetch',
        'xmlhttprequest error',
        'no route to host',
        'software caused connection abort',
        'errno = 11001',
        'errno = 7',
        'errno = 61',
        'errno = -2',
      ],
      connection,
    ),
    (
      [
        'timeoutexception',
        'timed out',
        'timeout',
        '57014',
        'deadline exceeded',
      ],
      timeout,
    ),
    (
      [
        'invalid login credentials',
        'invalid_credentials',
        'invalid email or password',
        'wrong password',
      ],
      badCredentials,
    ),
    (['email not confirmed', 'email_not_confirmed'], emailNotConfirmed),
    (
      [
        'jwt expired',
        'invalid refresh token',
        'refresh_token_not_found',
        'session_not_found',
        'invalid claim',
        'token is expired',
      ],
      expiredSession,
    ),
    (
      [
        'rate limit',
        'too many requests',
        'over_request_rate_limit',
        'for security purposes',
        'statuscode: 429',
      ],
      tooManyAttempts,
    ),
    (
      [
        'bad gateway',
        'service unavailable',
        'internal server error',
        'statuscode: 500',
        'statuscode: 502',
        'statuscode: 503',
        'statuscode: 504',
        'status code 500',
        'status code 502',
        'status code 503',
      ],
      serverUnavailable,
    ),
    (
      [
        'row-level security',
        'row level security',
        'permission denied',
        '42501',
        'not authorized',
        'unauthorized',
        'statuscode: 401',
        'statuscode: 403',
      ],
      noPermission,
    ),
    (
      ['duplicate key', '23505', 'already registered', 'already exists'],
      duplicated,
    ),
    (['23503', 'foreign key'], inUse),
    (['53300', 'too many connections'], serverUnavailable),
    (['40001', '40p01', 'deadlock'], 'Conflicto de datos. Intenta de nuevo.'),
  ];

  /// Marcas que delatan texto tecnico dentro de un mensaje. El corte cae en el
  /// inicio del token (`ClientException`, no `Exception`) para no partir la
  /// frase escrita a mano que va delante.
  static final RegExp _technicalPattern = RegExp(
    r'[A-Za-z_]{2,}(?:Exception|Error)\b'
    r'|\bException\b'
    r'|\bOS Error\b'
    r'|\buri\s*='
    r'|https?://'
    r'|\berrno\b'
    r'|\bstatus ?code\b'
    r'|\bsqlstate\b'
    r'|\bPGRST[0-9]*'
    r'|\bJWT\b'
    r'|#[0-9]+\s'
    r'|\bstack trace\b'
    r'|\bbad state\b'
    r'|\binvalid argument'
    r'|\bnull check operator\b'
    r'|\bassertion failed\b'
    r"|\btype '"
    r'|\bis not a subtype\b'
    r'|\bhint:|\bdetails:|\bcode:',
    caseSensitive: false,
  );

  static String? _byPostgrestCode(String? code) {
    switch (code) {
      case '57014':
        return timeout;
      case '08000':
      case '08001':
      case '08003':
      case '08004':
      case '08006':
        return connection;
      case '23505':
        return duplicated;
      case '23503':
        return inUse;
      case '42501':
        return noPermission;
      case '40001':
      case '40P01':
        return 'Conflicto de datos. Intenta de nuevo.';
      case '53300':
        return serverUnavailable;
      default:
        return null;
    }
  }

  /// Motivos de BoringSSL, tal como viajan dentro de la excepcion:
  /// `HandshakeException: Handshake error in client (OS Error:
  /// CERTIFICATE_VERIFY_FAILED: certificate has expired(handshake.cc:393))`.
  ///
  /// El reloj se revisa primero porque el mismo texto trae ademas el
  /// `CERTIFICATE_VERIFY_FAILED` generico, que si no caeria en confianza.
  static const List<String> _tlsClockNeedles = [
    'certificate has expired',
    'certificate is not yet valid',
    'certificate_expired',
    'cert_not_yet_valid',
  ];

  static const List<String> _tlsTrustNeedles = [
    'unable to get local issuer certificate',
    'self signed certificate',
    'self-signed certificate',
    'unable to verify the first certificate',
    'certificate_verify_failed',
    'certificateverifyfailed',
    'unknown ca',
    'hostname mismatch',
  ];

  static String? _classifyTls(String lower) {
    for (final needle in _tlsClockNeedles) {
      if (lower.contains(needle)) return tlsClock;
    }
    for (final needle in _tlsTrustNeedles) {
      if (lower.contains(needle)) return tlsTrust;
    }
    // Handshake que se cae sin llegar a validar el certificado: es red.
    if (lower.contains('handshakeexception') || lower.contains('tlsexception')) {
      return tlsCertificate;
    }
    return null;
  }

  static String _classify(String raw, {String fallback = unknown}) {
    final text = _collapse(_stripExceptionPrefix(raw));
    if (text.isEmpty) return fallback;

    final lower = text.toLowerCase();

    // TLS primero: el motivo exacto cambia por completo lo que el usuario debe
    // hacer (mover el reloj vs revisar la red), y la tabla de firmas no sirve
    // porque gana la que aparezca antes en el texto — y `HandshakeException`
    // siempre aparece al principio, tapando el motivo real que va al final.
    //
    // Se mira el texto SIN desenvolver: `_stripExceptionPrefix` se come el
    // `HandshakeException:` inicial, y sin el un handshake caido sin motivo de
    // certificado ("Connection terminated during handshake") no se reconocia
    // como TLS y terminaba saliendo en ingles crudo a pantalla.
    final tls = _classifyTls(_collapse(raw).toLowerCase());
    if (tls != null) return tls;

    // Socket contra un equipo con IP y puerto (impresora, agente local): el
    // problema es la red local, no "tu internet".
    if (lower.contains('port = ') || lower.contains('address = ')) {
      return lanDevice;
    }

    int? bestIndex;
    String? bestMessage;
    for (final (needles, message) in _signatures) {
      for (final needle in needles) {
        final index = lower.indexOf(needle);
        if (index >= 0 && (bestIndex == null || index < bestIndex)) {
          bestIndex = index;
          bestMessage = message;
        }
      }
    }
    if (bestMessage != null) return bestMessage;

    // Mensaje escrito a mano dentro de un `throw Exception('...')`: se respeta.
    if (_firstTechnicalIndex(text) == null && text.contains(' ')) {
      return _cap(_capitalize(text));
    }
    return fallback;
  }

  /// Quita envoltorios `Exception: ` / `Error: ` del inicio, repetidamente.
  static String _stripExceptionPrefix(String text) {
    var out = text.trim();
    final pattern = RegExp(r'^(_?[A-Za-z]*Exception|Error)\s*:\s*');
    for (var i = 0; i < 3; i++) {
      final match = pattern.firstMatch(out);
      if (match == null) break;
      final rest = out.substring(match.end).trim();
      // Solo se desenvuelve si queda algo legible detras.
      if (rest.isEmpty) break;
      out = rest;
    }
    return out;
  }

  static int? _firstTechnicalIndex(String text) =>
      _technicalPattern.firstMatch(text)?.start;

  static bool _isEmptyPrefix(String prefix) {
    final p = prefix
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-záéíóúñ ]'), '')
        .trim();
    return p.isEmpty || p == 'error' || p == 'errores' || p == 'detalle';
  }

  static String _trimSeparators(String text) => text
      .replaceAll(RegExp(r'^[\s:;,\-–—\(\[]+'), '')
      .replaceAll(RegExp(r'[\s:;,\.\-–—\(\[]+$'), '')
      .trim();

  /// Normaliza espacios y descarta bytes no imprimibles, para que un error con
  /// contenido binario no salga como cuadritos ilegibles en pantalla.
  static String _collapse(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      final printable =
          rune == 9 ||
          rune == 10 ||
          rune == 13 ||
          (rune >= 32 && rune != 0xFFFD);
      buffer.write(printable ? String.fromCharCode(rune) : ' ');
    }
    return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _capitalize(String text) =>
      text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';

  static String _cap(String text) => text.length <= maxLength
      ? text
      : '${text.substring(0, maxLength - 1).trimRight()}…';
}
