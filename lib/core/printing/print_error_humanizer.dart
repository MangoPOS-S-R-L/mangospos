// =============================================================================
// Print error humanizer
//
// Convierte errores técnicos de impresión (SocketException, TimeoutException,
// ECONNREFUSED, OS Error) en mensajes en español accionables para el cajero.
//
// No es un i18n completo — es una capa de mapeo defensivo para que el cajero
// vea "La impresora 'Cocina' no responde" en vez de
// "Exception: SocketException: Connection refused (OS Error: Connection
// refused, errno = 61), address = 192.168.1.105, port = 9100".
//
// Uso:
//   final friendly = humanizePrintError(error, printerName: 'Cocina');
//   showDialog(content: friendly.message, action: friendly.hint);
//
// Cuando aparezca una variante de error nueva no cubierta, cae a un
// fallback genérico amable y se loggea para revisión.
// =============================================================================

/// Mensaje amigable derivado de un error de impresión.
class FriendlyPrintError {
  const FriendlyPrintError({
    required this.title,
    required this.message,
    this.hint,
  });

  /// Título corto (snackbar header / dialog title). Ej. "Impresora sin
  /// conexión", "Tiempo de espera agotado".
  final String title;

  /// Frase principal con contexto: qué pasó y qué se afectó. Ej.
  /// "La impresora 'Cocina' no responde. Tu venta sí quedó registrada."
  final String message;

  /// Acción sugerida concreta para el cajero. Ej. "Revisa que esté
  /// encendida y conectada al WiFi." Puede ser null si no hay acción
  /// clara que recomendar.
  final String? hint;
}

/// Convierte un error en una versión amigable. `printerName` es opcional
/// — si se conoce, los mensajes lo incluyen entre comillas para que el
/// cajero sepa cuál de varias impresoras es la afectada.
FriendlyPrintError humanizePrintError(
  Object error, {
  String? printerName,
}) {
  final raw = error.toString();
  final lower = raw.toLowerCase();
  // Recortamos "Exception:" del inicio porque es ruido visual.
  final namePart = printerName == null || printerName.trim().isEmpty
      ? ''
      : ' «${printerName.trim()}»';

  // ── No hay impresora configurada ────────────────────────────────────
  if (lower.contains('no hay impresora') ||
      lower.contains('no asignada') ||
      lower.contains('no configurada')) {
    return FriendlyPrintError(
      title: 'Sin impresora configurada',
      message:
          'No hay una impresora asignada para este tipo de comprobante. '
          'La venta se guardó pero no se imprimió el ticket.',
      hint: 'Ve a Ajustes → Impresión y asigna una impresora.',
    );
  }

  // ── Connection refused (impresora apagada / IP correcta pero puerto cerrado) ──
  if (lower.contains('connection refused') ||
      lower.contains('econnrefused') ||
      lower.contains('errno = 61') ||
      lower.contains('errno = 111')) {
    return FriendlyPrintError(
      title: 'Impresora no responde',
      message:
          'La impresora$namePart está conectada a la red pero rechaza '
          'la conexión. Tu venta sí quedó registrada.',
      hint:
          'Apaga la impresora 10 segundos y vuelve a encenderla. '
          'Si persiste, revisa el cable de red.',
    );
  }

  // ── Timeout ────────────────────────────────────────────────────────
  if (lower.contains('timeout') ||
      lower.contains('timed out') ||
      lower.contains('tiempo agotado') ||
      lower.contains('etimedout')) {
    return FriendlyPrintError(
      title: 'Tiempo de espera agotado',
      message:
          'La impresora$namePart no respondió a tiempo. Puede estar '
          'apagada, ocupada o con problemas de red. Tu venta sí quedó '
          'registrada.',
      hint:
          'Verifica que esté encendida y con papel. Reintenta en unos '
          'segundos.',
    );
  }

  // ── Host unreachable / network down ────────────────────────────────
  if (lower.contains('host is unreachable') ||
      lower.contains('no route to host') ||
      lower.contains('network is unreachable') ||
      lower.contains('failed host lookup') ||
      lower.contains('socketexception')) {
    return FriendlyPrintError(
      title: 'Sin conexión a la impresora',
      message:
          'No se pudo alcanzar la impresora$namePart en la red. Tu '
          'venta sí quedó registrada.',
      hint:
          'Verifica que el tablet y la impresora estén conectados al '
          'mismo WiFi.',
    );
  }

  // ── Agente local caído ─────────────────────────────────────────────
  if (lower.contains('agent') &&
      (lower.contains('offline') ||
          lower.contains('not available') ||
          lower.contains('caído') ||
          lower.contains('no responde'))) {
    return FriendlyPrintError(
      title: 'Agente de impresión sin conexión',
      message:
          'El agente local que conecta con la impresora$namePart no '
          'responde. Tu venta sí quedó registrada.',
      hint:
          'Verifica que el equipo donde corre el agente esté '
          'encendido y conectado al mismo WiFi.',
    );
  }

  // ── Cola en la nube (escalada) ─────────────────────────────────────
  if (lower.contains('cloud queue') ||
      lower.contains('encolado') ||
      lower.contains('queued')) {
    return FriendlyPrintError(
      title: 'Impresión en cola',
      message:
          'No pudimos imprimir ahora mismo, pero el trabajo quedó '
          'encolado y se intentará automáticamente cuando la '
          'impresora$namePart vuelva.',
      hint: 'Tu venta ya está registrada — no es necesario reintentar.',
    );
  }

  // ── Permisos / RLS ─────────────────────────────────────────────────
  if (lower.contains('permission denied') ||
      lower.contains('no tienes permiso')) {
    return FriendlyPrintError(
      title: 'Sin permiso',
      message:
          'Tu usuario no tiene permiso para esta operación de '
          'impresión.',
      hint: 'Pide al administrador que ajuste tu rol.',
    );
  }

  // ── Papel / hardware (raro pero posible si el driver lo reporta) ──
  if (lower.contains('paper') ||
      lower.contains('papel') ||
      lower.contains('cover') ||
      lower.contains('tapa')) {
    return FriendlyPrintError(
      title: 'Problema con la impresora',
      message:
          'La impresora$namePart reportó un problema mecánico (papel '
          'o tapa). Tu venta sí quedó registrada.',
      hint: 'Revisa que tenga papel y que la tapa esté cerrada.',
    );
  }

  // ── Fallback genérico ──────────────────────────────────────────────
  return FriendlyPrintError(
    title: 'No se pudo imprimir',
    message:
        'Tu venta sí quedó registrada, pero no fue posible enviar el '
        'ticket a la impresora$namePart.',
    hint:
        'Verifica que la impresora esté encendida y conectada. Si '
        'sigue fallando, puedes reimprimir desde el historial de '
        'ventas más tarde.',
  );
}
