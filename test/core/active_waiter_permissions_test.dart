// Permisos del mesero identificado por PIN (modo multimesero).
//
// En una tablet compartida los gates leían los permisos del usuario logueado,
// no los del mesero que metía su PIN: el mesero A le prestaba (o le negaba)
// sus permisos a todos los que entraran después. `ActiveWaiter.hasPermission`
// es la pieza que corrige eso.
//
// El contrato clave es el tri-estado: `null` significa "no sé, usá la sesión",
// y NO debe confundirse con `false` ("este mesero no tiene el permiso").

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/multimesero/active_waiter_provider.dart';

ActiveWaiter _waiter({Set<String>? permissions}) => ActiveWaiter(
      employeeId: 'emp-1',
      firstName: 'Rosa',
      lastName: 'Calderon',
      businessId: 'biz-1',
      validatedAt: DateTime(2026, 8, 12),
      userId: 'user-1',
      permissions: permissions,
    );

void main() {
  group('ActiveWaiter.hasPermission', () {
    test('sin permisos resueltos devuelve null (el caller cae a la sesión)',
        () {
      expect(_waiter().hasPermission('ventas.mesas.mover_unir'), isNull);
    });

    test('concede el permiso exacto', () {
      final w = _waiter(permissions: {'ventas.mesas.mover_unir'});
      expect(w.hasPermission('ventas.mesas.mover_unir'), isTrue);
    });

    test('niega un permiso que el mesero no tiene', () {
      final w = _waiter(permissions: {'ventas.mesas.abrir'});
      expect(w.hasPermission('ventas.mesas.mover_unir'), isFalse);
    });

    test('un set vacío niega, NO cae a la sesión', () {
      // Distinto de `null`: acá sí sabemos que el mesero no tiene nada.
      final w = _waiter(permissions: <String>{});
      expect(w.hasPermission('ventas.mesas.mover_unir'), isFalse);
    });

    test('respeta el comodín global', () {
      final w = _waiter(permissions: {'*'});
      expect(w.hasPermission('contabilidad.periodos.cerrar'), isTrue);
    });

    test('respeta el comodín por módulo', () {
      final w = _waiter(permissions: {'ventas.mesas.*'});
      expect(w.hasPermission('ventas.mesas.mover_unir'), isTrue);
      expect(w.hasPermission('ventas.orden.eliminar_item'), isFalse);
    });

    test('el comodín de módulo no alcanza a un prefijo más corto', () {
      final w = _waiter(permissions: {'ventas.mesas.*'});
      expect(w.hasPermission('ventas'), isFalse);
    });

    test('copyWith preserva userId y permisos', () {
      final w = _waiter(permissions: {'creditos.vender'});
      final copia = w.copyWith(firstName: 'Omar');
      expect(copia.firstName, 'Omar');
      expect(copia.userId, 'user-1');
      expect(copia.hasPermission('creditos.vender'), isTrue);
    });
  });
}
