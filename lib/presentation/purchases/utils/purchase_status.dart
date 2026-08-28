import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Etiqueta en español del estado de una orden de compra.
///
/// Vive acá porque el listado y el detalle de la factura tienen que nombrar
/// el mismo estado igual: dos tablas de traducción separadas se desincronizan
/// en cuanto se agrega un estado.
String purchaseStatusLabel(String status) {
  switch (status) {
    case 'draft':
      return 'Borrador';
    case 'sent':
      return 'Enviada';
    case 'partial':
      return 'Parcial';
    case 'received':
      return 'Recibida';
    case 'cancelled':
      return 'Cancelada';
    default:
      return status;
  }
}

/// Color con el que se pinta el estado. Recibida = cerrada y correcta,
/// parcial = falta mercancía, cancelada = fuera de juego.
Color purchaseStatusColor(String status) {
  switch (status) {
    case 'received':
      return AppColors.success;
    case 'partial':
      return AppColors.warning;
    case 'sent':
      return AppColors.info;
    case 'cancelled':
      return AppColors.destructive;
    default:
      return AppColors.mutedForeground;
  }
}
