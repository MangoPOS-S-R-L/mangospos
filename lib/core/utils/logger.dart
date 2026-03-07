import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

/// Servicio global de Logging para la aplicación.
///
/// Uso básico:
/// ```dart
/// AppLogger.d('Mensaje de debug');
/// AppLogger.i('Información general');
/// AppLogger.w('Advertencia');
/// AppLogger.e('Error fatal', error: e, stackTrace: st);
/// ```
class AppLogger {
  static final Logger _logger = Logger(
    printer: PrettyPrinter(
      methodCount: 2, // Número de métodos en el stacktrace a mostrar
      errorMethodCount: 8, // Métodos a mostrar si se pasa un error
      lineLength: 80, // Ancho de las líneas separadoras
      colors: true, // Colorizado en terminal
      printEmojis: true, // Emojis por nivel (💡, ⚠️, ⛔, etc.)
      printTime: true, // Mostrar timestamp
    ),
    // En release mode (producción), no imprimimos nada para mejorar performance
    // a menos que se configure un output diferente (ej: Crashlytics)
    level: kDebugMode ? Level.debug : Level.warning,
  );

  /// Level.trace - Menos importante, logs muy granulares o paso a paso
  static void t(dynamic message, {Object? error, StackTrace? stackTrace}) {
    _logger.t(message, error: error, stackTrace: stackTrace);
  }

  /// Level.debug - Información útil para depuración (variables, estados)
  static void d(dynamic message, {Object? error, StackTrace? stackTrace}) {
    _logger.d(message, error: error, stackTrace: stackTrace);
  }

  /// Level.info - Eventos importantes del flujo (Login exitoso, BD conectada)
  static void i(dynamic message, {Object? error, StackTrace? stackTrace}) {
    _logger.i(message, error: error, stackTrace: stackTrace);
  }

  /// Level.warning - Algo salió mal pero la app puede recuperarse/continuar
  static void w(dynamic message, {Object? error, StackTrace? stackTrace}) {
    _logger.w(message, error: error, stackTrace: stackTrace);
  }

  /// Level.error - Error crítico, excepción atrapada, fallo en servicio
  static void e(dynamic message, {Object? error, StackTrace? stackTrace}) {
    _logger.e(message, error: error, stackTrace: stackTrace);
  }

  /// Level.fatal - Error del que la app o módulo no puede recuperarse
  static void f(dynamic message, {Object? error, StackTrace? stackTrace}) {
    _logger.f(message, error: error, stackTrace: stackTrace);
  }
}
