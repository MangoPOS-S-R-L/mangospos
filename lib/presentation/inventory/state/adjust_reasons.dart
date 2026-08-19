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

  const AdjustReason(this.code, this.label, this.description, this.icon);
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
  ),
  AdjustReason(
    'expiration',
    'Vencido',
    'Producto vencido o caducado',
    Icons.event_busy_rounded,
  ),
  AdjustReason(
    'theft',
    'Faltante / robo',
    'Faltante sospechoso o pérdida',
    Icons.no_accounts_rounded,
  ),
  AdjustReason(
    'donation',
    'Donación / cortesía',
    'Regalo, donación o cortesía',
    Icons.volunteer_activism_rounded,
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
