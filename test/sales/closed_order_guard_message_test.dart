import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/data/repositories/sales_repository.dart';

/// Regresión del caso SP07 (Car City S.R.L, 2026-08-19, orden 5A618117).
///
/// El barrendero de mesas fantasma cerró una mesa vacía a los 16 minutos
/// mientras el mesero seguía con la pantalla abierta. Quince minutos después
/// el mesero cargó el lavado sobre esa orden muerta: la comanda salió, el
/// insumo se descontó y los RD$500 quedaron colgando de una sesión cerrada,
/// invisibles en el salón.
///
/// El candado vive en la BD (trigger `trg_block_items_on_closed_order`,
/// migración 20260819_0004): resucita la orden cuando es seguro y rechaza con
/// SQLSTATE propio cuando no lo es. Lo único testeable sin red es que la app
/// traduzca esos códigos en vez de escupir el texto crudo de Postgres.
void main() {
  PostgrestException pg(String code) =>
      PostgrestException(message: 'raise from trigger', code: code);

  group('closedOrderErrorMessage', () {
    test('MP401 (cuenta ya cobrada) manda a abrir la mesa de nuevo', () {
      final msg = closedOrderErrorMessage(pg('MP401'));
      expect(msg, isNotNull);
      expect(msg, contains('ya fue cobrada'));
    });

    test('MP402 (mesa tomada por otra cuenta) manda a la cuenta activa', () {
      final msg = closedOrderErrorMessage(pg('MP402'));
      expect(msg, isNotNull);
      expect(msg, contains('cuenta activa'));
    });

    test('MP403 (orden inexistente) manda al salón', () {
      expect(closedOrderErrorMessage(pg('MP403')), contains('salón'));
    });

    test('otros errores de Postgres no se disfrazan', () {
      // 23505 = unique_violation. Si lo tradujéramos, esconderíamos un bug
      // distinto detrás de un mensaje de mesa cerrada.
      expect(closedOrderErrorMessage(pg('23505')), isNull);
      expect(closedOrderErrorMessage(pg('P0001')), isNull);
    });

    test('errores que no son de Postgres pasan de largo', () {
      expect(closedOrderErrorMessage(Exception('sin red')), isNull);
      expect(closedOrderErrorMessage('boom'), isNull);
    });
  });
}
