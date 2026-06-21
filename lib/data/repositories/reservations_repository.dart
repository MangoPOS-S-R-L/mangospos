import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/repositories/i_reservations_repository.dart';
import '../datasources/queries/reservations_queries.dart';
import '../models/reservation.dart';

/// Excepción de dominio con un `code` estable que la UI traduce a un mensaje
/// amigable. Los códigos vienen de los `raise exception` en los RPCs.
class ReservationException implements Exception {
  final String code;
  ReservationException(this.code);

  /// Mensaje listo para mostrar al usuario (español, sin voseo).
  String get message {
    switch (code) {
      case 'TABLE_ALREADY_RESERVED':
        return 'Esa mesa ya tiene una reserva en ese horario. Elige otra hora o mesa.';
      case 'MODULE_NOT_ENABLED':
        return 'El módulo de Reservas no está activo para este negocio.';
      case 'NO_BUSINESS_ACCESS':
        return 'No tienes acceso a este negocio.';
      case 'CUSTOMER_NAME_REQUIRED':
        return 'Escribe el nombre del cliente.';
      case 'RESERVATION_NOT_FOUND':
        return 'La reserva ya no existe.';
      case 'RESERVATION_LOCKED':
        return 'No se puede editar una reserva ya sentada o cerrada.';
      case 'RESERVATION_NOT_SEATABLE':
        return 'Esta reserva está cancelada o marcada como no llegó.';
      default:
        return 'No se pudo completar la operación. Intenta de nuevo.';
    }
  }

  @override
  String toString() => 'ReservationException($code)';
}

class ReservationsRepository implements IReservationsRepository {
  final SupabaseClient _client;

  ReservationsRepository(this._client);

  static const _knownCodes = {
    'TABLE_ALREADY_RESERVED',
    'MODULE_NOT_ENABLED',
    'NO_BUSINESS_ACCESS',
    'CUSTOMER_NAME_REQUIRED',
    'RESERVATION_NOT_FOUND',
    'RESERVATION_LOCKED',
    'RESERVATION_NOT_SEATABLE',
  };

  /// Traduce un error de Postgres a [ReservationException] cuando reconoce el
  /// código emitido por los RPCs; si no, re-lanza el original.
  Never _rethrow(Object error) {
    if (error is PostgrestException) {
      for (final code in _knownCodes) {
        if (error.message.contains(code)) {
          throw ReservationException(code);
        }
      }
    }
    throw error;
  }

  Reservation _rowToReservation(dynamic res) {
    final map = res is List
        ? Map<String, dynamic>.from(res.first as Map)
        : Map<String, dynamic>.from(res as Map);
    return Reservation.fromMap(map);
  }

  @override
  Future<List<Reservation>> fetchByDay(
    String businessId,
    DateTime localDay, {
    ReservationStatus? status,
  }) async {
    // Ventana [inicio de día local, inicio del día siguiente) → UTC.
    final start = DateTime(localDay.year, localDay.month, localDay.day);
    final end = start.add(const Duration(days: 1));

    var query = _client
        .from(ReservationsQueries.tableReservations)
        .select(ReservationsQueries.selectBase)
        .eq('business_id', businessId)
        .gte('reserved_for', start.toUtc().toIso8601String())
        .lt('reserved_for', end.toUtc().toIso8601String());

    if (status != null) {
      query = query.eq('status', status.wireValue);
    }

    final rows = await query.order('reserved_for');
    return List<Map<String, dynamic>>.from(rows)
        .map(Reservation.fromMap)
        .toList(growable: false);
  }

  @override
  Future<List<Reservation>> fetchUpcomingByTable(
    String businessId,
    String tableId, {
    Duration window = const Duration(hours: 12),
  }) async {
    final now = DateTime.now().toUtc();
    final until = now.add(window);

    final rows = await _client
        .from(ReservationsQueries.tableReservations)
        .select(ReservationsQueries.selectBase)
        .eq('business_id', businessId)
        .eq('table_id', tableId)
        .inFilter('status', const ['pending', 'confirmed', 'seated'])
        .gte('reserved_for', now.toIso8601String())
        .lte('reserved_for', until.toIso8601String())
        .order('reserved_for');

    return List<Map<String, dynamic>>.from(rows)
        .map(Reservation.fromMap)
        .toList(growable: false);
  }

  @override
  Future<Reservation> create(ReservationInput input) async {
    try {
      final res = await _client.rpc('fn_create_reservation', params: {
        'p_business_id': input.businessId,
        'p_table_id': input.tableId,
        'p_customer_name': input.customerName,
        'p_party_size': input.partySize,
        'p_reserved_for': input.reservedForLocal.toUtc().toIso8601String(),
        'p_duration_minutes': input.durationMinutes,
        'p_customer_id': input.customerId,
        'p_customer_phone': input.customerPhone,
        'p_notes': input.notes,
      });
      return _rowToReservation(res);
    } catch (e) {
      _rethrow(e);
    }
  }

  @override
  Future<Reservation> update(String id, ReservationInput input) async {
    try {
      final res = await _client.rpc('fn_update_reservation', params: {
        'p_id': id,
        'p_table_id': input.tableId,
        'p_customer_name': input.customerName,
        'p_party_size': input.partySize,
        'p_reserved_for': input.reservedForLocal.toUtc().toIso8601String(),
        'p_duration_minutes': input.durationMinutes,
        'p_customer_id': input.customerId,
        'p_customer_phone': input.customerPhone,
        'p_notes': input.notes,
      });
      return _rowToReservation(res);
    } catch (e) {
      _rethrow(e);
    }
  }

  @override
  Future<String> seat(String id) async {
    try {
      final res = await _client.rpc('fn_seat_reservation', params: {
        'p_id': id,
      });
      final map = Map<String, dynamic>.from(res as Map);
      return map['session_id'] as String;
    } catch (e) {
      _rethrow(e);
    }
  }

  @override
  Future<void> cancel(String id, {String? reason}) async {
    try {
      await _client.rpc('fn_cancel_reservation', params: {
        'p_id': id,
        'p_reason': reason,
      });
    } catch (e) {
      _rethrow(e);
    }
  }

  @override
  Future<void> markNoShow(String id) async {
    try {
      await _client
          .from(ReservationsQueries.tableReservations)
          .update({'status': ReservationStatus.noShow.wireValue})
          .eq('id', id);
    } catch (e) {
      _rethrow(e);
    }
  }

  /// Suscripción realtime a la tabla de reservas del negocio. El viewmodel
  /// recarga el día actual cuando algo cambia (patrón de ByZoneViewModel).
  RealtimeChannel subscribe({
    required String businessId,
    required void Function() onChange,
  }) {
    final channel = _client.channel('reservations:$businessId');
    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'reservations',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'business_id',
            value: businessId,
          ),
          callback: (_) => onChange(),
        )
        .subscribe();
    return channel;
  }
}
