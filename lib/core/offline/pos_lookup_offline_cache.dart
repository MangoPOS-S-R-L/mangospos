import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/storage_service.dart';

/// Cache en disco de las consultas que el POS hace ANTES de dejar vender: los
/// impuestos del negocio y los modificadores / grupos de combo de cada
/// producto.
///
/// Por qué existe (caída de red del 2026-09-19, producción parada): las dos
/// vivían solo en memoria y se pedían a la red en el momento.
/// - Modificadores: se consultan antes de CADA `addItem`. Sin red, cualquier
///   producto que no se hubiera tocado desde que abrió la app no entraba a la
///   orden, y el error iba solo al log.
/// - Impuestos: al fallar la consulta se vaciaban y se marcaba
///   `taxConfigError`, que bloquea el cobro. Sin red no se podía cobrar.
///
/// Son datos de configuración que cambian poco y que el servidor recalcula al
/// sincronizar, así que servir la última copia buena es seguro.
///
/// Todo va en UNA clave por negocio y en claro (no hay datos sensibles), con
/// los grupos normalizados por id: un mismo grupo ("Término", "Salsas") lo
/// comparten decenas de productos y guardarlo por producto multiplicaría el
/// tamaño. La clave termina en el businessId, como exige `OfflineCachePruner`.
class PosLookupOfflineCache {
  PosLookupOfflineCache._();

  static final PosLookupOfflineCache _instance = PosLookupOfflineCache._();
  factory PosLookupOfflineCache() => _instance;

  @visibleForTesting
  PosLookupOfflineCache.forTesting(StorageService storage)
    : _injected = storage;

  StorageService? _injected;
  Future<StorageService> get _storage async =>
      _injected ?? await StorageService.getInstance();

  static const taxesPrefix = 'offline_business_taxes_';
  static const itemOptionsPrefix = 'offline_item_options_';
  static const receiptBusinessPrefix = 'offline_receipt_business_';
  static const cashReasonsPrefix = 'offline_cash_reasons_';

  /// Escrituras en serie por clave: dos productos consultados a la vez no se
  /// pisan el blob.
  final Map<String, Future<void>> _writeChain = {};

  // ---------------------------------------------------------------------------
  // Impuestos del negocio
  // ---------------------------------------------------------------------------

  Future<void> saveBusinessTaxes(
    String businessId,
    List<Map<String, dynamic>> rows,
  ) async {
    if (businessId.isEmpty) return;
    try {
      final storage = await _storage;
      await storage.write(
        '$taxesPrefix$businessId',
        jsonEncode({
          'saved_at': DateTime.now().toIso8601String(),
          'rows': rows,
        }),
      );
    } catch (e) {
      debugPrint('PosLookupOfflineCache.saveBusinessTaxes error: $e');
    }
  }

  /// `null` si nunca se guardaron. Una lista vacía guardada es un dato válido
  /// (negocio sin impuestos) y se devuelve tal cual.
  Future<List<Map<String, dynamic>>?> loadBusinessTaxes(
    String businessId,
  ) async {
    if (businessId.isEmpty) return null;
    try {
      final storage = await _storage;
      final raw = await storage.read('$taxesPrefix$businessId');
      if (raw == null || raw.isEmpty) return null;
      final payload = jsonDecode(raw);
      if (payload is! Map || payload['rows'] is! List) return null;
      return (payload['rows'] as List)
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
    } catch (e) {
      debugPrint('PosLookupOfflineCache.loadBusinessTaxes error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Encabezado del recibo (nombre fiscal, RNC, dirección, teléfono)
  // ---------------------------------------------------------------------------

  /// Fila de `businesses` que usan precuenta y factura para el encabezado.
  /// Sin ella, sin red el papel salía sin RNC ni dirección.
  Future<void> saveReceiptBusinessRow(
    String businessId,
    Map<String, dynamic> row,
  ) async {
    if (businessId.isEmpty) return;
    try {
      final storage = await _storage;
      await storage.write('$receiptBusinessPrefix$businessId', jsonEncode(row));
    } catch (e) {
      debugPrint('PosLookupOfflineCache.saveReceiptBusinessRow error: $e');
    }
  }

  Future<Map<String, dynamic>?> loadReceiptBusinessRow(
    String businessId,
  ) async {
    if (businessId.isEmpty) return null;
    try {
      final storage = await _storage;
      final raw = await storage.read('$receiptBusinessPrefix$businessId');
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (e) {
      debugPrint('PosLookupOfflineCache.loadReceiptBusinessRow error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Razones de movimientos de caja (gastos / ingresos)
  // ---------------------------------------------------------------------------

  /// La razón es obligatoria para registrar un gasto: sin el catálogo en disco
  /// la pantalla de ingresos/egresos no dejaba registrar nada sin red, aunque
  /// el movimiento en sí ya sabe encolarse.
  Future<void> saveCashReasons(
    String businessId,
    List<Map<String, dynamic>> rows,
  ) async {
    if (businessId.isEmpty) return;
    try {
      final storage = await _storage;
      await storage.write('$cashReasonsPrefix$businessId', jsonEncode(rows));
    } catch (e) {
      debugPrint('PosLookupOfflineCache.saveCashReasons error: $e');
    }
  }

  Future<List<Map<String, dynamic>>?> loadCashReasons(String businessId) async {
    if (businessId.isEmpty) return null;
    try {
      final storage = await _storage;
      final raw = await storage.read('$cashReasonsPrefix$businessId');
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return decoded
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
    } catch (e) {
      debugPrint('PosLookupOfflineCache.loadCashReasons error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Modificadores y combos por producto
  // ---------------------------------------------------------------------------

  /// Guarda los grupos de modificadores de UN producto, con la forma exacta
  /// que devuelve `SalesRepository.getModifierGroupsForMenuItem`
  /// (`{group_id, position, modifier_groups: {...}}`).
  Future<void> saveModifierGroups(
    String businessId,
    String menuItemId,
    List<Map<String, dynamic>> rows,
  ) {
    return _mutate(businessId, (blob) {
      _putModifierRows(blob, menuItemId, rows);
    });
  }

  /// Reemplaza todos los modificadores del negocio de una vez (bajada en
  /// background). `rowsByItem` trae cada producto con grupos; los productos
  /// sin grupos se marcan como "sin modificadores" para no bloquear offline.
  Future<void> replaceAllModifierGroups(
    String businessId,
    Map<String, List<Map<String, dynamic>>> rowsByItem, {
    Iterable<String> itemsWithoutGroups = const [],
  }) {
    return _mutate(businessId, (blob) {
      blob['groups'] = <String, dynamic>{};
      blob['modifier_items'] = <String, dynamic>{};
      rowsByItem.forEach(
        (itemId, rows) => _putModifierRows(blob, itemId, rows),
      );
      for (final itemId in itemsWithoutGroups) {
        (blob['modifier_items'] as Map)[itemId] = const <dynamic>[];
      }
    });
  }

  /// Grupos del producto, o `null` si este equipo nunca los bajó.
  Future<List<Map<String, dynamic>>?> loadModifierGroups(
    String businessId,
    String menuItemId,
  ) async {
    final blob = await _read(businessId);
    final links = (blob['modifier_items'] as Map?)?[menuItemId];
    if (links is! List) return null;
    final groups = blob['groups'] as Map? ?? const {};
    final rows = <Map<String, dynamic>>[];
    for (final link in links.whereType<Map>()) {
      final groupId = link['group_id']?.toString();
      final group = groups[groupId];
      if (group is! Map) continue;
      rows.add({
        'group_id': groupId,
        'position': link['position'],
        // Copia profunda: el llamador puede mutar (ordena `modifiers`).
        'modifier_groups': jsonDecode(jsonEncode(group)),
      });
    }
    return rows;
  }

  Future<void> saveComboGroups(
    String businessId,
    String menuItemId,
    List<Map<String, dynamic>> rows,
  ) {
    return _mutate(businessId, (blob) {
      final combos = (blob['combo_items'] as Map?) ?? <String, dynamic>{};
      combos[menuItemId] = rows;
      blob['combo_items'] = combos;
    });
  }

  Future<List<Map<String, dynamic>>?> loadComboGroups(
    String businessId,
    String menuItemId,
  ) async {
    final blob = await _read(businessId);
    final rows = (blob['combo_items'] as Map?)?[menuItemId];
    if (rows is! List) return null;
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(jsonDecode(jsonEncode(row))))
        .toList(growable: false);
  }

  void _putModifierRows(
    Map<String, dynamic> blob,
    String menuItemId,
    List<Map<String, dynamic>> rows,
  ) {
    final groups = (blob['groups'] as Map?) ?? <String, dynamic>{};
    final items = (blob['modifier_items'] as Map?) ?? <String, dynamic>{};
    final links = <Map<String, dynamic>>[];
    for (final row in rows) {
      final group = row['modifier_groups'];
      final groupId = (row['group_id'] ?? (group is Map ? group['id'] : null))
          ?.toString();
      if (groupId == null || groupId.isEmpty || group is! Map) continue;
      groups[groupId] = group;
      links.add({'group_id': groupId, 'position': row['position']});
    }
    items[menuItemId] = links;
    blob['groups'] = groups;
    blob['modifier_items'] = items;
  }

  Future<Map<String, dynamic>> _read(String businessId) async {
    if (businessId.isEmpty) return <String, dynamic>{};
    try {
      final storage = await _storage;
      final raw = await storage.read('$itemOptionsPrefix$businessId');
      if (raw == null || raw.isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } catch (e) {
      debugPrint('PosLookupOfflineCache._read error: $e');
      return <String, dynamic>{};
    }
  }

  Future<void> _mutate(
    String businessId,
    void Function(Map<String, dynamic> blob) change,
  ) {
    if (businessId.isEmpty) return Future.value();
    final key = '$itemOptionsPrefix$businessId';
    final previous = _writeChain[key] ?? Future<void>.value();
    final next = previous.then((_) async {
      try {
        final blob = await _read(businessId);
        change(blob);
        blob['saved_at'] = DateTime.now().toIso8601String();
        final storage = await _storage;
        await storage.write(key, jsonEncode(blob));
      } catch (e) {
        debugPrint('PosLookupOfflineCache._mutate error: $e');
      }
    });
    _writeChain[key] = next;
    return next;
  }
}
