import 'package:mangopos/data/models/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PrintingRepository {
  PrintingRepository(this._client);

  final SupabaseClient _client;

  // ------- Printers -------
  Future<List<PrinterDevice>> getPrinters(String businessId) async {
    final rows = await _client
        .from('printers')
        .select()
        .eq('business_id', businessId)
        .order('created_at');
    return (rows as List<dynamic>)
        .map((e) => PrinterDevice.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> createPrinter({
    required String businessId,
    required String name,
    String? ip,
    String? mac,
    PrinterType type = PrinterType.network,
  }) {
    return _client.from('printers').insert({
          'business_id': businessId,
          'name': name,
          'ip': ip,
          'mac': mac,
          'type': type.name,
        });
  }

  Future<void> savePrinter(PrinterDevice printer) {
    return _client.from('printers').upsert(printer.toMap());
  }

  Future<void> deletePrinter(String id) {
    return _client.from('printers').delete().eq('id', id);
  }

  Future<void> enqueueTestPrint(String printerId) {
    return _client.rpc('enqueue_print_test', params: {'p_printer_id': printerId});
  }

  // ------- Areas -------
  Future<List<PrintArea>> getPrintAreas(String businessId) async {
    final rows = await _client
        .from('print_areas_view')
        .select()
        .eq('business_id', businessId)
        .order('created_at');
    return (rows as List<dynamic>)
        .map((e) => PrintArea.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> createArea({
    required String businessId,
    required String name,
  }) {
    return _client.from('print_areas').insert({
          'business_id': businessId,
          'name': name,
        });
  }

  Future<void> deleteArea(String id) {
    return _client.from('print_areas').delete().eq('id', id);
  }

  // ------- Area <-> Printer assignments -------
  Future<List<PrintAreaPrinter>> getAreaPrinters(String areaId) async {
    final rows = await _client
        .from('print_area_printers')
        .select()
        .eq('area_id', areaId);
    return (rows as List<dynamic>)
        .map((e) => PrintAreaPrinter.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> linkAreaToPrinter({
    required String businessId,
    required String areaId,
    required String printerId,
    bool enabled = true,
    bool printsOrders = true,
    bool printsPrebills = false,
    bool printsReceipts = false,
  }) {
    return _client.from('print_area_printers').upsert({
          'business_id': businessId,
          'area_id': areaId,
          'printer_id': printerId,
          'enabled': enabled,
          'prints_orders': printsOrders,
          'prints_prebills': printsPrebills,
          'prints_receipts': printsReceipts,
        });
  }

  Future<void> unlinkAreaPrinter({
    required String areaId,
    required String printerId,
  }) {
    return _client
        .from('print_area_printers')
        .delete()
        .match({'area_id': areaId, 'printer_id': printerId});
  }
}
