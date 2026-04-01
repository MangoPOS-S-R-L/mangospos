import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'cookie_local_storage.dart';

/// 🔧 Configuración personalizada de Supabase
/// Incluye timeouts, reintentos y manejo de errores
class SupabaseConfig {
  static const List<String> _authRefreshSchemaMismatchSignatures = [
    'missing destination name oauth_client_id',
    'missing destination name scopes',
    'missing destination name refresh_token_hmac_key',
  ];

  static const List<String> _tlsCertificateErrorSignatures = [
    'handshakeexception',
    'certificate_verify_failed',
    'unable to get local issuer certificate',
    'certificateverifyfailed',
  ];

  /// Timeout para operaciones de lectura (SELECT)
  static const Duration readTimeout = Duration(seconds: 15);

  /// Timeout para operaciones de escritura (INSERT, UPDATE, DELETE)
  static const Duration writeTimeout = Duration(seconds: 20);

  /// Timeout para llamadas RPC
  static const Duration rpcTimeout = Duration(seconds: 25);

  /// Número máximo de reintentos para operaciones fallidas
  static const int maxRetries = 3;

  /// Delay inicial entre reintentos (se incrementa exponencialmente)
  static const Duration initialRetryDelay = Duration(milliseconds: 500);

  /// Configuración de headers personalizados
  static Map<String, String> get customHeaders => {
    'X-Client-Info': 'mangopos-flutter',
    'Prefer': 'return=representation',
  };

  /// Inicializar Supabase con configuración personalizada
  static Future<void> initialize({
    required String url,
    required String anonKey,
  }) async {
    // Limpiamos los parámetros por si vienen con comillas o backticks residuales del entorno
    String cleanUrl = url
        .replaceAll('`', '')
        .replaceAll('\'', '')
        .replaceAll('"', '')
        .trim();
    final cleanAnonKey = anonKey
        .replaceAll('`', '')
        .replaceAll('\'', '')
        .replaceAll('"', '')
        .trim();

    // Asegurarse de que el URL tenga scheme (https://)
    if (!cleanUrl.startsWith('http://') && !cleanUrl.startsWith('https://')) {
      cleanUrl = 'https://$cleanUrl';
    }

    await Supabase.initialize(
      url: cleanUrl,
      anonKey: cleanAnonKey,
      debug: kDebugMode || kIsWeb, // Enable debug
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
        autoRefreshToken: true,
        detectSessionInUri: true,
        localStorage: SharedCookieLocalStorage(),
      ),
      realtimeClientOptions: const RealtimeClientOptions(eventsPerSecond: 10),
      storageOptions: const StorageClientOptions(retryAttempts: 3),
    );
  }

  /// Verificar si el error es recuperable
  static bool isRecoverableError(dynamic error) {
    if (isAuthRefreshSchemaMismatchError(error)) {
      return false;
    }

    if (error is PostgrestException) {
      // Códigos de error recuperables
      final recoverableCodes = [
        '57014', // statement_timeout
        '08000', // connection_exception
        '08003', // connection_does_not_exist
        '08006', // connection_failure
        '08001', // sqlclient_unable_to_establish_sqlconnection
        '08004', // sqlserver_rejected_establishment_of_sqlconnection
        '40001', // serialization_failure
        '40P01', // deadlock_detected
        '53300', // too_many_connections
      ];

      return recoverableCodes.contains(error.code);
    }

    // Errores de red también son recuperables
    return error.toString().contains('SocketException') ||
        error.toString().contains('TimeoutException') ||
        error.toString().contains('HandshakeException');
  }

  static bool isAuthRefreshSchemaMismatchError(dynamic error) {
    final message = error.toString().toLowerCase();
    for (final signature in _authRefreshSchemaMismatchSignatures) {
      if (message.contains(signature)) {
        return true;
      }
    }
    return false;
  }

  static bool isTransientAuthRefreshError(dynamic error) {
    final message = error.toString();
    if (!message.contains('AuthRetryableFetchException')) {
      return false;
    }

    if (isAuthRefreshSchemaMismatchError(error)) {
      return false;
    }

    return message.contains('Bad Gateway') ||
        message.contains('statusCode: 500') ||
        message.contains('statusCode: 502');
  }

  static bool isTlsCertificateError(dynamic error) {
    final message = error.toString().toLowerCase();
    for (final signature in _tlsCertificateErrorSignatures) {
      if (message.contains(signature)) {
        return true;
      }
    }
    return false;
  }

  /// Obtener mensaje de error amigable
  static String getFriendlyErrorMessage(dynamic error) {
    if (isAuthRefreshSchemaMismatchError(error)) {
      return 'Tu sesion vencio y el servidor de autenticacion no pudo renovarla. Inicia sesion de nuevo.';
    }

    if (isTlsCertificateError(error)) {
      return 'No se pudo validar el certificado del servidor. Revisa la fecha y hora del equipo y actualiza Windows o el navegador.';
    }

    if (error is PostgrestException) {
      switch (error.code) {
        case '57014':
          return 'La operación tardó demasiado. Por favor, intenta de nuevo.';
        case '08000':
        case '08003':
        case '08006':
          return 'Error de conexión. Verifica tu conexión a internet.';
        case '23505':
          return 'Este registro ya existe.';
        case '23503':
          return 'No se puede eliminar porque está siendo usado.';
        case '42501':
          return 'No tienes permisos para realizar esta acción.';
        case '40001':
        case '40P01':
          return 'Conflicto de datos. Por favor, intenta de nuevo.';
        case '53300':
          return 'Demasiadas conexiones activas. Intenta más tarde.';
        default:
          return error.message;
      }
    }

    if (error.toString().contains('SocketException')) {
      return 'No se pudo conectar al servidor. Verifica tu conexión.';
    }

    if (error.toString().contains('TimeoutException')) {
      return 'La operación tardó demasiado. Por favor, intenta de nuevo.';
    }

    return 'Error inesperado: ${error.toString()}';
  }
}
