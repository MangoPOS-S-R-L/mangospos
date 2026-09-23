// Reporte «¿Quién me vende más barato?» (Reportes → Precios por proveedor).
//
// Junta dos lecturas: `fn_purchase_price_comparison` sin filtro de insumos
// (todo el negocio, mig 20260915_0008) y los NOMBRES de los insumos, que la
// función no devuelve.
//
// Los nombres se traen del catálogo completo paginado en vez de filtrar por la
// lista de ids: una lista de cientos de uuid en la URL es justo lo que hace
// saltar el 414 de PostgREST.
//
// Degrada: si la base no tiene la función, `supported` viene en false y la
// pantalla explica qué falta en vez de reventar.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/core/inventory/supplier_price_report.dart';
import 'package:mangopos/data/datasources/queries/inventory_queries.dart';
import 'package:mangopos/data/repositories/price_comparison_repository.dart';

class SupplierPriceReportData {
  /// Filas listas para pintar, ordenadas por ahorro estimado.
  final List<SupplierPriceReportRow> rows;

  /// False = falta aplicar 20260915_0008 en la base.
  final bool supported;

  const SupplierPriceReportData({required this.rows, required this.supported});

  static const unsupported = SupplierPriceReportData(
    rows: [],
    supported: false,
  );
}

class SupplierPriceReportRepository {
  SupplierPriceReportRepository(this._client, this._prices);

  final SupabaseClient _client;
  final PriceComparisonRepository _prices;

  static const int _pageSize = 1000;

  Future<SupplierPriceReportData> load({
    required String businessId,
    int daysBack = 90,
  }) async {
    final prices = await _prices.getComparison(
      businessId: businessId,
      daysBack: daysBack,
    );
    if (prices == null) return SupplierPriceReportData.unsupported;
    if (prices.isEmpty) {
      return const SupplierPriceReportData(rows: [], supported: true);
    }

    final items = await _loadItemNames(businessId);
    return SupplierPriceReportData(
      rows: buildSupplierPriceReport(prices: prices, items: items),
      supported: true,
    );
  }

  /// id → nombre y unidad base del insumo. Sin nombres el reporte igual se
  /// arma (queda «Insumo sin nombre»), así que un fallo acá no lo tumba.
  Future<Map<String, SupplierPriceItemInfo>> _loadItemNames(
    String businessId,
  ) async {
    final result = <String, SupplierPriceItemInfo>{};
    try {
      for (var from = 0; ; from += _pageSize) {
        final rows = await _client
            .from(InventoryQueries.tableInventoryItems)
            .select('id, name, unit')
            .eq('business_id', businessId)
            .order('id')
            .range(from, from + _pageSize - 1);
        final page = List<Map<String, dynamic>>.from(rows);
        for (final row in page) {
          final id = row['id']?.toString();
          if (id == null || id.isEmpty) continue;
          result[id] = SupplierPriceItemInfo(
            name: row['name']?.toString() ?? '',
            unit: row['unit']?.toString() ?? '',
          );
        }
        if (page.length < _pageSize) break;
      }
    } catch (_) {
      // Sin nombres el reporte sigue siendo utilizable.
    }
    return result;
  }
}

final supplierPriceReportRepositoryProvider =
    Provider<SupplierPriceReportRepository>(
      (ref) => SupplierPriceReportRepository(
        Supabase.instance.client,
        ref.read(priceComparisonRepositoryProvider),
      ),
    );
