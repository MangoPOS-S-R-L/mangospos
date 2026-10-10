// Comanda/factura de venta rápida o manual: la mesa virtual se imprime por su
// etiqueta ("Venta rapida 2"), nunca por su código interno ("quick#2"). Las
// mesas reales siguen imprimiendo su código.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/utils/virtual_sale_table_name.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('virtualSaleTableName', () {
    test('carril con etiqueta usa la etiqueta', () {
      expect(
        virtualSaleTableName(code: 'quick#2', label: 'Venta rapida 2'),
        'Venta rapida 2',
      );
      expect(
        virtualSaleTableName(code: 'manual', label: 'Venta manual'),
        'Venta manual',
      );
    });

    test('sin etiqueta usable se arma desde el código', () {
      expect(virtualSaleTableName(code: 'quick#2'), 'Venta rapida 2');
      expect(
        virtualSaleTableName(code: 'manual#3', label: ' '),
        'Venta manual 3',
      );
      expect(virtualSaleTableName(code: 'quick'), 'Venta rapida');
      // El historial manda el código como etiqueta cuando no hay otra.
      expect(
        virtualSaleTableName(code: 'quick#4', label: 'quick#4'),
        'Venta rapida 4',
      );
    });

    test('mesas compartidas de antes no imprimen el "auto"', () {
      expect(
        virtualSaleTableName(code: 'quick', label: 'Venta rapida auto'),
        'Venta rapida',
      );
      expect(
        virtualSaleTableName(code: 'manual', label: 'Venta manual auto'),
        'Venta manual',
      );
    });

    test('carritos retail y ventas offline usan su etiqueta', () {
      expect(
        virtualSaleTableName(
          code: 'quick-0b1c2d3e-0000-4000-8000-000000000001',
          label: 'Venta rapida',
        ),
        'Venta rapida',
      );
      expect(virtualSaleTableName(code: 'manual-local-123'), 'Venta manual');
    });

    test('mesas reales no se tocan', () {
      expect(virtualSaleTableName(code: 'M5', label: 'Mesa 5'), isNull);
      expect(virtualSaleTableName(code: 'DEL-001', label: 'Uber Eats'), isNull);
      expect(virtualSaleTableName(code: 'Manual', label: 'Barra'), isNull);
      expect(virtualSaleTableName(code: 'quickly', label: 'Terraza'), isNull);
      expect(virtualSaleTableName(code: null, label: 'Mesa 1'), isNull);
    });
  });

  group('datos de cabecera del ticket', () {
    Future<Map<String, dynamic>> displayData(Map<String, dynamic> table) async {
      final client = SupabaseClient(
        'http://localhost:54321',
        'test',
        httpClient: MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path.endsWith('/rest/v1/orders')) {
            return http.Response(
              jsonEncode([
                {
                  'id': 'order-0001',
                  'order_number': 42,
                  'created_at': '2026-10-09T12:00:00Z',
                  'table_sessions': {
                    'people_count': 1,
                    'customer_name': null,
                    'dining_tables': table,
                    'waiter': null,
                    'opener': null,
                  },
                },
              ]),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          return http.Response(
            'null',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      return PrintingService(client).debugOrderDisplayData('order-0001');
    }

    test('carril de venta rápida imprime su etiqueta', () async {
      final data = await displayData({
        'code': 'quick#2',
        'label': 'Venta rapida 2',
      });
      expect(data['tableName'], 'Venta rapida 2');
      expect(data['orderNumber'], '42');
    });

    test('venta manual en la mesa compartida de antes', () async {
      final data = await displayData({
        'code': 'manual',
        'label': 'Venta manual auto',
      });
      expect(data['tableName'], 'Venta manual');
    });

    test('mesa real sigue imprimiendo su código', () async {
      final data = await displayData({'code': 'M5', 'label': 'Mesa 5'});
      expect(data['tableName'], 'M5');
    });

    test('mesa real sin código imprime su etiqueta', () async {
      final data = await displayData({'code': '', 'label': 'Terraza'});
      expect(data['tableName'], 'Terraza');
    });
  });
}
