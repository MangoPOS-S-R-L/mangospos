import 'package:flutter/foundation.dart';

import '../../data/models/bank_account.dart';
import '../../data/models/sales_models.dart';
import '../storage/storage_service.dart';

/// Diario DURABLE del intento de cobro dividido (Plan de cierre offline, P0
/// cobros: "persistir antes de enviar la intención completa de cobro").
///
/// Por qué existe: el plan del cobro (métodos, montos, índices de abono, fecha
/// y NCF offline) y su progreso (qué abonos ya confirmó el servidor) vivían
/// solo en memoria del modal. Si la app se cerraba a mitad de un cobro
/// dividido, al reabrir se armaba un plan NUEVO desde el índice 0: un abono ya
/// cobrado con otro método se cobraba otra vez.
///
/// Con el diario, al reabrir el cobro de la MISMA cuenta se restaura el mismo
/// plan, bloqueado, con los mismos índices (`split_sequence`). El servidor
/// deduplica por (orden, subcuenta, método, índice): un abono que sí se cobró
/// pero cuyo acuse nunca llegó se reconoce en vez de cobrarse dos veces.
///
/// Se guarda en SharedPreferences con un prefijo que "Limpiar caché" no borra
/// y que la poda de cachés protege (ver `OfflineCachePruner`).
class PaymentIntentJournal {
  const PaymentIntentJournal();

  static const prefix = 'offline_payment_intent_';

  static String keyFor(String orderId, String? checkId) =>
      '$prefix${orderId}_${(checkId == null || checkId.isEmpty) ? 'order' : checkId}';

  Future<PaymentIntent?> load(String orderId, String? checkId) async {
    try {
      final storage = await StorageService.getInstance();
      final key = keyFor(orderId, checkId);
      final raw = await storage.readJson(key);
      if (raw == null) return null;
      final intent = PaymentIntent.fromJson(raw);
      return intent;
    } catch (e) {
      debugPrint('[PaymentIntentJournal] no se pudo leer el intento: $e');
      return null;
    }
  }

  /// `false` si no se pudo escribir (el caller decide; nunca lanza).
  Future<bool> save(PaymentIntent intent) async {
    try {
      final storage = await StorageService.getInstance();
      return await storage.writeJson(
        keyFor(intent.orderId, intent.checkId),
        intent.toJson(),
      );
    } catch (e) {
      debugPrint('[PaymentIntentJournal] no se pudo guardar el intento: $e');
      return false;
    }
  }

  Future<void> clear(String orderId, String? checkId) async {
    try {
      final storage = await StorageService.getInstance();
      await storage.delete(keyFor(orderId, checkId));
    } catch (e) {
      debugPrint('[PaymentIntentJournal] no se pudo borrar el intento: $e');
    }
  }

  /// Borra los intentos de [businessId] (limpieza explícita de datos del
  /// negocio). Los intentos sin negocio conocido se conservan.
  Future<int> deleteForBusiness(String businessId) async {
    var deleted = 0;
    try {
      final storage = await StorageService.getInstance();
      for (final key in await storage.getKeysByPrefix(prefix)) {
        final raw = await storage.readJson(key);
        if (raw?['business_id']?.toString() == businessId &&
            await storage.delete(key)) {
          deleted++;
        }
      }
    } catch (e) {
      debugPrint('[PaymentIntentJournal] limpieza por negocio falló: $e');
    }
    return deleted;
  }
}

/// Un abono planeado: lo que el cajero cargó en el modal.
class PaymentIntentLine {
  const PaymentIntentLine({
    required this.method,
    required this.amount,
    this.reference,
    this.bankAccount,
  });

  /// Nombre del enum del modal (`cash`, `card`, `transfer`, `tableDeposit`…).
  final String method;
  final double amount;
  final String? reference;
  final BankAccount? bankAccount;

  Map<String, dynamic> toJson() => {
    'method': method,
    'amount': amount,
    'reference': reference,
    'bank_account': bankAccount?.toInsert(),
  };

  static PaymentIntentLine? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final method = map['method']?.toString();
    final amount = map['amount'];
    if (method == null || method.isEmpty || amount is! num) return null;
    BankAccount? bank;
    final rawBank = map['bank_account'];
    if (rawBank is Map) {
      try {
        bank = BankAccount.fromMap(Map<String, dynamic>.from(rawBank));
      } catch (_) {
        bank = null;
      }
    }
    return PaymentIntentLine(
      method: method,
      amount: amount.toDouble(),
      reference: map['reference']?.toString(),
      bankAccount: bank,
    );
  }
}

class PaymentIntent {
  const PaymentIntent({
    required this.attemptId,
    required this.orderId,
    required this.checkId,
    required this.totalAmount,
    required this.lines,
    required this.paidAt,
    required this.createdAt,
    this.businessId,
    this.offline = false,
    this.offlineNcf,
    this.offlineNcfResolved = false,
    this.salesNoteSelected = false,
    this.recordedPayments = const {},
    this.splitSequenceBase = 0,
    this.paidBeforeAttempt = 0,
  });

  /// Identidad del intento: los ids de la cola offline se derivan de él
  /// (`payment-<attemptId>-<índice>`), así un reintento no encola dos veces.
  final String attemptId;
  final String orderId;
  final String? checkId;
  final String? businessId;
  final double totalAmount;
  final List<PaymentIntentLine> lines;

  /// Fecha del cobro: se conserva en los reintentos (`p_paid_at`).
  final DateTime paidAt;
  final DateTime createdAt;

  /// El intento ya tomó el camino offline: no se mezcla con online.
  final bool offline;

  /// NCF de papel asignado offline. Persistirlo evita pedir un SEGUNDO número
  /// al Hub si la app se reinicia (un número quemado = hueco fiscal).
  final String? offlineNcf;
  final bool offlineNcfResolved;
  final bool salesNoteSelected;

  /// Abonos que el servidor (o la cola) ya confirmó, por índice.
  final Map<int, Payment> recordedPayments;

  /// `split_sequence` del abono 0 de este intento (el servidor lo da al tomar
  /// el candado para no chocar con abonos anteriores). Fijo durante todo el
  /// intento: recalcularlo tras un reinicio rompería la deduplicación.
  final int splitSequenceBase;

  /// Lo que OTRO intento ya había cobrado en la cuenta cuando arrancó este
  /// (cobro anterior a medias). [totalAmount] es solo el restante.
  final double paidBeforeAttempt;

  PaymentIntent copyWith({
    bool? offline,
    String? offlineNcf,
    bool? offlineNcfResolved,
    Map<int, Payment>? recordedPayments,
  }) => PaymentIntent(
    attemptId: attemptId,
    orderId: orderId,
    checkId: checkId,
    businessId: businessId,
    totalAmount: totalAmount,
    lines: lines,
    paidAt: paidAt,
    createdAt: createdAt,
    offline: offline ?? this.offline,
    offlineNcf: offlineNcf ?? this.offlineNcf,
    offlineNcfResolved: offlineNcfResolved ?? this.offlineNcfResolved,
    salesNoteSelected: salesNoteSelected,
    recordedPayments: recordedPayments ?? this.recordedPayments,
    splitSequenceBase: splitSequenceBase,
    paidBeforeAttempt: paidBeforeAttempt,
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'attempt_id': attemptId,
    'order_id': orderId,
    'check_id': checkId,
    'business_id': businessId,
    'total_amount': totalAmount,
    'lines': lines.map((l) => l.toJson()).toList(growable: false),
    'paid_at': paidAt.toUtc().toIso8601String(),
    'created_at': createdAt.toUtc().toIso8601String(),
    'offline': offline,
    'offline_ncf': offlineNcf,
    'offline_ncf_resolved': offlineNcfResolved,
    'sales_note_selected': salesNoteSelected,
    'split_sequence_base': splitSequenceBase,
    'paid_before_attempt': paidBeforeAttempt,
    'recorded_payments': {
      for (final entry in recordedPayments.entries)
        '${entry.key}': _paymentToJson(entry.value),
    },
  };

  static PaymentIntent? fromJson(Map<String, dynamic> map) {
    final attemptId = map['attempt_id']?.toString();
    final orderId = map['order_id']?.toString();
    final total = map['total_amount'];
    final paidAt = DateTime.tryParse(map['paid_at']?.toString() ?? '');
    final createdAt = DateTime.tryParse(map['created_at']?.toString() ?? '');
    final rawLines = map['lines'];
    if (attemptId == null ||
        orderId == null ||
        total is! num ||
        paidAt == null ||
        createdAt == null ||
        rawLines is! List) {
      return null;
    }
    final lines = <PaymentIntentLine>[];
    for (final raw in rawLines) {
      final line = PaymentIntentLine.fromJson(raw);
      // Una línea ilegible invalida el plan entero: restaurar un plan
      // incompleto cambiaría los índices y rompería la deduplicación.
      if (line == null) return null;
      lines.add(line);
    }
    final recorded = <int, Payment>{};
    final rawRecorded = map['recorded_payments'];
    if (rawRecorded is Map) {
      rawRecorded.forEach((key, value) {
        final index = int.tryParse('$key');
        if (index != null && value is Map) {
          recorded[index] = Payment.fromMap(Map<String, dynamic>.from(value));
        }
      });
    }
    final checkId = map['check_id']?.toString();
    return PaymentIntent(
      attemptId: attemptId,
      orderId: orderId,
      checkId: (checkId == null || checkId.isEmpty) ? null : checkId,
      businessId: map['business_id']?.toString(),
      totalAmount: total.toDouble(),
      lines: lines,
      paidAt: paidAt.toUtc(),
      createdAt: createdAt.toUtc(),
      offline: map['offline'] == true,
      offlineNcf: map['offline_ncf']?.toString(),
      offlineNcfResolved: map['offline_ncf_resolved'] == true,
      salesNoteSelected: map['sales_note_selected'] == true,
      recordedPayments: recorded,
      splitSequenceBase: (map['split_sequence_base'] as num?)?.toInt() ?? 0,
      paidBeforeAttempt: (map['paid_before_attempt'] as num?)?.toDouble() ?? 0,
    );
  }

  static Map<String, dynamic> _paymentToJson(Payment p) => {
    'id': p.id,
    'business_id': p.businessId,
    'order_id': p.orderId,
    'check_id': p.checkId,
    'fiscal_document_id': p.fiscalDocumentId,
    'payment_method_id': p.paymentMethodId,
    'payment_method_code': p.paymentMethodCode,
    'payment_method_name': p.paymentMethodName,
    'amount': p.amount,
    'reference': p.reference,
    'change_amount': p.changeAmount,
    'status': p.status,
    'processed_by': p.processedBy,
    'session_id': p.sessionId,
    'bank_account_id': p.bankAccountId,
    'created_at': p.createdAt.toIso8601String(),
  };
}
