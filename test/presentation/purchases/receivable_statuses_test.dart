// Estados de orden que admiten recepción.
//
// El selector de "Recibir orden de compra" (Recepciones → Registro de
// compras) arma su lista con esta constante. Si alguien mete 'received' o
// 'cancelled', se podría recibir dos veces la misma mercancía o meter stock
// contra una orden anulada — y ninguno de los dos casos lo frena la RPC por
// sí solo: `fn_receive_purchase_order_v2` rechaza la orden recibida, pero
// mostrarla en el selector ya es prometer algo que va a fallar.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/repositories/purchases_repository.dart';

void main() {
  group('PurchasesRepository.receivableStatuses', () {
    test('no incluye órdenes ya recibidas ni canceladas', () {
      expect(PurchasesRepository.receivableStatuses, isNot(contains('received')));
      expect(
        PurchasesRepository.receivableStatuses,
        isNot(contains('cancelled')),
      );
    });

    test('incluye los tres estados que todavía esperan mercancía', () {
      expect(
        PurchasesRepository.receivableStatuses,
        containsAll(<String>['draft', 'sent', 'partial']),
      );
    });

    test('son valores válidos del enum purchase_status', () {
      // draft | sent | partial | received | cancelled (schema.sql).
      const enumValues = <String>{
        'draft',
        'sent',
        'partial',
        'received',
        'cancelled',
      };
      for (final status in PurchasesRepository.receivableStatuses) {
        expect(
          enumValues,
          contains(status),
          reason: '"$status" no existe en el enum purchase_status: la consulta '
              'fallaría con 22P02 en vez de devolver órdenes.',
        );
      }
    });
  });
}
