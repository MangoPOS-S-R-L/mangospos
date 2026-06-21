class ReservationsQueries {
  static const tableReservations = 'reservations';

  /// Select con embed de la mesa y su zona para mostrar código + zona sin
  /// consultas extra. El FK `table_id → dining_tables` y `zone_id → zones`
  /// permiten el embed anidado de PostgREST.
  static const selectBase =
      'id, business_id, branch_id, table_id, customer_id, customer_name, '
      'customer_phone, party_size, reserved_for, duration_minutes, status, '
      'notes, session_id, created_at, '
      'dining_tables(code, zones(name))';
}
