// Catálogo de columnas del reporte tabular personalizable.
//
// Regla dura: las columnas salen SOLO de lo que el sistema ya devuelve. El
// contrato común de todos los desgloses es `SalesBreakdownRow {label, amount,
// count, quantity}`; todo lo demás se deriva de esos cuatro campos o es propio
// de un reporte que sí trae forma propia (`ProductSalesReportRow`, el detalle
// de comprobantes fiscales). Cada columna declara su `source` para que el
// panel muestre de dónde sale cada número y nadie pida una que no existe.

import 'package:intl/intl.dart';

import '../../../core/fiscal/ncf_types.dart';
import '../viewmodel/reports_viewmodel.dart';
import '../widgets/fiscal_documents_detail_card.dart'
    show FiscalDocumentsDetailCard;

/// Tipo de dato: decide alineación, formato y cómo viaja al export.
enum ReportColumnKind { text, integer, decimal, money, percent, date, status }

/// Cómo se totaliza la columna. Nunca una suma ciega.
enum ReportColumnTotal {
  /// Σ de las filas válidas (monto, conteo, cantidad, campos sumables).
  sum,

  /// Σ numerador ÷ Σ denominador × 100 (margen). No promedio de promedios.
  weighted,

  /// Participación: 100.0 % en el total; en el subtotal, Σ de la del bloque.
  share,

  /// % acumulado: 100.0 % en el total; en blanco en el subtotal.
  cumulativeShare,

  /// En blanco: tasas, posición, acumulados y texto.
  none,
}

/// De dónde sale la columna. Agrupa la lista "Disponibles" del panel.
enum ReportColumnOrigin { system, derived, product, document }

/// Color condicional de la cifra (regla 6).
enum ReportCellTone {
  none,

  /// Verde si ≥ 0, rojo si < 0 (ganancia, margen).
  signed,

  /// Ámbar solo cuando hay monto (descuentos, cortesías).
  cautionWhenPositive,
}

enum ReportDensity { comfortable, compact }

extension ReportColumnOriginLabel on ReportColumnOrigin {
  String get label => switch (this) {
        ReportColumnOrigin.system => 'Campos del sistema',
        ReportColumnOrigin.derived => 'Calculadas',
        ReportColumnOrigin.product => 'Solo en Ventas por producto',
        ReportColumnOrigin.document => 'Del comprobante',
      };
}

extension ReportColumnKindX on ReportColumnKind {
  bool get isNumeric => switch (this) {
        ReportColumnKind.integer ||
        ReportColumnKind.decimal ||
        ReportColumnKind.money ||
        ReportColumnKind.percent =>
          true,
        _ => false,
      };
}

/// Una fila cruda del reporte, ya mapeada a claves de campo (no de columna).
class ReportRecord {
  const ReportRecord(this.values, {this.excluded = false});

  final Map<String, Object?> values;

  /// Se lista pero no suma (comprobante anulado).
  final bool excluded;

  Object? operator [](String field) => values[field];

  double? number(String field) => (values[field] as num?)?.toDouble();
}

/// Lo que una columna calculada necesita saber de la tabla para su valor.
class ReportValueContext {
  const ReportValueContext({
    required this.shareBase,
    this.position = 0,
    this.cumulative = 0,
  });

  /// Σ del campo de participación sobre las filas válidas.
  final double shareBase;

  /// Posición 1-based en el orden actual (0 mientras se ordena).
  final int position;

  /// Σ del campo de participación hasta esta fila, inclusive.
  final double cumulative;
}

typedef ReportValueFn = Object? Function(
    ReportRecord record, ReportValueContext context);

class ReportColumn {
  const ReportColumn({
    required this.id,
    required this.label,
    required this.description,
    required this.source,
    required this.kind,
    required this.origin,
    required this.value,
    this.total = ReportColumnTotal.none,
    this.locked = false,
    this.tone = ReportCellTone.none,
    this.groupable = false,
    this.positional = false,
    this.minWidth,
    this.ratioOf,
  });

  final String id;
  final String label;
  final String description;

  /// Campo o fórmula de origen, en monoespaciada en el panel.
  final String source;
  final ReportColumnKind kind;
  final ReportColumnOrigin origin;
  final ReportValueFn value;
  final ReportColumnTotal total;

  /// No se puede quitar (el eje).
  final bool locked;
  final ReportCellTone tone;

  /// Se puede agrupar por ella cuando está visible.
  final bool groupable;

  /// Depende del orden de las filas (#, acumulados): se calcula después de
  /// ordenar y por eso no se puede ordenar por ella.
  final bool positional;

  /// Piso de ancho propio (p. ej. la columna `#`).
  final double? minWidth;

  /// Campos del total ponderado (solo con [ReportColumnTotal.weighted]).
  final ({String numerator, String denominator})? ratioOf;

  bool get sortable => !positional;
}

/// Configuración de la tabla que el usuario modifica y guarda. Nunca incluye
/// el rango de fechas: ese siempre se elige en la barra.
class ReportViewConfig {
  const ReportViewConfig({
    required this.columns,
    this.sortColumn,
    this.sortAscending = false,
    this.groupBy,
    this.density = ReportDensity.comfortable,
  });

  /// Columnas visibles, en orden.
  final List<String> columns;
  final String? sortColumn;
  final bool sortAscending;
  final String? groupBy;
  final ReportDensity density;

  ReportViewConfig copyWith({
    List<String>? columns,
    String? sortColumn,
    bool? sortAscending,
    String? groupBy,
    ReportDensity? density,
    bool clearSort = false,
    bool clearGroup = false,
  }) {
    return ReportViewConfig(
      columns: columns ?? this.columns,
      sortColumn: clearSort ? null : (sortColumn ?? this.sortColumn),
      sortAscending: sortAscending ?? this.sortAscending,
      groupBy: clearGroup ? null : (groupBy ?? this.groupBy),
      density: density ?? this.density,
    );
  }

  /// Deja la configuración válida para [definition]: descarta columnas que ya
  /// no existen (un impuesto que dejó de aparecer, una vista guardada vieja),
  /// garantiza las bloqueadas, y suelta orden/agrupación que apunten a una
  /// columna no visible.
  ReportViewConfig normalizedFor(ReportDefinition definition) {
    final seen = <String>{};
    final visible = <String>[
      for (final id in columns)
        if (definition.column(id) != null && seen.add(id)) id,
    ];
    for (final column in definition.columns.reversed) {
      if (column.locked && !seen.contains(column.id)) {
        visible.insert(0, column.id);
        seen.add(column.id);
      }
    }
    final sort = sortColumn == null ? null : definition.column(sortColumn!);
    final keepSort = sort != null && sort.sortable && seen.contains(sort.id);
    final group = groupBy == null ? null : definition.column(groupBy!);
    final keepGroup =
        group != null && group.groupable && seen.contains(group.id);
    return ReportViewConfig(
      columns: List.unmodifiable(visible),
      sortColumn: keepSort ? sortColumn : null,
      sortAscending: keepSort ? sortAscending : false,
      groupBy: keepGroup ? groupBy : null,
      density: density,
    );
  }

  /// Igualdad de lo que define la vista (columnas, orden y agrupación). La
  /// densidad viaja con la vista guardada pero no la "modifica".
  bool sameLayoutAs(ReportViewConfig other) {
    if (columns.length != other.columns.length) return false;
    for (var i = 0; i < columns.length; i++) {
      if (columns[i] != other.columns[i]) return false;
    }
    return sortColumn == other.sortColumn &&
        (sortColumn == null || sortAscending == other.sortAscending) &&
        groupBy == other.groupBy;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'columns': columns,
        if (sortColumn != null) 'sort': sortColumn,
        if (sortColumn != null) 'asc': sortAscending,
        if (groupBy != null) 'group': groupBy,
        'density': density.name,
      };

  static ReportViewConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final columns = raw['columns'];
    if (columns is! List) return null;
    return ReportViewConfig(
      columns: columns.map((c) => c.toString()).toList(growable: false),
      sortColumn: raw['sort']?.toString(),
      sortAscending: raw['asc'] == true,
      groupBy: raw['group']?.toString(),
      density: raw['density'] == ReportDensity.compact.name
          ? ReportDensity.compact
          : ReportDensity.comfortable,
    );
  }
}

/// Vista predefinida (Por defecto, Pareto, …).
class ReportViewPreset {
  const ReportViewPreset({
    required this.id,
    required this.label,
    required this.config,
  });

  final String id;
  final String label;
  final ReportViewConfig config;
}

class ReportDefinition {
  ReportDefinition({
    required this.key,
    required this.title,
    required this.source,
    required this.columns,
    required this.presets,
    required this.shareField,
    required this.catalogNote,
    required this.totalLabel,
  }) : _byId = {for (final c in columns) c.id: c};

  /// Clave estable para vistas guardadas: `sales.byCategory`, …
  final String key;
  final String title;

  /// Función de origen (`getCategoryRows()`).
  final String source;

  /// Catálogo completo, en el orden de la vista "Completa".
  final List<ReportColumn> columns;

  /// La primera es la vista por defecto.
  final List<ReportViewPreset> presets;

  /// Campo base de participación y acumulados (`amount` o `total`).
  final String shareField;

  /// Nota al pie del panel: por qué el catálogo es ese y no más.
  final String catalogNote;

  /// Rótulo de la fila de total según cuántas filas válidas suma.
  final String Function(int validRows) totalLabel;

  final Map<String, ReportColumn> _byId;

  ReportColumn? column(String id) => _byId[id];

  ReportViewConfig get defaultConfig => presets.first.config;

  ReportViewPreset? preset(String id) {
    for (final preset in presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }
}

/// Rótulos de un desglose (tomados de `sales_report_view.dart`).
class BreakdownLabels {
  const BreakdownLabels({
    required this.axis,
    required this.count,
    required this.amount,
    required this.unit,
    required this.showQuantity,
  });

  final String axis;
  final String count;
  final String amount;

  /// Unidad del conteo en singular, para los derivados: "ticket", "orden".
  final String unit;

  /// False donde el reporte no devuelve cantidad: se muestra guion.
  final bool showQuantity;
}

/// Ids de columnas. Públicos para vistas, pruebas y exports.
abstract final class ReportColumnIds {
  static const position = 'position';
  static const label = 'label';
  static const quantity = 'quantity';
  static const count = 'count';
  static const amount = 'amount';
  static const share = 'share';
  static const amountPerCount = 'amount_per_count';
  static const amountPerUnit = 'amount_per_unit';
  static const cumulative = 'cumulative';
  static const cumulativeShare = 'cumulative_share';
  static const quantityPerCount = 'quantity_per_count';

  // Ventas por producto.
  static const category = 'category';
  static const projectedQuantity = 'projected_quantity';
  static const grossSales = 'gross_sales';
  static const discounts = 'discounts';
  static const courtesies = 'courtesies';
  static const cost = 'cost';
  static const grossProfit = 'gross_profit';
  static const marginPct = 'margin_pct';

  // Detalle por comprobante.
  static const issuedAt = 'issued_at';
  static const ncfNumber = 'ncf_number';
  static const ncfType = 'ncf_type';
  static const customerName = 'customer_name';
  static const customerRnc = 'customer_rnc';
  static const subtotal = 'subtotal';
  static const serviceFee = 'service_fee';
  static const total = 'total';
  static const status = 'status';
  static const taxPrefix = 'tax:';
}

double? _ratio(double? numerator, double? denominator) {
  if (numerator == null || denominator == null || denominator == 0) {
    return null;
  }
  return numerator / denominator;
}

abstract final class ReportCatalog {
  static const String _systemRow = 'SalesBreakdownRow';
  static const String _productRow = 'ProductSalesReportRow';

  /// Columnas calculadas: se derivan de `amount`, `count` y `quantity`, cero
  /// cambios en la consulta. [shareField] es el monto base de participación.
  static List<ReportColumn> _derivedColumns({
    required String amountLabel,
    required String unit,
    String shareField = ReportColumnIds.amount,
    String shareSource = 'amount',
    bool includeRates = true,
  }) {
    return [
      ReportColumn(
        id: ReportColumnIds.share,
        label: '% del total',
        description: 'Qué parte del total representa la fila.',
        source: '$shareSource ÷ Σ $shareSource',
        kind: ReportColumnKind.percent,
        origin: ReportColumnOrigin.derived,
        total: ReportColumnTotal.share,
        value: (r, c) {
          if (r.excluded || c.shareBase == 0) return null;
          final v = r.number(shareField);
          return v == null ? null : v / c.shareBase * 100;
        },
      ),
      if (includeRates) ...[
        ReportColumn(
          id: ReportColumnIds.amountPerCount,
          label: '$amountLabel por $unit',
          description: 'Promedio de ${amountLabel.toLowerCase()} por $unit.',
          source: 'amount ÷ count',
          kind: ReportColumnKind.money,
          origin: ReportColumnOrigin.derived,
          value: (r, _) => _ratio(
              r.number(ReportColumnIds.amount), r.number(ReportColumnIds.count)),
        ),
        ReportColumn(
          id: ReportColumnIds.amountPerUnit,
          label: '$amountLabel por unidad',
          description: 'Precio promedio de cada unidad.',
          source: 'amount ÷ quantity',
          kind: ReportColumnKind.money,
          origin: ReportColumnOrigin.derived,
          value: (r, _) => _ratio(r.number(ReportColumnIds.amount),
              r.number(ReportColumnIds.quantity)),
        ),
        ReportColumn(
          id: ReportColumnIds.quantityPerCount,
          label: 'Cantidad por $unit',
          description: 'Unidades promedio por $unit.',
          source: 'quantity ÷ count',
          kind: ReportColumnKind.decimal,
          origin: ReportColumnOrigin.derived,
          value: (r, _) => _ratio(r.number(ReportColumnIds.quantity),
              r.number(ReportColumnIds.count)),
        ),
        ReportColumn(
          id: ReportColumnIds.cumulative,
          label: 'Acumulado',
          description: 'Suma del monto desde la primera fila hasta esta.',
          source: 'Σ $shareSource hasta la fila',
          kind: ReportColumnKind.money,
          origin: ReportColumnOrigin.derived,
          positional: true,
          value: (r, c) => r.excluded ? null : c.cumulative,
        ),
      ],
      ReportColumn(
        id: ReportColumnIds.cumulativeShare,
        label: '% acumulado',
        description: 'Lectura Pareto: cuánto del total llevas hasta la fila.',
        source: 'Σ share hasta la fila',
        kind: ReportColumnKind.percent,
        origin: ReportColumnOrigin.derived,
        total: ReportColumnTotal.cumulativeShare,
        positional: true,
        value: (r, c) => r.excluded || c.shareBase == 0
            ? null
            : c.cumulative / c.shareBase * 100,
      ),
    ];
  }

  static ReportColumn _positionColumn() => ReportColumn(
        id: ReportColumnIds.position,
        label: '#',
        description: 'Posición de la fila en el orden actual.',
        source: 'posición en el orden actual',
        kind: ReportColumnKind.integer,
        origin: ReportColumnOrigin.derived,
        positional: true,
        minWidth: 64,
        value: (_, c) => c.position,
      );

  static List<ReportColumn> _systemColumns({
    required BreakdownLabels labels,
    required String rowType,
    String labelField = 'label',
    String amountField = 'amount',
    String countField = 'count',
    String quantityField = 'quantity',
  }) {
    return [
      ReportColumn(
        id: ReportColumnIds.label,
        label: labels.axis,
        description: 'Eje del reporte. Siempre visible.',
        source: '$rowType.$labelField',
        kind: ReportColumnKind.text,
        origin: ReportColumnOrigin.system,
        locked: true,
        value: (r, _) => r[ReportColumnIds.label],
      ),
      ReportColumn(
        id: ReportColumnIds.quantity,
        label: 'Cantidad',
        description: labels.showQuantity
            ? 'Unidades del rango.'
            : 'Este reporte no devuelve cantidad: se muestra guion.',
        source: '$rowType.$quantityField',
        kind: ReportColumnKind.decimal,
        origin: ReportColumnOrigin.system,
        total: ReportColumnTotal.sum,
        value: (r, _) => r[ReportColumnIds.quantity],
      ),
      ReportColumn(
        id: ReportColumnIds.count,
        label: labels.count,
        description: '${labels.count} registrados en el rango.',
        source: '$rowType.$countField',
        kind: ReportColumnKind.integer,
        origin: ReportColumnOrigin.system,
        total: ReportColumnTotal.sum,
        value: (r, _) => r[ReportColumnIds.count],
      ),
      ReportColumn(
        id: ReportColumnIds.amount,
        label: labels.amount,
        description: 'Total en dinero (${labels.amount}).',
        source: '$rowType.$amountField',
        kind: ReportColumnKind.money,
        origin: ReportColumnOrigin.system,
        total: ReportColumnTotal.sum,
        value: (r, _) => r[ReportColumnIds.amount],
      ),
    ];
  }

  static const _breakdownNote =
      'Estas columnas salen de lo que el reporte ya devuelve: '
      'SalesBreakdownRow { label, amount, count, quantity }. Las calculadas '
      'se derivan de esos cuatro campos. Costo, ITBIS o margen por fila no '
      'existen en este desglose; agregarlos exige extender la consulta.';

  /// Los diez desgloses que devuelven `SalesBreakdownRow`.
  static ReportDefinition breakdown({
    required String key,
    required String title,
    required String source,
    required BreakdownLabels labels,
  }) {
    final system =
        _systemColumns(labels: labels, rowType: _systemRow);
    final derived =
        _derivedColumns(amountLabel: labels.amount, unit: labels.unit);
    final columns = <ReportColumn>[_positionColumn(), ...system, ...derived];
    const axis = ReportColumnIds.label;
    return ReportDefinition(
      key: key,
      title: title,
      source: source,
      columns: columns,
      shareField: ReportColumnIds.amount,
      catalogNote: _breakdownNote,
      totalLabel: (_) => 'Total',
      presets: [
        const ReportViewPreset(
          id: 'default',
          label: 'Por defecto',
          config: ReportViewConfig(columns: [
            axis,
            ReportColumnIds.quantity,
            ReportColumnIds.count,
            ReportColumnIds.amount,
          ]),
        ),
        ReportViewPreset(
          id: 'share',
          label: 'Con participación',
          config: ReportViewConfig(columns: [
            axis,
            if (labels.showQuantity) ReportColumnIds.quantity,
            ReportColumnIds.count,
            ReportColumnIds.amount,
            ReportColumnIds.share,
          ]),
        ),
        const ReportViewPreset(
          id: 'pareto',
          label: 'Pareto',
          config: ReportViewConfig(
            columns: [
              ReportColumnIds.position,
              axis,
              ReportColumnIds.amount,
              ReportColumnIds.share,
              ReportColumnIds.cumulative,
              ReportColumnIds.cumulativeShare,
            ],
            sortColumn: ReportColumnIds.amount,
          ),
        ),
        ReportViewPreset(
          id: 'averages',
          label: 'Promedios',
          config: ReportViewConfig(columns: [
            axis,
            ReportColumnIds.count,
            ReportColumnIds.amount,
            ReportColumnIds.amountPerCount,
            if (labels.showQuantity) ...[
              ReportColumnIds.amountPerUnit,
              ReportColumnIds.quantityPerCount,
            ],
          ]),
        ),
        ReportViewPreset(
          id: 'full',
          label: 'Completa',
          config: ReportViewConfig(
            columns: [for (final c in columns) c.id],
          ),
        ),
      ],
    );
  }

  /// Ventas por producto: el contrato común + sus ocho campos propios.
  static ReportDefinition productSales() {
    const labels = BreakdownLabels(
      axis: 'Producto',
      count: 'Tickets',
      amount: 'Netas',
      unit: 'ticket',
      showQuantity: true,
    );
    final system = _systemColumns(
      labels: labels,
      rowType: _productRow,
      labelField: 'product',
      amountField: 'netSales',
      countField: 'tickets',
      quantityField: 'quantitySold',
    );
    ReportColumn money(
      String id,
      String label,
      String description,
      String field, {
      ReportCellTone tone = ReportCellTone.none,
    }) =>
        ReportColumn(
          id: id,
          label: label,
          description: description,
          source: '$_productRow.$field',
          kind: ReportColumnKind.money,
          origin: ReportColumnOrigin.product,
          total: ReportColumnTotal.sum,
          tone: tone,
          value: (r, _) => r[id],
        );
    final product = <ReportColumn>[
      ReportColumn(
        id: ReportColumnIds.category,
        label: 'Categoría',
        description: 'Categoría del producto. Se puede agrupar por ella.',
        source: '$_productRow.category',
        kind: ReportColumnKind.text,
        origin: ReportColumnOrigin.product,
        groupable: true,
        value: (r, _) => r[ReportColumnIds.category],
      ),
      ReportColumn(
        id: ReportColumnIds.projectedQuantity,
        label: 'Proy. mes',
        description: 'Unidades proyectadas para el mes.',
        source: '$_productRow.projectedQuantity',
        kind: ReportColumnKind.decimal,
        origin: ReportColumnOrigin.product,
        total: ReportColumnTotal.sum,
        value: (r, _) => r[ReportColumnIds.projectedQuantity],
      ),
      money(ReportColumnIds.grossSales, 'Brutas',
          'Ventas antes de descuentos y cortesías.', 'grossSales'),
      money(ReportColumnIds.discounts, 'Descuentos', 'Descuentos aplicados.',
          'discounts',
          tone: ReportCellTone.cautionWhenPositive),
      money(ReportColumnIds.courtesies, 'Cortesías', 'Cortesías concedidas.',
          'courtesies',
          tone: ReportCellTone.cautionWhenPositive),
      money(ReportColumnIds.cost, 'Costo', 'Costo del producto vendido.',
          'cost'),
      money(ReportColumnIds.grossProfit, 'Gan. bruta', 'Netas menos costo.',
          'grossProfit',
          tone: ReportCellTone.signed),
      ReportColumn(
        id: ReportColumnIds.marginPct,
        label: 'Margen %',
        description: 'Ganancia ÷ netas. El total es ponderado.',
        source: '$_productRow.marginPct',
        kind: ReportColumnKind.percent,
        origin: ReportColumnOrigin.product,
        total: ReportColumnTotal.weighted,
        tone: ReportCellTone.signed,
        ratioOf: (
          numerator: ReportColumnIds.grossProfit,
          denominator: ReportColumnIds.amount,
        ),
        value: (r, _) => r[ReportColumnIds.marginPct],
      ),
    ];
    final derived =
        _derivedColumns(amountLabel: labels.amount, unit: labels.unit);
    final columns = <ReportColumn>[
      _positionColumn(),
      system[0],
      product[0],
      system[1],
      product[1],
      product[2],
      product[3],
      product[4],
      system[3],
      product[5],
      product[6],
      product[7],
      system[2],
      ...derived,
    ];
    return ReportDefinition(
      key: 'sales.byProduct',
      title: 'Ventas por producto',
      source: 'getFilteredProductSalesRows()',
      columns: columns,
      shareField: ReportColumnIds.amount,
      catalogNote:
          'Ventas por producto devuelve ProductSalesReportRow: el contrato '
          'común (producto, cantidad, tickets, netas) más ocho campos propios '
          'que solo existen en este reporte. Las calculadas se derivan de esos '
          'campos, sin cambiar la consulta.',
      totalLabel: (_) => 'Total',
      presets: [
        const ReportViewPreset(
          id: 'default',
          label: 'Por defecto',
          config: ReportViewConfig(columns: [
            ReportColumnIds.label,
            ReportColumnIds.category,
            ReportColumnIds.quantity,
            ReportColumnIds.projectedQuantity,
            ReportColumnIds.grossSales,
            ReportColumnIds.discounts,
            ReportColumnIds.courtesies,
            ReportColumnIds.amount,
            ReportColumnIds.cost,
            ReportColumnIds.grossProfit,
            ReportColumnIds.marginPct,
          ]),
        ),
        const ReportViewPreset(
          id: 'share',
          label: 'Con participación',
          config: ReportViewConfig(columns: [
            ReportColumnIds.label,
            ReportColumnIds.quantity,
            ReportColumnIds.count,
            ReportColumnIds.amount,
            ReportColumnIds.share,
          ]),
        ),
        const ReportViewPreset(
          id: 'pareto',
          label: 'Pareto',
          config: ReportViewConfig(
            columns: [
              ReportColumnIds.position,
              ReportColumnIds.label,
              ReportColumnIds.amount,
              ReportColumnIds.share,
              ReportColumnIds.cumulative,
              ReportColumnIds.cumulativeShare,
            ],
            sortColumn: ReportColumnIds.amount,
          ),
        ),
        const ReportViewPreset(
          id: 'averages',
          label: 'Promedios',
          config: ReportViewConfig(columns: [
            ReportColumnIds.label,
            ReportColumnIds.count,
            ReportColumnIds.amount,
            ReportColumnIds.amountPerCount,
            ReportColumnIds.amountPerUnit,
            ReportColumnIds.quantityPerCount,
          ]),
        ),
        const ReportViewPreset(
          id: 'profitability',
          label: 'Rentabilidad',
          config: ReportViewConfig(
            columns: [
              ReportColumnIds.label,
              ReportColumnIds.category,
              ReportColumnIds.amount,
              ReportColumnIds.cost,
              ReportColumnIds.grossProfit,
              ReportColumnIds.marginPct,
            ],
            sortColumn: ReportColumnIds.grossProfit,
          ),
        ),
        ReportViewPreset(
          id: 'full',
          label: 'Completa',
          config: ReportViewConfig(
            columns: [for (final c in columns) c.id],
          ),
        ),
      ],
    );
  }

  /// Segundo nivel del reporte por comprobante: un documento por fila. Los
  /// impuestos salen de `tax_breakdown[]`, una columna por impuesto presente.
  static ReportDefinition fiscalDocuments({
    required List<String> taxLabels,
    required String serviceFeeLabel,
    required bool hasServiceFee,
  }) {
    ReportColumn text(String id, String label, String description,
            {bool locked = false, bool groupable = false}) =>
        ReportColumn(
          id: id,
          label: label,
          description: description,
          source: 'doc.$id',
          kind: ReportColumnKind.text,
          origin: ReportColumnOrigin.document,
          locked: locked,
          groupable: groupable,
          value: (r, _) => r[id],
        );
    ReportColumn money(String id, String label, String description,
            String source) =>
        ReportColumn(
          id: id,
          label: label,
          description: description,
          source: source,
          kind: ReportColumnKind.money,
          origin: ReportColumnOrigin.document,
          total: ReportColumnTotal.sum,
          value: (r, _) => r[id],
        );

    final taxColumns = [
      for (final tax in taxLabels)
        money('${ReportColumnIds.taxPrefix}$tax', tax,
            'Impuesto $tax del comprobante.', 'doc.tax_breakdown[].tax_amount'),
    ];
    final ncf = text(ReportColumnIds.ncfNumber, 'NCF',
        'Número de comprobante fiscal. Siempre visible.',
        locked: true);
    final type = text(ReportColumnIds.ncfType, 'Tipo',
        'Tipo de comprobante. Se puede agrupar por él.',
        groupable: true);
    final customer = text(ReportColumnIds.customerName, 'Cliente',
        'Nombre del cliente o CONSUMIDOR FINAL.');
    final rnc = text(ReportColumnIds.customerRnc, 'RNC/Cédula',
        'Identificación fiscal del cliente.');
    final subtotal = money(ReportColumnIds.subtotal, 'Subtotal',
        'Monto antes de impuestos.', 'doc.subtotal');
    final serviceFee = money(ReportColumnIds.serviceFee, serviceFeeLabel,
        'Cargo de servicio del comprobante.', 'doc.service_fee');
    final total = money(ReportColumnIds.total, 'Total',
        'Total facturado. Los anulados no suman.', 'doc.total');
    final status = ReportColumn(
      id: ReportColumnIds.status,
      label: 'Estado',
      description: 'Activo o Anulado. Los anulados se listan pero no suman.',
      source: 'doc.status',
      kind: ReportColumnKind.status,
      origin: ReportColumnOrigin.document,
      value: (r, _) => r[ReportColumnIds.status],
    );
    final issuedAt = ReportColumn(
      id: ReportColumnIds.issuedAt,
      label: 'Fecha',
      description: 'Fecha y hora de emisión.',
      source: 'doc.issued_at',
      kind: ReportColumnKind.date,
      origin: ReportColumnOrigin.document,
      value: (r, _) => r[ReportColumnIds.issuedAt],
    );
    final share = _derivedColumns(
      amountLabel: 'Total',
      unit: 'documento',
      shareField: ReportColumnIds.total,
      shareSource: 'total',
      includeRates: false,
    ).first;

    final columns = <ReportColumn>[
      _positionColumn(),
      ncf,
      type,
      customer,
      rnc,
      subtotal,
      ...taxColumns,
      serviceFee,
      total,
      share,
      status,
      issuedAt,
    ];
    final taxIds = [for (final c in taxColumns) c.id];
    return ReportDefinition(
      key: 'sales.byReceipt.documents',
      title: 'Detalle por comprobante',
      source: 'getVisibleFiscalDocuments()',
      columns: columns,
      shareField: ReportColumnIds.total,
      catalogNote:
          'Cada columna es un campo del comprobante fiscal tal como lo '
          'devuelve el reporte (issued_at, ncf_number, ncf_type, '
          'customer_name, customer_rnc, subtotal, tax_breakdown[], '
          'service_fee, total, status), más su % del total. Los anulados se '
          'listan pero no suman.',
      totalLabel: (valid) => valid == 1
          ? 'Total de 1 documento válido'
          : 'Total de $valid documentos válidos',
      presets: [
        ReportViewPreset(
          id: 'default',
          label: 'Por defecto',
          config: ReportViewConfig(columns: [
            ReportColumnIds.ncfNumber,
            ReportColumnIds.ncfType,
            ReportColumnIds.customerName,
            ReportColumnIds.customerRnc,
            ReportColumnIds.subtotal,
            ...taxIds,
            if (hasServiceFee) ReportColumnIds.serviceFee,
            ReportColumnIds.total,
            ReportColumnIds.status,
            ReportColumnIds.issuedAt,
          ]),
        ),
        ReportViewPreset(
          id: 'accountant',
          label: 'Para el contador',
          // Orden de los formatos 606/607: identificación, comprobante,
          // fecha y montos.
          config: ReportViewConfig(
            columns: [
              ReportColumnIds.customerRnc,
              ReportColumnIds.ncfNumber,
              ReportColumnIds.ncfType,
              ReportColumnIds.issuedAt,
              ReportColumnIds.subtotal,
              ...taxIds,
              if (hasServiceFee) ReportColumnIds.serviceFee,
              ReportColumnIds.total,
              ReportColumnIds.status,
            ],
            sortColumn: ReportColumnIds.issuedAt,
            sortAscending: true,
          ),
        ),
        ReportViewPreset(
          id: 'full',
          label: 'Completa',
          config: ReportViewConfig(
            columns: [for (final c in columns) c.id],
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Registros: del contrato del viewmodel a claves de campo.
  // -------------------------------------------------------------------------

  static ReportRecord breakdownRecord(
    SalesBreakdownRow row, {
    required bool showQuantity,
  }) {
    return ReportRecord({
      ReportColumnIds.label: row.label,
      // Guion, no cero: donde el reporte no devuelve cantidad, el dato no
      // existe (y sus derivadas tampoco).
      ReportColumnIds.quantity: showQuantity ? row.quantity : null,
      ReportColumnIds.count: row.count,
      ReportColumnIds.amount: row.amount,
    });
  }

  static ReportRecord productRecord(ProductSalesReportRow row) {
    return ReportRecord({
      ReportColumnIds.label: row.product,
      ReportColumnIds.category: row.category,
      ReportColumnIds.quantity: row.quantitySold,
      // Sin proyección para el producto → guion (igual que la tabla previa).
      ReportColumnIds.projectedQuantity:
          row.projectedQuantity > 0 ? row.projectedQuantity : null,
      ReportColumnIds.grossSales: row.grossSales,
      ReportColumnIds.discounts: row.discounts,
      ReportColumnIds.courtesies: row.courtesies,
      ReportColumnIds.amount: row.netSales,
      ReportColumnIds.cost: row.cost,
      ReportColumnIds.grossProfit: row.grossProfit,
      ReportColumnIds.marginPct: row.marginPct,
      ReportColumnIds.count: row.tickets,
    });
  }

  /// Etiquetas de impuesto del conjunto, SIN el cargo de servicio (que va en
  /// su propia columna).
  static List<String> documentTaxLabels(
    List<Map<String, dynamic>> documents,
    String serviceFeeLabel,
  ) {
    return FiscalDocumentsDetailCard.collectTaxLabels(
            documents, serviceFeeLabel)
        .where((label) => label != serviceFeeLabel)
        .toList(growable: false);
  }

  static bool documentsHaveServiceFee(List<Map<String, dynamic>> documents) =>
      documents
          .any((doc) => ((doc['service_fee'] as num?)?.toDouble() ?? 0) > 0);

  static ReportRecord documentRecord(
    Map<String, dynamic> doc, {
    required List<String> taxLabels,
    required String serviceFeeLabel,
  }) {
    final voided = ReportsViewModel.isVoidedFiscalDocument(doc);
    final issuedAt = DateTime.tryParse(doc['issued_at']?.toString() ?? '');
    final rnc = doc['customer_rnc']?.toString().trim() ?? '';
    final serviceFee = (doc['service_fee'] as num?)?.toDouble() ?? 0;
    return ReportRecord(
      {
        ReportColumnIds.ncfNumber: doc['ncf_number']?.toString() ?? '',
        ReportColumnIds.ncfType: ncfTypeName(doc['ncf_type']?.toString()),
        ReportColumnIds.customerName:
            doc['customer_name']?.toString() ?? 'CONSUMIDOR FINAL',
        ReportColumnIds.customerRnc: rnc.isEmpty ? null : rnc,
        ReportColumnIds.subtotal: (doc['subtotal'] as num?)?.toDouble() ?? 0,
        for (final tax in taxLabels)
          '${ReportColumnIds.taxPrefix}$tax': () {
            final amount = FiscalDocumentsDetailCard.taxAmountForLabel(
                doc, tax, serviceFeeLabel);
            // Sin ese impuesto en el comprobante: el dato no existe → guion.
            return amount > 0 ? amount : null;
          }(),
        ReportColumnIds.serviceFee: serviceFee > 0 ? serviceFee : null,
        ReportColumnIds.total: (doc['total'] as num?)?.toDouble() ?? 0,
        ReportColumnIds.status: voided ? 'Anulado' : 'Activo',
        ReportColumnIds.issuedAt: issuedAt?.toLocal(),
      },
      excluded: voided,
    );
  }
}

/// Formatos de celda. La moneda viene del negocio (`state.currency`).
class ReportFormats {
  ReportFormats({required this.currency});

  final NumberFormat currency;
  final NumberFormat integer = NumberFormat('#,##0', 'en_US');
  final NumberFormat decimal = NumberFormat('#,##0.##', 'en_US');
  final NumberFormat percent = NumberFormat('#,##0.0', 'en_US');
  final DateFormat date = DateFormat('dd/MM/yyyy hh:mm a');

  /// Guion cuando el dato no existe. Un cero es una afirmación falsa.
  static const String missing = '—';

  String format(ReportColumnKind kind, Object? value) {
    if (value == null) return missing;
    switch (kind) {
      case ReportColumnKind.text:
      case ReportColumnKind.status:
        return value.toString();
      case ReportColumnKind.integer:
        return integer.format(value as num);
      case ReportColumnKind.decimal:
        return decimal.format(value as num);
      case ReportColumnKind.money:
        return currency.format(value as num);
      case ReportColumnKind.percent:
        return '${percent.format(value as num)} %';
      case ReportColumnKind.date:
        return value is DateTime ? date.format(value) : value.toString();
    }
  }
}
