import 'package:flutter/material.dart';

/// Catálogo de razones de ajuste (Sprint Inventario V1.1, migración 0017).
///
/// El backend valida que el `reason_code` esté en este enum: si agregas o
/// quitas valores acá, sincroniza el CHECK constraint en la DB.
///
/// Vive fuera de las vistas porque lo consumen dos flujos distintos —
/// el cuadre de stock (`stock_reconciliation_view`) y el ajuste contextual
/// de Insumos (`item_adjust_dialog`)— y una copia privada por pantalla se
/// desincroniza del CHECK al primer cambio.
class AdjustReason {
  final String code;
  final String label;
  final String description;
  final IconData icon;

  /// `true` cuando el ajuste es una SALIDA de mercancía y no un cuadre.
  ///
  /// Decide si al guardar sale el conduce firmable ([WasteExitTicket]): una
  /// rotura, un vencido, lo que se bota al limpiar, un faltante o una donación
  /// son mercancía que se fue y alguien tiene que firmar por ella. Un conteo
  /// físico o una corrección de tecleo no son salidas: no hay nada que firmar.
  final bool isExit;

  /// `false` cuando el motivo solo existe como SALIDA relativa (Salidas /
  /// Mermas) y no se ofrece en el ajuste que fija la existencia a un número.
  /// Un consumo interno es «saqué 12 rollos», no «quedan 40».
  final bool adjustable;

  const AdjustReason(
    this.code,
    this.label,
    this.description,
    this.icon, {
    this.isExit = false,
    this.adjustable = true,
  });
}

const List<AdjustReason> kAdjustReasons = [
  AdjustReason(
    'physical_count',
    'Conteo físico',
    'Cuadrar con la realidad de la bodega',
    Icons.fact_check_rounded,
  ),
  // Gastables (20260930_0051): el papel higiénico que se entrega a los baños
  // no se perdió — se usó. Va primero porque es la salida más frecuente de un
  // gastable; en los reportes cuenta como CONSUMO, no como merma.
  AdjustReason(
    'internal_use',
    'Consumo interno',
    'Gastable entregado para usarse en el negocio',
    Icons.move_down_rounded,
    isExit: true,
    adjustable: false,
  ),
  AdjustReason(
    'breakage',
    'Rotura / dañado',
    'Producto roto o no apto para venta',
    Icons.broken_image_rounded,
    isExit: true,
  ),
  AdjustReason(
    'expiration',
    'Vencido',
    'Producto vencido o caducado',
    Icons.event_busy_rounded,
    isExit: true,
  ),
  AdjustReason(
    'cleaning',
    'Limpieza',
    'Se botó al limpiar la nevera o la línea',
    Icons.cleaning_services_rounded,
    isExit: true,
  ),
  AdjustReason(
    'theft',
    'Faltante / robo',
    'Faltante sospechoso o pérdida',
    Icons.no_accounts_rounded,
    isExit: true,
  ),
  AdjustReason(
    'donation',
    'Donación / cortesía',
    'Regalo, donación o cortesía',
    Icons.volunteer_activism_rounded,
    isExit: true,
  ),
  AdjustReason(
    'correction',
    'Corrección',
    'Corrección de error operativo',
    Icons.edit_note_rounded,
  ),
  AdjustReason(
    'other',
    'Otro',
    'Otro motivo (requiere notas)',
    Icons.more_horiz_rounded,
  ),
];

/// Código del consumo interno (gastables, 20260930_0051).
const kInternalUseReason = 'internal_use';

/// Razón por código. `null` si el código no está en el catálogo.
AdjustReason? adjustReasonByCode(String code) {
  for (final r in kAdjustReasons) {
    if (r.code == code) return r;
  }
  return null;
}
