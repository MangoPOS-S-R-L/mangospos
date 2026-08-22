// Fase 3 Proveedores — el proveedor como RELACIÓN, no como ficha.
//
// La pantalla anterior sabía nombre, RNC, contacto y un texto de condiciones.
// Nada de eso ayuda a decidir a quién comprarle. Estos modelos cargan lo que
// convierte la fila en una relación comercial: cuánto le compraste, a qué
// precio, si el precio subió, cuánto le debés, cuándo vence y si entrega
// completo y a tiempo.
//
// Todo el armado es PURO (ver [SuppliersOverview.build] y
// [SupplierDetail.build]): el repositorio trae filas crudas y esto las cruza.
// Así las reglas que se pueden equivocar —el plazo, el cumplimiento, la
// variación de precio— se prueban sin Supabase.

import '../../purchases/utils/payment_terms.dart';
import 'inventory_state.dart';

// ── Condiciones comerciales ────────────────────────────────────────────────

/// Qué clase de trato hay con el proveedor.
enum SupplierTermsType {
  /// Se paga al recibir. No genera cuenta por pagar.
  contado,

  /// Se paga a N días. Es lo único que produce un vencimiento.
  credito,

  /// Se adelanta una parte. El resto no tiene plazo derivable.
  anticipo,
}

/// Desde cuándo cuentan los días del crédito.
enum SupplierTermsBase {
  /// Fecha de la factura del proveedor (default del mercado).
  invoice,

  /// Fecha en que la mercancía se recibió. Importa cuando la factura llega
  /// antes que el camión.
  receipt,
}

/// Condiciones de pago resueltas.
///
/// El campo `payment_terms` de la base es TEXTO LIBRE: en la misma columna
/// conviven «30 dias», «contado», «15 dias fin de mes» y «50% anticipo».
/// Esta clase decide qué se puede afirmar y qué no, y —clave— distingue el
/// dato de la interpretación con [structured]:
///
///   - [structured] true  → salió de columnas (`payment_terms_type` /
///     `payment_terms_days`). Se puede calcular un vencimiento.
///   - [structured] false → se dedujo del texto. Se muestra, pero la pantalla
///     invita a confirmarlo antes de que alimente una fecha.
///
/// La extracción del número delega en [PaymentTerms], que ya la resuelve para
/// el módulo de compras: si divergieran, la misma ficha produciría dos
/// vencimientos distintos según por qué pantalla se entre.
class SupplierTerms {
  final SupplierTermsType? type;

  /// Días de plazo. Sólo tiene sentido con [SupplierTermsType.credito].
  final int? days;

  final SupplierTermsBase base;

  /// Lo que escribió el negocio, tal cual. Nunca se pisa ni se borra.
  final String freeText;

  /// El tipo vino de la base, no de leer el texto.
  final bool structured;

  const SupplierTerms({
    this.type,
    this.days,
    this.base = SupplierTermsBase.invoice,
    this.freeText = '',
    this.structured = false,
  });

  static const unknown = SupplierTerms();

  /// Sin condiciones que mostrar: ni tipo, ni texto.
  bool get isEmpty => type == null && freeText.trim().isEmpty;

  /// Genera cuenta por pagar con fecha. Es la única forma en que la pantalla
  /// puede prometer un vencimiento sin inventarlo.
  bool get hasDueDate =>
      type == SupplierTermsType.credito && days != null && days! > 0;

  /// Etiqueta corta para la fila y el chip.
  String get label {
    switch (type) {
      case SupplierTermsType.contado:
        return 'Contado';
      case SupplierTermsType.credito:
        final d = days;
        if (d == null || d <= 0) return 'Crédito';
        return 'Crédito $d ${d == 1 ? 'día' : 'días'}';
      case SupplierTermsType.anticipo:
        return freeText.trim().isEmpty ? 'Anticipo' : freeText.trim();
      case null:
        final text = freeText.trim();
        return text.isEmpty ? 'Sin definir' : text;
    }
  }

  /// Vencimiento a partir de [from], o `null` si no hay plazo defendible.
  DateTime? dueDateFrom(DateTime from) {
    if (!hasDueDate) return null;
    return DateTime(from.year, from.month, from.day + days!);
  }

  /// Resuelve las condiciones de un proveedor.
  ///
  /// Orden de precedencia: la columna de tipo manda; después el número; y sólo
  /// al final se lee el texto. Un dato explícito nunca lo pisa una deducción.
  factory SupplierTerms.fromSupplier(InventorySupplierDetail s) {
    final text = s.paymentTerms.trim();
    final base = s.paymentTermsFrom == 'receipt'
        ? SupplierTermsBase.receipt
        : SupplierTermsBase.invoice;

    switch (s.paymentTermsType) {
      case 'contado':
        return SupplierTerms(
          type: SupplierTermsType.contado,
          days: 0,
          base: base,
          freeText: text,
          structured: true,
        );
      case 'credito':
        return SupplierTerms(
          type: SupplierTermsType.credito,
          // Con tipo crédito y sin número, el plazo cae al texto antes de
          // rendirse: es mejor «Crédito 30 días (por confirmar)» que
          // «Crédito» a secas.
          days: s.paymentTermsDays ??
              PaymentTerms.resolve(freeText: text).days,
          base: base,
          freeText: text,
          structured: true,
        );
      case 'anticipo':
        return SupplierTerms(
          type: SupplierTermsType.anticipo,
          base: base,
          freeText: text,
          structured: true,
        );
    }

    // Sin tipo: el número de `payment_terms_days` es dato duro, pero un 0 no
    // distingue «contado» de «sin configurar» — esa columna nació con default
    // 0 en la migración 20260811_0001, así que un 0 se ignora acá.
    final days = s.paymentTermsDays;
    if (days != null && days > 0 && days <= 365) {
      return SupplierTerms(
        type: SupplierTermsType.credito,
        days: days,
        base: base,
        freeText: text,
        structured: true,
      );
    }

    if (text.isEmpty) return SupplierTerms(base: base);

    final lower = text.toLowerCase();
    if (const {
      'contado',
      'de contado',
      'al contado',
      'efectivo',
      'cash',
      '0',
    }.contains(lower)) {
      return SupplierTerms(
        type: SupplierTermsType.contado,
        days: 0,
        base: base,
        freeText: text,
      );
    }

    if (text.contains('%') &&
        RegExp('anticipo|adelanto|avance').hasMatch(lower)) {
      return SupplierTerms(
        type: SupplierTermsType.anticipo,
        base: base,
        freeText: text,
      );
    }

    final suggestion = PaymentTerms.resolve(freeText: text);
    if (suggestion.days != null) {
      return SupplierTerms(
        type: SupplierTermsType.credito,
        days: suggestion.days,
        base: base,
        freeText: text,
      );
    }

    // Texto que no es un plazo («2/10 neto 30», «contra entrega parcial»):
    // se muestra literal y NADA lo convierte en fecha.
    return SupplierTerms(base: base, freeText: text);
  }
}

// ── Filas crudas que alimentan el armado ───────────────────────────────────

/// Una orden de compra, reducida a lo que la relación comercial necesita.
class SupplierOrderRow {
  final String supplierId;
  final String status;
  final double total;
  final DateTime? createdAt;
  final DateTime? receivedDate;
  final DateTime? expectedDate;

  const SupplierOrderRow({
    required this.supplierId,
    required this.status,
    this.total = 0,
    this.createdAt,
    this.receivedDate,
    this.expectedDate,
  });

  /// La orden ya se resolvió: llegó completa, llegó a medias o se canceló.
  /// Un borrador o una orden enviada todavía no dicen nada del proveedor.
  bool get isClosed =>
      status == 'received' || status == 'partial' || status == 'cancelled';

  bool get isReceived => status == 'received';

  /// Cuenta para «Compras 12 meses». Un borrador no es una compra y una
  /// cancelada tampoco: sumarlas inflaría el volumen del proveedor.
  bool get counts => status != 'draft' && status != 'cancelled';

  static SupplierOrderRow? fromMap(Map<String, dynamic> map) {
    final supplierId = map['supplier_id']?.toString();
    if (supplierId == null || supplierId.isEmpty) return null;
    return SupplierOrderRow(
      supplierId: supplierId,
      status: map['status']?.toString() ?? 'draft',
      total: _toDouble(map['total']),
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
      receivedDate: DateTime.tryParse(map['received_date']?.toString() ?? ''),
      expectedDate: DateTime.tryParse(map['expected_date']?.toString() ?? ''),
    );
  }
}

/// Una cuenta por pagar abierta.
class SupplierPayableRow {
  final String supplierId;
  final String? orderId;
  final String reference;
  final double balance;
  final double originalAmount;
  final DateTime? dueDate;
  final String status;
  final DateTime? createdAt;

  const SupplierPayableRow({
    required this.supplierId,
    this.orderId,
    this.reference = '',
    this.balance = 0,
    this.originalAmount = 0,
    this.dueDate,
    this.status = 'pending',
    this.createdAt,
  });

  /// Sigue debiéndose. `paid` y `cancelled` no son deuda.
  bool get isOpen =>
      balance > 0 &&
      (status == 'pending' || status == 'partial' || status == 'overdue');

  /// Días para el vencimiento; negativo si ya pasó. `null` sin fecha.
  int? daysToDue({DateTime? now}) {
    final due = dueDate;
    if (due == null) return null;
    final today = now ?? DateTime.now();
    return DateTime(
      due.year,
      due.month,
      due.day,
    ).difference(DateTime(today.year, today.month, today.day)).inDays;
  }

  bool isOverdue({DateTime? now}) {
    final days = daysToDue(now: now);
    return days != null && days < 0;
  }

  static SupplierPayableRow? fromMap(Map<String, dynamic> map) {
    final supplierId = map['supplier_id']?.toString();
    if (supplierId == null || supplierId.isEmpty) return null;
    return SupplierPayableRow(
      supplierId: supplierId,
      orderId: map['purchase_order_id']?.toString(),
      reference: (map['ncf']?.toString().trim().isNotEmpty ?? false)
          ? map['ncf'].toString()
          : (map['invoice_number']?.toString() ?? ''),
      balance: _toDouble(map['balance']),
      originalAmount: _toDouble(map['original_amount']),
      dueDate: DateTime.tryParse(map['due_date']?.toString() ?? ''),
      status: map['status']?.toString() ?? 'pending',
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
    );
  }
}

// ── El proveedor visto como relación ───────────────────────────────────────

/// Un proveedor con su historia comercial. Es lo que pinta cada fila de la
/// lista y el encabezado del detalle.
class SupplierOverview {
  final InventorySupplierDetail supplier;
  final SupplierTerms terms;

  /// Suma de las órdenes de los últimos 12 meses (sin borradores ni
  /// canceladas) y cuántas fueron.
  final double spend;
  final int orders;

  /// Denominador y numerador del cumplimiento: órdenes ya resueltas y cuántas
  /// llegaron completas.
  final int ordersClosed;
  final int ordersReceived;

  /// Promedio de días entre creación y recepción de las últimas órdenes
  /// recibidas. `null` si ninguna trae las dos fechas.
  final double? avgLeadDays;

  /// Deuda abierta y cuántos documentos la componen.
  final double payable;
  final int payableCount;
  final int overdueCount;
  final DateTime? nextDueDate;

  /// Nombres de los insumos que provee (los primeros, para la fila) y el
  /// total. La fila muestra tres y el detalle los muestra todos.
  final List<String> supplies;
  final int suppliesCount;

  /// De cuántos insumos es el suplidor PREFERIDO
  /// (`inventory_items.preferred_supplier_id`). Es lo que hace que la fila
  /// diga «PRINCIPAL»: no es una etiqueta suelta, es una decisión que ya se
  /// tomó en la ficha del insumo.
  final int preferredCount;

  const SupplierOverview({
    required this.supplier,
    this.terms = SupplierTerms.unknown,
    this.spend = 0,
    this.orders = 0,
    this.ordersClosed = 0,
    this.ordersReceived = 0,
    this.avgLeadDays,
    this.payable = 0,
    this.payableCount = 0,
    this.overdueCount = 0,
    this.nextDueDate,
    this.supplies = const [],
    this.suppliesCount = 0,
    this.preferredCount = 0,
  });

  String get id => supplier.id;
  String get name => supplier.name;
  bool get isActive => supplier.isActive;
  bool get hasRnc => supplier.rnc.trim().isNotEmpty;
  bool get isPreferred => preferredCount > 0;
  bool get owesMoney => payable > 0;

  /// Porcentaje de órdenes que llegaron completas. `null` cuando todavía no
  /// hay ninguna resuelta: mostrar 0% ahí acusaría a un proveedor nuevo de
  /// incumplir.
  double? get fulfillmentPct {
    if (ordersClosed <= 0) return null;
    return (ordersReceived / ordersClosed) * 100;
  }

  /// Días hasta el vencimiento más próximo; negativo si ya venció.
  int? daysToNextDue({DateTime? now}) {
    final due = nextDueDate;
    if (due == null) return null;
    final today = now ?? DateTime.now();
    return DateTime(
      due.year,
      due.month,
      due.day,
    ).difference(DateTime(today.year, today.month, today.day)).inDays;
  }

  /// Las dos primeras iniciales del nombre, para el avatar.
  String get initials {
    final words = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList(growable: false);
    if (words.isEmpty) return '??';
    if (words.length == 1) {
      final w = words.first;
      return (w.length == 1 ? w : w.substring(0, 2)).toUpperCase();
    }
    return '${words[0][0]}${words[1][0]}'.toUpperCase();
  }
}

/// La lista completa, con los totales del negocio.
class SuppliersOverview {
  /// Ordenados: activos primero, después por volumen de compra descendente y
  /// finalmente por nombre. El inactivo baja al final porque no compite.
  final List<SupplierOverview> suppliers;

  final double totalSpend;
  final double totalPayable;

  /// El esquema soporta condiciones estructuradas (migración aplicada).
  /// Cuando es `false` la pantalla no ofrece configurarlas y se queda con el
  /// texto libre.
  final bool termsSupported;

  /// El esquema tiene `supplier_items`.
  final bool linksSupported;

  final bool fromCache;

  const SuppliersOverview({
    this.suppliers = const [],
    this.totalSpend = 0,
    this.totalPayable = 0,
    this.termsSupported = false,
    this.linksSupported = false,
    this.fromCache = false,
  });

  static const empty = SuppliersOverview();

  int get activeCount => suppliers.where((s) => s.isActive).length;
  int get inactiveCount => suppliers.length - activeCount;
  int get owingCount => suppliers.where((s) => s.owesMoney).length;
  int get withoutRncCount =>
      suppliers.where((s) => s.isActive && !s.hasRnc).length;
  int get withoutTermsCount =>
      suppliers.where((s) => s.isActive && s.terms.type == null).length;

  SupplierOverview? byId(String id) {
    for (final s in suppliers) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// El vencimiento abierto más próximo de todo el negocio.
  DateTime? get nextDueDate {
    DateTime? next;
    for (final s in suppliers) {
      final due = s.nextDueDate;
      if (due == null) continue;
      if (next == null || due.isBefore(next)) next = due;
    }
    return next;
  }

  /// Cruza el catálogo de proveedores con sus órdenes, sus deudas y los
  /// insumos que proveen. Puro: mismas entradas, mismas salidas.
  static SuppliersOverview build({
    required List<InventorySupplierDetail> suppliers,
    List<SupplierOrderRow> orders = const [],
    List<SupplierPayableRow> payables = const [],
    Map<String, List<String>> supplies = const {},
    Map<String, int> preferredCounts = const {},
    bool termsSupported = false,
    bool linksSupported = false,
    bool fromCache = false,
    DateTime? now,
  }) {
    final stats = <String, _SupplierStats>{};
    _SupplierStats statsOf(String id) =>
        stats[id] ??= _SupplierStats();

    for (final order in orders) {
      final s = statsOf(order.supplierId);
      if (order.counts) {
        s.spend += order.total;
        s.orders++;
      }
      if (order.isClosed) {
        s.closed++;
        if (order.isReceived) s.received++;
      }
      final created = order.createdAt;
      final receivedAt = order.receivedDate;
      if (order.isReceived && created != null && receivedAt != null) {
        final days = DateTime(receivedAt.year, receivedAt.month, receivedAt.day)
            .difference(DateTime(created.year, created.month, created.day))
            .inDays;
        // Una recepción fechada ANTES de la orden es un dato mal cargado, no
        // una entrega instantánea: promediarla mentiría hacia abajo.
        if (days >= 0) {
          s.leadDays.add(days.toDouble());
        }
      }
    }

    for (final payable in payables) {
      if (!payable.isOpen) continue;
      final s = statsOf(payable.supplierId);
      s.payable += payable.balance;
      s.payableCount++;
      if (payable.isOverdue(now: now)) s.overdue++;
      final due = payable.dueDate;
      if (due != null && (s.nextDue == null || due.isBefore(s.nextDue!))) {
        s.nextDue = due;
      }
    }

    final rows = suppliers.map((supplier) {
      final s = stats[supplier.id] ?? _SupplierStats();
      final names = supplies[supplier.id] ?? const <String>[];
      return SupplierOverview(
        supplier: supplier,
        terms: SupplierTerms.fromSupplier(supplier),
        spend: s.spend,
        orders: s.orders,
        ordersClosed: s.closed,
        ordersReceived: s.received,
        avgLeadDays: s.leadDays.isEmpty
            ? null
            : s.leadDays.reduce((a, b) => a + b) / s.leadDays.length,
        payable: s.payable,
        payableCount: s.payableCount,
        overdueCount: s.overdue,
        nextDueDate: s.nextDue,
        supplies: names,
        suppliesCount: names.length,
        preferredCount: preferredCounts[supplier.id] ?? 0,
      );
    }).toList()
      ..sort((a, b) {
        if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
        final bySpend = b.spend.compareTo(a.spend);
        if (bySpend != 0) return bySpend;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    return SuppliersOverview(
      suppliers: rows,
      totalSpend: rows.fold<double>(0, (acc, s) => acc + s.spend),
      totalPayable: rows.fold<double>(0, (acc, s) => acc + s.payable),
      termsSupported: termsSupported,
      linksSupported: linksSupported,
      fromCache: fromCache,
    );
  }
}

class _SupplierStats {
  double spend = 0;
  int orders = 0;
  int closed = 0;
  int received = 0;
  final List<double> leadDays = [];
  double payable = 0;
  int payableCount = 0;
  int overdue = 0;
  DateTime? nextDue;
}

// ── El interior del proveedor ──────────────────────────────────────────────

/// Un insumo que este proveedor provee, con su historia de precio.
///
/// El vínculo puede venir de dos lados y NO son lo mismo:
///   - [linked]: hay una fila en `supplier_items`. Alguien lo declaró.
///   - [purchases] > 0: se le compró de hecho, aunque nadie lo declarara.
///
/// El segundo caso es el que hoy vive escondido en las líneas de las órdenes:
/// la relación existe, simplemente no está escrita en ninguna parte donde el
/// reorden pueda encontrarla.
class SupplierItemLink {
  final String itemId;
  final String itemName;
  final String sku;
  final String unit;

  /// Cómo llama el PROVEEDOR a este insumo. Vacío mientras no se cargue.
  final String supplierCode;
  final String purchaseUnit;

  /// Precio de lista acordado (`supplier_items.last_price`).
  final double? listPrice;

  /// Último precio realmente PAGADO y el anterior, de las líneas de las
  /// órdenes. La comparación de estos dos es la variación.
  final double? lastPaidPrice;
  final double? previousPaidPrice;

  final DateTime? lastPurchaseAt;

  /// Cuántas órdenes de este proveedor incluyeron el insumo.
  final int purchases;

  final bool linked;
  final bool preferred;

  const SupplierItemLink({
    required this.itemId,
    required this.itemName,
    this.sku = '',
    this.unit = '',
    this.supplierCode = '',
    this.purchaseUnit = '',
    this.listPrice,
    this.lastPaidPrice,
    this.previousPaidPrice,
    this.lastPurchaseAt,
    this.purchases = 0,
    this.linked = false,
    this.preferred = false,
  });

  /// Precio a mostrar: lo último que se pagó manda sobre la lista, porque es
  /// lo que de verdad costó.
  double? get price => lastPaidPrice ?? listPrice;

  /// Variación porcentual entre las dos últimas compras. `null` cuando hay
  /// una sola: sin punto de comparación no hay tendencia.
  double? get variationPct {
    final last = lastPaidPrice;
    final prev = previousPaidPrice;
    if (last == null || prev == null || prev <= 0) return null;
    return ((last - prev) / prev) * 100;
  }

  /// Alza que merece atención. El umbral es 5%: por debajo es ruido de
  /// empaque o redondeo, por encima se come el margen del plato.
  bool get isSharpRise => (variationPct ?? 0) >= 5;

  /// Se le compra pero nadie lo declaró: el reorden no lo va a encontrar.
  bool get isImplicitOnly => !linked && purchases > 0;
}

/// Una línea de orden de compra, reducida a la historia del precio.
class SupplierPurchaseLine {
  final String itemId;
  final double unitCost;
  final double quantity;
  final DateTime? at;

  const SupplierPurchaseLine({
    required this.itemId,
    this.unitCost = 0,
    this.quantity = 0,
    this.at,
  });
}

/// Todo lo que hay dentro de un proveedor.
class SupplierDetail {
  final SupplierOverview overview;

  /// Insumos que provee: los declarados en `supplier_items` unidos a los que
  /// aparecen en sus órdenes. Ordenados por gasto reciente.
  final List<SupplierItemLink> items;

  /// Órdenes del proveedor, de la más reciente a la más vieja.
  final List<SupplierOrderRow> orders;

  /// Cuentas por pagar abiertas, por vencimiento.
  final List<SupplierPayableRow> payables;

  final bool linksSupported;

  const SupplierDetail({
    required this.overview,
    this.items = const [],
    this.orders = const [],
    this.payables = const [],
    this.linksSupported = false,
  });

  /// Insumos a los que se les compra sin haberlos declarado. Es el número que
  /// justifica el botón «Vincular insumo».
  int get implicitItemsCount => items.where((i) => i.isImplicitOnly).length;

  /// Insumos cuyo precio subió fuerte en la última compra.
  List<SupplierItemLink> get sharpRises =>
      items.where((i) => i.isSharpRise).toList(growable: false);

  /// Cruza los insumos declarados con las líneas de las órdenes.
  ///
  /// [lines] tiene que venir ORDENADO de la compra más reciente a la más
  /// vieja: de ahí salen «último precio» y «anterior» sin volver a ordenar
  /// por cada insumo.
  static SupplierDetail build({
    required SupplierOverview overview,
    List<SupplierItemLink> declared = const [],
    List<SupplierPurchaseLine> lines = const [],
    List<SupplierOrderRow> orders = const [],
    List<SupplierPayableRow> payables = const [],
    Set<String> preferredItemIds = const {},
    Map<String, InventoryItemSummary> catalog = const {},
    bool linksSupported = false,
  }) {
    final prices = <String, List<SupplierPurchaseLine>>{};
    for (final line in lines) {
      (prices[line.itemId] ??= <SupplierPurchaseLine>[]).add(line);
    }

    final byItem = <String, SupplierItemLink>{
      for (final d in declared) d.itemId: d,
    };

    // Los insumos que aparecen en las órdenes pero nadie declaró entran igual:
    // esconderlos sería repetir el problema que la pantalla viene a resolver.
    for (final itemId in prices.keys) {
      if (byItem.containsKey(itemId)) continue;
      final item = catalog[itemId];
      byItem[itemId] = SupplierItemLink(
        itemId: itemId,
        itemName: item?.name ?? 'Insumo',
        sku: item?.sku ?? '',
        unit: item?.unit ?? '',
        purchaseUnit: item?.purchaseUnit ?? '',
      );
    }

    final items = byItem.values.map((link) {
      final history = prices[link.itemId] ?? const <SupplierPurchaseLine>[];
      // Una compra al mismo precio no es un cambio de precio: para la
      // variación interesa el último precio DISTINTO, no la línea anterior.
      double? last;
      double? previous;
      for (final line in history) {
        if (line.unitCost <= 0) continue;
        if (last == null) {
          last = line.unitCost;
          continue;
        }
        if (line.unitCost != last) {
          previous = line.unitCost;
          break;
        }
      }
      return SupplierItemLink(
        itemId: link.itemId,
        itemName: link.itemName,
        sku: link.sku,
        unit: link.unit,
        supplierCode: link.supplierCode,
        purchaseUnit: link.purchaseUnit,
        listPrice: link.listPrice,
        lastPaidPrice: last,
        previousPaidPrice: previous,
        lastPurchaseAt: history.isEmpty ? null : history.first.at,
        purchases: history.length,
        linked: link.linked,
        preferred: preferredItemIds.contains(link.itemId),
      );
    }).toList()
      ..sort((a, b) {
        // Lo que subió de precio primero: es lo único accionable de la tabla.
        if (a.isSharpRise != b.isSharpRise) return a.isSharpRise ? -1 : 1;
        final byDate = (b.lastPurchaseAt ?? DateTime(1970)).compareTo(
          a.lastPurchaseAt ?? DateTime(1970),
        );
        if (byDate != 0) return byDate;
        return a.itemName.toLowerCase().compareTo(b.itemName.toLowerCase());
      });

    final openPayables =
        payables.where((p) => p.isOpen).toList(growable: false)..sort((a, b) {
          final ad = a.dueDate;
          final bd = b.dueDate;
          // Sin fecha al final: no se puede priorizar lo que no vence.
          if (ad == null && bd == null) return 0;
          if (ad == null) return 1;
          if (bd == null) return -1;
          return ad.compareTo(bd);
        });

    return SupplierDetail(
      overview: overview,
      items: items,
      orders: orders,
      payables: openPayables,
      linksSupported: linksSupported,
    );
  }
}

double _toDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}
