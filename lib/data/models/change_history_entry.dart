// Una línea del historial de cambios (tabla `change_history`, migraciones
// 20261013_0001 y 20261013_0002). La llenan triggers en la base de datos;
// la app solo la lee.

import 'package:mangopos/core/utils/app_time.dart';

class ChangeHistoryEntry {
  final int id;

  /// Tabla de origen: menu_items, taxes, order_items, cash_transactions…
  final String tableName;
  final String rowId;

  /// create | update | delete | void
  final String action;

  /// Lo que cambió, legible: «Pollo frito», «Mesa 5», «Caja 1».
  final String label;

  /// Lo segundo: «ITBIS 18%», el motivo de caja, la mesa destino…
  final String context;

  /// Nombre de quien lo hizo, tal como era al momento del cambio.
  final String actorName;

  /// Hora de negocio (AST), como el resto de la app.
  final DateTime changedAt;

  /// update: {campo: [antes, después]} · create/delete/void: la fila.
  /// Las acciones de operación traen `event` (cash_deposit, discount…).
  final Map<String, dynamic> changes;

  /// request.path de PostgREST ('/menu_items', '/rpc/fn_x'); null = interno.
  final String? source;

  const ChangeHistoryEntry({
    required this.id,
    required this.tableName,
    required this.rowId,
    required this.action,
    required this.label,
    required this.context,
    required this.actorName,
    required this.changedAt,
    required this.changes,
    this.source,
  });

  factory ChangeHistoryEntry.fromJson(Map<String, dynamic> json) {
    final raw = json['changes'];
    return ChangeHistoryEntry(
      id: (json['id'] as num).toInt(),
      tableName: json['table_name']?.toString() ?? '',
      rowId: json['row_id']?.toString() ?? '',
      action: json['action']?.toString() ?? 'update',
      label: json['label']?.toString() ?? '',
      context: json['context']?.toString() ?? '',
      actorName: json['actor_name']?.toString() ?? '',
      changedAt:
          AppTime.tryParseServerToAst(json['changed_at']) ?? AppTime.nowAst(),
      changes: raw is Map ? Map<String, dynamic>.from(raw) : const {},
      source: json['source']?.toString(),
    );
  }
}
