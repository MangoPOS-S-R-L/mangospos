import 'dart:convert';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/core/utils/catalog_csv_parser.dart';
import 'package:mangopos/data/repositories/catalog_import_repository.dart';
import 'package:mangopos/services/session/session_controller.dart';

/// Diálogo de carga masiva de catálogo desde CSV (fase R3 retail).
///
/// Columnas aceptadas (header, ES/EN): nombre, precio, costo, sku, barcode,
/// categoria, impuesto. Idempotente por SKU. Crea categorías faltantes y liga
/// el impuesto por nombre (o el impuesto por defecto elegido).
class ImportCatalogDialog extends ConsumerStatefulWidget {
  const ImportCatalogDialog({super.key});

  @override
  ConsumerState<ImportCatalogDialog> createState() =>
      _ImportCatalogDialogState();
}

enum _Stage { idle, parsed, importing, done }

class _ImportCatalogDialogState extends ConsumerState<ImportCatalogDialog> {
  _Stage _stage = _Stage.idle;
  String? _fileName;
  CatalogCsvParseResult? _parsed;
  String? _error;

  // Configuración de import.
  String _taxMode = 'inclusive';
  String? _defaultTaxId;
  List<Map<String, dynamic>> _taxes = const [];

  // Progreso / resultado.
  int _progressDone = 0;
  int _progressTotal = 0;
  CatalogImportResult? _result;

  Future<void> _pickFile() async {
    setState(() => _error = null);
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['csv', 'txt', 'xlsx', 'xls'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      setState(() => _error = 'No se pudo leer el archivo.');
      return;
    }
    final ext = (file.extension ?? '').toLowerCase();
    CatalogCsvParseResult result;
    try {
      if (ext == 'xlsx' || ext == 'xls') {
        result = CatalogCsvParser.fromRows(_excelToRows(bytes));
      } else {
        final content = utf8.decode(bytes, allowMalformed: true);
        result = CatalogCsvParser.parse(content);
      }
    } catch (e) {
      setState(() => _error = 'No se pudo leer el archivo: $e');
      return;
    }
    await _loadTaxes();
    if (!mounted) return;
    setState(() {
      _fileName = file.name;
      _parsed = result;
      _stage = _Stage.parsed;
    });
  }

  /// Convierte el primer sheet de un Excel a una tabla de Strings para el
  /// parser compartido (misma lógica de headers/aliases que el CSV).
  List<List<String?>> _excelToRows(List<int> bytes) {
    final book = Excel.decodeBytes(bytes);
    final table = <List<String?>>[];
    for (final sheet in book.tables.values) {
      for (final row in sheet.rows) {
        table.add(row.map((cell) => cell?.value?.toString()).toList());
      }
      break; // solo el primer sheet
    }
    return table;
  }

  Future<void> _loadTaxes() async {
    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) return;
    try {
      final rows = await Supabase.instance.client
          .from('taxes')
          .select('id,name,rate')
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('rate');
      _taxes = List<Map<String, dynamic>>.from(rows as List);
      // Default: el primer impuesto con tasa 0 (EXENTO) si existe — típico de
      // colmado; si no, sin impuesto.
      final exempt = _taxes.firstWhere(
        (t) => ((t['rate'] as num?)?.toDouble() ?? 0) == 0,
        orElse: () => const {},
      );
      _defaultTaxId = exempt['id']?.toString();
    } catch (_) {
      _taxes = const [];
    }
  }

  Future<void> _runImport() async {
    final rows = _parsed?.rows ?? const <CatalogImportRow>[];
    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (rows.isEmpty || businessId == null || businessId.isEmpty) return;

    setState(() {
      _stage = _Stage.importing;
      _progressDone = 0;
      _progressTotal = rows.length;
    });

    final repo = CatalogImportRepository(Supabase.instance.client);
    try {
      final result = await repo.importRows(
        businessId: businessId,
        rows: rows,
        taxMode: _taxMode,
        defaultTaxId: _defaultTaxId,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _progressDone = done;
            _progressTotal = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _stage = _Stage.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Error durante el import: $e';
        _stage = _Stage.parsed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Importar catálogo'),
      content: SizedBox(width: 460, child: _buildBody()),
      actions: _buildActions(),
    );
  }

  Widget _buildBody() {
    switch (_stage) {
      case _Stage.idle:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Sube un archivo CSV o Excel con tus productos. Columnas '
              'reconocidas (en español o inglés):',
            ),
            const SizedBox(height: 8),
            const Text(
              '• nombre, precio (obligatorias)\n'
              '• costo, sku, barcode, categoria, impuesto (opcionales)',
              style: TextStyle(height: 1.4),
            ),
            const SizedBox(height: 12),
            const Text(
              'Se omiten productos cuyo SKU ya exista (puedes re-subir sin '
              'duplicar). Las categorías nuevas se crean automáticamente.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ],
        );
      case _Stage.parsed:
        final p = _parsed!;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Archivo: ${_fileName ?? ''}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('✓ ${p.rows.length} productos listos para importar'),
            if (p.errors.isNotEmpty)
              Text('⚠ ${p.errors.length} filas con error (se omiten)',
                  style: const TextStyle(color: Colors.orange)),
            const Divider(height: 24),
            const Text('Impuesto por defecto',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            DropdownButton<String?>(
              isExpanded: true,
              value: _defaultTaxId,
              hint: const Text('Sin impuesto'),
              items: [
                const DropdownMenuItem<String?>(
                    value: null, child: Text('Sin impuesto')),
                ..._taxes.map((t) => DropdownMenuItem<String?>(
                      value: t['id'].toString(),
                      child: Text(
                          '${t['name']} (${(t['rate'] as num?)?.toString() ?? '0'}%)'),
                    )),
              ],
              onChanged: (v) => setState(() => _defaultTaxId = v),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Precios incluyen impuesto'),
                const Spacer(),
                Switch(
                  value: _taxMode == 'inclusive',
                  onChanged: (v) =>
                      setState(() => _taxMode = v ? 'inclusive' : 'exclusive'),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ],
        );
      case _Stage.importing:
        final pct = _progressTotal == 0 ? 0.0 : _progressDone / _progressTotal;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            LinearProgressIndicator(value: pct),
            const SizedBox(height: 12),
            Text('Importando $_progressDone de $_progressTotal…'),
          ],
        );
      case _Stage.done:
        final r = _result!;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('✓ ${r.created} productos importados',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, color: Colors.green)),
            if (r.categoriesCreated > 0)
              Text('• ${r.categoriesCreated} categorías nuevas'),
            if (r.skipped > 0)
              Text('• ${r.skipped} omitidos (SKU ya existía)'),
            if (r.failed > 0)
              Text('• ${r.failed} con error',
                  style: const TextStyle(color: Colors.red)),
            if (r.errors.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('Errores:',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              ...r.errors.take(5).map((e) => Text('• $e',
                  style: const TextStyle(fontSize: 11, color: Colors.black54))),
            ],
          ],
        );
    }
  }

  List<Widget> _buildActions() {
    switch (_stage) {
      case _Stage.idle:
        return [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancelar')),
          FilledButton.icon(
              onPressed: _pickFile,
              icon: const Icon(Icons.upload_file),
              label: const Text('Seleccionar archivo')),
        ];
      case _Stage.parsed:
        final count = _parsed?.rows.length ?? 0;
        return [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: count == 0 ? null : _runImport,
              child: Text('Importar $count')),
        ];
      case _Stage.importing:
        return const [
          TextButton(onPressed: null, child: Text('Importando…')),
        ];
      case _Stage.done:
        return [
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Listo')),
        ];
    }
  }
}
