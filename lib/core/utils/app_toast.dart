import 'package:flutter/material.dart';
import 'package:mangopos/app/theme/mango_colors.dart';

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
class AppToast {
  const AppToast._();

  static const _errorRed = Color(0xFFEF4444);
  static const _warningAmber = Color(0xFFF59E0B);

  static void success(BuildContext context, String message) =>
      _show(context, message, MangoColors.successGreen,
          Icons.check_circle_rounded);

  static void error(BuildContext context, String message) =>
      _show(context, message, _errorRed, Icons.error_rounded);

  static void warning(BuildContext context, String message) =>
      _show(context, message, _warningAmber, Icons.warning_amber_rounded);

  static void info(BuildContext context, String message) =>
      _show(context, message, MangoColors.infoBlue, Icons.info_rounded);

  static void _show(
    BuildContext context,
    String message,
    Color accent,
    IconData icon,
  ) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.white,
          elevation: 10,
          duration: const Duration(seconds: 3),
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
                    message,
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
