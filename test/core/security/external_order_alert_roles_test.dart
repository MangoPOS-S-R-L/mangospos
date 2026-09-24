// Quién oye el aviso de un pedido de canal externo y quién no.
//
// Regla del dueño (2026-09-24): suena en el equipo del cajero, NUNCA en el del
// mesero. El corte lo da el permiso `ventas.ordenes.ver`, así que si alguien
// lo agrega al preset equivocado, el ruido aparece donde no debe y nadie se
// entera hasta que un mesero se queja.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/security/access_control_catalog.dart';

void main() {
  const permiso = 'ventas.ordenes.ver';

  test('el permiso existe en el catálogo del cliente', () {
    // Sin esta fila, el gate no encuentra el código y no lo tiene NADIE —
    // ni el cajero. Es el mismo modo de fallo silencioso que ya mordió con
    // los permisos de crédito.
    expect(allAccessPermissionCodes, contains(permiso));
  });

  test('el MESERO no lo tiene: su tablet nunca suena', () {
    expect(rolePresets['waiter']!.permissionCodes, isNot(contains(permiso)));
  });

  test('el CAJERO sí lo tiene', () {
    expect(rolePresets['cashier']!.permissionCodes, contains(permiso));
  });

  test('supervisor, administrador y propietario también', () {
    for (final rol in ['manager', 'admin', 'owner']) {
      expect(
        rolePresets[rol]!.permissionCodes,
        contains(permiso),
        reason: 'el preset $rol debería recibir el aviso',
      );
    }
  });

  test('cocina y repartidor tampoco: no cobran ni despachan el pedido', () {
    for (final rol in ['cook', 'delivery']) {
      expect(
        rolePresets[rol]!.permissionCodes,
        isNot(contains(permiso)),
        reason: 'el preset $rol no debería sonar',
      );
    }
  });
}
