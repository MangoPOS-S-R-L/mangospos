import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/app_time.dart';
import '../models/kitchen_comanda_report.dart';
import '../models/kitchen_missing_report.dart';

export '../models/kitchen_comanda_report.dart';
export '../models/kitchen_missing_report.dart';

/// Error del reporte de comandas, ya en palabras del usuario.
class KitchenComandaReportException implements Exception {
  const KitchenComandaReportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Lee el reporte de comandas por la RPC `fn_kitchen_comandas_report`
/// (migración 20260919_0001).
///
/// No es un select directo a `order_items` porque su RLS exige mesa: la venta
/// rápida y la manual, que también mandan a cocina, no saldrían.
class KitchenComandaReportRepository {
  KitchenComandaReportRepository(this._client);

  final SupabaseClient _client;

  static const _rpc = 'fn_kitchen_comandas_report';

  /// PostgREST corta cada respuesta en 1000 filas sin avisar (también la de
  /// una RPC): un día movido supera eso fácil. Se pagina ordenando por
  /// columnas de la salida para que las páginas no se pisen.
  static const _pageSize = 500;

  /// [from]/[to] en hora de pared AST, [to] exclusivo (igual que Reportes).
  Future<KitchenComandaReport> getReport({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    return KitchenComandaReport.fromRows(
      await _fetchAll({
        'p_business_id': businessId,
        'p_from': AppTime.astToUtcIso(from),
        'p_to': AppTime.astToUtcIso(to),
      }),
    );
  }

  /// Lo que salió a cocina y sigue sin cobrar AHORA (mesas abiertas y
  /// órdenes huérfanas), sin importar cuándo se envió.
  Future<KitchenComandaReport> getOpenUncharged({
    required String businessId,
  }) async {
    return KitchenComandaReport.fromRows(
      await _fetchAll({'p_business_id': businessId, 'p_open_only': true}),
    );
  }

  /// Productos cobrados en el rango (fecha del pago, como Ventas) que nunca
  /// pasaron por cocina. Cada fila trae la hora del cobro en
  /// `kitchen_sent_at` y `sent_source` = 'none'.
  Future<KitchenComandaReport> getChargedWithoutComanda({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    return KitchenComandaReport.fromRows(
      await _fetchAll({
        'p_business_id': businessId,
        'p_from': AppTime.astToUtcIso(from),
        'p_to': AppTime.astToUtcIso(to),
        'p_without_comanda': true,
      }),
    );
  }

  /// Las comandas "desaparecidas" del rango: lo que se borró o se redujo
  /// después de enviarse, y lo enviado que ninguna cuenta viva muestra
  /// (`fn_kitchen_missing_report`, migración 20260919_0002).
  Future<KitchenMissingReport> getMissing({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    return KitchenMissingReport.fromRows(
      await _fetchAll({
        'p_business_id': businessId,
        'p_from': AppTime.astToUtcIso(from),
        'p_to': AppTime.astToUtcIso(to),
      }, rpc: _missingRpc),
    );
  }

  static const _missingRpc = 'fn_kitchen_missing_report';

  Future<List<Map<String, dynamic>>> _fetchAll(
    Map<String, dynamic> params, {
    String rpc = _rpc,
  }) async {
    final rows = <Map<String, dynamic>>[];
    try {
      for (var offset = 0; ; offset += _pageSize) {
        final page = List<Map<String, dynamic>>.from(
          await _client
                  .rpc(rpc, params: params)
                  .order('kitchen_sent_at', ascending: true)
                  .order('item_id', ascending: true)
                  .range(offset, offset + _pageSize - 1)
              as List,
        );
        rows.addAll(page);
        if (page.length < _pageSize) break;
      }
    } catch (e) {
      throw KitchenComandaReportException(friendlyError(e, rpc: rpc));
    }
    return rows;
  }

  static String friendlyError(Object error, {String rpc = _rpc}) {
    final msg = error.toString();
    if (msg.contains('PGRST202') ||
        msg.contains('42883') ||
        msg.contains('Could not find the function')) {
      return rpc == _missingRpc
          ? 'Las comandas desaparecidas todavía no están instaladas en el '
                'servidor (falta aplicar la migración 20260919_0002).'
          : 'El reporte de comandas todavía no está instalado en el servidor '
                '(falta aplicar la migración 20260919_0001).';
    }
    if (msg.contains('UNAUTHORIZED_BUSINESS')) {
      return 'No tienes acceso a las comandas de este negocio.';
    }
    if (msg.contains('INVALID_RANGE')) {
      return 'El rango de fechas no es válido.';
    }
    return 'No se pudieron cargar las comandas: $msg';
  }
}

final kitchenComandaReportRepositoryProvider =
    Provider<KitchenComandaReportRepository>((ref) {
      return KitchenComandaReportRepository(Supabase.instance.client);
    });
