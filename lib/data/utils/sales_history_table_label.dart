/// Lo que va en la columna "Mesa" del Historial de ventas.
///
/// Prioridad: la mesa que trae la vista `sales_documents` (migración
/// 20260921_0001) → la etiqueta de la mesa resuelta por la app → su código.
/// Sin mesa (venta rápida, manual, delivery) se dice qué fue en vez de un
/// guion: "Venta rápida" responde la pregunta que un guion deja abierta.
String salesHistoryTableLabel({
  String? viewLabel,
  String? tableLabel,
  String? tableCode,
  String? origin,
}) {
  for (final candidate in [viewLabel, tableLabel, tableCode]) {
    final text = candidate?.trim() ?? '';
    if (text.isNotEmpty) return text;
  }
  return switch (origin?.trim()) {
    'quick' || 'quick_sale' => 'Venta rápida',
    'manual' => 'Venta manual',
    'delivery' => 'Delivery',
    'self_service' => 'Autoservicio',
    _ => '—',
  };
}
