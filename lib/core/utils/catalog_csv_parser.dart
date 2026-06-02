// Parser de CSV para carga masiva de catálogo retail (RF-R11 / fase R3).
//
// Pura (sin IO ni red): recibe el texto del CSV y devuelve filas tipadas más
// los errores por fila. Headers flexibles en español/inglés. El delimitador se
// autodetecta entre coma y punto y coma (Excel en locales ES suele usar `;`).
//
// Idempotencia y persistencia NO viven aquí — eso lo hace CatalogImportRepository.

/// Una fila válida del CSV ya normalizada.
class CatalogImportRow {
  const CatalogImportRow({
    required this.lineNumber,
    required this.name,
    required this.price,
    this.cost,
    this.sku,
    this.barcode,
    this.category,
    this.tax,
  });

  /// Número de línea en el archivo (1-based, contando el header) para reportes.
  final int lineNumber;
  final String name;
  final double price;
  final double? cost;
  final String? sku;
  final String? barcode;
  final String? category;

  /// Nombre del impuesto tal como viene en el CSV (se resuelve contra los
  /// impuestos del negocio en el repo). Null = usar el impuesto por defecto.
  final String? tax;
}

/// Error de parseo de una fila (se omite de las filas válidas).
class CatalogImportRowError {
  const CatalogImportRowError(this.lineNumber, this.message);
  final int lineNumber;
  final String message;
}

class CatalogCsvParseResult {
  const CatalogCsvParseResult({required this.rows, required this.errors});
  final List<CatalogImportRow> rows;
  final List<CatalogImportRowError> errors;

  bool get isEmpty => rows.isEmpty;
  int get total => rows.length + errors.length;
}

class CatalogCsvParser {
  const CatalogCsvParser._();

  // Sinónimos aceptados por columna (lowercase, sin acentos).
  static const Map<String, List<String>> _aliases = {
    'name': ['name', 'nombre', 'descripcion', 'producto'],
    'price': ['price', 'precio', 'p.publico', 'p publico', 'precio publico'],
    'cost': ['cost', 'costo', 'p.compra', 'p compra', 'precio compra'],
    'sku': ['sku', 'codigo', 'cod', 'clave'],
    'barcode': ['barcode', 'codigo de barras', 'codigo barras', 'ean', 'upc'],
    'category': ['category', 'categoria', 'cat', 'rubro'],
    'tax': ['tax', 'impuesto', 'itbis', 'iva'],
  };

  /// Parsea [content] (texto del CSV completo, incluyendo header).
  static CatalogCsvParseResult parse(String content) {
    final lines = _splitLines(content);
    if (lines.isEmpty) {
      return const CatalogCsvParseResult(rows: [], errors: []);
    }
    final delimiter = _detectDelimiter(lines.first);
    final table = lines
        .map((line) => _splitFields(line, delimiter))
        .toList(growable: false);
    return fromRows(table);
  }

  /// Parsea una tabla ya tokenizada (primera fila = header). Compartido por el
  /// CSV ([parse]) y por el import de Excel (que convierte celdas a String).
  static CatalogCsvParseResult fromRows(List<List<String?>> table) {
    if (table.isEmpty) {
      return const CatalogCsvParseResult(rows: [], errors: []);
    }

    final header = table.first
        .map((h) => _normalizeHeader(h ?? ''))
        .toList(growable: false);

    final colIndex = <String, int>{};
    for (final entry in _aliases.entries) {
      final idx = header.indexWhere((h) => entry.value.contains(h));
      if (idx >= 0) colIndex[entry.key] = idx;
    }

    final rows = <CatalogImportRow>[];
    final errors = <CatalogImportRowError>[];

    if (!colIndex.containsKey('name') || !colIndex.containsKey('price')) {
      errors.add(const CatalogImportRowError(
        1,
        'El archivo debe tener al menos las columnas "nombre" y "precio".',
      ));
      return CatalogCsvParseResult(rows: rows, errors: errors);
    }

    for (var i = 1; i < table.length; i++) {
      final lineNumber = i + 1; // 1-based, header = línea 1
      final fields = table[i];
      if (fields.every((f) => (f ?? '').trim().isEmpty)) continue;

      String? at(String key) {
        final idx = colIndex[key];
        if (idx == null || idx >= fields.length) return null;
        final v = fields[idx]?.trim() ?? '';
        return v.isEmpty ? null : v;
      }

      final name = at('name');
      if (name == null) {
        errors.add(CatalogImportRowError(lineNumber, 'Falta el nombre.'));
        continue;
      }
      final priceRaw = at('price');
      final price = _parseNumber(priceRaw);
      if (price == null) {
        errors.add(CatalogImportRowError(
            lineNumber, 'Precio inválido: "${priceRaw ?? ''}".'));
        continue;
      }

      rows.add(CatalogImportRow(
        lineNumber: lineNumber,
        name: name,
        price: price,
        cost: _parseNumber(at('cost')),
        sku: at('sku'),
        barcode: at('barcode'),
        category: at('category'),
        tax: at('tax'),
      ));
    }

    return CatalogCsvParseResult(rows: rows, errors: errors);
  }

  static List<String> _splitLines(String content) {
    return content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .where((l) => l.isNotEmpty)
        .toList(growable: false);
  }

  static String _detectDelimiter(String headerLine) {
    final commas = ','.allMatches(headerLine).length;
    final semis = ';'.allMatches(headerLine).length;
    return semis > commas ? ';' : ',';
  }

  /// Split respetando comillas dobles (con escape "" → ").
  static List<String> _splitFields(String line, String delimiter) {
    final out = <String>[];
    final buffer = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          buffer.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == delimiter && !inQuotes) {
        out.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
    out.add(buffer.toString());
    return out;
  }

  static String _normalizeHeader(String raw) {
    var s = raw.trim().toLowerCase();
    // quitar comillas y acentos comunes
    s = s.replaceAll('"', '');
    const accents = {
      'á': 'a',
      'é': 'e',
      'í': 'i',
      'ó': 'o',
      'ú': 'u',
      'ñ': 'n',
    };
    accents.forEach((k, v) => s = s.replaceAll(k, v));
    return s;
  }

  /// Parsea un número tolerando separador de miles y coma decimal.
  static double? _parseNumber(String? raw) {
    if (raw == null) return null;
    var s = raw.trim().replaceAll(RegExp(r'[^0-9.,-]'), '');
    if (s.isEmpty) return null;
    final hasComma = s.contains(',');
    final hasDot = s.contains('.');
    if (hasComma && hasDot) {
      // El último separador es el decimal; el otro es de miles.
      if (s.lastIndexOf(',') > s.lastIndexOf('.')) {
        s = s.replaceAll('.', '').replaceAll(',', '.');
      } else {
        s = s.replaceAll(',', '');
      }
    } else if (hasComma) {
      s = s.replaceAll(',', '.');
    }
    return double.tryParse(s);
  }
}
