/// Una intención completa, conservada al reintentar una respuesta perdida.
class BillSplitEdit {
  const BillSplitEdit({
    required this.opId,
    required this.orderId,
    required this.assignments,
    required this.checks,
    required this.deletedCheckIds,
    this.baseVersion,
    this.equalPeople,
    this.force = false,
  });
  final String opId;
  final String orderId;
  final List<Map<String, dynamic>> assignments;
  final List<Map<String, dynamic>> checks;
  final List<String> deletedCheckIds;
  final int? baseVersion;
  final int? equalPeople;
  final bool force;
  Map<String, dynamic> toRpcParams() => {
    'p_op_id': opId,
    'p_order_id': orderId,
    'p_assignments': assignments,
    'p_checks': checks,
    'p_deleted_check_ids': deletedCheckIds,
    'p_base_version': baseVersion,
    'p_equal_people': equalPeople,
    'p_force': force,
  };
}

class BillSplitServerOutdated implements Exception {
  const BillSplitServerOutdated();
  static const message =
      'Falta aplicar la migración 20261015_0003 en el '
      'servidor para guardar divisiones completas. Avísale al administrador.';
  @override
  String toString() => message;
}

class BillSplitUnitsNotReady implements Exception {
  const BillSplitUnitsNotReady();
  static const message =
      'No se pudieron preparar los productos por unidad. Reintenta. '
      'Si continúa, el administrador debe verificar la migración '
      '20261015_0004 del servidor.';
  @override
  String toString() => message;
}
