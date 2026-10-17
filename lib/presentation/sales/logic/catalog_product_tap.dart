/// Cuenta y visita donde se tocó el catálogo, antes de consultar sus opciones.
/// Una mesa puede volver con la misma orden; la visita distingue A → B → A.
class CatalogProductTapSelection {
  const CatalogProductTapSelection({
    required this.orderId,
    required this.businessId,
    required this.origin,
    required this.tableId,
    required this.visitId,
  });

  final String? orderId;
  final String? businessId;
  final String origin;
  final String? tableId;
  final Object? visitId;

  bool matches(CatalogProductTapSelection current) =>
      orderId != null &&
      orderId!.isNotEmpty &&
      businessId != null &&
      businessId!.isNotEmpty &&
      orderId == current.orderId &&
      businessId == current.businessId &&
      origin == current.origin &&
      tableId == current.tableId &&
      identical(visitId, current.visitId);
}

/// Una selección todavía consultando opciones también pertenece a la cuenta.
/// La precuenta espera a que termine, incluso antes de que exista la línea.
class CatalogProductTapTracker {
  final _pending = <(String, String), int>{};

  bool isPending({required String? businessId, required String? orderId}) =>
      businessId != null &&
      orderId != null &&
      (_pending[(businessId, orderId)] ?? 0) > 0;

  Future<T> track<T>({
    required String businessId,
    required String orderId,
    required Future<T> Function() action,
  }) async {
    final key = (businessId, orderId);
    _pending[key] = (_pending[key] ?? 0) + 1;
    try {
      return await action();
    } finally {
      final remaining = _pending[key]! - 1;
      if (remaining == 0) {
        _pending.remove(key);
      } else {
        _pending[key] = remaining;
      }
    }
  }
}

/// Prepara una selección del catálogo y la agrega solo mientras sigue en la
/// cuenta capturada. Consultas lentas o diálogos abiertos no trasladan el
/// producto a la siguiente mesa. Los callbacks permiten probar la espera real
/// sin montar el resto de la pantalla de ventas.
Future<void> runCatalogProductTap<Group, Modifier>({
  required bool isCombo,
  required bool Function() selectionStillCurrent,
  required Future<List<Group>> Function() loadComboGroups,
  required Future<List<Modifier>?> Function(List<Group>) chooseCombo,
  required Future<List<Group>> Function() loadModifierGroups,
  required Future<List<Modifier>?> Function(List<Group>) chooseModifiers,
  required Future<void> Function(List<Modifier>) addItem,
}) async {
  if (!selectionStillCurrent()) return;
  var modifiers = <Modifier>[];
  if (isCombo) {
    final groups = await loadComboGroups();
    if (!selectionStillCurrent()) return;
    final selected = await chooseCombo(groups);
    if (!selectionStillCurrent() || selected == null) return;
    modifiers = selected;
  }

  final groups = await loadModifierGroups();
  if (!selectionStillCurrent()) return;
  if (groups.isNotEmpty) {
    final selected = await chooseModifiers(groups);
    if (!selectionStillCurrent() || selected == null) return;
    modifiers = [...modifiers, ...selected];
  }
  if (!selectionStillCurrent()) return;
  await addItem(modifiers);
}
