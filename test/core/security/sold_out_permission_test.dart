// Permiso del "86" (agotar producto) desde la POS.
//
// El boton apaga `menu_items.is_active` y el producto desaparece del menu de
// todas las tablets hasta que un admin lo reactive en Productos — no hay
// "des-agotar" en la POS. Regla del dueno (2026-09-06): los MESEROS no; el
// cajero, el gerente y el admin si.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/security/access_control_catalog.dart';

const _code = 'ventas.orden.agotar_producto';

void main() {
  group('ventas.orden.agotar_producto', () {
    test('esta en el catalogo (si falta, el permiso es decorativo)', () {
      expect(permissionByCode(_code), isNotNull);
    });

    test('el mesero NO lo tiene', () {
      expect(presetCodesForRole('waiter'), isNot(contains(_code)));
      expect(presetCodesForRole('mesero'), isNot(contains(_code)));
    });

    test('cajero y gerente si lo tienen', () {
      expect(presetCodesForRole('cashier'), contains(_code));
      expect(presetCodesForRole('manager'), contains(_code));
    });

    test('cocina y delivery tampoco', () {
      expect(presetCodesForRole('cook'), isNot(contains(_code)));
      expect(presetCodesForRole('delivery'), isNot(contains(_code)));
    });
  });

  // Invariante general: un codigo que un preset concede pero que no existe en
  // el catalogo no se puede sembrar en `public.permissions`, y el RPC de
  // permisos lo descarta en silencio (ver 20260822_0002).
  test('todo codigo de un preset existe en el catalogo', () {
    final huerfanos = <String>{};
    for (final preset in rolePresets.values) {
      for (final code in preset.permissionCodes) {
        if (permissionByCode(code) == null) huerfanos.add(code);
      }
    }
    expect(huerfanos, isEmpty, reason: 'codigos sin definicion: $huerfanos');
  });
}
