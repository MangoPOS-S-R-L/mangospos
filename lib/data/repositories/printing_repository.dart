// lib/data/printing/repository.dart
import 'package:mangopos/data/models/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PrintingRepository {
  final _sb = Supabase.instance.client;

  // ------- Printers -------
  Future<List<PrinterDevice>> fetchPrinters(String businessId) async {
    final rows = await _sb
        .from('printers')
        .select()
        .eq('business_id', businessId)
        .order('created_at');
    return (rows as List).map((e) => PrinterDevice.fromMap(e)).toList();
  }

  Future<void> upsertPrinter(PrinterDevice p) =>
      _sb.from('printers').upsert(p.toMap());

  Future<void> deletePrinter(String id) =>
      _sb.from('printers').delete().eq('id', id);

  // ------- Areas -------
  Future<List<PrintArea>> fetchAreas(String businessId) async {
    final rows = await _sb
        .from('print_areas')
        .select()
        .eq('business_id', businessId)
        .order('title');
    return (rows as List).map((e) => PrintArea.fromMap(e)).toList();
  }

  Future<void> createArea(String businessId, String title) =>
      _sb.from('print_areas').insert({'business_id': businessId, 'title': title});

  Future<void> deleteArea(String id) =>
      _sb.from('print_areas').delete().eq('id', id);

  // ------- Area <-> Printer assignments -------
  Future<List<String>> printersForArea(String areaId) async {
    final rows = await _sb
        .from('area_printers')
        .select('printer_id')
        .eq('area_id', areaId);
    return (rows as List).map((e) => e['printer_id'] as String).toList();
  }

  Future<void> setAreaPrinters(String areaId, List<String> printerIds) async {
    // idempotente: borra y re-inserta (puedes migrar a diff si prefieres)
    await _sb.from('area_printers').delete().eq('area_id', areaId);
    if (printerIds.isEmpty) return;
    await _sb.from('area_printers').insert(
      printerIds.map((pid) => {'area_id': areaId, 'printer_id': pid}).toList(),
    );
  }
}
