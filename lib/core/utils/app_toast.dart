import 'package:flutter/material.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/utils/friendly_error.dart';
import 'package:mangopos/core/utils/logger.dart';

/// Toast/notificación estándar de MangoPOS.
///
/// Convención de la app: todo el feedback al usuario (éxito, error, aviso, info)
/// se muestra como toast flotante temático — nunca como banner inline estático
/// ni sin confirmación visible. Usar en cualquier feature:
///
/// ```dart
/// AppToast.success(context, 'Promoción creada');
/// AppToast.error(context, 'No se pudo guardar');
/// ```
///
/// Dos garantías para el usuario:
/// 1. **Nunca muestra texto técnico.** El mensaje pasa por [FriendlyError], así
///    que `'No se pudo imprimir: $e'` sale como `'No se pudo imprimir. Sin
///    conexión con el servidor…'`. El detalle crudo queda en el log.
/// 2. **Nunca se acumula.** Cada toast borra el anterior y se va solo; no hay
///    forma de encolar 5 avisos de 5 segundos.
class AppToast {
  const AppToast._();

  static const _errorRed = Color(0xFFEF4444);
  static const _warningAmber = Color(0xFFF59E0B);

  /// Tope de permanencia en pantalla. Un aviso más largo estorba y el usuario
  /// ya vio el resultado en la propia pantalla.
  static const Duration maxDuration = Duration(seconds: 5);
  static const Duration _defaultDuration = Duration(seconds: 3);
  static const Duration _errorDuration = Duration(seconds: 4);

  static void success(BuildContext context, String message) => _show(
    context,
    message,
    MangoColors.successGreen,
    Icons.check_circle_rounded,
  );

  static void error(BuildContext context, String message) => _show(
    context,
    message,
    _errorRed,
    Icons.error_rounded,
    duration: _errorDuration,
  );

  static void warning(BuildContext context, String message) =>
      _show(context, message, _warningAmber, Icons.warning_amber_rounded);

  static void info(BuildContext context, String message) =>
      _show(context, message, MangoColors.infoBlue, Icons.info_rounded);

  static void _show(
    BuildContext context,
    String message,
    Color accent,
    IconData icon, {
    Duration duration = _defaultDuration,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    // El detalle técnico se registra pero no se muestra.
    final friendly = FriendlyError.humanize(message);
    if (friendly != message) {
      AppLogger.w('Toast con detalle técnico oculto al usuario: $message');
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.white,
          elevation: 10,
          duration: duration > maxDuration ? maxDuration : duration,
          margin: const EdgeInsets.all(16),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          content: Row(
            children: [
              // Acento de color lateral.
              Container(
                width: 6,
                height: 46,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(14),
                    bottomLeft: Radius.circular(14),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: accent, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text(
                    friendly,
                    style: const TextStyle(
                      color: MangoColors.darkGray,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
        ),
      );
  }
}
