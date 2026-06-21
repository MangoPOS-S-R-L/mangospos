import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/reservation.dart';
import 'package:mangopos/presentation/reservations/state/reservations_state.dart';

void main() {
  group('ReservationStatus', () {
    test('wire roundtrip', () {
      for (final s in ReservationStatus.values) {
        expect(reservationStatusFromWire(s.wireValue), s);
      }
    });

    test('no_show maps correctly', () {
      expect(reservationStatusFromWire('no_show'), ReservationStatus.noShow);
      expect(ReservationStatus.noShow.wireValue, 'no_show');
    });

    test('unknown / null falls back to confirmed', () {
      expect(reservationStatusFromWire(null), ReservationStatus.confirmed);
      expect(reservationStatusFromWire('garbage'), ReservationStatus.confirmed);
    });

    test('active states ocupan la franja', () {
      expect(ReservationStatus.confirmed.isActive, isTrue);
      expect(ReservationStatus.seated.isActive, isTrue);
      expect(ReservationStatus.cancelled.isActive, isFalse);
      expect(ReservationStatus.noShow.isActive, isFalse);
      expect(ReservationStatus.completed.isActive, isFalse);
    });

    test('editable solo antes de sentar', () {
      expect(ReservationStatus.confirmed.isEditable, isTrue);
      expect(ReservationStatus.pending.isEditable, isTrue);
      expect(ReservationStatus.seated.isEditable, isFalse);
      expect(ReservationStatus.completed.isEditable, isFalse);
    });
  });

  group('Reservation.fromMap', () {
    test('parsea campos base + embed de mesa/zona', () {
      final r = Reservation.fromMap({
        'id': 'r1',
        'business_id': 'b1',
        'table_id': 't1',
        'customer_id': 'c1',
        'customer_name': 'Juan Pérez',
        'customer_phone': '809-555-1234',
        'party_size': 4,
        'reserved_for': '2026-06-20T23:30:00+00:00',
        'duration_minutes': 120,
        'status': 'confirmed',
        'notes': 'Cumpleaños',
        'session_id': null,
        'created_at': '2026-06-19T10:00:00+00:00',
        'dining_tables': {
          'code': 'T05',
          'zones': {'name': 'Terraza'},
        },
      });

      expect(r.id, 'r1');
      expect(r.partySize, 4);
      expect(r.durationMinutes, 120);
      expect(r.status, ReservationStatus.confirmed);
      expect(r.tableCode, 'T05');
      expect(r.zoneName, 'Terraza');
      expect(r.notes, 'Cumpleaños');
      // endsAt = inicio + duración
      expect(
        r.endsAtLocal.difference(r.reservedForLocal),
        const Duration(minutes: 120),
      );
    });

    test('tolera embed ausente y defaults', () {
      final r = Reservation.fromMap({
        'id': 'r2',
        'business_id': 'b1',
        'table_id': 't1',
        'customer_name': 'Walk-in',
        'reserved_for': '2026-06-20T18:00:00+00:00',
        'status': 'seated',
      });
      expect(r.partySize, 1);
      expect(r.durationMinutes, 90);
      expect(r.tableCode, isNull);
      expect(r.zoneName, isNull);
      expect(r.isSeated, isTrue);
    });
  });

  group('ReservationsState.visible', () {
    Reservation make(String id, ReservationStatus status, int hourUtc) {
      return Reservation(
        id: id,
        businessId: 'b1',
        tableId: 't1',
        customerName: 'X',
        partySize: 2,
        reservedFor: DateTime.utc(2026, 6, 20, hourUtc),
        durationMinutes: 90,
        status: status,
      );
    }

    test('sin filtro ordena por hora', () {
      final state = ReservationsState(
        selectedDay: DateTime(2026, 6, 20),
        reservations: [
          make('late', ReservationStatus.confirmed, 22),
          make('early', ReservationStatus.confirmed, 18),
        ],
      );
      expect(state.visible.map((r) => r.id).toList(), ['early', 'late']);
    });

    test('filtra por estado', () {
      final state = ReservationsState(
        selectedDay: DateTime(2026, 6, 20),
        statusFilter: ReservationStatus.cancelled,
        reservations: [
          make('a', ReservationStatus.confirmed, 18),
          make('b', ReservationStatus.cancelled, 19),
        ],
      );
      expect(state.visible.map((r) => r.id).toList(), ['b']);
    });
  });
}
