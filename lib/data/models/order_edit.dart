import 'package:uuid/uuid.dart';

import 'sales_models.dart';

/// T04 (20261010_0006): lo que el operador estaba editando. El servidor
/// rechaza la edición si la línea (o la cuenta) ya no está como la veía.
class OrderEditBase {
  const OrderEditBase._({this.version, this.expected, this.force = false});

  /// Versión del servidor que el operador estaba viendo.
  final int? version;

  /// Sin versión (línea creada sin red): los valores que el operador veía.
  final Map<String, dynamic>? expected;

  /// El operador decidió, ante un conflicto, aplicar su cambio sobre lo
  /// vigente.
  final bool force;

  /// Una línea: su versión; sin ella, los valores que se veían.
  factory OrderEditBase.ofItem(OrderItem item) => item.version != null
      ? OrderEditBase._(version: item.version)
      : OrderEditBase._(expected: expectedValuesOf(item));

  /// La cuenta: su versión (null si no se conoce).
  factory OrderEditBase.ofOrder(Order? order) =>
      OrderEditBase._(version: order?.version);

  factory OrderEditBase.ofVersion(int? version) =>
      OrderEditBase._(version: version);

  /// Aplica sobre lo vigente (solo por decisión explícita del operador).
  static const OrderEditBase forced = OrderEditBase._(force: true);

  /// Los valores de una línea que puede cambiar el operador, como los guarda
  /// el servidor (notas vacías = null).
  static Map<String, dynamic> expectedValuesOf(OrderItem item) {
    final notes = item.notes?.trim();
    return {
      'qty': item.quantity,
      'notes': (notes == null || notes.isEmpty) ? null : notes,
      'is_takeout': item.isTakeout,
      'discounts': item.discounts,
    };
  }

  /// Campos que viajan en una acción de la cola offline.
  Map<String, dynamic> toAction() => {
    'base_version': version,
    'expected': ?expected,
    if (force) 'force_apply': true,
  };

  static OrderEditBase fromAction(Map<String, dynamic> action) {
    if (action['force_apply'] == true) return forced;
    final rawExpected = action['expected'];
    return OrderEditBase._(
      version: (action['base_version'] as num?)?.toInt(),
      expected: rawExpected is Map
          ? Map<String, dynamic>.from(rawExpected)
          : null,
    );
  }
}

/// Una edición: cuenta, identificador único (los reintentos lo repiten) y lo
/// que el operador estaba editando.
class OrderEdit {
  OrderEdit({required this.orderId, required this.base, String? opId})
    : opId = opId ?? const Uuid().v4();

  final String orderId;
  final String opId;
  final OrderEditBase base;
}

/// Respuesta de fn_apply_order_edit.
class OrderEditResult {
  const OrderEditResult({
    required this.status,
    this.reason,
    this.version,
    this.current,
    this.replayed = false,
    this.versions = const {},
    this.removedIds = const [],
  });

  factory OrderEditResult.fromMap(Map<String, dynamic> map) => OrderEditResult(
    status: map['status']?.toString() ?? 'conflict',
    reason: map['reason']?.toString(),
    version:
        (map['version'] as num?)?.toInt() ??
        (map['current_version'] as num?)?.toInt(),
    current: map['current'] is Map
        ? Map<String, dynamic>.from(map['current'] as Map)
        : null,
    replayed: map['replayed'] == true,
    versions: {
      if (map['versions'] is Map)
        for (final entry in (map['versions'] as Map).entries)
          if (entry.value is num)
            entry.key.toString(): (entry.value as num).toInt(),
    },
    removedIds: [
      if (map['removed'] is List)
        for (final id in map['removed'] as List) id.toString(),
    ],
  );

  final String status;
  final String? reason;

  /// La versión vigente: la nueva si se aplicó, la actual si hubo conflicto.
  final int? version;

  /// Estado actual de la línea (o de la cuenta) en el servidor.
  final Map<String, dynamic>? current;
  final bool replayed;

  /// Lote (mover / unir líneas): la versión nueva de cada línea.
  final Map<String, int> versions;

  /// Unir líneas: las que se sumaron a otra y ya no existen.
  final List<String> removedIds;

  bool get applied => status == 'applied';
}

/// Otro equipo cambió lo que el operador estaba editando: la edición no se
/// aplicó. Se conserva la intención para que el operador decida.
class OrderEditConflict implements Exception {
  const OrderEditConflict(this.result);

  final OrderEditResult result;

  String get message => switch (result.reason) {
    'order_closed' => 'La cuenta ya se cerró en otro equipo.',
    'item_missing' => 'Otro equipo quitó este producto de la cuenta.',
    'item_closed' => 'Este producto ya se cobró o se anuló en otro equipo.',
    'check_closed' =>
      'Esta subcuenta ya se cobró o se cerró. Recarga la división.',
    'check_exists' =>
      'Otro equipo creó una subcuenta en esa posición. Recarga la división.',
    'check_not_empty' =>
      'La subcuenta recibió productos nuevos. Recarga antes de retirarla.',
    _ => 'Otro equipo cambió esto mientras lo editabas.',
  };

  /// Lo que hay ahora en el servidor, en palabras.
  String? get currentDescription {
    final current = result.current;
    if (current == null) return null;
    String amount(num value) =>
        value % 1 == 0 ? value.toInt().toString() : value.toStringAsFixed(2);
    final parts = <String>[];
    final qty = current['qty'];
    if (qty is num) parts.add('cantidad ${amount(qty)}');
    final notes = current['notes']?.toString().trim();
    if (notes != null && notes.isNotEmpty) parts.add('nota «$notes»');
    if (current['is_takeout'] == true) parts.add('para llevar');
    final discounts = current['discounts'];
    if (discounts is num && discounts > 0) {
      parts.add('descuento ${amount(discounts)}');
    }
    final fee = current['delivery_fee'];
    if (fee is num && fee > 0) parts.add('delivery ${amount(fee)}');
    return parts.isEmpty ? null : 'Ahora: ${parts.join(', ')}.';
  }

  @override
  String toString() => 'OrderEditConflict(${result.reason}): $message';
}

/// El servidor no tiene la migración 20261010_0006: no se edita (nunca sin
/// versión).
class OrderEditServerOutdated implements Exception {
  const OrderEditServerOutdated();

  // «Falta aplicar la migración»: la cola offline lo reconoce y conserva la
  // acción sin mandarla a dead-letter.
  static const message =
      'Falta aplicar la migración 20261010_0006 en el servidor para editar '
      'cuentas. Avísale al administrador.';

  @override
  String toString() => message;
}
