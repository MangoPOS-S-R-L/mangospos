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

  const AdjustReason(
    this.code,
    this.label,
    this.description,
    this.icon, {
    this.isExit = false,
  });
}

const List<AdjustReason> kAdjustReasons = [
  AdjustReason(
    'physical_count',
    'Conteo físico',
    'Cuadrar con la realidad de la bodega',
    Icons.fact_check_rounded,
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

/// Razón por código. `null` si el código no está en el catálogo.
AdjustReason? adjustReasonByCode(String code) {
  for (final r in kAdjustReasons) {
    if (r.code == code) return r;
  }
  return null;
}
