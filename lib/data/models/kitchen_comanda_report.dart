import '../../core/utils/app_time.dart';
import '../../core/utils/order_number_utils.dart';
import '../utils/order_pricing_utils.dart' show cleanOrderItemNote;

/// Qué pasó en caja con un producto que salió a cocina.
enum KitchenChargeState {
  /// Se cobró (el ítem quedó 'paid').
  charged,

  /// Se "cobró" en cero: cortesía.
  courtesy,

  /// No hay nada que cobrar: precio 0 o unidad gratis de una promoción.
  zeroCharge,

  /// La mesa sigue abierta: todavía se puede cobrar.
  pending,

  /// La orden se cerró, se canceló o quedó huérfana sin cobrar este producto.
  /// Es la diferencia que hay que investigar.
  unpaid,

  /// Se anuló DESPUÉS de mandarse a cocina.
  voided;

  String get label => switch (this) {
    charged => 'Cobrado',
    courtesy => 'Cortesía',
    zeroCharge => 'Cobrado a 0',
    pending => 'Pendiente',
    unpaid => 'Sin cobrar',
    voided => 'Anulado',
  };
}

/// Modificador de un ítem de comanda ("Sin cebolla", "Extra queso x2").
class KitchenComandaModifier {
  const KitchenComandaModifier({required this.name, this.qty = 1});

  final String name;
  final double qty;
}

/// Un ítem enviado a cocina, tal como lo devuelve
/// `fn_kitchen_comandas_report`.
class KitchenComandaItem {
  const KitchenComandaItem({
    required this.itemId,
    required this.orderId,
    required this.sentAt,
    required this.createdAt,
    required this.productName,
    required this.quantity,
    required this.tableName,
    this.productId,
    this.notes,
    this.status = '',
    this.isTakeout = false,
    this.origin,
    this.author,
    this.openerName,
    this.areaCodes = const [],
    this.areaNames = const [],
    this.modifiers = const [],
    this.unitPrice = 0,
    this.isCourtesy = false,
    this.orderStatus,
    this.orderClosedAt,
    this.sessionClosedAt,
    this.sentSource = 'stamp',
    this.isZeroValue = false,
    this.voidNote,
    this.voidAt,
    this.voidSource,
  });

  final String itemId;
  final String orderId;

  /// Marca de la ronda (hora de pared AST): los ítems enviados juntos la
  /// comparten y forman una comanda.
  final DateTime sentAt;
  final DateTime createdAt;
  final String? productId;
  final String productName;
  final double quantity;
  final String? notes;
  final String status;
  final bool isTakeout;
  final String tableName;
  final String? origin;

  /// Quien digitó el ítem con su PIN.
  final String? author;

  /// Quien abrió la mesa: respaldo si nadie firmó los ítems.
  final String? openerName;

  /// Áreas de producción (Cocina, Bar…). Vacío = el producto no tiene área y
  /// su comanda no se imprime en ninguna estación.
  final List<String> areaCodes;
  final List<String> areaNames;
  final List<KitchenComandaModifier> modifiers;

  final double unitPrice;
  final bool isCourtesy;
  final String? orderStatus;
  final DateTime? orderClosedAt;
  final DateTime? sessionClosedAt;

  /// De dónde salió la hora de envío: 'stamp' (la marca del ítem), 'split'
  /// (fila creada al dividir la cuenta, hereda la de su original) o 'quick'
  /// (venta rápida: la comanda sale al cobrar y no se marca).
  final String sentSource;

  /// Cobrado a 0: precio 0 (sin extras con precio) o unidad gratis de una
  /// promoción.
  final bool isZeroValue;

  /// La nota que se escribió al anular ("Usuario: motivo"), solo en lo
  /// anulado. Null si no se dio motivo (o si el producto se eliminó: eso
  /// borra la fila y el motivo no se guarda).
  final String? voidNote;

  /// Cuándo se anuló (hora de pared AST).
  final DateTime? voidAt;

  /// De dónde salió la nota: 'factura' (se anuló la factura desde el
  /// historial) o 'mesa' (se anuló la orden desde la mesa).
  final String? voidSource;

  bool get isVoid => status == 'void';

  /// Se cargó a una orden que YA estaba cerrada (cobrada o anulada). Pasa
  /// cuando se libera una mesa vacía y le cargan productos a la orden
  /// muerta: la comanda sale, pero ninguna cuenta lo muestra.
  bool get loadedAfterClose {
    final closed = orderClosedAt;
    return closed != null && createdAt.isAfter(closed);
  }

  /// La orden se anuló a propósito (anular orden la cierra 'canceled'). Lo
  /// cargado DESPUÉS de anularla no se anuló: se perdió.
  bool get isOrderVoided => orderStatus == 'canceled' && !loadedAfterClose;

  /// El cobro marca 'paid' el ítem (subcuenta u orden completa). Si no está
  /// cobrado ni anulado, sigue pendiente solo mientras la orden Y la mesa
  /// estén abiertas: una orden viva con la mesa cerrada es huérfana y nadie
  /// la va a cobrar.
  ///
  /// Lo anulado, la cortesía y lo cobrado a 0 NUNCA son pendientes ni "sin
  /// cobrar", por eso van primero, en este orden. Lo eliminado a propósito
  /// no llega: `deleteItem` borra la fila.
  KitchenChargeState get chargeState {
    if (isVoid || isOrderVoided) return KitchenChargeState.voided;
    // La cortesía se decide antes de cobrar: una mesa abierta con cortesía
    // no le debe ese producto a nadie.
    if (isCourtesy) return KitchenChargeState.courtesy;
    if (isZeroValue) return KitchenChargeState.zeroCharge;
    if (status == 'paid') return KitchenChargeState.charged;
    final orderOpen =
        orderClosedAt == null &&
        orderStatus != 'paid' &&
        orderStatus != 'canceled';
    return orderOpen && sessionClosedAt == null
        ? KitchenChargeState.pending
        : KitchenChargeState.unpaid;
  }

  /// Por qué quedó así, para investigarlo: sin cobrar o anulado.
  String? get stateReason {
    switch (chargeState) {
      case KitchenChargeState.unpaid:
        if (loadedAfterClose) return 'Se cargó a una orden ya cerrada';
        if (orderStatus == 'paid' || orderClosedAt != null) {
          return 'La orden se cobró sin este producto';
        }
        return 'Mesa cerrada con la orden abierta';
      case KitchenChargeState.voided:
        // Lo más específico primero: anular la factura también deja los
        // productos en 'void', y eso no es "producto anulado".
        if (voidSource == 'factura') return 'Factura anulada';
        if (isOrderVoided) return 'Orden anulada';
        return 'Producto anulado';
      default:
        return null;
    }
  }

  /// Clave para sumar "cuánto de cada producto": el producto del menú, o el
  /// nombre si la línea no tiene `product_id` (ítem abierto / legacy).
  String get productKey =>
      productId ?? 'name:${productName.trim().toLowerCase()}';

  static KitchenComandaItem? fromRow(Map<String, dynamic> row) {
    final itemId = row['item_id']?.toString() ?? '';
    final orderId = row['order_id']?.toString() ?? '';
    final sentAt = AppTime.tryParseServerToAst(row['kitchen_sent_at']);
    if (itemId.isEmpty || orderId.isEmpty || sentAt == null) return null;
    final rawMods = row['modifiers'];
    return KitchenComandaItem(
      itemId: itemId,
      orderId: orderId,
      sentAt: sentAt,
      createdAt: AppTime.tryParseServerToAst(row['item_created_at']) ?? sentAt,
      productId: _clean(row['product_id']),
      productName: _clean(row['product_name']) ?? 'Producto',
      quantity: _toDouble(row['quantity'], fallback: 1),
      // Sin los marcadores técnicos ([CORTESIA:…], [PROMO_AUTO:…]).
      notes: _clean(cleanOrderItemNote(row['notes']?.toString())),
      status: row['status']?.toString() ?? '',
      isTakeout: row['is_takeout'] == true,
      tableName: _clean(row['table_name']) ?? 'Venta',
      origin: _clean(row['origin']),
      author: _clean(row['item_author']),
      openerName: _clean(row['opener_name']),
      areaCodes: _stringList(row['area_codes']),
      areaNames: _stringList(row['area_names']),
      modifiers: [
        if (rawMods is List)
          for (final m in rawMods)
            if (m is Map && _clean(m['name']) != null)
              KitchenComandaModifier(
                name: _clean(m['name'])!,
                qty: _toDouble(m['qty'], fallback: 1),
              ),
      ],
      unitPrice: _toDouble(row['unit_price']),
      isCourtesy: row['is_courtesy'] == true,
      orderStatus: _clean(row['order_status']),
      orderClosedAt: AppTime.tryParseServerToAst(row['order_closed_at']),
      sessionClosedAt: AppTime.tryParseServerToAst(row['session_closed_at']),
      sentSource: _clean(row['sent_source']) ?? 'stamp',
      isZeroValue: row['is_zero_value'] == true,
      voidNote: _clean(row['void_note']),
      voidAt: AppTime.tryParseServerToAst(row['void_at']),
      voidSource: _clean(row['void_source']),
    );
  }
}

/// Una comanda: lo que se mandó a cocina de una orden en un mismo envío.
class KitchenComanda {
  const KitchenComanda({required this.orderId, required this.items});

  final String orderId;
  final List<KitchenComandaItem> items;

  DateTime get sentAt => items.first.sentAt;
  String get tableName => items.first.tableName;
  String get orderNumber => shortOrderNumber(orderId);

  /// El "MESERO:" de la comanda impresa (misma regla que
  /// `PrintTicketService._resolveItemsAuthorName`): autor único → ese; varios
  /// → el del ítem más reciente; nadie firmó → quien abrió la mesa.
  String? get waiterName {
    final authors = <String>{};
    String? latest;
    DateTime? latestAt;
    for (final item in items) {
      final name = item.author;
      if (name == null) continue;
      authors.add(name);
      if (latestAt == null || !item.createdAt.isBefore(latestAt)) {
        latestAt = item.createdAt;
        latest = name;
      }
    }
    if (authors.length == 1) return authors.first;
    if (authors.isNotEmpty) return latest;
    return items.first.openerName;
  }

  double get units => items.fold(0.0, (s, i) => s + i.quantity);

  /// La nota de la anulación de esta comanda (la primera que haya: todos sus
  /// productos son de la misma orden).
  String? get voidNote {
    for (final i in items) {
      if (i.voidNote != null) return i.voidNote;
    }
    return null;
  }

  /// Cuándo se anuló esta comanda (la primera hora que haya).
  DateTime? get voidAt {
    for (final i in items) {
      if (i.voidAt != null) return i.voidAt;
    }
    return null;
  }

  /// Unidades de esta comanda en un estado de cobro.
  double unitsIn(KitchenChargeState state) => items
      .where((i) => i.chargeState == state)
      .fold(0.0, (s, i) => s + i.quantity);

  /// Los ítems como se leen en una comanda: las filas que dividir la cuenta
  /// partió (4 cervezas → 4 filas de 1) vuelven a juntarse en una línea
  /// "4 × Cerveza", con sus modificadores sumados.
  List<KitchenComandaItem> get displayItems {
    final merged = <String, KitchenComandaItem>{};
    final order = <String>[];
    for (final item in items) {
      final mods = [for (final m in item.modifiers) m.name]..sort();
      final key = '${item.productKey}|${item.notes ?? ''}|${mods.join('|')}';
      final prev = merged[key];
      if (prev == null) {
        merged[key] = item;
        order.add(key);
        continue;
      }
      final modQty = <String, double>{
        for (final m in prev.modifiers) m.name: m.qty,
      };
      for (final m in item.modifiers) {
        modQty[m.name] = (modQty[m.name] ?? 0) + m.qty;
      }
      merged[key] = KitchenComandaItem(
        itemId: prev.itemId,
        orderId: prev.orderId,
        sentAt: prev.sentAt,
        createdAt: prev.createdAt,
        productId: prev.productId,
        productName: prev.productName,
        quantity: prev.quantity + item.quantity,
        notes: prev.notes,
        status: prev.status,
        isTakeout: prev.isTakeout,
        tableName: prev.tableName,
        origin: prev.origin,
        author: prev.author ?? item.author,
        openerName: prev.openerName,
        areaCodes: prev.areaCodes,
        areaNames: prev.areaNames,
        modifiers: [
          for (final m in prev.modifiers)
            KitchenComandaModifier(
              name: m.name,
              qty: _roundModQty(modQty[m.name] ?? m.qty),
            ),
        ],
        unitPrice: prev.unitPrice,
        isCourtesy: prev.isCourtesy,
        orderStatus: prev.orderStatus,
        orderClosedAt: prev.orderClosedAt,
        sessionClosedAt: prev.sessionClosedAt,
        sentSource: prev.sentSource,
        isZeroValue: prev.isZeroValue,
        voidNote: prev.voidNote ?? item.voidNote,
        voidAt: prev.voidAt ?? item.voidAt,
        voidSource: prev.voidSource ?? item.voidSource,
      );
    }
    return [for (final k in order) merged[k]!];
  }

  /// Estaciones a las que fue esta comanda, sin repetir.
  List<String> get areaNames {
    final names = <String>[];
    for (final item in items) {
      for (final name in item.areaNames) {
        if (!names.contains(name)) names.add(name);
      }
    }
    return names;
  }
}

/// "Cuánto salió de cada producto" en el rango.
class KitchenProductTotal {
  const KitchenProductTotal({
    required this.productName,
    required this.quantity,
    required this.comandas,
  });

  final String productName;
  final double quantity;

  /// En cuántas comandas apareció.
  final int comandas;
}

/// Opción del filtro por estación.
class KitchenComandaArea {
  const KitchenComandaArea({required this.code, required this.name});

  final String code;
  final String name;
}

/// Reporte de comandas: cada envío a cocina del rango, en orden cronológico,
/// y el total por producto. Modelo puro; la consulta vive en
/// `KitchenComandaReportRepository`.
class KitchenComandaReport {
  KitchenComandaReport(
    this.allComandas, {
    this.hasChargeData = true,
    this.hasVoidNotes = true,
  }) : comandas = [
         for (final c in allComandas)
           if (c.items.any(_notVoided))
             KitchenComanda(
               orderId: c.orderId,
               items: c.items.where(_notVoided).toList(growable: false),
             ),
       ];

  /// Fuera de las comandas va todo lo anulado: el producto anulado y el de
  /// una orden anulada. Así "Productos" aquí y "Enviado" en el comparador son
  /// el mismo número.
  static bool _notVoided(KitchenComandaItem i) =>
      i.chargeState != KitchenChargeState.voided;

  /// Pseudo-código del filtro para los productos sin área de producción.
  static const noAreaCode = '__none__';

  static final empty = KitchenComandaReport(const []);

  /// false = el servidor tiene una versión vieja de
  /// `fn_kitchen_comandas_report`, sin el estado de la orden y de la mesa.
  /// Sin eso no se sabe qué se cobró: toda orden parecería abierta y todo
  /// saldría "pendiente" (pasó con una orden anulada el 2026-09-19).
  final bool hasChargeData;

  /// false = la RPC del servidor es anterior a las notas de anulación (no
  /// trae `void_note`). Entonces "sin nota" no significa que no se escribió
  /// motivo: significa que el servidor no lo manda.
  final bool hasVoidNotes;

  /// Texto de la nota de una comanda anulada, distinguiendo "no se escribió"
  /// de "el servidor no la manda".
  String voidNoteLabel(KitchenComanda comanda) {
    if (!hasVoidNotes) {
      return 'Nota: (no disponible, falta actualizar la migración 20260919_0001)';
    }
    final at = comanda.voidAt;
    final when = at == null
        ? ''
        : ' (${_two(at.day)}/${_two(at.month)} ${_two(at.hour)}:'
              '${_two(at.minute)})';
    final note = comanda.voidNote;
    return 'Nota$when: ${note ?? '(sin nota)'}';
  }

  /// Todo lo que salió a cocina, incluso lo anulado después. Fuente del
  /// comparador con lo cobrado.
  final List<KitchenComanda> allComandas;

  /// Las comandas sin los productos anulados, del primer envío al último: lo
  /// que se ve, se imprime y se suma en "cuánto salió de cada producto".
  final List<KitchenComanda> comandas;

  bool get isEmpty => comandas.isEmpty;
  int get comandasCount => comandas.length;
  int get ordersCount => comandas.map((c) => c.orderId).toSet().length;
  double get units => comandas.fold(0.0, (s, c) => s + c.units);

  /// Estaciones presentes en el rango, para el filtro. "Sin área" va al final
  /// y solo si hay productos sin área.
  List<KitchenComandaArea> get areas {
    final byCode = <String, String>{};
    var hasNoArea = false;
    for (final c in allComandas) {
      for (final item in c.items) {
        if (item.areaCodes.isEmpty) hasNoArea = true;
        for (var i = 0; i < item.areaCodes.length; i++) {
          byCode.putIfAbsent(
            item.areaCodes[i],
            () => i < item.areaNames.length
                ? item.areaNames[i]
                : item.areaCodes[i],
          );
        }
      }
    }
    final list = [
      for (final e in byCode.entries)
        KitchenComandaArea(code: e.key, name: e.value),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (hasNoArea) {
      list.add(const KitchenComandaArea(code: noAreaCode, name: 'Sin área'));
    }
    return list;
  }

  /// Lo que salió por UNA estación. Un producto con dos áreas (Cocina y Bar)
  /// cuenta en las dos, igual que imprime una comanda en cada una. Sin
  /// filtro ([code] null) cada ítem cuenta una sola vez.
  KitchenComandaReport forArea(String? code) {
    if (code == null) return this;
    bool keep(KitchenComandaItem i) =>
        code == noAreaCode ? i.areaCodes.isEmpty : i.areaCodes.contains(code);
    return KitchenComandaReport(
      hasChargeData: hasChargeData,
      hasVoidNotes: hasVoidNotes,
      [
        for (final c in allComandas)
          if (c.items.any(keep))
            KitchenComanda(
              orderId: c.orderId,
              items: c.items.where(keep).toList(growable: false),
            ),
      ],
    );
  }

  /// Las comandas que tienen productos en [state], con SOLO esos productos:
  /// "cuáles fueron las comandas que no se cobraron". Del primer envío al
  /// último.
  List<KitchenComanda> comandasIn(KitchenChargeState state) => [
    for (final c in allComandas)
      if (c.items.any((i) => i.chargeState == state))
        KitchenComanda(
          orderId: c.orderId,
          items: c.items
              .where((i) => i.chargeState == state)
              .toList(growable: false),
        ),
  ];

  /// Como [comandasIn] pero con varios estados a la vez (p. ej. cobrado en
  /// dinero y cobrado a 0).
  List<KitchenComanda> comandasInAny(Set<KitchenChargeState> states) => [
    for (final c in allComandas)
      if (c.items.any((i) => states.contains(i.chargeState)))
        KitchenComanda(
          orderId: c.orderId,
          items: c.items
              .where((i) => states.contains(i.chargeState))
              .toList(growable: false),
        ),
  ];

  /// Lo abierto agrupado por cuenta (una por orden), solo lo que de verdad
  /// se debe: una cortesía o un producto a 0 en una mesa abierta no está
  /// "sin cobrar". Para el reporte cargado en modo "aún sin cobrar".
  List<KitchenAccount> get openAccounts => _accountsWhere(
    (i) =>
        i.chargeState == KitchenChargeState.pending ||
        i.chargeState == KitchenChargeState.unpaid,
  );

  /// Todo agrupado por cuenta, sin filtrar. Para el reporte cargado en modo
  /// "cobrado sin comanda" (ahí `since` es la hora del cobro).
  List<KitchenAccount> get accounts => _accountsWhere((_) => true);

  List<KitchenAccount> _accountsWhere(bool Function(KitchenComandaItem) keep) {
    final byOrder = <String, List<KitchenComanda>>{};
    for (final c in allComandas) {
      final items = c.items.where(keep).toList(growable: false);
      if (items.isEmpty) continue;
      byOrder
          .putIfAbsent(c.orderId, () => [])
          .add(KitchenComanda(orderId: c.orderId, items: items));
    }
    final result = [
      for (final e in byOrder.entries)
        KitchenAccount(orderId: e.key, comandas: e.value),
    ];
    // Lo más viejo primero.
    result.sort((a, b) {
      final byDate = a.since.compareTo(b.since);
      return byDate != 0 ? byDate : a.orderId.compareTo(b.orderId);
    });
    return result;
  }

  /// Enviado a cocina vs. cobrado: por producto y cada producto que no se
  /// cobró normal.
  KitchenChargeComparison get comparison =>
      KitchenChargeComparison.fromComandas(allComandas);

  /// Total por producto, el que más salió primero.
  List<KitchenProductTotal> get productTotals {
    final qty = <String, double>{};
    final names = <String, String>{};
    final inComandas = <String, int>{};
    for (final c in comandas) {
      final seen = <String>{};
      for (final item in c.items) {
        final key = item.productKey;
        qty[key] = (qty[key] ?? 0) + item.quantity;
        // El nombre del envío más reciente: si lo renombraron, sale el nuevo.
        names[key] = item.productName;
        if (seen.add(key)) inComandas[key] = (inComandas[key] ?? 0) + 1;
      }
    }
    final list = [
      for (final key in qty.keys)
        KitchenProductTotal(
          productName: names[key]!,
          quantity: qty[key]!,
          comandas: inComandas[key] ?? 0,
        ),
    ];
    list.sort((a, b) {
      final byQty = b.quantity.compareTo(a.quantity);
      return byQty != 0
          ? byQty
          : a.productName.toLowerCase().compareTo(b.productName.toLowerCase());
    });
    return list;
  }

  /// Agrupa los ítems en comandas: misma orden + misma marca de ronda.
  factory KitchenComandaReport.fromRows(List<Map<String, dynamic>> rows) {
    final byKey = <String, List<KitchenComandaItem>>{};
    for (final row in rows) {
      final item = KitchenComandaItem.fromRow(row);
      if (item == null) continue;
      final key = '${item.orderId}|${item.sentAt.microsecondsSinceEpoch}';
      byKey.putIfAbsent(key, () => []).add(item);
    }
    final comandas =
        [
          for (final items in byKey.values)
            KitchenComanda(
              orderId: items.first.orderId,
              items: [...items]
                ..sort((a, b) {
                  final byDate = a.createdAt.compareTo(b.createdAt);
                  return byDate != 0 ? byDate : a.itemId.compareTo(b.itemId);
                }),
            ),
        ]..sort((a, b) {
          final byDate = a.sentAt.compareTo(b.sentAt);
          return byDate != 0 ? byDate : a.orderId.compareTo(b.orderId);
        });
    return KitchenComandaReport(
      comandas,
      // La columna más nueva de la RPC: si viene, vienen todas las de cobro.
      hasChargeData:
          rows.isEmpty || rows.any((r) => r.containsKey('is_zero_value')),
      hasVoidNotes: rows.isEmpty || rows.any((r) => r.containsKey('void_note')),
    );
  }
}

/// Una cuenta (una orden) con sus productos: lo que sigue sin cobrar ahora,
/// o lo que se cobró sin comanda.
class KitchenAccount {
  const KitchenAccount({required this.orderId, required this.comandas});

  final String orderId;

  /// Sus comandas, del primer envío al último.
  final List<KitchenComanda> comandas;

  List<KitchenComandaItem> get items => [for (final c in comandas) ...c.items];

  String get tableName => comandas.first.tableName;
  String get orderNumber => shortOrderNumber(orderId);

  /// Primer envío a cocina (desde cuándo se debe); en "cobrado sin comanda",
  /// la hora del cobro.
  DateTime get since => comandas.first.sentAt;

  /// Mesero de la última comanda (quien la está atendiendo).
  String? get waiterName => comandas.last.waiterName;

  double get units => comandas.fold(0.0, (s, c) => s + c.units);

  /// La mesa ya se cerró pero la orden sigue viva: nadie la va a cobrar
  /// desde el salón.
  bool get isOrphan => comandas.first.items.first.sessionClosedAt != null;

  /// Todos sus productos en líneas ("4 × Cerveza"), juntando las comandas.
  List<KitchenComandaItem> get displayItems =>
      KitchenComanda(orderId: orderId, items: items).displayItems;
}

/// Una fila del comparador: un producto, cuánto salió a cocina y qué pasó
/// con eso en caja.
class KitchenChargeProductRow {
  const KitchenChargeProductRow({
    required this.productName,
    this.sent = 0,
    this.charged = 0,
    this.courtesy = 0,
    this.zeroCharge = 0,
    this.pending = 0,
    this.unpaid = 0,
    this.voided = 0,
  });

  final String productName;

  /// Enviado a cocina, sin contar lo anulado (igual que las comandas).
  final double sent;

  /// Cobrado: quedó en una factura. INCLUYE las cortesías (van en la factura
  /// en cero), igual que los productos del reporte de Ventas.
  final double charged;

  /// De lo cobrado, cuánto fue cortesía.
  final double courtesy;

  /// De lo cobrado, cuánto fue a 0 (precio 0 o gratis por promoción).
  final double zeroCharge;
  final double pending;
  final double unpaid;

  /// Anulado después de enviarse. Va aparte: ya no está en la cuenta, así
  /// que no forma parte de la diferencia.
  final double voided;

  /// Enviado − cobrado = pendiente + sin cobrar.
  double get difference => sent - charged;

  bool get hasDifference => difference > 0.005;

  /// Algo que mirar: diferencia, cortesía o anulado.
  bool get needsReview => hasDifference || courtesy > 0.005 || voided > 0.005;
}

/// Un producto enviado a cocina que no se cobró normal (sin cobrar,
/// pendiente, cortesía o anulado), con su comanda para saber cuándo, dónde y
/// quién.
class KitchenChargeDifference {
  const KitchenChargeDifference({required this.comanda, required this.item});

  final KitchenComanda comanda;
  final KitchenComandaItem item;

  KitchenChargeState get state => item.chargeState;
}

/// Una comanda con los productos que quedaron en un mismo estado de cobro.
class KitchenChargeComandaGroup {
  const KitchenChargeComandaGroup({required this.state, required this.comanda});

  final KitchenChargeState state;

  /// La comanda con SOLO los productos en [state].
  final KitchenComanda comanda;

  /// Todos son de la misma orden: el motivo es el mismo.
  String? get reason => comanda.items.first.stateReason;

  /// La nota de la anulación, si se escribió una.
  String? get note => comanda.voidNote;
}

/// Comparador "enviado a cocina vs. cobrado".
class KitchenChargeComparison {
  const KitchenChargeComparison({
    required this.products,
    required this.differences,
  });

  /// Primero lo que hay que revisar: sin cobrar, luego la diferencia más
  /// grande.
  final List<KitchenChargeProductRow> products;

  /// Sin cobrar primero, después pendiente, cortesía y anulado; dentro de
  /// cada estado, del primer envío al último.
  final List<KitchenChargeDifference> differences;

  double _sum(double Function(KitchenChargeProductRow) f) =>
      products.fold(0.0, (s, p) => s + f(p));

  double get sent => _sum((p) => p.sent);
  double get charged => _sum((p) => p.charged);
  double get courtesy => _sum((p) => p.courtesy);
  double get zeroCharge => _sum((p) => p.zeroCharge);
  double get pending => _sum((p) => p.pending);
  double get unpaid => _sum((p) => p.unpaid);
  double get voided => _sum((p) => p.voided);

  /// Enviado − cobrado = pendiente + sin cobrar.
  double get difference => sent - charged;

  /// Todo lo que salió a cocina quedó en una factura (puede haber cortesías
  /// y anulados, pero nada pendiente ni sin cobrar).
  bool get allCharged => pending + unpaid < 0.005;

  /// Las diferencias agrupadas POR COMANDA: una entrada por comanda y
  /// estado, con solo los productos en ese estado. Mismo orden que
  /// [differences] (sin cobrar primero; dentro, del primer envío al último).
  List<KitchenChargeComandaGroup> get byComanda {
    final groups = <String, List<KitchenChargeDifference>>{};
    for (final d in differences) {
      final key =
          '${d.state.name}|${d.comanda.orderId}|'
          '${d.comanda.sentAt.microsecondsSinceEpoch}';
      groups.putIfAbsent(key, () => []).add(d);
    }
    return [
      for (final g in groups.values)
        KitchenChargeComandaGroup(
          state: g.first.state,
          comanda: KitchenComanda(
            orderId: g.first.comanda.orderId,
            items: [for (final d in g) d.item],
          ),
        ),
    ];
  }

  static const _stateOrder = [
    KitchenChargeState.unpaid,
    KitchenChargeState.pending,
    KitchenChargeState.courtesy,
    KitchenChargeState.voided,
  ];

  factory KitchenChargeComparison.fromComandas(List<KitchenComanda> comandas) {
    final names = <String, String>{};
    final byProduct = <String, Map<KitchenChargeState, double>>{};
    final differences = <KitchenChargeDifference>[];
    for (final c in comandas) {
      for (final item in c.items) {
        final key = item.productKey;
        names[key] = item.productName;
        final state = item.chargeState;
        final bucket = byProduct.putIfAbsent(key, () => {});
        bucket[state] = (bucket[state] ?? 0) + item.quantity;
        // Cobrado a 0 no es diferencia: no había nada que cobrar.
        if (state != KitchenChargeState.charged &&
            state != KitchenChargeState.zeroCharge) {
          differences.add(KitchenChargeDifference(comanda: c, item: item));
        }
      }
    }

    final products = <KitchenChargeProductRow>[];
    byProduct.forEach((key, b) {
      double q(KitchenChargeState s) => b[s] ?? 0;
      final charged =
          q(KitchenChargeState.charged) +
          q(KitchenChargeState.courtesy) +
          q(KitchenChargeState.zeroCharge);
      products.add(
        KitchenChargeProductRow(
          productName: names[key]!,
          sent:
              charged +
              q(KitchenChargeState.pending) +
              q(KitchenChargeState.unpaid),
          charged: charged,
          courtesy: q(KitchenChargeState.courtesy),
          zeroCharge: q(KitchenChargeState.zeroCharge),
          pending: q(KitchenChargeState.pending),
          unpaid: q(KitchenChargeState.unpaid),
          voided: q(KitchenChargeState.voided),
        ),
      );
    });
    products.sort((a, b) {
      for (final cmp in [
        b.unpaid.compareTo(a.unpaid),
        b.difference.compareTo(a.difference),
        b.courtesy.compareTo(a.courtesy),
        b.voided.compareTo(a.voided),
        b.sent.compareTo(a.sent),
      ]) {
        if (cmp != 0) return cmp;
      }
      return a.productName.toLowerCase().compareTo(b.productName.toLowerCase());
    });

    // List.sort no es estable: se ordena por índice para desempatar por la
    // posición original.
    final indexed = [for (var i = 0; i < differences.length; i++) i]
      ..sort((x, y) {
        final a = differences[x];
        final b = differences[y];
        final byState = _stateOrder
            .indexOf(a.state)
            .compareTo(_stateOrder.indexOf(b.state));
        if (byState != 0) return byState;
        final byDate = a.comanda.sentAt.compareTo(b.comanda.sentAt);
        return byDate != 0 ? byDate : x.compareTo(y);
      });

    return KitchenChargeComparison(
      products: products,
      differences: [for (final i in indexed) differences[i]],
    );
  }
}

String? _clean(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

String _two(int v) => v.toString().padLeft(2, '0');

/// Los modificadores prorrateados al dividir (1/3 = 0.333) suman 0.999: a
/// dos decimales vuelve a ser 1.
double _roundModQty(double v) => (v * 100).roundToDouble() / 100;

double _toDouble(Object? v, {double fallback = 0}) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? fallback;
  return fallback;
}

List<String> _stringList(Object? v) => v is List
    ? [
        for (final e in v)
          if (_clean(e) != null) _clean(e)!,
      ]
    : const [];
