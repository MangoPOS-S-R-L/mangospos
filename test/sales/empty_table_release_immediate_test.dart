import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/data/repositories/sales_repository.dart';

/// Regla del dueño (10-oct): salir de una mesa SIN productos la libera al
/// instante, sin otra condición. Mientras `fn_release_empty_table_v2` (T02,
/// 20261010_0030) no exista en la base, la app no puede dejar la mesa naranja:
/// usa la liberación vigente. Lo que otro equipo tuviera sin subir de esa
/// cuenta no se pierde: vuelve como cuenta en revisión (20261010_0020).
void main() {
  const json = {'content-type': 'application/json'};

  ({SalesRepository repo, List<String> calls}) repoWithServer({
    required bool hasV2,
  }) {
    final calls = <String>[];
    final client = SupabaseClient(
      'http://localhost:54321',
      'test-anon-key',
      httpClient: MockClient((request) async {
        final fn = request.url.pathSegments.last;
        calls.add(fn);
        if (fn == 'fn_release_empty_table_v2' && !hasV2) {
          return http.Response(
            jsonEncode({
              'code': 'PGRST202',
              'message':
                  'Could not find the function public.fn_release_empty_table_v2',
              'details': null,
              'hint': null,
            }),
            404,
            headers: json,
            request: request,
          );
        }
        return http.Response(
          '{"released":true,"closed_session":true}',
          200,
          headers: json,
          request: request,
        );
      }),
    );
    return (repo: SalesRepository(client), calls: calls);
  }

  test('sin la migración de T02, salir de una mesa vacía la libera al instante',
      () async {
    final s = repoWithServer(hasV2: false);

    final released = await s.repo.releaseEmptyTableIfNeeded(
      'order-1',
      deviceId: 'tablet-A',
      hasPendingWork: false,
    );

    expect(released, isTrue);
    expect(s.calls, ['fn_release_empty_table_v2', 'fn_release_empty_table']);
  });

  test('con trabajo propio pendiente de esa cuenta no se libera', () async {
    final s = repoWithServer(hasV2: false);

    final released = await s.repo.releaseEmptyTableIfNeeded(
      'order-1',
      deviceId: 'tablet-A',
      hasPendingWork: true,
    );

    expect(released, isFalse);
    expect(s.calls, ['fn_release_empty_table_v2']);
  });

  test('con la migración de T02 usa la liberación nueva, una sola llamada',
      () async {
    final s = repoWithServer(hasV2: true);

    final released = await s.repo.releaseEmptyTableIfNeeded(
      'order-1',
      deviceId: 'tablet-A',
      hasPendingWork: false,
    );

    expect(released, isTrue);
    expect(s.calls, ['fn_release_empty_table_v2']);
  });

  test('una cuenta local nunca toca el servidor', () async {
    final s = repoWithServer(hasV2: false);

    final released = await s.repo.releaseEmptyTableIfNeeded(
      'local-order-abc',
      deviceId: 'tablet-A',
      hasPendingWork: false,
    );

    expect(released, isFalse);
    expect(s.calls, isEmpty);
  });
}
