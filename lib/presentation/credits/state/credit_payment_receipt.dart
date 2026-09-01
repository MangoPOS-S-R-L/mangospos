// El recibo de un abono a crédito.
//
// Lo arma `fn_register_credit_abono_v2` y llega completo desde la BD: número,
// monto, método, cliente y el saldo que quedó. Se modela acá y no como un
// Map suelto porque el mismo objeto lo consumen tres salidas —el ticket
// térmico, la pantalla del modo sin impresora y la reimpresión desde el
// historial— y un `payment['metodo']` mal escrito en cualquiera de las tres
// imprime un recibo en blanco sin fallar.

class CreditPaymentReceipt {
  /// Número del recibo (AB-00001). Vacío en los abonos anteriores a la
  /// migración 20260902_0002, que nunca se numeraron.
  final String code;

  final String paymentId;
  final String creditId;
  final double amount;

  /// Código del método (`cash`, `card`, `transfer`) y su nombre para el papel.
  final String methodCode;
  final String methodName;

  final String? reference;
  final String? customerName;

  /// Saldo que quedó DESPUÉS de este abono. Es el dato por el que el cliente
  /// vuelve a preguntar, así que va en el recibo y no se recalcula al vuelo.
  final double balanceAfter;

  /// Deuda original, para que el recibo se explique solo.
  final double originalAmount;

  /// Estado del crédito tras el abono: `paid` cuando quedó saldado.
  final String creditStatus;

  final DateTime createdAt;

  const CreditPaymentReceipt({
    required this.code,
    required this.paymentId,
    required this.creditId,
    required this.amount,
    required this.methodCode,
    required this.methodName,
    required this.reference,
    required this.customerName,
    required this.balanceAfter,
    required this.originalAmount,
    required this.creditStatus,
    required this.createdAt,
  });

  bool get isSettled => creditStatus == 'paid' || balanceAfter <= 0.009;

  bool get isCash => methodCode == 'cash';

  /// Desde el jsonb `payment` que devuelve `fn_register_credit_abono_v2`.
  factory CreditPaymentReceipt.fromRpc(Map<String, dynamic> json) {
    return CreditPaymentReceipt(
      code: (json['code'] ?? '').toString(),
      paymentId: (json['id'] ?? '').toString(),
      creditId: (json['credit_id'] ?? '').toString(),
      amount: _toDouble(json['amount']),
      methodCode: (json['method_code'] ?? 'cash').toString(),
      methodName: (json['method_name'] ?? 'Efectivo').toString(),
      reference: _trimOrNull(json['reference']),
      customerName: _trimOrNull(json['customer_name']),
      balanceAfter: _toDouble(json['balance_after']),
      originalAmount: _toDouble(json['original_amount']),
      creditStatus: (json['credit_status'] ?? 'partial').toString(),
      createdAt: _toDate(json['created_at']),
    );
  }

  /// Desde una fila del historial (`selectReceivablePayments`), que trae el
  /// método embebido y no conoce el saldo posterior ni la deuda original —
  /// esos los aporta el crédito al que pertenece la fila.
  factory CreditPaymentReceipt.fromHistoryRow(
    Map<String, dynamic> row, {
    required Map<String, dynamic> credit,
  }) {
    final method = row['payment_methods'];
    final methodMap = method is Map
        ? Map<String, dynamic>.from(method)
        : const <String, dynamic>{};
    final customer = credit['customers'];
    final customerMap = customer is Map
        ? Map<String, dynamic>.from(customer)
        : const <String, dynamic>{};

    return CreditPaymentReceipt(
      code: (row['code'] ?? '').toString(),
      paymentId: (row['id'] ?? '').toString(),
      creditId: (row['credit_id'] ?? '').toString(),
      amount: _toDouble(row['amount']),
      methodCode: (methodMap['code'] ?? 'cash').toString(),
      methodName: (methodMap['name'] ?? 'Efectivo').toString(),
      reference: _trimOrNull(row['reference']),
      customerName: _trimOrNull(customerMap['name']),
      // El historial no guarda el saldo posterior de cada abono. Se reimprime
      // con el saldo VIGENTE del crédito, que es lo que el cliente quiere
      // saber hoy; el recibo lo dice explícitamente para no mentir.
      balanceAfter: _toDouble(credit['balance']),
      originalAmount: _toDouble(credit['original_amount']),
      creditStatus: (credit['status'] ?? 'partial').toString(),
      createdAt: _toDate(row['created_at']),
    );
  }

  static double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? 0;
  }

  static String? _trimOrNull(dynamic v) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }

  static DateTime _toDate(dynamic v) {
    if (v is DateTime) return v;
    return DateTime.tryParse(v?.toString() ?? '')?.toLocal() ?? DateTime.now();
  }
}
