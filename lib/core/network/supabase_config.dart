// lib/core/network/supabase_config.dart
import 'package:supabase_flutter/supabase_flutter.dart';

/// 🔧 Configuración personalizada de Supabase
/// Incluye timeouts, reintentos y manejo de errores
class SupabaseConfig {
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
    await Supabase.initialize(
      url: url,
      anonKey: anonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
        // Mantener sesión activa
        autoRefreshToken: true,
      ),
      realtimeClientOptions: const RealtimeClientOptions(
        // Configuración de reconexión automática
        eventsPerSecond: 10,
      ),
      // Configuración de almacenamiento local
      storageOptions: const StorageClientOptions(retryAttempts: 3),
    );
  }

  /// Verificar si el error es recuperable
  static bool isRecoverableError(dynamic error) {
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

  /// Obtener mensaje de error amigable
  static String getFriendlyErrorMessage(dynamic error) {
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
