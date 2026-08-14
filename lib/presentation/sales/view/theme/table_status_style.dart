import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/app_time.dart';
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

/// Paleta de una card de mesa: los tres colores que definen el estado.
///
///  Estado      | Barra y texto | Fondo    | Borde
///  ------------|---------------|----------|-----------------------
///  Disponible  | #22C55E       | #F4FCF7  | rgba(34,197,94,.3)
///  Ocupado     | #F59E0B       | #FFFBF4  | rgba(245,158,11,.3)
///  Por Cobrar  | #3B82F6       | #F6FAFF  | rgba(59,130,246,.3)
///  Reservado   | #8B5CF6       | #FAF7FF  | rgba(139,92,246,.3)
class TableStatusPalette {
  /// Barra lateral de 6px y texto del estado.
  final Color accent;

  /// Relleno de la card.
  final Color surface;

  /// Borde de 1px (el accent al 30%).
  final Color border;

  const TableStatusPalette({
    required this.accent,
    required this.surface,
    required this.border,
  });
}

/// Paleta autoritativa por estado de mesa. La usan el grid ([TableCard]) y el
/// floor map ([ZoneFloorMap]) para que las dos representaciones no diverjan.
TableStatusPalette tableStatusPalette(ventas.TableStatus status) {
  switch (status) {
    case ventas.TableStatus.disponible:
      return TableStatusPalette(
        accent: AppColors.success, // verde
        surface: AppColors.successSurface,
        border: AppColors.success.withValues(alpha: 0.3),
      );
    case ventas.TableStatus.ocupado:
      return TableStatusPalette(
        accent: AppColors.warning, // ámbar
        surface: AppColors.warningSurface,
        border: AppColors.warning.withValues(alpha: 0.3),
      );
    case ventas.TableStatus.pagando:
      return TableStatusPalette(
        accent: AppColors.info, // azul
        surface: AppColors.infoSurface,
        border: AppColors.info.withValues(alpha: 0.3),
      );
    case ventas.TableStatus.reservado:
      return TableStatusPalette(
        accent: AppColors.reserved, // violeta
        surface: AppColors.reservedSurface,
        border: AppColors.reserved.withValues(alpha: 0.3),
      );
  }
}

/// Color autoritativo por estado de mesa (barra y texto). Atajo sobre
/// [tableStatusPalette] para los sitios que solo necesitan el acento.
Color tableStatusColor(ventas.TableStatus status) =>
    tableStatusPalette(status).accent;

/// Convierte el [TableStatus] crudo de `v_zone_table_status` en el
/// modelo de UI [ventas.VentasTable] que consumen las tarjetas y nodos
/// del mapa. Centraliza el cálculo de estado (disponible/ocupado/
/// pagando) y el formateo del tiempo abierto.
ventas.VentasTable ventasTableFromStatus(TableStatus ts) {
  final ventas.TableStatus status;
  if (isTableEffectivelyEmpty(ts)) {
    // Sin consumo: la mesa apartada se pinta RESERVADA (violeta); el resto
    // queda disponible. `dining_tables.state` es la única fuente de la
    // reserva — si la vista no trae la columna, cae en disponible.
    status = (ts.tableState ?? '').toLowerCase() == 'reserved'
        ? ventas.TableStatus.reservado
        : ventas.TableStatus.disponible;
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

  // La tarjeta muestra LA HORA a la que se abrió la mesa (08:15 p. m.), no
  // los minutos que lleva abierta. Si la fila no trae `opened_at` — overlay
  // offline, snapshot viejo — se reconstruye restando los minutos abiertos,
  // que da la misma hora de pared.
  DateTime? openedAt = ts.openedAt;
  if (openedAt == null && ts.minutesOpen != null && ts.minutesOpen! >= 0) {
    openedAt = AppTime.nowAst().subtract(Duration(minutes: ts.minutesOpen!));
  }
  final time = openedAt == null
      ? null
      : DateFormat('hh:mm a').format(openedAt);

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
