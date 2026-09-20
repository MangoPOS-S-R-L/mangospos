import '../../core/utils/app_time.dart';
import 'kitchen_comanda_report.dart';

/// Cómo desapareció un producto que salió a cocina (columna `missing_kind`
/// de `fn_kitchen_missing_report`, migración 20260919_0002).
enum KitchenMissingKind {
  /// Se borró de la cuenta después de enviarse.
  deleted,

  /// Se le bajó la cantidad después de enviarse (la cantidad es lo quitado).
  reduced,

  /// La orden sigue viva pero su mesa se cerró: nadie la va a cobrar.
  orphan,

  /// Se cargó a una orden que ya estaba cerrada o anulada.
  loadedAfterClose,

  /// Quedó en una subcuenta cerrada: no suma al total que se cobra.
  closedCheck,

  /// La orden se cobró sin este producto.
  chargedWithout;

  static KitchenMissingKind? parse(Object? raw) => switch (raw?.toString()) {
    'deleted' => deleted,
    'reduced' => reduced,
    'orphan' => orphan,
    'loaded_after_close' => loadedAfterClose,
    'closed_check' => closedCheck,
    'charged_without' => chargedWithout,
    _ => null,
  };

  /// Alguien lo quitó de la cuenta (queda registro de quién y por qué). Lo
  /// demás sigue en la base pero ninguna cuenta viva lo muestra.
  bool get isRemoval => this == deleted || this == reduced;

  String get label => switch (this) {
    deleted => 'Borrado de la cuenta',
    reduced => 'Cantidad reducida',
    orphan => 'Orden huérfana',
    loadedAfterClose => 'Cargado a una orden cerrada',
    closedCheck => 'En una subcuenta cerrada',
    chargedWithout => 'Cobrada sin este producto',
  };

  /// Por qué ninguna cuenta lo muestra (solo lo que no se quitó a mano).
  String? get explanation => switch (this) {
    orphan => 'La mesa se cerró con la orden abierta: no sale en el salón.',
    loadedAfterClose => 'Se cargó después de cerrar o anular la orden.',
    closedCheck => 'Quedó en una subcuenta cerrada: no suma al total.',
    chargedWithout => 'La orden se cobró sin este producto.',
    _ => null,
  };
}

/// Un producto enviado a cocina que desapareció de la cuenta.
class KitchenMissingItem {
  const KitchenMissingItem({
    required this.item,
    required this.kind,
    this.removedAt,
    this.reason,
    this.removedBy,
    this.qtyBefore,
    this.qtyAfter,
  });

  /// El producto tal como salió en la comanda. En lo reducido, `quantity`
  /// es lo que se quitó.
  final KitchenComandaItem item;
  final KitchenMissingKind kind;

  /// Cuándo se borró o se redujo (hora de pared AST).
  final DateTime? removedAt;

  /// El motivo que se escribió. Null = no se anotó.
  final String? reason;

  /// Quién lo hizo (el operador con PIN, o la cuenta de la tablet).
  final String? removedBy;
  final double? qtyBefore;
  final double? qtyAfter;

  double get quantity => item.quantity;

  /// "Borrado 18/09 21:14 por Ana · Motivo: cliente no lo quiso", "Reducido
  /// de 3 a 1 …", o la explicación de por qué ninguna cuenta lo muestra.
  String get detail {
    if (!kind.isRemoval) return kind.explanation ?? '';
    final parts = <String>[];
    final at = removedAt;
    final when = at == null ? '' : ' ${_stamp(at)}';
    if (kind == KitchenMissingKind.reduced) {
      final from = qtyBefore;
      final to = qtyAfter;
      parts.add(
        from != null && to != null
            ? 'Reducido de ${_fmt(from)} a ${_fmt(to)}$when'
            : 'Reducido$when',
      );
    } else {
      parts.add('Borrado$when');
    }
    if (removedBy != null) parts.add('por $removedBy');
    return '${parts.join(' ')} · Motivo: ${reason ?? '(no se anotó)'}';
  }

  static KitchenMissingItem? fromRow(Map<String, dynamic> row) {
    final kind = KitchenMissingKind.parse(row['missing_kind']);
    final item = KitchenComandaItem.fromRow(row);
    if (kind == null || item == null) return null;
    return KitchenMissingItem(
      item: item,
      kind: kind,
      removedAt: AppTime.tryParseServerToAst(row['removed_at']),
      reason: _clean(row['removed_reason']),
      removedBy: _clean(row['removed_by']),
      qtyBefore: _toDoubleOrNull(row['qty_before']),
      qtyAfter: _toDoubleOrNull(row['qty_after']),
    );
  }
}

/// Una comanda (orden + envío) con sus productos que desaparecieron de una
/// misma forma.
class KitchenMissingGroup {
  const KitchenMissingGroup({required this.kind, required this.entries});

  final KitchenMissingKind kind;
  final List<KitchenMissingItem> entries;

  /// La comanda: mesa, número de orden, hora de envío y mesero.
  KitchenComanda get comanda => KitchenComanda(
    orderId: entries.first.item.orderId,
    items: [for (final e in entries) e.item],
  );

  double get units => entries.fold(0.0, (s, e) => s + e.quantity);
}

/// Las comandas "desaparecidas" del rango: lo que salió a cocina y hoy no
/// está en ninguna cuenta. Dos grupos:
///   * [removals]: se borró o se redujo después de enviarse (desde que existe
///     el registro de la migración 20260919_0002).
///   * [outsideAccounts]: sigue en la base, pero ninguna cuenta viva lo
///     muestra (huérfana, cargado a una orden cerrada, subcuenta cerrada,
///     cobrada sin él).
class KitchenMissingReport {
  KitchenMissingReport(List<KitchenMissingItem> entries)
    : entries = List.unmodifiable(entries);

  static final empty = KitchenMissingReport(const []);

  /// Del primer envío al último.
  final List<KitchenMissingItem> entries;

  bool get isEmpty => entries.isEmpty;

  List<KitchenMissingItem> get removals =>
      entries.where((e) => e.kind.isRemoval).toList(growable: false);

  List<KitchenMissingItem> get outsideAccounts =>
      entries.where((e) => !e.kind.isRemoval).toList(growable: false);

  double get removedUnits => removals.fold(0.0, (s, e) => s + e.quantity);
  double get outsideUnits =>
      outsideAccounts.fold(0.0, (s, e) => s + e.quantity);

  /// Agrupadas por comanda y forma de desaparecer, del primer envío al
  /// último.
  List<KitchenMissingGroup> groups({required bool removals}) {
    final byKey = <String, List<KitchenMissingItem>>{};
    for (final e in entries) {
      if (e.kind.isRemoval != removals) continue;
      final key =
          '${e.kind.name}|${e.item.orderId}|'
          '${e.item.sentAt.microsecondsSinceEpoch}';
      byKey.putIfAbsent(key, () => []).add(e);
    }
    final list = [
      for (final g in byKey.values)
        KitchenMissingGroup(kind: g.first.kind, entries: g),
    ];
    list.sort((a, b) {
      final byDate = a.entries.first.item.sentAt.compareTo(
        b.entries.first.item.sentAt,
      );
      return byDate != 0
          ? byDate
          : a.entries.first.item.orderId.compareTo(
              b.entries.first.item.orderId,
            );
    });
    return list;
  }

  /// Mismo filtro por estación que [KitchenComandaReport.forArea].
  KitchenMissingReport forArea(String? code) {
    if (code == null) return this;
    return KitchenMissingReport([
      for (final e in entries)
        if (code == KitchenComandaReport.noAreaCode
            ? e.item.areaCodes.isEmpty
            : e.item.areaCodes.contains(code))
          e,
    ]);
  }

  factory KitchenMissingReport.fromRows(List<Map<String, dynamic>> rows) {
    final entries = [for (final row in rows) ?KitchenMissingItem.fromRow(row)];
    // List.sort no es estable: se desempata por la posición original.
    final indexed = [for (var i = 0; i < entries.length; i++) i]
      ..sort((x, y) {
        final byDate = entries[x].item.sentAt.compareTo(entries[y].item.sentAt);
        return byDate != 0 ? byDate : x.compareTo(y);
      });
    return KitchenMissingReport([for (final i in indexed) entries[i]]);
  }
}

String? _clean(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

double? _toDoubleOrNull(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

String _two(int v) => v.toString().padLeft(2, '0');

String _stamp(DateTime at) =>
    '${_two(at.day)}/${_two(at.month)} ${_two(at.hour)}:${_two(at.minute)}';

/// 3 → "3", 0.5 → "0.5".
String _fmt(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}
