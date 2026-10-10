import 'package:supabase_flutter/supabase_flutter.dart';

/// Línea de una cuenta en revisión (solo lectura: no se edita hasta resolverla).
class ReviewAccountItem {
  final String name;
  final double quantity;
  final double total;

  const ReviewAccountItem({
    required this.name,
    required this.quantity,
    required this.total,
  });
}

/// Cuenta en revisión (20261010_0020): una segunda orden de la sesión de la
/// mesa que llegó de un equipo sin conexión o tarde. No se cobra ni se mezcla
/// sola: alguien decide unirla a la cuenta actual o anularla como duplicado.
class ReviewAccount {
  final String orderId;

  /// offline_conflict | late_items_after_release | late_items_after_settle
  final String reason;
  final DateTime? reviewAt;
  final String? sourceOrderId;
  final List<ReviewAccountItem> items;

  /// Quién la tomó (primer nombre del mesero) y en qué mesa (20261010_0024).
  /// Null sin esa migración.
  final String? waiterName;
  final String? tableCode;

  const ReviewAccount({
    required this.orderId,
    required this.reason,
    required this.reviewAt,
    required this.sourceOrderId,
    required this.items,
    this.waiterName,
    this.tableCode,
  });

  double get total => items.fold(0, (sum, i) => sum + i.total);

  /// Explicación para quien decide.
  String get reasonLabel => switch (reason) {
    'offline_conflict' =>
      'Se tomó sin conexión en otro equipo mientras la mesa ya tenía otra cuenta.',
    'late_items_after_release' =>
      'Productos que llegaron de otro equipo después de liberar la mesa.',
    'late_items_after_settle' =>
      'Productos que llegaron después de cobrar la cuenta anterior.',
    _ => 'Cuenta recuperada de otro equipo.',
  };

  factory ReviewAccount.fromRow(Map<String, dynamic> row) {
    final rawItems = (row['order_items'] as List?) ?? const [];
    final items = <ReviewAccountItem>[];
    for (final raw in rawItems) {
      final item = Map<String, dynamic>.from(raw as Map);
      final status = item['status']?.toString();
      if (status == 'void' || status == 'paid') continue;
      items.add(
        ReviewAccountItem(
          name: (item['product_name'] ?? 'Producto').toString(),
          quantity: _num(item['qty'] ?? item['quantity'], fallback: 1),
          total: _num(item['total']),
        ),
      );
    }
    return ReviewAccount(
      orderId: row['id'].toString(),
      reason: (row['review_reason'] ?? '').toString(),
      reviewAt: DateTime.tryParse('${row['review_at'] ?? ''}')?.toLocal(),
      sourceOrderId: row['review_source_order_id']?.toString(),
      items: items,
      waiterName: _text(row['waiter_name']),
      tableCode: _text(row['table_code']),
    );
  }

  static String? _text(Object? v) {
    final t = v?.toString().trim();
    return t == null || t.isEmpty ? null : t;
  }

  static double _num(Object? v, {double fallback = 0}) =>
      v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? fallback;
}

/// Resultado de resolver una cuenta en revisión (`fn_resolve_review_order`).
enum ReviewResolution {
  /// Sus productos pasaron a la cuenta actual.
  merged,

  /// No había cuenta actual: esta pasó a ser la de la mesa.
  promoted,

  /// Se anuló como duplicado.
  voided,

  /// Tiene cobros: no se une ni se anula aquí.
  hasPayments,

  /// Se movió a otra mesa libre y pasó a ser su cuenta.
  moved,

  /// Ya la resolvió otra persona.
  alreadyResolved,
}

/// Transferir o unir una mesa con una cuenta en revisión dejaría la otra
/// cuenta huérfana (fn_transfer_table_session elige «la orden más nueva»).
class ReviewPendingException implements Exception {
  final String message;
  const ReviewPendingException([
    this.message =
        'Esta mesa tiene una cuenta en revisión. Resuélvela (tocando la mesa) '
        'antes de transferirla o unirla.',
  ]);

  @override
  String toString() => message;
}

class OrderReviewRepository {
  final SupabaseClient _client;

  OrderReviewRepository(this._client);

  /// Cuentas en revisión abiertas de una sesión de mesa, con quién la tomó y
  /// en qué mesa (`fn_review_accounts`, 20261010_0024). Sin esa migración,
  /// lectura directa (sin mesero ni mesa).
  Future<List<ReviewAccount>> openReviewAccounts(String sessionId) async {
    try {
      final res = await _client.rpc(
        'fn_review_accounts',
        params: {'p_session_id': sessionId},
      );
      return [
        for (final r in (res is List ? res : const []).whereType<Map>())
          ReviewAccount.fromRow(Map<String, dynamic>.from(r)),
      ];
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST202') rethrow;
    }
    final rows = await _client
        .from('orders')
        .select(
          'id, review_reason, review_at, review_source_order_id, '
          'order_items(product_name, quantity, qty, total, status)',
        )
        .eq('session_id', sessionId)
        .not('review_reason', 'is', null)
        .isFilter('closed_at', null)
        .not('status_ext', 'in', '(paid,void)')
        .order('review_at');
    return (rows as List)
        .map((r) => ReviewAccount.fromRow(Map<String, dynamic>.from(r as Map)))
        .toList(growable: false);
  }

  /// True si alguna de las sesiones tiene una cuenta en revisión abierta.
  /// Sin 20261010_0020 (columna inexistente) no hay cuentas en revisión.
  Future<bool> anyOpenReview(Iterable<String> sessionIds) async {
    final ids = sessionIds.where((id) => id.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return false;
    try {
      final rows = await _client
          .from('orders')
          .select('id')
          .inFilter('session_id', ids)
          .not('review_reason', 'is', null)
          .isFilter('closed_at', null)
          .not('status_ext', 'in', '(paid,void)')
          .limit(1);
      return (rows as List).isNotEmpty;
    } on PostgrestException catch (e) {
      if (e.code == '42703') return false;
      rethrow;
    }
  }

  /// Unir ([merge] true) o anular como duplicado (motivo obligatorio).
  Future<({ReviewResolution resolution, int itemsMoved})> resolve(
    String orderId, {
    required bool merge,
    String? reason,
  }) async {
    final res = await _client.rpc(
      'fn_resolve_review_order',
      params: {
        'p_order_id': orderId,
        'p_action': merge ? 'merge' : 'void',
        'p_reason': reason,
      },
    );
    final map = res is Map ? Map<String, dynamic>.from(res) : const {};
    final moved = (map['items_moved'] as num?)?.toInt() ?? 0;
    final resolution = _resolution(map['outcome']);
    return (resolution: resolution, itemsMoved: moved);
  }

  /// «Mover a otra mesa» (20261010_0024): mesa libre → pasa a ser su cuenta;
  /// ocupada → sus productos se suman a la cuenta de esa mesa.
  Future<({ReviewResolution resolution, int itemsMoved})> moveToTable(
    String orderId,
    String targetTableId,
  ) async {
    final res = await _client.rpc(
      'fn_move_review_order',
      params: {'p_order_id': orderId, 'p_target_table_id': targetTableId},
    );
    final map = res is Map ? Map<String, dynamic>.from(res) : const {};
    final moved = (map['items_moved'] as num?)?.toInt() ?? 0;
    return (resolution: _resolution(map['outcome']), itemsMoved: moved);
  }

  static ReviewResolution _resolution(Object? outcome) {
    return switch (outcome?.toString()) {
      'moved' => ReviewResolution.moved,
      'merged' => ReviewResolution.merged,
      'promoted' => ReviewResolution.promoted,
      'voided' => ReviewResolution.voided,
      'has_payments' => ReviewResolution.hasPayments,
      _ => ReviewResolution.alreadyResolved,
    };
  }
}
