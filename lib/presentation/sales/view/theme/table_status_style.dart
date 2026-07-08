import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../data/models/table_status.dart';
import '../../../../domain/models/ventas_table.dart' as ventas;

/// Fuente única de verdad para el estilo y la semántica del estado de
/// una mesa. La usan TANTO el grid ([TableCard]) como el floor map
/// ([ZoneFloorMap]) para que su representación nunca diverja: mismo
/// color, mismo criterio de "ocupada fantasma", misma conversión a
/// [ventas.VentasTable].

/// Una mesa con sesión abierta pero sin orders ni items abiertos está
/// "ocupada fantasma" — el cajero la abrió, no agregó productos y se
/// salió. La consideramos disponible visualmente; el sweep del viewmodel
/// cierra la sesión huérfana en background.
bool isTableEffectivelyEmpty(TableStatus ts) {
  return ts.sessionId == null || (ts.itemsCount == 0 && ts.ordersCount == 0);
}

/// Color autoritativo por estado de mesa (misma paleta que el grid):
/// verde = disponible, naranja = ocupada, azul = pre-cuenta/pagando.
Color tableStatusColor(ventas.TableStatus status) {
  switch (status) {
    case ventas.TableStatus.disponible:
      return AppColors.success; // verde
    case ventas.TableStatus.ocupado:
      return AppColors.warning; // naranja
    case ventas.TableStatus.pagando:
      return AppColors.info; // azul
  }
}

/// Convierte el [TableStatus] crudo de `v_zone_table_status` en el
/// modelo de UI [ventas.VentasTable] que consumen las tarjetas y nodos
/// del mapa. Centraliza el cálculo de estado (disponible/ocupado/
/// pagando) y el formateo del tiempo abierto.
ventas.VentasTable ventasTableFromStatus(TableStatus ts) {
  final ventas.TableStatus status;
  if (isTableEffectivelyEmpty(ts)) {
    status = ventas.TableStatus.disponible;
  } else {
    final statusRaw = (ts.status ?? '').toLowerCase();
    if (statusRaw == 'paying' ||
        statusRaw == 'checkout' ||
        statusRaw == 'payment') {
      status = ventas.TableStatus.pagando;
    } else {
      status = ventas.TableStatus.ocupado;
    }
  }

  String? time;
  if (ts.minutesOpen != null && ts.minutesOpen! > 0) {
    final hours = ts.minutesOpen! ~/ 60;
    final mins = ts.minutesOpen! % 60;
    time =
        '${hours.toString().padLeft(2, '0')}:${mins.toString().padLeft(2, '0')}';
  }

  return ventas.VentasTable(
    id: ts.tableId,
    code: ts.code,
    status: status,
    zone: ts.zoneId,
    guests: ts.peopleCount > 0 ? ts.peopleCount : null,
    time: time,
    total: ts.total > 0 ? ts.total : null,
    waiterId: ts.sessionId, // sessionId usado como waiterId temporalmente
    waiterName: ts.waiterName,
    customerName: ts.customerName,
    isPendingSync: ts.isPendingSync,
  );
}
