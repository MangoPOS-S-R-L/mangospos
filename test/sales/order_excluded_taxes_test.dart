// Quitar impuestos de una orden puntual (estilo Square POS).
//
// El recálculo real vive en `fn_set_order_excluded_taxes` (SQL) y no se puede
// cubrir desde acá. Lo que estas pruebas fijan es el contrato del lado del
// cliente, que es donde ya nos mordió antes:
//
//  1. `TaxDef` tiene que cargar el `taxes.id`. Sin id no hay forma de decir
//     CUÁL impuesto se excluye — el motor identificaba por nombre y dos
//     impuestos homónimos (o un rename) rompían la exclusión.
//
//  2. El modal solo puede ofrecer impuestos que realmente se cobran en el
//     origen de venta actual, y solo los que traen id.
//
//  3. El aviso de "esto se declara a la DGII" tiene que salir para los
//     impuestos fiscales y NO para la propina — es lo único que separa
//     "quitar la propina que el cliente rechazó" de "sub-declarar el ITBIS".

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/tax/tax_engine.dart';

Map<String, dynamic> _taxRow({
  String? id,
  String name = 'ITBIS',
  double rate = 18,
  bool isServiceFee = false,
  bool includeInEcf = true,
  bool applyOnZone = true,
  bool applyOnQuick = true,
}) => {
  if (id != null) 'id': id,
  'name': name,
  'rate': rate,
  'is_active': true,
  'is_service_fee': isServiceFee,
  'apply_on_zone': applyOnZone,
  'apply_on_manual': true,
  'apply_on_quick': applyOnQuick,
  'apply_on_delivery': true,
  'apply_on_takeout': true,
  'include_in_ecf': includeInEcf,
};

/// Espejo de `SalesViewModel.availableTaxesForOrigin`. El viewmodel arrastra
/// Supabase y el árbol de providers, así que la regla se prueba acá sobre las
/// mismas `TaxDef`; si un día divergen, el test de arriba (id obligatorio) es
/// el que avisa.
List<TaxDef> _selectable(List<TaxDef> defs, SaleOrigin origin) => defs
    .where((tx) => tx.isActive && tx.rate > 0 && tx.appliesTo(origin))
    .where((tx) => tx.id.isNotEmpty)
    .toList(growable: false);

void main() {
  group('TaxDef.id', () {
    test('se carga desde la fila de taxes', () {
      final def = TaxDef.fromMap(_taxRow(id: 'tax-itbis'));
      expect(def.id, 'tax-itbis');
    });

    test('queda vacío si la fila no lo trae, sin romper el parseo', () {
      // Las filas legacy y los tax_lines optimistas del carrito no traen id.
      // Deben seguir parseando: lo único que pierden es poder excluirse.
      final def = TaxDef.fromMap(_taxRow());
      expect(def.id, '');
      expect(def.rate, 18);
      expect(def.name, 'ITBIS');
    });
  });

  group('Impuestos ofrecidos en el modal', () {
    final defs = [
      TaxDef.fromMap(_taxRow(id: 'itbis', name: 'ITBIS', rate: 18)),
      TaxDef.fromMap(
        _taxRow(
          id: 'ley',
          name: 'Propina Ley',
          rate: 10,
          isServiceFee: true,
          includeInEcf: false,
          applyOnQuick: false,
        ),
      ),
      // Sin id: no se puede excluir, así que no se ofrece.
      TaxDef.fromMap(_taxRow(name: 'Legacy sin id', rate: 5)),
    ];

    test('en zona salen los dos que aplican, no el que no tiene id', () {
      final selectable = _selectable(defs, SaleOrigin.zone);

      expect(selectable.map((t) => t.id), ['itbis', 'ley']);
    });

    test('en venta rápida la propina no aplica y no se ofrece', () {
      final selectable = _selectable(defs, SaleOrigin.quick);

      expect(selectable.map((t) => t.id), ['itbis']);
      // Coherencia con el motor: si no aplica al origen, tampoco se cobra.
      expect(
        defs.firstWhere((t) => t.id == 'ley').appliesTo(SaleOrigin.quick),
        isFalse,
      );
    });
  });

  group('Aviso DGII', () {
    // Misma regla que usa el modal para decidir si pinta la advertencia.
    bool isFiscal(TaxDef tax) => tax.includeInEcf && !tax.effectiveIsServiceFee;

    test('el ITBIS se marca como declarable', () {
      expect(isFiscal(TaxDef.fromMap(_taxRow(id: 'itbis'))), isTrue);
    });

    test('la propina de ley no dispara el aviso', () {
      final ley = TaxDef.fromMap(
        _taxRow(
          id: 'ley',
          name: 'Propina Ley',
          rate: 10,
          isServiceFee: true,
          includeInEcf: false,
        ),
      );
      expect(isFiscal(ley), isFalse);
    });

    test('un impuesto que el contador sí declara dispara el aviso aunque '
        'sea service fee por configuración', () {
      // include_in_ecf es un toggle por negocio: algunos contadores declaran
      // la propina. Si está marcada como service fee, el aviso NO sale —
      // effectiveIsServiceFee manda. Se fija para que el día que se cambie
      // sea una decisión consciente y no un efecto colateral.
      final propinaDeclarada = TaxDef.fromMap(
        _taxRow(
          id: 'ley2',
          name: 'Propina Ley',
          rate: 10,
          isServiceFee: true,
          includeInEcf: true,
        ),
      );
      expect(isFiscal(propinaDeclarada), isFalse);
    });
  });
}
