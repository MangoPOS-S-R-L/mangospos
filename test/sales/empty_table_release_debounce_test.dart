import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/data/repositories/sales_repository.dart';

/// Regresión del caso MESA9 (Sophisticated Managment SRL, 2026-08-13).
///
/// Cuando la ruta de la mesa se REEMPLAZA, el `dispose()` de la pantalla que
/// sale y el `initState()` de la que entra caen en frames contiguos. En el
/// caso real pasaron **73 ms** entre que la limpieza anuló la orden vacía y
/// que `fn_open_table` creó una nueva en la misma sesión; después la limpieza
/// cerró la sesión y dejó la orden nueva huérfana: viva, con la comanda ya
/// impresa y los insumos ya descontados, pero sin mesa y sin forma de cobrarla.
///
/// La ventana de gracia existe para que la reapertura llegue ANTES que la
/// liberación y la cancele. Estos tests cubren esa mecánica, que es lo único
/// observable sin llegar a la red.
void main() {
  late SalesRepository sales;

  setUpAll(() {
    sales = SalesRepository(
      SupabaseClient('http://localhost:54321', 'test-anon-key'),
    );
  });

  tearDown(() {
    // Ningún timer debe sobrevivir al test: si se dispara, sale a la red.
    SalesRepository.cancelPendingEmptyTableRelease('order-1');
    SalesRepository.cancelPendingEmptyTableRelease('order-2');
    SalesRepository.cancelPendingEmptyTableRelease('mesa-9');
    SalesRepository.cancelPendingEmptyTableRelease('mesa-10');
  });

  test('programar una liberación la deja pendiente, no la ejecuta', () {
    sales.scheduleEmptyTableRelease('order-1', tableId: 'mesa-9');

    expect(SalesRepository.pendingEmptyTableReleaseCount, 1);
  });

  test('reabrir la mesa cancela la liberación pendiente', () {
    sales.scheduleEmptyTableRelease('order-1', tableId: 'mesa-9');
    expect(SalesRepository.pendingEmptyTableReleaseCount, 1);

    // Esto es lo que hacen `_initializeOrder` y `openTable` ANTES del RPC:
    // cancelan por MESA, sin necesidad de conocer todavía el order_id nuevo.
    SalesRepository.cancelPendingEmptyTableRelease('mesa-9');

    expect(SalesRepository.pendingEmptyTableReleaseCount, 0);
  });

  test('la clave es la mesa, no la orden: reentrar cancela aunque el RPC '
      'vaya a devolver otra orden', () {
    sales.scheduleEmptyTableRelease('order-1', tableId: 'mesa-9');

    // El order_id todavía no existe cuando se cancela — ese es justo el punto.
    SalesRepository.cancelPendingEmptyTableRelease('mesa-9');

    expect(SalesRepository.pendingEmptyTableReleaseCount, 0);
  });

  test('_handleBack y dispose sobre la misma mesa se deduplican', () {
    // Antes eran DOS liberaciones para la misma orden.
    sales.scheduleEmptyTableRelease('order-1', tableId: 'mesa-9');
    sales.scheduleEmptyTableRelease('order-1', tableId: 'mesa-9');

    expect(SalesRepository.pendingEmptyTableReleaseCount, 1);
  });

  test('mesas distintas no se pisan', () {
    sales.scheduleEmptyTableRelease('order-1', tableId: 'mesa-9');
    sales.scheduleEmptyTableRelease('order-2', tableId: 'mesa-10');
    expect(SalesRepository.pendingEmptyTableReleaseCount, 2);

    SalesRepository.cancelPendingEmptyTableRelease('mesa-9');

    expect(SalesRepository.pendingEmptyTableReleaseCount, 1);
  });

  test('sin tableId cae a la orden como clave', () {
    sales.scheduleEmptyTableRelease('order-1');
    expect(SalesRepository.pendingEmptyTableReleaseCount, 1);

    SalesRepository.cancelPendingEmptyTableRelease('order-1');

    expect(SalesRepository.pendingEmptyTableReleaseCount, 0);
  });

  test('las órdenes offline no programan nada (no existen en el server)', () {
    sales.scheduleEmptyTableRelease('local-order-abc123');

    expect(SalesRepository.pendingEmptyTableReleaseCount, 0);
  });

  test('un orderId vacío no programa nada', () {
    sales.scheduleEmptyTableRelease('');

    expect(SalesRepository.pendingEmptyTableReleaseCount, 0);
  });

  test('cancelar algo que no existe es inocuo', () {
    SalesRepository.cancelPendingEmptyTableRelease(null);
    SalesRepository.cancelPendingEmptyTableRelease('');
    SalesRepository.cancelPendingEmptyTableRelease('no-existe');

    expect(SalesRepository.pendingEmptyTableReleaseCount, 0);
  });

  test('la ventana de gracia cubre de sobra los 73 ms del caso real', () {
    expect(
      SalesRepository.emptyTableReleaseDelay,
      greaterThan(const Duration(milliseconds: 73)),
    );
  });

  test('pero se mantiene imperceptible en el salón', () {
    // El dueño lo nota: la mesa tiene que ponerse verde enseguida. La ventana
    // solo cubre el salto entre frames porque la cancelación va ANTES del RPC,
    // así que no hay razón para que crezca a segundos.
    expect(
      SalesRepository.emptyTableReleaseDelay,
      lessThanOrEqualTo(const Duration(milliseconds: 500)),
    );
  });
}
