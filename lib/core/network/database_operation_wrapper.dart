// lib/core/network/database_operation_wrapper.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'supabase_config.dart';

/// 🔄 Wrapper para operaciones de base de datos con reintentos automáticos
/// Maneja timeouts, errores recuperables y proporciona logging
class DatabaseOperationWrapper {
  /// Ejecutar operación con reintentos automáticos
  static Future<T> execute<T>({
    required Future<T> Function() operation,
    String operationName = 'Database Operation',
    Duration? timeout,
    int? maxRetries,
    bool enableRetry = true,
  }) async {
    final effectiveTimeout = timeout ?? SupabaseConfig.readTimeout;
    final effectiveMaxRetries = maxRetries ?? SupabaseConfig.maxRetries;

    int attempt = 0;
    Duration currentDelay = SupabaseConfig.initialRetryDelay;

    while (true) {
      attempt++;

      try {
        if (kDebugMode) {
          print(
            '[$operationName] Intento $attempt de ${effectiveMaxRetries + 1}',
          );
        }

        // Ejecutar operación con timeout
        final result = await operation().timeout(
          effectiveTimeout,
          onTimeout: () {
            throw TimeoutException(
              'La operación "$operationName" excedió el tiempo límite de ${effectiveTimeout.inSeconds}s',
            );
          },
        );

        if (kDebugMode && attempt > 1) {
          print('[$operationName] ✅ Exitoso después de $attempt intentos');
        }

        return result;
      } catch (error, stackTrace) {
        final isLastAttempt = attempt > effectiveMaxRetries;
        final isRecoverable = SupabaseConfig.isRecoverableError(error);

        if (kDebugMode) {
          print('[$operationName] ❌ Error en intento $attempt: $error');
          print('  - Recuperable: $isRecoverable');
          print('  - Último intento: $isLastAttempt');
        }

        // Si es el último intento o el error no es recuperable, lanzar error
        if (isLastAttempt || !isRecoverable || !enableRetry) {
          if (kDebugMode) {
            print('[$operationName] 🚫 Operación fallida definitivamente');
            print('Stack trace: $stackTrace');
          }

          // Lanzar con mensaje amigable
          throw DatabaseOperationException(
            message: SupabaseConfig.getFriendlyErrorMessage(error),
            originalError: error,
            operationName: operationName,
            attempts: attempt,
          );
        }

        // Esperar antes de reintentar (backoff exponencial)
        if (kDebugMode) {
          print(
            '[$operationName] ⏳ Reintentando en ${currentDelay.inMilliseconds}ms...',
          );
        }

        await Future.delayed(currentDelay);

        // Incrementar delay exponencialmente (con jitter)
        currentDelay = Duration(
          milliseconds:
              (currentDelay.inMilliseconds * 2) +
              (DateTime.now().millisecond % 100),
        );
      }
    }
  }

  /// Ejecutar operación de lectura (SELECT)
  static Future<T> read<T>({
    required Future<T> Function() operation,
    String operationName = 'Read Operation',
  }) {
    return execute(
      operation: operation,
      operationName: operationName,
      timeout: SupabaseConfig.readTimeout,
    );
  }

  /// Ejecutar operación de escritura (INSERT, UPDATE, DELETE)
  static Future<T> write<T>({
    required Future<T> Function() operation,
    String operationName = 'Write Operation',
  }) {
    return execute(
      operation: operation,
      operationName: operationName,
      timeout: SupabaseConfig.writeTimeout,
    );
  }

  /// Ejecutar llamada RPC
  static Future<T> rpc<T>({
    required Future<T> Function() operation,
    String operationName = 'RPC Call',
  }) {
    return execute(
      operation: operation,
      operationName: operationName,
      timeout: SupabaseConfig.rpcTimeout,
    );
  }

  /// Ejecutar múltiples operaciones en paralelo con manejo de errores
  static Future<List<T>> parallel<T>({
    required List<Future<T> Function()> operations,
    String operationName = 'Parallel Operations',
    bool failFast = false,
  }) async {
    if (failFast) {
      // Si una falla, todas fallan
      return Future.wait(
        operations.map(
          (op) => execute(operation: op, operationName: operationName),
        ),
      );
    } else {
      // Continuar aunque algunas fallen
      final results = await Future.wait(
        operations.map(
          (op) => execute(operation: op, operationName: operationName)
              .catchError((e) {
                // Re-lanzar el error para que sea manejado por el caller
                throw e;
              }),
        ),
        eagerError: false,
      );

      // Retornar todos los resultados exitosos
      return results;
    }
  }
}

/// Excepción personalizada para operaciones de base de datos
class DatabaseOperationException implements Exception {
  final String message;
  final dynamic originalError;
  final String operationName;
  final int attempts;

  DatabaseOperationException({
    required this.message,
    required this.originalError,
    required this.operationName,
    required this.attempts,
  });

  @override
  String toString() {
    return 'DatabaseOperationException: $message\n'
        'Operación: $operationName\n'
        'Intentos: $attempts\n'
        'Error original: $originalError';
  }
}
