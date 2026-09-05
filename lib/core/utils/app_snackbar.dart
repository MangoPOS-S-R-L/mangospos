// lib/core/utils/app_snackbar.dart
import 'package:flutter/material.dart';

import 'friendly_error.dart';
import 'logger.dart';

/// Reemplazo directo de `showSnackBar` para las pantallas que arman su propio
/// [SnackBar] (con acción, color o contenido a medida) y por eso no pueden usar
/// `AppToast`.
///
/// Aplica las dos reglas de la app sin tocar el diseño del aviso:
/// 1. **Reemplaza, no encola.** Borra el aviso anterior, así cinco errores
///    seguidos muestran uno solo y no cinco turnos de espera.
/// 2. **Se va solo y sin texto técnico.** Recorta la duración a [maxDuration] y
///    pasa el texto por [FriendlyError] cuando el contenido es un [Text].
///
/// ```dart
/// ScaffoldMessenger.of(context).showAppSnackBar(
///   SnackBar(content: Text('No se pudo transferir: $e')),
/// );
/// ```
extension AppSnackBarMessenger on ScaffoldMessengerState {
  /// Duración máxima en pantalla, igual que en `AppToast`.
  static const Duration maxDuration = Duration(seconds: 5);

  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showAppSnackBar(
    SnackBar snackBar,
  ) {
    clearSnackBars();
    return showSnackBar(_normalizeSnackBar(snackBar));
  }
}

/// Devuelve el mismo aviso con duración acotada y texto ya humanizado.
SnackBar _normalizeSnackBar(SnackBar snackBar) {
  final duration = snackBar.duration > AppSnackBarMessenger.maxDuration
      ? AppSnackBarMessenger.maxDuration
      : snackBar.duration;
  final content = _humanizeContent(snackBar.content);

  if (identical(content, snackBar.content) && duration == snackBar.duration) {
    return snackBar;
  }

  return SnackBar(
    key: snackBar.key,
    content: content,
    backgroundColor: snackBar.backgroundColor,
    elevation: snackBar.elevation,
    margin: snackBar.margin,
    padding: snackBar.padding,
    width: snackBar.width,
    shape: snackBar.shape,
    behavior: snackBar.behavior,
    action: snackBar.action,
    actionOverflowThreshold: snackBar.actionOverflowThreshold,
    showCloseIcon: snackBar.showCloseIcon,
    closeIconColor: snackBar.closeIconColor,
    duration: duration,
    onVisible: snackBar.onVisible,
    dismissDirection: snackBar.dismissDirection,
    clipBehavior: snackBar.clipBehavior,
  );
}

/// Solo se toca el caso simple `Text('...')`; un contenido compuesto (fila con
/// spinner, íconos) se respeta tal cual porque lo redactó la pantalla.
Widget _humanizeContent(Widget content) {
  if (content is! Text) return content;
  final data = content.data;
  if (data == null || data.isEmpty) return content;

  final friendly = FriendlyError.humanize(data);
  if (friendly == data) return content;

  AppLogger.w('SnackBar con detalle técnico oculto al usuario: $data');
  return Text(
    friendly,
    style: content.style,
    textAlign: content.textAlign,
    maxLines: content.maxLines,
    overflow: content.overflow,
    softWrap: content.softWrap,
    semanticsLabel: content.semanticsLabel,
  );
}
