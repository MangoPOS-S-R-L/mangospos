// «MESERO:» de comanda/precuenta/factura cuando la RPC del mesero falla: con
// mesa abierta por PIN NUNCA sale la cuenta del equipo (`opened_by`), que en
// multimesero es quien tiene la sesión iniciada, no quien atendió.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  Future<Map<String, dynamic>> displayData({
    String? openedByEmployeeId,
    List<Map<String, dynamic>>? employees,
    String? fallbackWaiterName,
  }) async {
    final client = SupabaseClient(
      'http://localhost:54321',
      'test',
      httpClient: MockClient((request) async {
        http.Response json(Object? body, {int status = 200}) => http.Response(
          jsonEncode(body),
          status,
          headers: {'content-type': 'application/json'},
          request: request,
        );
        final path = request.url.path;
        if (path.endsWith('/rpc/fn_order_opener_name')) {
          return json({'message': 'sin respuesta'}, status: 500);
        }
        if (path.endsWith('/rest/v1/employees')) {
          if (employees == null) {
            return json({'message': 'sin respuesta'}, status: 500);
          }
          return json(employees);
        }
        if (path.endsWith('/rest/v1/orders')) {
          return json([
            {
              'id': 'order-0001',
              'order_number': 7,
              'created_at': '2026-10-09T12:00:00Z',
              'table_sessions': {
                'people_count': 2,
                'customer_name': null,
                'opened_by_employee_id': openedByEmployeeId,
                'dining_tables': {'code': 'M5', 'label': 'Mesa 5'},
                'waiter': {'full_name': 'Arianis Cuenta'},
                'opener': {'full_name': 'Arianis Cuenta'},
              },
            },
          ]);
        }
        return json(null);
      }),
    );
    addTearDown(client.dispose);
    return PrintingService(client).debugOrderDisplayData(
      'order-0001',
      fallbackWaiterName: fallbackWaiterName,
    );
  }

  test('mesa con PIN: sale el mesero, no la cuenta del equipo', () async {
    final data = await displayData(
      openedByEmployeeId: 'emp-claudia',
      employees: [
        {'first_name': 'Claudia', 'last_name': 'Perez'},
      ],
    );
    expect(data['waiterName'], 'Claudia Perez');
  });

  test('mesa con PIN y sin poder leer al mesero: respaldo del caller, '
      'nunca la cuenta', () async {
    final conFallback = await displayData(
      openedByEmployeeId: 'emp-claudia',
      fallbackWaiterName: 'Claudia',
    );
    expect(conFallback['waiterName'], 'Claudia');

    final sinFallback = await displayData(openedByEmployeeId: 'emp-claudia');
    expect(sinFallback['waiterName'], isNull);
  });

  test('mesa abierta sin PIN: sale la cuenta que la abrió', () async {
    final data = await displayData();
    expect(data['waiterName'], 'Arianis Cuenta');
  });
}
