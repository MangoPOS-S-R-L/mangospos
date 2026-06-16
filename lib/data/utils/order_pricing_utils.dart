import 'package:mangopos/core/tax/tax_engine.dart';

import '../models/sales_models.dart';

double _r(double v) => double.parse(v.toStringAsFixed(2));

/// True si la línea es una OFERTA vendida desde el tile (marcador `[DEAL:` en
/// notes). Para esas líneas el subtotal viene neto y el descuento se muestra
/// aparte sin doble conteo.
bool _notesHasDealMarker(String? notes) {
  if (notes == null || notes.isEmpty) return false;
  return notes
      .split('\n')
      .map((line) => line.trim())
      .any((line) => line.startsWith('[DEAL:') && line.endsWith(']'));
}

/// Convierte las notas internas de un item en texto legible (UI y tickets):
/// oculta los marcadores técnicos ([DEAL:...], [PROMO_AUTO:...], [CORTESIA:...])
/// y, si era una línea de OFERTA sin otra nota, muestra "Oferta aplicada".
/// Devuelve '' cuando no queda nada visible (el caller no debe imprimir "NOTA:").
String cleanOrderItemNote(String? raw) {
  if (raw == null || raw.trim().isEmpty) return '';
  var isDeal = false;
  final visible = <String>[];
  for (final line in raw.split('\n').map((l) => l.trim())) {
    if (line.isEmpty) continue;
    if (line.startsWith('[DEAL') && line.endsWith(']')) {
      isDeal = true;
      continue;
    }
    if ((line.startsWith('[PROMO_AUTO:') || line.startsWith('[CORTESIA:')) &&
        line.endsWith(']')) {
      continue;
    }
    visible.add(line);
  }
  if (isDeal && visible.isEmpty) return 'Oferta aplicada';
  return visible.join(' · ');
}

// ─────────────────────────────────────────────────────────────────────────────
// Resolve service rate from order-level DB values
// ─────────────────────────────────────────────────────────────────────────────

/// Devuelve la tasa efectiva de service fee de una orden (0..1).
///
/// **PRD 2:** el motor backend consolida la propina dentro de `oi.tax` y
/// deja `order.serviceFee = 0` siempre. Esa es la fuente de verdad.
/// El default ANTES era `0.10` (10%) y eso era la causa de la propina
/// fantasma post-PRD-2: cualquier orden donde `order.serviceFee = 0` (es
/// decir, todas las nuevas) recibía un 10% adicional aplicado por
/// `summarizeItemPricing` por sobre el `oi.tax` que ya incluía propina,
/// duplicando el cargo en el total.
///
/// El default ahora es **0**. Sólo se devuelve una tasa > 0 cuando la
/// orden tiene `serviceFee > 0` persistido (caso de órdenes históricas
/// pre-PRD-2 que sí tenían el concepto separado).
double resolveOrderServiceRate(Order? order) {
  if (order == null) return 0.0;
  final subtotal = order.subtotal;
  final serviceFee = order.serviceFee;
  if (subtotal > 0 && serviceFee > 0) {
    return serviceFee / subtotal;
  }
  return 0.0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Item-level pricing
// ─────────────────────────────────────────────────────────────────────────────

class OrderItemPricingSummary {
  final double subtotal;
  final double tax;
  final double discounts;
  final double serviceFee;
  final double extraServiceFee;
  final double total;

  const OrderItemPricingSummary({
    required this.subtotal,
    required this.tax,
    required this.discounts,
    required this.serviceFee,
    required this.extraServiceFee,
    required this.total,
  });
}

/// Compute the catalog gross amount for an [OrderItem].
double _itemGross(OrderItem item) {
  return catalogGrossAmount(
    unitPrice: item.unitPrice,
    quantity: item.quantity,
    modifiers: item.modifiers
        .map((m) => (price: m.price, qty: m.qty))
        .toList(growable: false),
  );
}

/// Factor de escala para los `amount` de `tax_lines` en items takeout
/// inclusive. El trigger backend computa los amounts con la base extraída
/// a tasa consolidada completa (ej. 28%) aún cuando takeout solo aplica
/// algunos taxes — el resultado es un rate impreso (18%) inconsistente
/// con el ratio amount/base recomputado.
///
/// Devuelve 1.0 (sin cambio) para items que no son takeout, no inclusive,
/// sin tax_lines, o sin rate aplicable.
///
/// Para takeout inclusive con rate aplicable > 0:
///   correctTax = gross - gross/(1+rate)        ej. 76.27 = 500 - 423.73
///   originalSum = sum(line.amount)             ej. 70.31
///   scale = correctTax / originalSum           ej. 1.0848
double _takeoutInclusiveScale(OrderItem item) {
  if (item.taxMode != 'inclusive' || !item.isTakeout) return 1.0;
  if (item.taxLines.isEmpty) return 1.0;

  final applicableRate = item.taxLines.fold<double>(
    0,
    (sum, line) => sum + (line.taxRate / 100.0),
  );
  if (applicableRate <= 0) return 1.0;

  final gross = _itemGross(item);
  if (gross <= 0) return 1.0;

  final correctTax = gross - (gross / (1 + applicableRate));
  final originalSum = item.taxLines.fold<double>(
    0,
    (sum, line) => sum + line.amount,
  );
  if (originalSum <= 0) return 1.0;

  return correctTax / originalSum;
}

OrderItemPricingSummary summarizeItemPricing(Order? order, OrderItem item, {String? forcedOrigin}) {
  // PRD 2.5: modelo unificado. oi.tax ya incluye TODOS los impuestos aplicables
  // (ITBIS + Ley + cualquier otro), filtrados por apply_on_<origin> en el motor
  // backend. Ya no hay distinción tax vs service_fee a nivel item.
  //
  // Para items inclusive: el trigger backend fn_compute_item_totals extrae
  // oi.subtotal y oi.tax usando la rate consolidada (ej. 28%). Confiamos en
  // esos valores y NO recalculamos en el frontend.
  //
  // Para items con modifiers en draft: oi.subtotal puede no incluir modifiers
  // hasta que el motor backend recalcule. Usamos el gross calculado como
  // fallback en ese caso (solo para exclusive — para inclusive el gross
  // incluye tax y rompería la math).
  final grossWithModifiers = _itemGross(item);
  final dbDiscounts = _r(item.discounts);
  final fullRate = (item.originalTaxRate ?? item.taxRate) / 100.0;

  // PRD 6: si el item tiene tax_lines (snapshot per-tax desde backend), esa
  // es la fuente de verdad del impuesto efectivo — ya respeta filtros
  // takeout/origin/etc. `oi.tax` puede quedar stale tras un toggle
  // (la columna se recomputa por trigger pero las fórmulas históricas no
  // siempre cubren todos los casos). Preferimos siempre la suma de
  // tax_lines cuando existen.
  //
  // Excepcion: items con tax_rate=0 son "no paga impuesto" por diseño.
  // Algunos items legacy quedaron con tax_rate=0 pero tax_lines poblados
  // por `fn_populate_item_tax_lines` (que mira menu_item_taxes del producto
  // ignorando oi.tax_rate). Sumar esos tax_lines inflaba el total cobrado
  // al cliente vs lo que muestra el backend. Cuando tax_rate=0 confiamos
  // en oi.tax=0 y dejamos los tax_lines como metadata informativa.
  final taxLinesSum = (item.taxLines.isEmpty || item.taxRate == 0)
      ? null
      : _r(item.taxLines.fold<double>(0, (s, line) => s + line.amount));

  // LÍNEA DE OFERTA (tile del catálogo, marcada [DEAL:] en notes): el trigger
  // backend guarda `subtotal` ya NETO (bruto - descuento) y `tax` sobre el neto.
  // El cálculo general restaría el descuento OTRA VEZ (doble) y, para productos
  // inclusive, lo extrae mal (daba 710 en vez de 960). Aquí mostramos el BRUTO
  // (subtotal + descuento) y el descuento, restando una sola vez: el total queda
  // = subtotal_neto + tax (idéntico al de la BD). Así abajo se ve "Subtotal /
  // Descuento" correcto. Solo afecta a estas líneas (no toca el resto).
  if (_notesHasDealMarker(item.notes)) {
    final disc = _r(item.discounts);
    final netSub = _r(item.subtotal);
    final tx = _r(taxLinesSum ?? item.tax);
    return OrderItemPricingSummary(
      subtotal: _r(netSub + disc),
      tax: tx,
      discounts: disc,
      serviceFee: 0,
      extraServiceFee: 0,
      total: _r(netSub + tx),
    );
  }

  // Detectar si los modifiers en draft aún no fueron procesados por el
  // backend (oi.subtotal/oi.tax persistidos no incluyen el modifier nuevo).
  // En ese caso recomputamos en frontend para que el total mostrado en
  // draft coincida con el confirmado y no haya cambio de precio sorpresa
  // al enviar a cocina.
  final persistedGross = item.taxMode == 'inclusive'
      ? _r(item.subtotal + item.tax)
      : _r(item.subtotal);
  final modifiersOutOfSync = item.modifiers.isNotEmpty &&
      grossWithModifiers > persistedGross + 0.01;

  // FIX takeout inclusive: el trigger backend extrae `oi.subtotal` a la
  // tasa consolidada completa (ej. 28% = ITBIS+Ley) y filtra los `tax_lines`
  // por `apply_on_takeout`. Eso deja inconsistencia: subtotal sale a tasa
  // completa pero tax solo trae los aplicables, y `subtotal + tax != gross`.
  // El sistema debe pasar el "ahorro" del impuesto excluido al base
  // (cliente sigue pagando el precio de menú). Recomputamos:
  //   applicableRate = sum(tax_lines.taxRate / 100)   ej. 0.18 para takeout
  //   subtotal = gross / (1 + applicableRate)         ej. 500/1.18 = 423.73
  //   tax      = gross - subtotal                     ej. 76.27 (= 18% de 423.73)
  // Math: subtotal + tax == gross == precio menú ✓
  final double applicableInclusiveRate;
  if (item.taxMode == 'inclusive' && item.isTakeout && item.taxLines.isNotEmpty) {
    applicableInclusiveRate = item.taxLines.fold<double>(
      0,
      (sum, line) => sum + (line.taxRate / 100.0),
    );
  } else {
    applicableInclusiveRate = -1; // sentinela: no recomputar
  }

  final double dbSubtotal;
  final double dbTax;
  if (item.taxMode == 'inclusive' && applicableInclusiveRate >= 0) {
    if (applicableInclusiveRate > 0) {
      dbSubtotal = _r(grossWithModifiers / (1 + applicableInclusiveRate));
      dbTax = _r(grossWithModifiers - dbSubtotal);
    } else {
      // Todos los impuestos excluidos por takeout → base = gross, tax = 0.
      dbSubtotal = _r(grossWithModifiers);
      dbTax = 0;
    }
  } else if (modifiersOutOfSync) {
    if (item.taxMode == 'inclusive') {
      dbSubtotal = fullRate > 0
          ? _r(grossWithModifiers / (1 + fullRate))
          : _r(grossWithModifiers);
      dbTax = _r(grossWithModifiers - dbSubtotal);
    } else {
      dbSubtotal = _r(grossWithModifiers);
      dbTax = _r(dbSubtotal * fullRate);
    }
  } else {
    // Preferir suma de tax_lines (filtrada por takeout/origin) sobre
    // el oi.tax que puede estar desincronizado.
    dbTax = taxLinesSum ?? _r(item.tax);
    if (item.taxMode == 'inclusive') {
      // Inclusive: confiar en oi.subtotal (ya extraído por trigger backend con
      // tasa consolidada). Si está en 0 (optimistic), fallback a extraer del
      // gross usando tax_rate.
      if (item.subtotal > 0) {
        dbSubtotal = _r(item.subtotal);
      } else {
        dbSubtotal = fullRate > 0
            ? _r(grossWithModifiers / (1 + fullRate))
            : _r(grossWithModifiers);
      }
    } else {
      // Exclusive: oi.subtotal es la base (sin tax).
      dbSubtotal = _r(item.subtotal > 0 ? item.subtotal : grossWithModifiers);
    }
  }

  // Compatibilidad legacy: order.serviceFee > 0 solo aparece en órdenes
  // históricas pre-PRD-2.5. Para esas, mantenemos el cálculo proporcional
  // para no romper su display. Para órdenes nuevas (post-PRD-2.5),
  // order.serviceFee = 0 y este path no aplica.
  final orderServiceFee = order?.serviceFee ?? 0;
  final orderSubtotal = order?.subtotal ?? 0;
  final legacyServiceFee = (orderServiceFee > 0.004 && orderSubtotal > 0)
      ? _r((orderServiceFee / orderSubtotal) * dbSubtotal)
      : 0.0;

  // RED DE SEGURIDAD (anti-sobre-descuento): el descuento de una línea NUNCA
  // puede exceder su monto (subtotal + impuesto + service fee legacy). Aunque
  // una promo —auto o tile— escriba un descuento malo, el total jamás queda
  // negativo ni sub-cobra. Cap defensivo: en el caso correcto es no-op.
  final lineGross = dbSubtotal + dbTax + legacyServiceFee;
  final cappedDiscounts = _r(dbDiscounts.clamp(0, lineGross).toDouble());

  return OrderItemPricingSummary(
    subtotal: dbSubtotal,
    tax: dbTax,
    discounts: cappedDiscounts,
    serviceFee: legacyServiceFee,
    extraServiceFee: 0,
    total: _r(dbSubtotal + dbTax + legacyServiceFee - cappedDiscounts),
  );
}

double itemDisplayTotal(Order? order, OrderItem item) {
  final catalogGross = _itemGross(item);
  if (item.taxMode == 'inclusive') {
    return _r((catalogGross - item.discounts).clamp(0, double.infinity));
  }
  final gross = (item.modifiers.isEmpty && item.subtotal > catalogGross)
      ? item.subtotal
      : catalogGross;
  return _r((gross - item.discounts).clamp(0, double.infinity));
}

double itemDisplayUnitPrice(Order? order, OrderItem item) {
  final qty = item.quantity <= 0 ? 1.0 : item.quantity;
  return _r(itemDisplayTotal(order, item) / qty);
}

/// Total base de la línea (sin impuestos), usado en tickets/facturas para
/// que la suma de líneas coincida con el SUBTOTAL del ticket.
///
/// El trigger backend guarda `oi.subtotal` como base pre-descuento en ambos
/// modos (los descuentos viajan separados en `oi.discounts`). Devolvemos
/// `s.subtotal` directo. La suma de líneas coincide con `summary.subtotal`
/// = SUBTOTAL del ticket = subtotal de la UI.
double itemDisplayBaseTotal(Order? order, OrderItem item) {
  final s = summarizeItemPricing(order, item);
  return _r(s.subtotal);
}

double itemDisplayBaseUnitPrice(Order? order, OrderItem item) {
  final qty = item.quantity <= 0 ? 1.0 : item.quantity;
  return _r(itemDisplayBaseTotal(order, item) / qty);
}

// ─────────────────────────────────────────────────────────────────────────────
// Order-level pricing
// ─────────────────────────────────────────────────────────────────────────────

class OrderPricingSummary {
  final double subtotal;
  final double tax;
  final double discounts;
  final double serviceFee;
  final double extraServiceFee;
  final double total;
  final Map<double, double> taxDetails;

  const OrderPricingSummary({
    required this.subtotal,
    required this.tax,
    required this.discounts,
    required this.serviceFee,
    required this.extraServiceFee,
    required this.total,
    this.taxDetails = const {},
  });
}

/// Construye el desglose de impuestos a partir de las `order_item_tax_lines`
/// (PRD 2 §6.1). Agrupa por `tax_id` (estable, sobrevive renombres del
/// impuesto), suma los `amount` y usa el `taxName`/`taxRate` del primer
/// snapshot del grupo para el label.
///
/// Contrato del retorno (3 estados):
///   - `[]` (lista vacía) → la orden post-PRD-2 está validada y NO tiene
///     impuestos. Cierra el bug de Agua Dasany: items legítimamente exentos
///     no deben caer al fallback heurístico viejo (que cobraría 10% por
///     default). El caller debe respetar este vacío.
///   - `[(...)]` (lista con elementos) → desglose desde snapshot, usar tal
///     cual.
///   - `null` → orden pre-PRD-2 (tiene `oi.tax > 0` pero no hay tax_lines).
///     El caller debe caer al path heurístico de [buildOrderTaxBreakdown].
///
/// Nota sobre PRD 3 / reportes agregados: si en el futuro se agrupan tax_lines
/// de **varias órdenes** que cubran un cambio de nombre del impuesto, el
/// snapshot del primer grupo deja de ser confiable como label. Para ese caso
/// (PRD 3) hay que hacer JOIN con `taxes` y usar el nombre vigente. Acá estamos
/// en el contexto de UNA orden, así que todos los snapshots del mismo `tax_id`
/// son coherentes por construcción.
List<({String label, double amount})>? buildBreakdownFromTaxLines(
  Iterable<OrderItem> items,
) {
  final activeItems = items.where((i) => i.status != 'void');

  // Items que el motor backend ya marcó como tributantes (oi.tax > 0).
  final taxedItems = activeItems.where((i) => i.tax.abs() > 0.005).toList();

  if (taxedItems.isEmpty) {
    // Todos los items son legítimamente exentos. Devolver lista vacía
    // explícita evita el fallback heurístico viejo que cobraría propina
    // fantasma con su default de 10% (caso Agua Dasany pre-PRD-2).
    return const [];
  }

  // Si hay items con tax > 0 pero ninguno tiene tax_lines, esa orden es
  // pre-PRD-2 (creada antes del deploy de F2.2). Devolver null para que el
  // caller use el path heurístico, que sí funciona para ese caso histórico.
  final hasAnyLines = taxedItems.any((i) => i.taxLines.isNotEmpty);
  if (!hasAnyLines) return null;

  // Agrupar por tax_id, escalando amounts en items takeout inclusive.
  // El trigger backend computa los `tax_lines.amount` con la base extraída
  // a tasa consolidada completa (ej. 390.63 = 500/1.28), incluso cuando en
  // takeout solo aplican algunos taxes. Eso deja una inconsistencia entre
  // el rate impreso (18%) y el ratio amount/base. Escalamos los amounts
  // para que reflejen la tasa real aplicada sobre la base recomputada
  // (ej. 76.27 = 18% de 423.73 cuando el customer paga gross 500 sin Ley).
  // Agrupamos por (nombre normalizado, rate) y NO por tax_id. El motivo:
  // los items optimistas en el frontend (sales_viewmodel.addItem) generan
  // tax_lines sintéticos con un id `tmp_tax_<name>` que NO coincide con el
  // UUID real del backend. Si agrupamos por id, el row recien agregado
  // muestra "ITBIS (18%)" duplicado mientras el backend resuelve el item
  // real (~1-2s). Agrupar por nombre+rate hace que el optimistico se
  // fusione con los reales y el breakdown sea estable.
  final byKey = <String, ({String name, double rate, double amount})>{};
  bool hasAnyLine = false;
  for (final item in activeItems) {
    if (item.taxLines.isEmpty) continue;
    hasAnyLine = true;
    final scale = _takeoutInclusiveScale(item);
    for (final line in item.taxLines) {
      final adjustedAmount = line.amount * scale;
      final key =
          '${line.taxName.toLowerCase()}|${line.taxRate.toStringAsFixed(2)}';
      final existing = byKey[key];
      if (existing == null) {
        byKey[key] = (
          name: line.taxName,
          rate: line.taxRate,
          amount: adjustedAmount,
        );
      } else {
        byKey[key] = (
          name: existing.name,
          rate: existing.rate,
          amount: existing.amount + adjustedAmount,
        );
      }
    }
  }

  if (!hasAnyLine) return const [];

  final breakdown = <({String label, double amount})>[];
  // Orden estable: por nombre alfabético para que el ticket no varíe entre
  // refrescos. Si el operador prefiere otro orden, se hace en una pasada
  // posterior (ej: ITBIS primero, propina último).
  final sortedKeys = byKey.keys.toList()
    ..sort((a, b) => byKey[a]!.name.compareTo(byKey[b]!.name));

  for (final key in sortedKeys) {
    final entry = byKey[key]!;
    final amount = _r(entry.amount);
    if (amount <= 0.004) continue;
    final pct = entry.rate % 1 == 0 ? entry.rate.toInt() : entry.rate;
    breakdown.add((label: '${entry.name} ($pct%)', amount: amount));
  }

  return breakdown;
}

List<({String label, double amount})> buildOrderTaxBreakdown(
  Order? order,
  Iterable<OrderItem> items, {
  String? forcedOrigin,
  Iterable<({String label, double amount})> configuredBreakdown = const [],
}) {
  // PRD 2: si los items vienen con tax_lines (post-deploy F2.2), usamos
  // el desglose desde snapshot. Sino, fallback al path heurístico viejo
  // que sirve para órdenes históricas pre-PRD-2.
  final fromLines = buildBreakdownFromTaxLines(items);
  if (fromLines != null) return fromLines;

  final summary = summarizeOrderPricing(order, items, forcedOrigin: forcedOrigin);
  final breakdown = <({String label, double amount})>[];

  // Agrupamos primero por displayRate para que ítems con taxRate "camuflado"
  // (28 = 18 ITBIS + 10 propina) y sin camuflar (18 puro) caigan en la misma
  // línea de "ITBIS (18%)" en vez de duplicar el renglón.
  final Map<double, double> itbisByDisplayRate = <double, double>{};
  summary.taxDetails.forEach((rate, amount) {
    if (amount <= 0.004) return;
    final displayRate = (rate == 28.0) ? 18.0 : rate;
    itbisByDisplayRate[displayRate] =
        (itbisByDisplayRate[displayRate] ?? 0) + amount;
  });

  final sortedDisplayRates = itbisByDisplayRate.keys.toList()..sort();
  for (final displayRate in sortedDisplayRates) {
    final amount = _r(itbisByDisplayRate[displayRate] ?? 0);
    if (amount <= 0.004) continue;
    final pct = displayRate % 1 == 0 ? displayRate.toInt() : displayRate;
    breakdown.add((label: 'ITBIS ($pct%)', amount: amount));
  }

  if (summary.serviceFee > 0.004) {
    final rate = (resolveOrderServiceRate(order) * 100).roundToDouble();
    final displayRate = rate > 0 ? rate : 10.0;
    final pct = displayRate % 1 == 0 ? displayRate.toInt() : displayRate;
    breakdown.add((label: 'Propina Ley ($pct%)', amount: summary.serviceFee));
  }

  return breakdown;
}

OrderPricingSummary summarizeOrderPricing(
  Order? order,
  Iterable<OrderItem> items, {
  String? forcedOrigin,
}) {
  double subtotal = 0;
  double tax = 0;
  double discounts = 0;
  double serviceFee = 0;
  double extraServiceFee = 0;

  final Map<double, double> taxGroups = {};
  // FIX 2026-05-01: para items inclusive el catalog gross es la fuente
  // de verdad del total (ej: 2 frappes × RD$ 300 = RD$ 600 exactos). El
  // sumar `s.subtotal + s.tax` per-item arrastra error de redondeo del
  // trigger backend (300/1.28 = 234.375 ≈ 234.38, tax 65.63 → total
  // 300.01 vs catalog 300). Acumulamos gross aparte para que el TOTAL
  // de la orden coincida con el precio de menú visto por el cajero.
  double inclusiveGrossNet = 0;

  for (final item in items) {
    if (item.status == 'void') continue;
    final s = summarizeItemPricing(order, item, forcedOrigin: forcedOrigin);

    subtotal += s.subtotal;
    tax += s.tax;
    serviceFee += s.serviceFee;
    discounts += s.discounts;
    extraServiceFee += s.extraServiceFee;

    if (item.taxMode == 'inclusive') {
      final gross = _itemGross(item);
      inclusiveGrossNet += (gross - item.discounts).clamp(0, double.infinity);
    }

    final rate = item.taxRate.toDouble();
    if (rate > 0) {
      taxGroups[rate] = (taxGroups[rate] ?? 0) + s.tax;
    }
  }

  // PRD 2.5: Total = Base + Taxes + Service Fee - Discounts.
  // Para órdenes 100% inclusive, el total se ancla al gross catálogo
  // (sin drift por redondeo de tasas consolidadas y SIN sumar
  // serviceFee aparte porque ya está baked en el catálogo). Para
  // órdenes mixtas o 100% exclusive, sumamos componentes.
  final hasOnlyInclusive = items.every(
    (i) => i.status == 'void' || i.taxMode == 'inclusive',
  );
  final double finalTotal = hasOnlyInclusive && items.isNotEmpty
      ? _r(inclusiveGrossNet)
      : _r(subtotal + tax + serviceFee + extraServiceFee - discounts);

  return OrderPricingSummary(
    subtotal: _r(subtotal),
    tax: _r(tax),
    discounts: _r(discounts),
    serviceFee: _r(serviceFee),
    extraServiceFee: _r(extraServiceFee),
    total: finalTotal,
    taxDetails: taxGroups.map((key, value) => MapEntry(key, _r(value))),
  );
}
