// lib/data/models/dining_table.dart
import 'package:flutter/foundation.dart';

/// Formas admitidas en BD: 'square' | 'circle'
enum TableShape { square, circle }

/// Estados en BD: 'available' | 'occupied' | 'reserved' | 'blocked'
enum TableState { available, occupied, reserved, blocked }

extension TableShapeX on TableShape {
  String get db => this == TableShape.circle ? 'circle' : 'square';

  static TableShape fromDb(String? v) {
    switch (v) {
      case 'circle':
        return TableShape.circle;
      case 'square':
      default:
        return TableShape.square;
    }
  }
}

extension TableStateX on TableState {
  String get db {
    switch (this) {
      case TableState.occupied:
        return 'occupied';
      case TableState.reserved:
        return 'reserved';
      case TableState.blocked:
        return 'blocked';
      case TableState.available:
      default:
        return 'available';
    }
  }

  static TableState fromDb(String? v) {
    switch (v) {
      case 'occupied':
        return TableState.occupied;
      case 'reserved':
        return TableState.reserved;
      case 'blocked':
        return TableState.blocked;
      case 'available':
      default:
        return TableState.available;
    }
  }
}

/// Modelo de mesa (coincide con la tabla `public.dining_tables`)
@immutable
class DiningTable {
  final String id;
  final String zoneId;
  final String code; // ej: T01, P05
  final String? label; // texto visible (opcional)
  final TableShape shape;
  final TableState state;
  final int capacity;

  // Datos para layout/editor (usados por el planner)
  final double posX;
  final double posY;
  final double width;
  final double height;
  final double rotation;
  final bool isActive;

  const DiningTable({
    required this.id,
    required this.zoneId,
    required this.code,
    this.label,
    required this.shape,
    required this.state,
    required this.capacity,
    required this.posX,
    required this.posY,
    required this.width,
    required this.height,
    required this.rotation,
    required this.isActive,
  });

  /// Conversión robusta desde mapa Supabase/Postgres.
  factory DiningTable.fromMap(Map<String, dynamic> j) {
    num asNum(Object? v, [num d = 0]) => (v is num) ? v : d;

    return DiningTable(
      id: (j['id'] ?? '') as String,
      zoneId: (j['zone_id'] ?? '') as String,
      code: (j['code'] ?? '') as String,
      label: j['label'] as String?,
      shape: TableShapeX.fromDb(j['shape'] as String?),
      state: TableStateX.fromDb(j['state'] as String?),
      capacity: asNum(j['capacity'], 4).toInt(),
      posX: asNum(j['pos_x']).toDouble(),
      posY: asNum(j['pos_y']).toDouble(),
      width: asNum(j['width'], 1).toDouble(),
      height: asNum(j['height'], 1).toDouble(),
      rotation: asNum(j['rotation']).toDouble(),
      isActive: (j['is_active'] ?? true) as bool,
    );
  }

  /// Mapa completo (útil para debug o mandar al cliente, NO para insert directo).
  Map<String, dynamic> toMap() => {
    'id': id,
    'zone_id': zoneId,
    'code': code,
    'label': label,
    'shape': shape.db,
    'state': state.db,
    'capacity': capacity,
    'pos_x': posX,
    'pos_y': posY,
    'width': width,
    'height': height,
    'rotation': rotation,
    'is_active': isActive,
  };

  /// Mapa mínimo para INSERT en `dining_tables`.
  /// No incluye `id` ni `is_active`; asume defaults/trigger en BD.
  Map<String, dynamic> toInsertMap() => {
    'zone_id': zoneId,
    'code': code,
    if (label != null) 'label': label,
    'shape': shape.db,
    'state': state.db,
    'capacity': capacity,
    'pos_x': posX,
    'pos_y': posY,
    'width': width,
    'height': height,
    'rotation': rotation,
  };

  /// Mapa para UPDATE (campos editables en el planner).
  Map<String, dynamic> toUpdateLayoutMap() => {
    'label': label,
    'shape': shape.db,
    'capacity': capacity,
    'pos_x': posX,
    'pos_y': posY,
    'width': width,
    'height': height,
    'rotation': rotation,
  };

  DiningTable copyWith({
    String? id,
    String? zoneId,
    String? code,
    String? label,
    TableShape? shape,
    TableState? state,
    int? capacity,
    double? posX,
    double? posY,
    double? width,
    double? height,
    double? rotation,
    bool? isActive,
  }) {
    return DiningTable(
      id: id ?? this.id,
      zoneId: zoneId ?? this.zoneId,
      code: code ?? this.code,
      label: label ?? this.label,
      shape: shape ?? this.shape,
      state: state ?? this.state,
      capacity: capacity ?? this.capacity,
      posX: posX ?? this.posX,
      posY: posY ?? this.posY,
      width: width ?? this.width,
      height: height ?? this.height,
      rotation: rotation ?? this.rotation,
      isActive: isActive ?? this.isActive,
    );
  }
}
