import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/utils/app_time.dart';
import '../datasources/queries/sales_queries.dart';
import '../models/credit_note_result.dart';
import '../models/offline_payment_replay.dart';
import '../models/order_edit.dart';
import '../models/order_item_removal_reason.dart';
import '../models/order_item_tax_line.dart';
import '../models/sales_models.dart';
import '../utils/payment_recovery.dart';
import '../models/sales_note.dart';
import '../utils/payment_amount_utils.dart';
import '../../core/offline/hub/hub_client.dart';
import '../../core/performance/performance_diagnostics.dart';

/// Resultado de abrir/reanudar una mesa: order_id + bundle completo
/// (order/items con modifiers+tax_lines/checks/customer). Compartido por el
/// camino directo ([SalesRepository.openTableAndLoad]) y el proxy del Hub
/// ([SalesRepository.openTableAndLoadViaHub]) — ambos parsean el MISMO JSON
/// que devuelve el RPC `fn_open_table_and_load`.
typedef OpenTableResult = ({
  String orderId,
  ({
    Order? order,
    List<OrderItem> items,
    List<OrderCheck> checks,
    String? customerId,
    String? customerName,
    String? note,
  })
  bundle,
});

class _PendingEmptyTableRelease {
  _PendingEmptyTableRelease(this.orderId);

  final String orderId;
  late final Timer timer;
  Future<bool> Function()? release;
  void Function(bool released)? onResult;
  void Function()? onReleased;
}

/// Excepción tipada para señalizar que la orden consultada no pertenece
/// al `businessId` activo. Los métodos de lectura la atrapan y devuelven
/// resultados vacíos en lugar de propagar el error a la UI.
class OrderOutOfScopeException implements Exception {
  const OrderOutOfScopeException();
  @override
  String toString() => 'ORDER_OUT_OF_SCOPE';
}

/// Traduce los errores del candado de órdenes cerradas (migración
/// `20260819_0004_no_items_on_closed_order`) a algo que el mesero pueda
/// accionar. El servidor los manda con SQLSTATE propio:
///
///   MP401 — la cuenta ya se cobró (hay pagos o NCF): no se resucita.
///   MP402 — la mesa ya la tomó otra sesión mientras esta estaba cerrada.
///   MP403 — la orden ya no existe.
///   MP404 — se intentó BORRAR un ítem de una cuenta ya facturada
///           (migración `20260902_0010_block_item_delete_on_invoiced`).
///
/// El caso feliz (la mesa la cerró el barrendero de mesas fantasma y nadie la
/// reabrió) NO llega aquí: el trigger resucita orden + sesión + mesa y el ítem
/// entra sin que el mesero se entere. Ver el encabezado de la migración.
///
/// Devuelve `null` si el error no es del candado — el caller sigue con su
/// mensaje de siempre.
String? closedOrderErrorMessage(Object error) {
  if (error is! PostgrestException) return null;
  switch (error.code) {
    case 'MP401':
      return 'Esta cuenta ya fue cobrada. Abre la mesa otra vez para cargar '
          'productos nuevos.';
    case 'MP402':
      return 'La mesa ya se abrió en otra cuenta. Carga el producto en la '
          'cuenta activa.';
    case 'MP403':
      return 'La orden ya no existe. Vuelve al salón y abre la mesa de nuevo.';
    case 'MP404':
      return 'Esta cuenta ya está facturada. Anula el producto en vez de '
          'borrarlo, o anula la factura completa.';
    default:
      return null;
  }
}

/// 🥭 MangoPOS - Sales Repository
/// Repositorio completo para el módulo de ventas
class SalesRepository {
  final SupabaseClient _client;
  SalesRepository(this._client);

  // PRD multimesero: incluir `created_by_employee_id` + embed del nombre
  // del empleado para que la UI pueda mostrar "quién agregó" cada item
  // sin necesidad de un round-trip extra ni un provider de empleados en
  // memoria. Postgrest resuelve el JOIN vía la FK
  // `order_items_created_by_employee_fk`.
  static const _itemFields =
      'id,order_id,product_id,product_name,sku,quantity,qty,unit_price,subtotal,discounts,tax,total,check_id,is_takeout,status,notes,tax_mode,tax_rate,original_tax_rate,print_area_code,created_at,created_by_employee_id,employees(first_name,last_name)';

  // T04: la versión de la línea (20261010_0006). Sin la migración la columna
  // no existe (42703): se carga sin ella y la edición va por valores.
  static bool _itemVersionColumnMissing = false;
  static String get _itemFieldsWithVersion =>
      _itemVersionColumnMissing ? _itemFields : '$_itemFields,version';

  /// Carga las `order_item_tax_lines` de una lista de items en una sola query
  /// y las devuelve agrupadas por `order_item_id`. Producto del PRD 2: la
  /// fuente del desglose de impuestos en pantalla pasa de heurística a
  /// snapshot inmutable persistido por el motor backend.
  Future<Map<String, List<OrderItemTaxLine>>> _loadTaxLinesByItem(
    List<String> itemIds,
  ) async {
    if (itemIds.isEmpty) return const {};

    // Chunking de inFilter para evitar HTTP 414 URI Too Long cuando una
    // mesa acumula cientos de items (ej. cuentas a credito que arrastran
    // dias). 100 UUIDs por lote deja la URL bajo los ~8KB que PostgREST
    // acepta por default.
    const inChunkSize = 100;
    final grouped = <String, List<OrderItemTaxLine>>{};

    for (var i = 0; i < itemIds.length; i += inChunkSize) {
      final end = (i + inChunkSize > itemIds.length)
          ? itemIds.length
          : i + inChunkSize;
      final chunk = itemIds.sublist(i, end);

      final raw = await _client
          .from('order_item_tax_lines')
          .select(
            'id, order_item_id, tax_id, tax_name, tax_rate, amount, created_at',
          )
          .inFilter('order_item_id', chunk)
          .order('created_at', ascending: true);

      for (final row in (raw as List)) {
        final line = OrderItemTaxLine.fromMap(
          Map<String, dynamic>.from(row as Map),
        );
        grouped
            .putIfAbsent(line.orderItemId, () => <OrderItemTaxLine>[])
            .add(line);
      }
    }
    return grouped;
  }

  /// Trae los modifiers de un conjunto de items en lotes (igual que
  /// _loadTaxLinesByItem). Se usa cuando el bundle NO los embebe.
  Future<Map<String, List<OrderItemModifier>>> _loadModifiersByItem(
    List<String> itemIds,
  ) async {
    if (itemIds.isEmpty) return const {};

    const inChunkSize = 100;
    final grouped = <String, List<OrderItemModifier>>{};

    for (var i = 0; i < itemIds.length; i += inChunkSize) {
      final end = (i + inChunkSize > itemIds.length)
          ? itemIds.length
          : i + inChunkSize;
      final chunk = itemIds.sublist(i, end);

      final rawModifiers = await _client
          .from('order_item_modifiers')
          .select('id, item_id, name, qty, price')
          .inFilter('item_id', chunk)
          .order('id', ascending: true);

      for (final row in (rawModifiers as List)) {
        final modifier = OrderItemModifier.fromMap(
          Map<String, dynamic>.from(row as Map),
        );
        grouped
            .putIfAbsent(modifier.itemId, () => <OrderItemModifier>[])
            .add(modifier);
      }
    }
    return grouped;
  }

  /// Parsea los modifiers embebidos por el RPC en cada item del bundle
  /// (clave 'modifiers'). Devuelve const [] si no hay o el formato no aplica.
  List<OrderItemModifier> _parseEmbeddedModifiers(dynamic raw) {
    if (raw is! List || raw.isEmpty) return const <OrderItemModifier>[];
    return raw
        .whereType<Map>()
        .map((m) => OrderItemModifier.fromMap(Map<String, dynamic>.from(m)))
        .toList(growable: false);
  }

  /// Parsea las tax_lines embebidas por el RPC en cada item del bundle
  /// (clave 'tax_lines'). Devuelve const [] si no hay o el formato no aplica.
  List<OrderItemTaxLine> _parseEmbeddedTaxLines(dynamic raw) {
    if (raw is! List || raw.isEmpty) return const <OrderItemTaxLine>[];
    return raw
        .whereType<Map>()
        .map((t) => OrderItemTaxLine.fromMap(Map<String, dynamic>.from(t)))
        .toList(growable: false);
  }

  Future<void> _assertOrderInBusinessScope(
    String orderId, {
    String? businessId,
  }) async {
    final scopedBusinessId = businessId?.trim();
    if (scopedBusinessId == null || scopedBusinessId.isEmpty) return;

    final row = await _client
        .from('orders')
        .select('id, table_sessions!inner(business_id)')
        .eq('id', orderId)
        .eq('table_sessions.business_id', scopedBusinessId)
        .maybeSingle();

    if (row == null) {
      throw const OrderOutOfScopeException();
    }
  }

  Future<void> _assertSessionInBusinessScope(
    String sessionId, {
    String? businessId,
  }) async {
    final scopedBusinessId = businessId?.trim();
    if (scopedBusinessId == null || scopedBusinessId.isEmpty) return;

    final row = await _client
        .from('table_sessions')
        .select('id')
        .eq('id', sessionId)
        .eq('business_id', scopedBusinessId)
        .maybeSingle();

    if (row == null) {
      throw Exception('SESSION_OUT_OF_SCOPE');
    }
  }

  Future<void> _assertTableInBusinessScope(
    String tableId, {
    String? businessId,
  }) async {
    final scopedBusinessId = businessId?.trim();
    if (scopedBusinessId == null || scopedBusinessId.isEmpty) return;

    final row = await _client
        .from('dining_tables')
        .select('id, zones!inner(business_id)')
        .eq('id', tableId)
        .eq('zones.business_id', scopedBusinessId)
        .maybeSingle();

    if (row == null) {
      throw Exception('TABLE_OUT_OF_SCOPE');
    }
  }

  /// Anular un pago puntual. Si el pago corresponde a una subcuenta,
  /// reabre solamente ese check. Si es un pago full-order (check_id null) y
  /// hay otros payments completed en la misma orden — es decir, un split por
  /// múltiples métodos — sólo anula ESE pago y deja a la orden en
  /// partially_paid. Si es el único pago, mantiene la anulación total
  /// (annulOrder).
  /// Pre-validación para anular ventas a CRÉDITO: si alguna cuenta por
  /// cobrar abierta de la orden ya tiene abonos, bloquea con mensaje claro —
  /// hay dinero del cliente recibido que habría que devolver, y eso se
  /// resuelve manualmente antes de anular. El trigger server-side
  /// `trg_payment_cancel_customer_credit` (mig 20260725_0003) es el backstop
  /// y además cancela la CxC automáticamente al anular el pago.
  Future<void> _ensureCreditAnnullable(String orderId) async {
    try {
      final rows = await _client
          .from('customer_credits')
          .select('id, balance, original_amount, status')
          .eq('order_id', orderId)
          .inFilter('status', ['pending', 'partial', 'overdue']);
      for (final row in List<Map<String, dynamic>>.from(rows)) {
        final balance = ((row['balance'] as num?) ?? 0).toDouble();
        final original = ((row['original_amount'] as num?) ?? 0).toDouble();
        if (row['status'] == 'partial' || balance < original - 0.01) {
          throw Exception(
            'La venta a crédito ya tiene abonos registrados. Resuelve o '
            'devuelve los abonos antes de anularla.',
          );
        }
      }
    } on PostgrestException {
      // Sin acceso/tabla: no bloqueamos por el pre-check; el trigger
      // server-side sigue siendo el backstop.
    }
  }

  /// Best-effort tras anular pago(s) credit: cancela las CxC abiertas de la
  /// orden. Redundante cuando la mig 20260725_0003 está aplicada (el trigger
  /// ya lo hizo y no quedan filas abiertas); cubre BD sin la mig cuando el
  /// usuario es owner/admin (RLS cc_admin_update). Silencioso a propósito.
  Future<void> _cancelOpenCreditsForOrder(String orderId) async {
    try {
      await _client
          .from('customer_credits')
          .update({'status': 'cancelled'})
          .eq('order_id', orderId)
          .inFilter('status', ['pending', 'partial', 'overdue']);
    } catch (_) {}
  }

  /// Patch de anulación para `fiscal_documents`. El motivo lo escribe el
  /// cajero al anular y hasta ahora se descartaba; para un NCF cancelado es
  /// justamente lo que hay que poder justificar después.
  ///
  /// Solo estas 4 columnas son actualizables por el cliente
  /// (mig 20260812_0001: policy fd_update + grant acotado).
  Map<String, dynamic> _cancelledFiscalDocumentPatch(String? reason) {
    final trimmed = reason?.trim();
    return <String, dynamic>{
      'status': 'cancelled',
      'cancelled_at': DateTime.now().toUtc().toIso8601String(),
      if (trimmed != null && trimmed.isNotEmpty) 'cancellation_reason': trimmed,
      if (_client.auth.currentUser?.id != null)
        'cancelled_by': _client.auth.currentUser!.id,
    };
  }

  /// Devuelve los `fiscal_documents` que quedaron cancelados, para emitirles
  /// la nota de crédito ([issueCreditNote]).
  Future<List<String>> annulPayment({
    required String paymentId,
    required String orderId,
    String? checkId,
    String? reason,
  }) async {
    final trimmedPaymentId = paymentId.trim();
    final trimmedOrderId = orderId.trim();
    final trimmedCheckId = checkId?.trim();
    final hasCheck = trimmedCheckId != null && trimmedCheckId.isNotEmpty;

    if (trimmedPaymentId.isEmpty) {
      throw Exception('PAYMENT_ID_REQUIRED');
    }
    if (trimmedOrderId.isEmpty) {
      throw Exception('ORDER_ID_REQUIRED');
    }

    // La unidad de anulación es el DOCUMENTO FISCAL, no el pago suelto.
    //
    // El historial agrupa por documento fiscal: una venta con pago mixto
    // (efectivo + tarjeta) es UNA fila cuyo botón "Anular" trae el pago
    // pivote — el que creó el NCF. Cancelar solo ese pago dejaba la venta a
    // medias: el NCF quedaba cancelado, pero la orden revivía como
    // `partially_paid`, la mesa volvía a `occupied` y la otra pierna seguía
    // en `completed` sin forma de anularla desde la UI (la fila ya no
    // aparecía como activa). Por eso se anulan juntas todas las piernas que
    // comparten el mismo NCF.
    const paymentCols =
        'id, order_id, check_id, fiscal_document_id, '
        'payment_method_id, amount, change_amount, session_id, status';

    final pivotRaw = await _client
        .from('payments')
        .select(paymentCols)
        .eq('id', trimmedPaymentId)
        .maybeSingle();

    if (pivotRaw == null) {
      throw Exception('PAYMENT_NOT_FOUND');
    }
    final pivotPayment = Map<String, dynamic>.from(pivotRaw);
    if ((pivotPayment['status']?.toString() ?? '') != 'completed') {
      // Antes retornaba en silencio y la UI festejaba un "anulada
      // correctamente" que no había ocurrido.
      throw Exception('Esta venta ya estaba anulada.');
    }

    // Piernas de ESTA venta. Sin fiscal_document_id (venta sin NCF), la
    // venta es solo el pago pivote.
    final fiscalDocumentId = pivotPayment['fiscal_document_id']
        ?.toString()
        .trim();
    var salePayments = <Map<String, dynamic>>[pivotPayment];
    if (fiscalDocumentId != null && fiscalDocumentId.isNotEmpty) {
      final legsRaw = await _client
          .from('payments')
          .select(paymentCols)
          .eq('fiscal_document_id', fiscalDocumentId)
          .eq('status', 'completed');
      final legs = List<Map<String, dynamic>>.from(legsRaw);
      if (legs.isNotEmpty) salePayments = legs;
    }
    final salePaymentIds = salePayments.map((p) => p['id'].toString()).toSet();

    // ¿Le quedan pagos vivos a la orden FUERA de esta venta? Si no, la
    // anulación es total: anula ítems, cierra la orden como `void` y libera
    // la mesa. Si sí (dos ventas con NCF distintos sobre la misma orden, o
    // cuentas divididas), solo se anula esta y la orden vuelve a
    // `partially_paid`.
    final orderPaymentsRaw = await _client
        .from('payments')
        .select('id, check_id')
        .eq('order_id', trimmedOrderId)
        .eq('status', 'completed');
    final hasSurvivors = List<Map<String, dynamic>>.from(orderPaymentsRaw)
        .where((p) => !hasCheck ? p['check_id'] == null : true)
        .any((p) => !salePaymentIds.contains(p['id'].toString()));

    if (!hasCheck && !hasSurvivors) {
      return annulOrder(orderId: trimmedOrderId, reason: reason);
    }

    try {
      final orderRaw = await _client
          .from('orders')
          .select('session_id')
          .eq('id', trimmedOrderId)
          .maybeSingle();
      final orderSessionId = orderRaw?['session_id']?.toString();

      String? tableId;
      if (orderSessionId != null && orderSessionId.isNotEmpty) {
        final sessionRaw = await _client
            .from('table_sessions')
            .select('table_id')
            .eq('id', orderSessionId)
            .maybeSingle();
        tableId = sessionRaw?['table_id']?.toString();
      }

      // Códigos de método de TODAS las piernas de la venta (una consulta).
      final methodIds = salePayments
          .map((p) => p['payment_method_id']?.toString())
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList(growable: false);
      final methodCodeById = <String, String>{};
      if (methodIds.isNotEmpty) {
        final methodsRaw = await _client
            .from('payment_methods')
            .select('id, code')
            .inFilter('id', methodIds);
        for (final m in List<Map<String, dynamic>>.from(methodsRaw)) {
          final id = m['id']?.toString();
          final code = m['code']?.toString();
          if (id != null && code != null) methodCodeById[id] = code;
        }
      }
      String? codeOf(Map<String, dynamic> p) =>
          methodCodeById[p['payment_method_id']?.toString() ?? ''];
      final hasCreditLeg = salePayments.any((p) => codeOf(p) == 'credit');

      // Venta a crédito: si su CxC ya tiene abonos, bloquear ANTES de tocar
      // nada (el trigger server-side también lo bloquea, pero aquí damos el
      // mensaje amigable sin dejar estado a medias).
      if (hasCreditLeg) {
        await _ensureCreditAnnullable(trimmedOrderId);
      }

      await _client
          .from('payments')
          .update({'status': 'cancelled'})
          .inFilter('id', salePaymentIds.toList(growable: false));

      // El NCF se cancela por documento cuando existe: en pago mixto las
      // piernas comparten fiscal_document_id y `fd.payment_id` apunta solo
      // al pivote, así que filtrar por payment_id dejaba fuera el resto.
      final fdPatch = _cancelledFiscalDocumentPatch(reason);
      final List<String> cancelledDocIds;
      if (fiscalDocumentId != null && fiscalDocumentId.isNotEmpty) {
        cancelledDocIds = _idsOf(
          await _client
              .from('fiscal_documents')
              .update(fdPatch)
              .eq('id', fiscalDocumentId)
              .select('id'),
        );
      } else {
        cancelledDocIds = _idsOf(
          await _client
              .from('fiscal_documents')
              .update(fdPatch)
              .inFilter('payment_id', salePaymentIds.toList(growable: false))
              .select('id'),
        );
      }

      // Reabrir items y check sólo para el flujo basado en checks. En split
      // full-order los items pertenecen a la orden entera (no a un check);
      // los dejamos como 'paid' — siguen asociados a los otros pagos del
      // split, y la orden vuelve a `partially_paid` para que el cajero
      // pueda registrar otro pago que cubra el monto anulado.
      if (hasCheck) {
        await _client
            .from('order_items')
            .update({'status': 'served'})
            .eq('order_id', trimmedOrderId)
            .eq('check_id', trimmedCheckId)
            .eq('status', 'paid');

        await _client
            .from('order_checks')
            .update({'is_closed': false, 'closed_at': null})
            .eq('id', trimmedCheckId);
      }

      await _client
          .from('orders')
          .update({'status_ext': 'partially_paid', 'closed_at': null})
          .eq('id', trimmedOrderId);

      if (orderSessionId != null && orderSessionId.isNotEmpty) {
        await _client
            .from('table_sessions')
            .update({'closed_at': null})
            .eq('id', orderSessionId);
      }

      if (tableId != null && tableId.isNotEmpty) {
        await _client
            .from('dining_tables')
            .update({'state': 'occupied'})
            .eq('id', tableId);
      }

      // Caja: una reversa por cada pierna en efectivo, contra la sesión de
      // caja donde se cobró (pueden ser distintas si el split se registró en
      // dos turnos).
      for (final leg in salePayments) {
        if (codeOf(leg) != 'cash') continue;
        final cashierSessionId = leg['session_id']?.toString();
        final netAmount = netPaymentAmount(leg['amount'], leg['change_amount']);
        if (cashierSessionId != null &&
            cashierSessionId.isNotEmpty &&
            netAmount > 0) {
          final legId = leg['id'].toString();
          await _client.from('cash_transactions').insert({
            'session_id': cashierSessionId,
            'amount': -netAmount,
            'type': 'sale',
            'description': 'Anulacion pago ${legId.substring(0, 8)}',
            'related_order_id': trimmedOrderId,
          });
        }
      }

      if (hasCreditLeg) {
        await _cancelOpenCreditsForOrder(trimmedOrderId);
      }

      return cancelledDocIds;
    } catch (e) {
      throw Exception('Error al anular pago: $e');
    }
  }

  /// Corrige el tipo de pago (método) de un pago YA cobrado. Sirve para
  /// arreglar errores del cajero (marcó "Efectivo" cuando fue "Tarjeta", etc.)
  /// sin tener que anular la venta.
  ///
  /// Ajusta la caja: si el método pasa de efectivo a no-efectivo se retira el
  /// monto neto de la sesión de caja del pago; si pasa de no-efectivo a
  /// efectivo se agrega. Entre dos métodos no-efectivo (tarjeta ↔ transferencia)
  /// no se toca la caja. Reusa el mismo criterio que la anulación.
  Future<void> updatePaymentMethod({
    required String paymentId,
    required String newMethodId,
  }) async {
    final trimmedPaymentId = paymentId.trim();
    final trimmedNewMethodId = newMethodId.trim();
    if (trimmedPaymentId.isEmpty) {
      throw Exception('PAYMENT_ID_REQUIRED');
    }
    if (trimmedNewMethodId.isEmpty) {
      throw Exception('PAYMENT_METHOD_REQUIRED');
    }

    try {
      final paymentRaw = await _client
          .from('payments')
          .select(
            'id, order_id, payment_method_id, amount, change_amount, session_id, status',
          )
          .eq('id', trimmedPaymentId)
          .maybeSingle();

      if (paymentRaw == null) {
        throw Exception('PAYMENT_NOT_FOUND');
      }
      final payment = Map<String, dynamic>.from(paymentRaw);
      if ((payment['status']?.toString() ?? '') != 'completed') {
        throw Exception('PAYMENT_NOT_COMPLETED');
      }

      final oldMethodId = payment['payment_method_id']?.toString();
      if (oldMethodId == trimmedNewMethodId) {
        // Sin cambio: no tocar nada.
        return;
      }

      // Códigos de método (cash/card/transfer/...) para decidir el ajuste
      // de caja. Traemos ambos en una sola consulta.
      final ids = <String>{
        if (oldMethodId != null && oldMethodId.isNotEmpty) oldMethodId,
        trimmedNewMethodId,
      }.toList();
      final methodsRaw = await _client
          .from('payment_methods')
          .select('id, code')
          .inFilter('id', ids);
      final codeById = <String, String>{};
      for (final m in List<Map<String, dynamic>>.from(methodsRaw)) {
        codeById[m['id']?.toString() ?? ''] = m['code']?.toString() ?? '';
      }
      final oldCode = oldMethodId == null ? '' : (codeById[oldMethodId] ?? '');
      final newCode = codeById[trimmedNewMethodId] ?? '';

      // Crédito no se puede corregir aquí: cambiar el método dejaría la
      // cuenta por cobrar huérfana (o no la crearía — el trigger corre solo
      // en INSERT). Anular el pago y cobrar de nuevo es el camino seguro.
      if (oldCode == 'credit' || newCode == 'credit') {
        throw Exception(
          'Los pagos a crédito no se pueden corregir desde aquí. Anula el '
          'pago (la cuenta por cobrar se cancela sola) y cobra de nuevo con '
          'el método correcto.',
        );
      }

      // Saldo de mesa: mismo problema que el crédito. El débito del saldo
      // cuelga de un trigger de INSERT, así que cambiar el método aquí dejaría
      // el saldo desfasado — pasar A saldo regalaría el consumo (nunca se
      // descuenta) y salir DE saldo no lo devolvería. Anular y recobrar sí
      // pasa por los dos triggers. La BD tiene el mismo candado como respaldo.
      if (oldCode == 'table_deposit' || newCode == 'table_deposit') {
        throw Exception(
          'Los cobros con saldo de mesa no se pueden corregir desde aquí. '
          'Anula el pago (el saldo vuelve solo a la mesa) y cobra de nuevo '
          'con el método correcto.',
        );
      }

      // Cambia el método del pago.
      await _client
          .from('payments')
          .update({'payment_method_id': trimmedNewMethodId})
          .eq('id', trimmedPaymentId);

      // Ajuste de caja (solo si cruza la frontera efectivo / no-efectivo).
      final wasCash = oldCode == 'cash';
      final isCash = newCode == 'cash';
      if (wasCash != isCash) {
        final cashierSessionId = payment['session_id']?.toString();
        final orderId = payment['order_id']?.toString();
        final netAmount = netPaymentAmount(
          payment['amount'],
          payment['change_amount'],
        );
        if (cashierSessionId != null &&
            cashierSessionId.isNotEmpty &&
            netAmount > 0) {
          // De efectivo → no-efectivo: sale de caja (negativo).
          // De no-efectivo → efectivo: entra a caja (positivo).
          final delta = wasCash ? -netAmount : netAmount;
          await _client.from('cash_transactions').insert({
            'session_id': cashierSessionId,
            'amount': delta,
            'type': 'sale',
            'description':
                'Correccion metodo pago ${trimmedPaymentId.substring(0, 8)}',
            'related_order_id': orderId,
          });
        }
      }
    } catch (e) {
      throw Exception('Error al editar tipo de pago: $e');
    }
  }

  // ============================================================
  // 📊 SESIONES DE MESA
  // ============================================================

  /// Abrir sesión de mesa (venta por mesa)
  Future<Map<String, dynamic>> openTable({
    required String tableId,
    String? userId,
    int peopleCount = 1,
    String? openedByEmployeeId,
  }) async {
    // ANTES del RPC: la mesa está en uso otra vez, así que una liberación
    // pendiente de la visita anterior ya no aplica. Cancelar aquí y no al
    // recibir la respuesta es lo que saca el viaje de red de la ventana de
    // gracia (ver emptyTableReleaseDelay).
    cancelPendingEmptyTableRelease(tableId);
    try {
      final response = await _client.rpc(
        SalesQueries.rpcOpenTable,
        params: {
          'p_people_count': peopleCount,
          'p_table_id': tableId,
          'p_user_id': userId,
          // Solo se manda si el modo multimesero está activo y el mesero
          // metió PIN. El RPC tiene este param con default null para
          // mantener backwards compat.
          'p_opened_by_employee_id': openedByEmployeeId,
        },
      );

      if (response == null) {
        throw Exception('No se pudo abrir la mesa');
      }

      return Map<String, dynamic>.from(response as Map);
    } catch (e) {
      throw Exception('Error al abrir mesa: $e');
    }
  }

  /// Sube a su mesa una cuenta creada en este equipo (`local-order-…`)
  /// conservando su identidad (`fn_open_local_table_order`, 20261010_0020):
  /// la misma identidad devuelve la misma cuenta, y si la mesa ya tiene otra
  /// cuenta con productos la guarda APARTE en revisión en vez de mezclarla
  /// (`fn_open_table` devuelve la cuenta abierta actual de la mesa). Sin la
  /// migración (PGRST202) cae a [openTable], el comportamiento anterior.
  Future<Map<String, dynamic>> openLocalTableOrder({
    required String clientOrderId,
    required String tableId,
    int peopleCount = 1,
    String? openedByEmployeeId,
  }) async {
    cancelPendingEmptyTableRelease(tableId);
    try {
      final response = await _client.rpc(
        'fn_open_local_table_order',
        params: {
          'p_client_order_id': clientOrderId,
          'p_table_id': tableId,
          'p_people_count': peopleCount,
          'p_opened_by_employee_id': openedByEmployeeId,
        },
      );
      if (response == null) {
        throw Exception('No se pudo abrir la mesa');
      }
      return Map<String, dynamic>.from(response as Map);
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST202') {
        return openTable(
          tableId: tableId,
          peopleCount: peopleCount,
          openedByEmployeeId: openedByEmployeeId,
        );
      }
      throw Exception('Error al abrir mesa: $e');
    } catch (e) {
      throw Exception('Error al abrir mesa: $e');
    }
  }

  /// Abre/reanuda una mesa y retorna el bundle COMPLETO en un solo
  /// round-trip — combina `fn_open_table` + `fn_get_order_bundle` +
  /// modifiers + tax_lines, todo embebido en items. Reduce la apertura
  /// de mesa de 3-4 queries (~700ms) a 1 RPC (~21ms server, ~150ms
  /// total con network).
  ///
  /// Retorna `(orderId, bundle)` donde `bundle` tiene la misma forma
  /// que el de `getOrderBundle()` — order/items/checks/customer — pero
  /// con `modifiers` y `tax_lines` ya pegados en cada item.
  Future<OpenTableResult> openTableAndLoad({
    required String tableId,
    String? userId,
    int peopleCount = 1,
    String? openedByEmployeeId,
  }) async {
    // Ver nota en openTable: se cancela ANTES del RPC.
    cancelPendingEmptyTableRelease(tableId);
    final response = await PerformanceDiagnostics.instance.measure(
      'rpc_apertura_mesa',
      () => _client.rpc(
        'fn_open_table_and_load',
        params: {
          'p_table_id': tableId,
          'p_user_id': userId,
          'p_people_count': peopleCount,
          'p_opened_by_employee_id': openedByEmployeeId,
        },
      ),
    );

    if (response == null) {
      throw Exception('No se pudo abrir la mesa');
    }

    return _parseOpenTableAndLoad(Map<String, dynamic>.from(response as Map));
  }

  /// Igual que [openTableAndLoad] pero A TRAVÉS del Hub Local: el Hub (que sí
  /// tiene internet) ejecuta el RPC contra Supabase y devuelve el MISMO JSON,
  /// que parseamos idéntico. Para cajas cliente cuya conexión directa a
  /// Supabase es mala → obtienen la orden REAL (con datos fiscales) sin
  /// depender de su propio WAN. Lanza si el Hub no responde (el caller cae al
  /// respaldo local).
  Future<OpenTableResult> openTableAndLoadViaHub({
    required String hubBaseUrl,
    required String tableId,
    String? userId,
    int peopleCount = 1,
    String? openedByEmployeeId,
  }) async {
    // Ver nota en openTable: se cancela ANTES de salir al Hub.
    cancelPendingEmptyTableRelease(tableId);
    final raw = await PerformanceDiagnostics.instance.measure(
      'proxy_hub_apertura_mesa',
      () => HubClient().proxyOpenTable(
        hubBaseUrl,
        tableId: tableId,
        userId: userId,
        peopleCount: peopleCount,
        openedByEmployeeId: openedByEmployeeId,
      ),
    );
    if (raw == null) {
      throw Exception('El Hub no pudo abrir la mesa (sin respuesta)');
    }
    return _parseOpenTableAndLoad(raw);
  }

  /// Parsea la respuesta cruda de `fn_open_table_and_load` (order_id + bundle
  /// con items/modifiers/tax_lines/checks embebidos) en [OpenTableResult].
  OpenTableResult _parseOpenTableAndLoad(Map<String, dynamic> payload) {
    final orderId = payload['order_id']?.toString();
    if (orderId == null || orderId.isEmpty) {
      throw Exception('fn_open_table_and_load no retornó order_id');
    }

    final bundleRaw = payload['bundle'];
    if (bundleRaw is! Map) {
      return (
        orderId: orderId,
        bundle: (
          order: null,
          items: const <OrderItem>[],
          checks: const <OrderCheck>[],
          customerId: null,
          customerName: null,
          note: null,
        ),
      );
    }

    final bundleMap = Map<String, dynamic>.from(bundleRaw);

    final orderMapRaw = bundleMap['order'];
    final order = orderMapRaw is Map
        ? Order.fromMap(Map<String, dynamic>.from(orderMapRaw))
        : null;

    // Items con modifiers + tax_lines embebidos por el RPC
    final itemsRaw = (bundleMap['items'] as List?) ?? const [];
    final items = <OrderItem>[];
    for (final row in itemsRaw) {
      if (row is! Map) continue;
      final itemMap = Map<String, dynamic>.from(row);

      final baseItem = OrderItem.fromMap(itemMap);

      // Parsear modifiers embebidos en el item
      final modsRaw = itemMap['modifiers'];
      final modifiers = <OrderItemModifier>[];
      if (modsRaw is List) {
        for (final m in modsRaw) {
          if (m is Map) {
            modifiers.add(
              OrderItemModifier.fromMap(Map<String, dynamic>.from(m)),
            );
          }
        }
      }

      // Parsear tax_lines embebidos
      final taxRaw = itemMap['tax_lines'];
      final taxLines = <OrderItemTaxLine>[];
      if (taxRaw is List) {
        for (final t in taxRaw) {
          if (t is Map) {
            taxLines.add(
              OrderItemTaxLine.fromMap(Map<String, dynamic>.from(t)),
            );
          }
        }
      }

      items.add(baseItem.copyWith(modifiers: modifiers, taxLines: taxLines));
    }

    final checksRaw = (bundleMap['checks'] as List?) ?? const [];
    final checks = checksRaw
        .whereType<Map>()
        .map((m) => OrderCheck.fromMap(Map<String, dynamic>.from(m)))
        .toList(growable: false);

    return (
      orderId: orderId,
      bundle: (
        order: order,
        items: items,
        checks: checks,
        customerId: bundleMap['customer_id']?.toString(),
        customerName: bundleMap['customer_name']?.toString(),
        note: bundleMap['note']?.toString(),
      ),
    );
  }

  /// Abrir venta manual o rápida
  ///
  /// [businessId] es CRÍTICO para Owners multi-sucursal: el RPC ignora
  /// `activeBusinessId` del cliente y por defecto elegía siempre el negocio
  /// más antiguo del usuario, abriendo la orden en otro tenant. Pasarlo
  /// explícitamente fuerza al RPC a abrir la orden en la sucursal activa.
  /// Ver migración 20260526_0003_fix_open_manual_or_quick_business_scope.sql.
  Future<Map<String, dynamic>> openManualOrQuick({
    required String origin, // 'manual' o 'quick_sale'
    String? customerName,
    int peopleCount = 1,
    String? businessId,
  }) async {
    try {
      // El RPC crea zona/mesa bajo el mismo candado que retail y offline,
      // dentro de la sucursal solicitada. Precrearlas desde el cliente podía
      // duplicar zonas o usar otro negocio del usuario antes de abrir la venta.
      final response = await _client.rpc(
        SalesQueries.rpcOpenManualOrQuick,
        params: {
          'p_origin': origin,
          'p_people_count': peopleCount,
          'p_user_id': _client.auth.currentUser?.id,
          if (businessId != null && businessId.isNotEmpty)
            'p_business_id': businessId,
        },
      );

      if (response == null) {
        throw Exception('No se pudo abrir la venta $origin');
      }

      return Map<String, dynamic>.from(response as Map);
    } catch (e) {
      throw Exception('Error al abrir venta $origin: $e');
    }
  }

  /// Venta rápida persistente: devuelve el id de la orden `quick` ABIERTA del
  /// negocio (la mesa virtual de venta rápida es única por negocio), o null si
  /// no hay ninguna. Permite RETOMAR una venta no cobrada en vez de abrir una
  /// nueva (que anularía la previa). Best-effort: null ante cualquier fallo.
  /// Ver docs/PRD_DELIVERY_FEE_PROPIO.md (Feature C venta rápida).
  Future<String?> findOpenQuickOrderId(String businessId) async {
    try {
      final rows = await _client
          .from('orders')
          .select(
            'id, created_at, table_sessions!inner(business_id, origin, closed_at)',
          )
          .eq('status_ext', 'open')
          .eq('table_sessions.business_id', businessId)
          .inFilter('table_sessions.origin', ['quick', 'quick_sale'])
          .isFilter('table_sessions.closed_at', null)
          .order('created_at', ascending: false)
          .limit(1);
      if (rows.isNotEmpty) {
        final id = (rows.first as Map)['id'];
        return id is String && id.isNotEmpty ? id : null;
      }
      return null;
    } catch (e) {
      // No es fatal: si falla la consulta, el caller abre una venta nueva.
      return null;
    }
  }

  /// Retail: abre una venta rápida en una mesa virtual DEDICADA por carrito
  /// (`slot`), permitiendo varias ventas rápidas simultáneas sin que abrir una
  /// nueva anule las demás. A diferencia de [openManualOrQuick] (que comparte
  /// una sola mesa virtual 'quick' y cierra la sesión previa), cada slot tiene
  /// su propia mesa/sesión/orden. Idempotente por slot: reabrir el mismo slot
  /// devuelve su orden abierta.
  Future<Map<String, dynamic>> openRetailCart({
    required String slot,
    required String businessId,
    int peopleCount = 1,
  }) async {
    try {
      final response = await _client.rpc(
        'fn_open_retail_cart',
        params: {
          'p_business_id': businessId,
          'p_user_id': _client.auth.currentUser?.id,
          'p_slot': slot,
          'p_people_count': peopleCount,
        },
      );
      if (response == null) {
        throw Exception('No se pudo abrir la venta rápida');
      }
      return Map<String, dynamic>.from(response as Map);
    } catch (e) {
      throw Exception('Error al abrir venta rápida (retail): $e');
    }
  }

  /// Recrea una venta offline usando su identidad estable e independiente.
  Future<Map<String, dynamic>> openOfflineSale({
    required String origin,
    required String slot,
    required String businessId,
  }) async {
    final response = await _client.rpc(
      'fn_open_offline_sale',
      params: {
        'p_business_id': businessId,
        'p_user_id': _client.auth.currentUser?.id,
        'p_origin': origin,
        'p_slot': slot,
        'p_people_count': 1,
      },
    );
    if (response == null) {
      throw StateError('No se pudo sincronizar la venta local.');
    }
    return Map<String, dynamic>.from(response as Map);
  }

  /// Asignar una orden manual a una mesa real
  Future<Map<String, dynamic>> assignManualOrderToTable({
    required String orderId,
    required String tableId,
    String? userId,
  }) async {
    try {
      final response = await _client.rpc(
        'fn_assign_manual_order_to_table',
        params: {
          'p_order_id': orderId,
          'p_table_id': tableId,
          'p_user_id': userId,
        },
      );

      if (response == null) {
        throw Exception('No se pudo asignar la venta manual a mesa');
      }

      return Map<String, dynamic>.from(response as Map);
    } catch (e) {
      throw Exception('Error al asignar venta manual a mesa: $e');
    }
  }

  /// Obtener sesiones activas
  Future<List<TableSession>> getActiveSessions(String businessId) async {
    try {
      final data = await _client
          .from('table_sessions')
          .select('*, dining_tables(code, zones(name))')
          .eq('business_id', businessId)
          .isFilter('closed_at', null)
          .order('opened_at', ascending: false);

      return data.map((json) => TableSession.fromMap(json)).toList();
    } catch (e) {
      throw Exception('Error al obtener sesiones activas: $e');
    }
  }

  // ── Liberación de mesa vacía ────────────────────────────────────────────
  // Timers de liberación pendientes, indexados por **tableId** (con fallback a
  // orderId si no hay mesa). Por mesa y no por orden a propósito: así la
  // cancelación puede dispararse al EMPEZAR la apertura, cuando todavía no se
  // sabe qué orden va a devolver el RPC. Eso saca la latencia de red de la
  // ecuación y es lo que permite que la ventana sea de milisegundos.
  //
  // Static porque el `dispose()` de la pantalla de mesa construye su propio
  // SalesRepository (no puede tocar `ref` durante el teardown), así que la
  // cancelación tiene que vivir fuera de cualquier instancia.
  static final Map<String, _PendingEmptyTableRelease>
  _pendingEmptyTableReleases = {};

  /// Gracia antes de liberar una mesa vacía.
  ///
  /// Existe por una razón medida: cuando la ruta de la mesa se REEMPLAZA, el
  /// `dispose()` de la instancia vieja y el `initState()` de la nueva caen en
  /// frames contiguos. En el caso real de MESA9 (2026-08-13) la orden nueva
  /// nació **73 ms** después de que la limpieza anulara la vieja, y la sesión
  /// se cerró encima de ella. Con esta ventana la reapertura llega primero y
  /// cancela la liberación; como la orden nunca se anula, `fn_open_table` la
  /// reusa y ni siquiera se crea una segunda orden.
  ///
  /// Por qué 400 ms y no 3 s: la cancelación ocurre al ARRANCAR la apertura
  /// (`cancelPendingEmptyTableRelease(tableId)` antes del RPC), no cuando el
  /// RPC responde. Así la ventana solo tiene que cubrir el salto entre el
  /// `dispose()` y el `initState()` de la pantalla entrante — un frame, ~16 ms
  /// — en vez del viaje de red. 400 ms son 25× ese salto, y aguantan un
  /// rebuild con jank a 10 fps. Subirlo NO da más protección: si en 400 ms no
  /// hubo reapertura, no la va a haber.
  static const Duration emptyTableReleaseDelay = Duration(milliseconds: 400);

  /// Programa la liberación de una mesa vacía tras [emptyTableReleaseDelay].
  ///
  /// Reprograma si ya había una pendiente para la misma mesa (el `_handleBack`
  /// y el `dispose()` disparan los dos: antes eso eran dos liberaciones, ahora
  /// es una). [onReleased] corre justo cuando la liberación TERMINA — es para
  /// refrescar el salón en ese instante y no antes, que era por qué la mesa
  /// parecía tardar en ponerse verde.
  void scheduleEmptyTableRelease(
    String orderId, {
    String? tableId,
    String? businessId,
    void Function()? onReleased,
    void Function(bool released)? onResult,
    Future<bool> Function()? release,
  }) {
    if (orderId.isEmpty || orderId.startsWith('local-order-')) return;

    final key = (tableId != null && tableId.isNotEmpty) ? tableId : orderId;
    final existing = _pendingEmptyTableReleases[key];
    if (existing?.orderId == orderId) {
      // _handleBack programa con callback; dispose llega un frame despues sin
      // callback. No reemplazarlo o el Hub y el salon nunca se enteran.
      existing!.onReleased = onReleased ?? existing.onReleased;
      existing.onResult = onResult ?? existing.onResult;
      existing.release ??= release;
      return;
    }
    existing?.timer.cancel();
    final pending = _PendingEmptyTableRelease(orderId)
      ..onReleased = onReleased
      ..onResult = onResult
      ..release = release;
    _pendingEmptyTableReleases[key] = pending;
    pending.timer = Timer(emptyTableReleaseDelay, () async {
      if (identical(_pendingEmptyTableReleases[key], pending)) {
        _pendingEmptyTableReleases.remove(key);
      }
      var released = false;
      try {
        released =
            await (pending.release?.call() ??
                releaseEmptyTableIfNeeded(orderId, businessId: businessId));
      } catch (error) {
        // Best-effort: si falla, el barrido de fn_release_empty_tables la
        // recoge más tarde. Nunca debe tumbar la navegación.
        debugPrint('No se pudo liberar la mesa vacia $key: $error');
      }
      try {
        pending.onResult?.call(released);
      } catch (error) {
        debugPrint('No se pudo notificar el cierre de $key: $error');
      }
      pending.onReleased?.call();
    });
  }

  /// Cancela la liberación pendiente de [tableId] (o de un orderId, si se
  /// programó sin mesa). La llaman TODOS los caminos de apertura, **antes** de
  /// mandar el RPC: si el mesero volvió a entrar, la mesa está en uso y la
  /// limpieza de la visita anterior ya no aplica.
  static void cancelPendingEmptyTableRelease(String? key) {
    if (key == null || key.isEmpty) return;
    _pendingEmptyTableReleases.remove(key)?.timer.cancel();
  }

  /// Liberaciones de mesa pendientes. Solo para tests: es lo único observable
  /// de la ventana de gracia sin llegar a la red.
  @visibleForTesting
  static int get pendingEmptyTableReleaseCount =>
      _pendingEmptyTableReleases.length;

  /// Libera defensivamente una mesa si la orden ya no tiene productos vigentes.
  ///
  /// Un solo RPC. La versión anterior hacía cuatro viajes sueltos sin
  /// transacción ni lock, y entre el chequeo de "¿hay otras órdenes abiertas?"
  /// y el cierre de la sesión cabía un `fn_open_table` concurrente: la orden
  /// que ese abría quedaba viva colgando de una sesión ya cerrada — invisible
  /// en el salón, nunca cobrada, y con los insumos ya descontados por su
  /// comanda. `fn_release_empty_table` hace lo mismo en una transacción,
  /// tomando FOR UPDATE sobre la fila de la mesa (ver migración
  /// 20260814_0001). Como cierra con `now()` del servidor, también acaba con
  /// las sesiones guardadas 4 h en el pasado.
  ///
  /// T02 (20261010_0030): [deviceId] es el equipo que sale y
  /// [hasPendingWork] si tiene algo de esa cuenta sin subir. Si otra terminal
  /// participó, la mesa se libera recién cuando ella confirme (o la conserva
  /// el barrido). Sin el equipo no se libera. Sin la migración (PGRST202) se
  /// libera al instante con `fn_release_empty_table` si este equipo no tiene
  /// nada pendiente de esa cuenta: regla del dueño (10-oct) y lo tardío de
  /// otro equipo vuelve como cuenta en revisión (20261010_0020).
  Future<bool> releaseEmptyTableIfNeeded(
    String orderId, {
    String? businessId,
    String? deviceId,
    bool hasPendingWork = true,
  }) async {
    if (orderId.isEmpty || orderId.startsWith('local-order-')) return false;
    if (deviceId == null || deviceId.isEmpty) return false;
    try {
      await _assertOrderInBusinessScope(orderId, businessId: businessId);

      final response = await _client.rpc(
        SalesQueries.rpcReleaseEmptyTableV2,
        params: {
          'p_order_id': orderId,
          'p_device_id': deviceId,
          'p_has_pending': hasPendingWork,
        },
      );

      if (response is Map) {
        return response['released'] == true;
      }
      return false;
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST202') {
        // Sin 20261010_0030: salir de una mesa SIN productos la libera al
        // instante con la función vigente (regla del dueño, 10-oct). Lo que
        // otro equipo tuviera sin subir no se pierde: vuelve como cuenta en
        // revisión (20261010_0020). Con trabajo propio pendiente, no.
        if (hasPendingWork) return false;
        try {
          return await _releaseEmptyTableNow(orderId);
        } catch (e) {
          throw Exception('Error al liberar mesa vacia: $e');
        }
      }
      throw Exception('Error al liberar mesa vacia: $e');
    } catch (e) {
      throw Exception('Error al liberar mesa vacia: $e');
    }
  }

  Future<bool> _releaseEmptyTableNow(String orderId) async {
    final response = await _client.rpc(
      'fn_release_empty_table',
      params: {'p_order_id': orderId},
    );
    return response is Map && response['released'] == true;
  }

  /// T02: este equipo participa en la sesión de [orderId] (la cargó en
  /// línea). Las liberaciones automáticas esperan su confirmación.
  Future<void> registerSessionParticipant(
    String orderId,
    String deviceId,
  ) async {
    await _client.rpc(
      SalesQueries.rpcRegisterSessionParticipant,
      params: {'p_order_id': orderId, 'p_device_id': deviceId},
    );
  }

  /// T02: pedidos de liberación que esperan la confirmación de este equipo.
  Future<List<({String sessionId, int version, List<String> orderIds})>>
  pendingReleaseRequests(String businessId, String deviceId) async {
    final rows = await _client.rpc(
      SalesQueries.rpcPendingReleaseRequests,
      params: {'p_business_id': businessId, 'p_device_id': deviceId},
    );
    if (rows is! List) return const [];
    return [
      for (final row in rows.whereType<Map>())
        (
          sessionId: row['session_id'].toString(),
          version: (row['version'] as num).toInt(),
          orderIds: [
            for (final id in (row['order_ids'] as List? ?? const []))
              id.toString(),
          ],
        ),
    ];
  }

  /// T02: confirma (con o sin pendientes) la versión [version] de la sesión.
  /// Si era la última confirmación, el servidor libera en el mismo paso.
  Future<Map<String, dynamic>?> ackSessionRelease({
    required String sessionId,
    required String deviceId,
    required int version,
    required bool hasPendingWork,
  }) async {
    final response = await _client.rpc(
      SalesQueries.rpcAckSessionRelease,
      params: {
        'p_session_id': sessionId,
        'p_device_id': deviceId,
        'p_version': version,
        'p_has_pending': hasPendingWork,
      },
    );
    return response is Map ? Map<String, dynamic>.from(response) : null;
  }

  Future<({String? customerId, String? customerName, String? note})>
  getSessionCustomer(String sessionId, {String? businessId}) async {
    try {
      await _assertSessionInBusinessScope(sessionId, businessId: businessId);

      var query = _client
          .from('table_sessions')
          .select('customer_id, customer_name, note')
          .eq('id', sessionId);

      final scopedBusinessId = businessId?.trim();
      if (scopedBusinessId != null && scopedBusinessId.isNotEmpty) {
        query = query.eq('business_id', scopedBusinessId);
      }

      final data = await query.maybeSingle();

      return (
        customerId: data?['customer_id'] as String?,
        customerName: data?['customer_name'] as String?,
        note: data?['note'] as String?,
      );
    } catch (e) {
      throw Exception('Error al obtener cliente de la sesión: $e');
    }
  }

  /// Cliente de la cuenta (vive en la sesión; [OrderEdit.orderId] es la
  /// orden que el operador editaba).
  Future<OrderEditResult> assignCustomerToSession({
    required String sessionId,
    required String customerId,
    required String customerName,
    String? businessId,
    required OrderEdit edit,
  }) async {
    await _assertSessionInBusinessScope(sessionId, businessId: businessId);
    return _editOrThrow(
      'Error al asignar cliente',
      () => applyOrderEdit(
        edit: edit,
        kind: 'session_customer',
        args: {
          'customer_id': customerId,
          'customer_name': customerName.trim().isEmpty
              ? null
              : customerName.trim(),
        },
      ),
    );
  }

  /// Actualiza la dirección de entrega del pedido de delivery. Update
  /// directo sobre `table_sessions.delivery_address` (mismo molde que
  /// [updateSessionNote]). Opcional: una dirección vacía la deja en null.
  Future<void> updateDeliveryAddress({
    required String sessionId,
    String? address,
    String? businessId,
  }) async {
    try {
      await _assertSessionInBusinessScope(sessionId, businessId: businessId);

      var query = _client
          .from('table_sessions')
          .update({
            'delivery_address': address?.trim().isEmpty == true
                ? null
                : address?.trim(),
          })
          .eq('id', sessionId);

      final scopedBusinessId = businessId?.trim();
      if (scopedBusinessId != null && scopedBusinessId.isNotEmpty) {
        query = query.eq('business_id', scopedBusinessId);
      }

      await query;
    } catch (e) {
      throw Exception('Error al actualizar la dirección de entrega: $e');
    }
  }

  /// Lee la dirección de entrega guardada en la sesión (o null).
  Future<String?> getSessionDeliveryAddress(
    String sessionId, {
    String? businessId,
  }) async {
    final row = await _client
        .from('table_sessions')
        .select('delivery_address')
        .eq('id', sessionId)
        .maybeSingle();
    final value = row?['delivery_address'] as String?;
    return (value == null || value.trim().isEmpty) ? null : value.trim();
  }

  /// Enciende/apaga un producto del menu (`menu_items.is_active`). Es el
  /// "86" que dispara el boton Agotar de la POS.
  ///
  /// El `.select()` NO es decorativo: la policy `menu_items_write` solo deja
  /// escribir `menu_items` a `user_businesses.role IN ('owner','admin')`. Un
  /// UPDATE bloqueado por RLS no es un error — PostgREST responde 204 sin
  /// tocar nada — asi que sin comprobar filas la POS mostraba "quedo marcado
  /// como agotado" y el producto seguia a la venta. Si no volvio ninguna
  /// fila, lanzamos para que la UI lo diga.
  Future<void> setMenuItemAvailability({
    required String menuItemId,
    required bool isActive,
  }) async {
    final List<dynamic> updated;
    try {
      updated = await _client
          .from('menu_items')
          .update({'is_active': isActive})
          .eq('id', menuItemId)
          .select('id');
    } catch (e) {
      throw Exception('Error al actualizar disponibilidad del producto: $e');
    }

    if (updated.isEmpty) {
      throw Exception(
        'No se pudo cambiar la disponibilidad del producto: tu usuario no '
        'tiene permiso para modificar el menu. Pideselo a un administrador.',
      );
    }
  }

  // ============================================================
  // 🍔 ITEMS DE ORDEN
  // ============================================================

  /// Agregar producto del menú a la orden
  /// Agrega una OFERTA como UNA línea a precio ORIGINAL (cantidad N) con el
  /// [discount] del deal en `discounts`, en UN viaje vía `fn_add_offer_deal`.
  /// Así el descuento se ve abajo en los totales. La línea lleva [DEAL:] (el
  /// motor la ignora) + promotion_id. Si la RPC no está aplicada
  /// (20260605_0005), inserta el producto y fija nombre/descuento con update
  /// directo (los triggers recomputan los totales).
  ///
  /// [clientOpId] identifica el toque (20260929_0001): un reintento con el
  /// mismo id no crea una segunda línea. Solo se cae al alta normal cuando el
  /// SERVIDOR respondió con error (su transacción se revirtió entera); ante un
  /// error de red el resultado es desconocido y se propaga — antes el respaldo
  /// atrapaba cualquier error y podía duplicar la oferta.
  /// Devuelve el id de la línea creada (null si el servidor no lo informó).
  Future<String?> addOfferDealItem({
    required String orderId,
    required String menuItemId,
    double quantity = 1,
    required double discount,
    required String name,
    String? promotionId,
    int checkPosition = 1,
    String? clientOpId,
    String? createdByEmployeeId,
  }) async {
    final opId = clientOpId ?? const Uuid().v4();
    Future<String?> viaMenuItem() => _addOfferDealViaMenuItem(
      clientOpId: opId,
      orderId: orderId,
      menuItemId: menuItemId,
      quantity: quantity,
      discount: discount,
      name: name,
      promotionId: promotionId,
      checkPosition: checkPosition,
      createdByEmployeeId: createdByEmployeeId,
    );

    final missingAt = _idempotentDealMissingAt;
    final skipIdempotent =
        missingAt != null &&
        DateTime.now().difference(missingAt) < _idempotentAddRecheck;
    if (skipIdempotent) {
      throw StateError(
        'Falta aplicar la migración de alta idempotente de ítems.',
      );
    }
    if (!skipIdempotent) {
      try {
        final response = await _client.rpc(
          SalesQueries.rpcAddOfferDealIdempotent,
          params: {
            'p_client_op_id': opId,
            'p_order_id': orderId,
            'p_menu_item_id': menuItemId,
            'p_qty': quantity,
            'p_discount': discount,
            'p_name': name,
            'p_promotion_id': promotionId,
            'p_check_position': checkPosition,
            'p_created_by_employee_id': createdByEmployeeId,
          },
        );
        _idempotentDealMissingAt = null;
        final itemId = response is Map ? response['item_id']?.toString() : null;
        return itemId == null || itemId.isEmpty ? null : itemId;
      } on PostgrestException catch (e) {
        if (e.code != 'PGRST202') {
          final friendly = closedOrderErrorMessage(e);
          if (friendly != null) throw Exception(friendly);
          // La oferta viva falló en el servidor y no dejó nada: alta normal
          // con el MISMO id (la bitácora quedó libre).
          return viaMenuItem();
        }
        _idempotentDealMissingAt = DateTime.now();
        throw StateError(
          'Falta aplicar la migración de alta idempotente de ítems.',
        );
      }
    }
    return null;
  }

  static DateTime? _idempotentDealMissingAt;

  Future<String?> _addOfferDealViaMenuItem({
    required String clientOpId,
    required String orderId,
    required String menuItemId,
    required double quantity,
    required double discount,
    required String name,
    required String? promotionId,
    required int checkPosition,
    required String? createdByEmployeeId,
  }) async {
    final added = await addItemFromMenuIdempotent(
      clientOpId: clientOpId,
      orderId: orderId,
      menuItemId: menuItemId,
      quantity: quantity,
      checkPosition: checkPosition,
      createdByEmployeeId: createdByEmployeeId,
    );
    if (added.itemId.isEmpty || !added.itemExists) return null;
    final id = added.itemId;
    final marker = promotionId != null ? '[DEAL:$promotionId]' : '[DEAL:]';
    final payload = <String, dynamic>{
      'product_name': name,
      'discounts': discount,
      'notes': marker,
    };
    if (promotionId != null) payload['promotion_id'] = promotionId;
    try {
      await _client.from('order_items').update(payload).eq('id', id);
    } catch (_) {
      payload.remove('promotion_id');
      await _client.from('order_items').update(payload).eq('id', id);
    }
    return id;
  }

  /// Igual que [addItemFromMenu] pero A TRAVÉS del Hub (que tiene internet):
  /// agrega el ítem REAL (+ modifiers) contra Supabase y devuelve su id. Para
  /// cajas cliente con conexión directa mala. Devuelve null si el Hub no
  /// respondió (el caller cae al respaldo local).
  Future<String?> addItemFromMenuViaHub({
    required String hubBaseUrl,
    required String orderId,
    required String menuItemId,
    double quantity = 1,
    int checkPosition = 1,
    bool isTakeout = false,
    String? notes,
    List<Map<String, dynamic>> modifiers = const [],
    String? employeeId,
    String? clientOpId,
  }) {
    return HubClient().proxyAddItem(
      hubBaseUrl,
      orderId: orderId,
      menuItemId: menuItemId,
      quantity: quantity,
      checkPosition: checkPosition,
      isTakeout: isTakeout,
      notes: notes,
      modifiers: modifiers,
      employeeId: employeeId,
      clientOpId: clientOpId,
    );
  }

  /// Cuándo se vio por última vez que `fn_add_item_from_menu_idempotent` no
  /// existe (migración 20260929_0001 sin aplicar). Mientras sea reciente se
  /// bloquea el alta; pasado [_idempotentAddRecheck] se vuelve a probar.
  static DateTime? _idempotentAddMissingAt;
  static const _idempotentAddRecheck = Duration(minutes: 5);

  @visibleForTesting
  static void debugResetIdempotentAddProbe() {
    _idempotentAddMissingAt = null;
    _idempotentDealMissingAt = null;
  }

  /// Alta de ítem con UN solo efecto por [clientOpId]: un reintento con el
  /// mismo id (respuesta perdida, replay de la cola, proxy del Hub) devuelve
  /// el ítem ya creado en vez de crear otro. `itemExists=false` = el ítem se
  /// creó y después se borró; no hay que tocarlo (ni sus modificadores).
  ///
  /// Si la migración no está aplicada se bloquea el alta: degradar a la RPC
  /// vieja haría posible cobrar dos veces tras una respuesta perdida.
  Future<({String itemId, bool replayed, bool itemExists})>
  addItemFromMenuIdempotent({
    required String clientOpId,
    required String orderId,
    required String menuItemId,
    double quantity = 1,
    int checkPosition = 1,
    bool isTakeout = false,
    String? notes,
    String? createdByEmployeeId,
  }) async {
    final missingAt = _idempotentAddMissingAt;
    final skipRpc =
        missingAt != null &&
        DateTime.now().difference(missingAt) < _idempotentAddRecheck;
    if (skipRpc) {
      throw StateError(
        'Falta aplicar la migración de alta idempotente de ítems.',
      );
    }
    try {
      final response = await _client.rpc(
        SalesQueries.rpcAddItemFromMenuIdempotent,
        params: {
          'p_client_op_id': clientOpId,
          'p_order_id': orderId,
          'p_menu_item_id': menuItemId,
          'p_qty': quantity,
          'p_check_position': checkPosition,
          'p_is_takeout': isTakeout,
          'p_notes': notes,
          'p_created_by_employee_id': createdByEmployeeId,
        },
      );
      _idempotentAddMissingAt = null;
      final map = Map<String, dynamic>.from(response as Map);
      final itemId = map['item_id']?.toString() ?? '';
      if (itemId.isEmpty) {
        throw StateError('fn_add_item_from_menu_idempotent sin item_id');
      }
      return (
        itemId: itemId,
        replayed: map['replayed'] == true,
        itemExists: map['item_exists'] != false,
      );
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST202') {
        final friendly = closedOrderErrorMessage(e);
        if (friendly != null) throw Exception(friendly);
        throw Exception('Error al agregar item: $e');
      }
      _idempotentAddMissingAt = DateTime.now();
      throw StateError(
        'Falta aplicar la migración de alta idempotente de ítems.',
      );
    } catch (e) {
      final friendly = closedOrderErrorMessage(e);
      if (friendly != null) throw Exception(friendly);
      throw Exception('Error al agregar item: $e');
    }
  }

  Future<String> addItemFromMenu({
    required String orderId,
    required String menuItemId,
    double quantity = 1,
    int checkPosition = 1,
    bool isTakeout = false,
    String? notes,
  }) async {
    try {
      final response = await _client.rpc(
        SalesQueries.rpcAddItemFromMenu,
        params: {
          'p_order_id': orderId,
          'p_menu_item_id': menuItemId,
          'p_qty': quantity,
          'p_check_position': checkPosition,
          'p_is_takeout': isTakeout,
          'p_notes': notes,
        },
      );

      return response as String;
    } catch (e) {
      // Candado de orden cerrada: el mensaje crudo de Postgres no le dice
      // nada al mesero. Ver `closedOrderErrorMessage`.
      final friendly = closedOrderErrorMessage(e);
      if (friendly != null) throw Exception(friendly);
      throw Exception('Error al agregar item: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getComboGroupsForMenuItem(
    String menuItemId,
  ) async {
    try {
      final data = await _client
          .from('combo_groups')
          .select(
            'id, name, min_select, max_select, is_required, sort_order, combo_group_items(id, menu_item_id, price_delta, is_default, sort_order, menu_items(id, name, price, is_active))',
          )
          .eq('menu_item_id', menuItemId)
          .order('sort_order');
      return List<Map<String, dynamic>>.from(data as List);
    } catch (e) {
      throw Exception('Error al obtener grupos del combo: $e');
    }
  }

  /// Precarga los grupos de todos los combos del catálogo en lotes, en vez
  /// de repetir una petición por producto durante la preparación offline.
  Future<Map<String, List<Map<String, dynamic>>>> getComboGroupsForItems(
    List<String> menuItemIds,
  ) async {
    final ids = menuItemIds.toSet().toList(growable: false);
    final grouped = <String, List<Map<String, dynamic>>>{
      for (final id in ids) id: <Map<String, dynamic>>[],
    };
    const batchSize = 100;
    const pageSize = 1000;
    for (var start = 0; start < ids.length; start += batchSize) {
      final batch = ids.skip(start).take(batchSize).toList(growable: false);
      for (var offset = 0; ; offset += pageSize) {
        final rows = await _client
            .from('combo_groups')
            .select(
              'id, menu_item_id, name, min_select, max_select, is_required, sort_order, '
              'combo_group_items(id, menu_item_id, price_delta, is_default, sort_order, '
              'menu_items(id, name, price, is_active))',
            )
            .inFilter('menu_item_id', batch)
            .order('menu_item_id', ascending: true)
            .order('sort_order', ascending: true)
            .order('id', ascending: true)
            .range(offset, offset + pageSize - 1);
        for (final row in rows) {
          final group = Map<String, dynamic>.from(row as Map);
          final itemId = group.remove('menu_item_id')?.toString();
          grouped[itemId]?.add(group);
        }
        if (rows.length < pageSize) break;
      }
    }
    return grouped;
  }

  // `is_sold_out` (auto-86 del modificador, 20260907_0004) va aparte: si la
  // migración no está aplicada PostgREST responde 42703 y se reintenta sin
  // ella. Sin este respaldo, una migración pendiente dejaría al POS sin poder
  // abrir modificadores.
  static const _modifierColumns =
      'id, group_id, name, price_delta, is_active, sort_order, default_selected';
  static const _modifierGroupColumns =
      'id, name, min_select, max_select, is_active, display_type, '
      'selection_mode, is_required, free_qty, max_qty_per_option, sort_order';

  static bool _isMissingColumn(PostgrestException e) =>
      e.code == '42703' || e.code == 'PGRST204';

  /// Ordena las opciones del grupo por sort_order ascendente; si empate, por
  /// nombre.
  static void _sortGroupModifiers(Object? group) {
    if (group is! Map || group['modifiers'] is! List) return;
    final modifiers = List<dynamic>.from(group['modifiers'] as List);
    modifiers.sort((a, b) {
      final ao = a is Map ? (a['sort_order'] as num?)?.toInt() ?? 0 : 0;
      final bo = b is Map ? (b['sort_order'] as num?)?.toInt() ?? 0 : 0;
      if (ao != bo) return ao.compareTo(bo);
      final an = (a is Map ? a['name'] : '')?.toString().toLowerCase() ?? '';
      final bn = (b is Map ? b['name'] : '')?.toString().toLowerCase() ?? '';
      return an.compareTo(bn);
    });
    group['modifiers'] = modifiers;
  }

  Future<List<Map<String, dynamic>>> getModifierGroupsForMenuItem(
    String menuItemId,
  ) async {
    try {
      // Orden personalizado por producto (menu_item_groups.position).
      // El cliente reordena los grupos desde el editor de producto.
      Future<List<dynamic>> fetch({required bool withSoldOut}) async {
        return await _client
                .from('menu_item_groups')
                .select(
                  'group_id, position, modifier_groups!inner($_modifierGroupColumns, '
                  'modifiers($_modifierColumns${withSoldOut ? ', is_sold_out' : ''}))',
                )
                .eq('menu_item_id', menuItemId)
                .eq('modifier_groups.is_active', true)
                .order('position', ascending: true)
            as List<dynamic>;
      }

      List<dynamic> data;
      try {
        data = await fetch(withSoldOut: true);
      } on PostgrestException catch (e) {
        if (!_isMissingColumn(e)) rethrow;
        data = await fetch(withSoldOut: false);
      }

      final rows = List<Map<String, dynamic>>.from(
        data,
      ).map((row) => Map<String, dynamic>.from(row)).toList(growable: false);

      for (final row in rows) {
        _sortGroupModifiers(row['modifier_groups']);
      }

      return rows;
    } catch (e) {
      throw Exception('Error al obtener modificadores del producto: $e');
    }
  }

  /// Los grupos de modificadores de TODOS los productos del negocio, con la
  /// misma forma por producto que [getModifierGroupsForMenuItem]. Para la
  /// bajada offline en background: dos consultas livianas (grupos una vez +
  /// enlaces producto→grupo) en vez de una por producto.
  Future<Map<String, List<Map<String, dynamic>>>>
  getModifierGroupsByItemForBusiness(String businessId) async {
    Future<List<dynamic>> fetchGroups({required bool withSoldOut}) async {
      return await _client
              .from('modifier_groups')
              .select(
                '$_modifierGroupColumns, '
                'modifiers($_modifierColumns${withSoldOut ? ', is_sold_out' : ''})',
              )
              .eq('business_id', businessId)
              .eq('is_active', true)
          as List<dynamic>;
    }

    List<dynamic> groupRows;
    try {
      groupRows = await fetchGroups(withSoldOut: true);
    } on PostgrestException catch (e) {
      if (!_isMissingColumn(e)) rethrow;
      groupRows = await fetchGroups(withSoldOut: false);
    }

    final groupsById = <String, Map<String, dynamic>>{};
    for (final raw in groupRows.whereType<Map>()) {
      final group = Map<String, dynamic>.from(raw);
      final id = group['id']?.toString();
      if (id == null || id.isEmpty) continue;
      _sortGroupModifiers(group);
      groupsById[id] = group;
    }
    if (groupsById.isEmpty) return const {};

    final links =
        await _client
                .from('menu_item_groups')
                .select(
                  'menu_item_id, group_id, position, modifier_groups!inner(business_id)',
                )
                .eq('modifier_groups.business_id', businessId)
                .order('position', ascending: true)
            as List<dynamic>;

    final byItem = <String, List<Map<String, dynamic>>>{};
    for (final raw in links.whereType<Map>()) {
      final itemId = raw['menu_item_id']?.toString();
      final groupId = raw['group_id']?.toString();
      final group = groupsById[groupId];
      if (itemId == null || group == null) continue;
      byItem.putIfAbsent(itemId, () => []).add({
        'group_id': groupId,
        'position': raw['position'],
        'modifier_groups': group,
      });
    }
    return byItem;
  }

  Future<void> addOrderItemModifiers({
    required String itemId,
    required List<Map<String, dynamic>> modifiers,
  }) async {
    if (modifiers.isEmpty) return;
    // Se guardan dos identidades además del nombre, y las dos son para que el
    // inventario pueda descontar:
    //   - menu_item_id  → componente elegido de un combo   (20260605_0002)
    //   - modifier_id   → opción del catálogo de modifiers (20260907_0002),
    //     la que lleva los insumos configurados («queso extra», «sin queso»).
    // Si alguna columna todavía no existe en la base, se reintenta sin ella,
    // de la más completa a la más vieja: la venta NUNCA se pierde por una
    // migración pendiente, solo se queda sin ese descuento.
    List<Map<String, dynamic>> rows({
      required bool withMenuItem,
      required bool withModifierId,
    }) => modifiers
        .map(
          (modifier) => {
            'item_id': itemId,
            'name': modifier['name'],
            'qty': modifier['qty'] ?? 1,
            'price': modifier['price'] ?? 0,
            if (withMenuItem && modifier['menu_item_id'] != null)
              'menu_item_id': modifier['menu_item_id'],
            if (withModifierId && modifier['modifier_id'] != null)
              'modifier_id': modifier['modifier_id'],
          },
        )
        .toList(growable: false);

    final hasComponentId = modifiers.any((m) => m['menu_item_id'] != null);
    final hasModifierId = modifiers.any((m) => m['modifier_id'] != null);

    // Intentos, del más completo al más pobre. Solo se agregan los que de
    // verdad cambian algo para estos modifiers.
    final attempts = <({bool menuItem, bool modifierId})>[
      (menuItem: true, modifierId: true),
      if (hasModifierId && hasComponentId) (menuItem: true, modifierId: false),
      if (hasModifierId || hasComponentId) (menuItem: false, modifierId: false),
    ];

    Object? firstError;
    for (final attempt in attempts) {
      try {
        await _client
            .from('order_item_modifiers')
            .insert(
              rows(
                withMenuItem: attempt.menuItem,
                withModifierId: attempt.modifierId,
              ),
            );
        return;
      } catch (e) {
        firstError ??= e;
        // Only a missing column justifies an older schema shape. A lost
        // response may already have committed the insert: never insert again.
        if (e is! PostgrestException ||
            (e.code != '42703' && e.code != 'PGRST204')) {
          rethrow;
        }
      }
    }
    throw Exception('Error al guardar modificadores del item: $firstError');
  }

  /// Deja EXACTAMENTE [modifiers] en un ítem RECIÉN creado (alta en línea,
  /// proxy del Hub, replay de add_item). No es una edición concurrente: el
  /// ítem acaba de nacer. Repetirlo con la misma lista no duplica.
  Future<void> replaceModifiersOfNewItem({
    required String itemId,
    required List<Map<String, dynamic>> modifiers,
  }) async {
    try {
      await _client.rpc(
        SalesQueries.rpcReplaceOrderItemModifiers,
        params: {'p_item_id': itemId, 'p_modifiers': modifiers},
      );
    } catch (e) {
      throw Exception('Error al guardar modificadores del item: $e');
    }
  }

  // ============================================================
  // ✏️ EDICIONES VERSIONADAS (T04, 20261010_0006)
  // ============================================================

  /// Única entrada para editar una cuenta o una línea: fn_apply_order_edit
  /// toma el candado del cobro, reconoce reintentos por [OrderEdit.opId] y
  /// rechaza versiones viejas. Devuelve el resultado aplicado; un conflicto
  /// lanza [OrderEditConflict] (no se aplicó nada) y sin la migración
  /// [OrderEditServerOutdated]. No hay respaldo de escritura directa.
  Future<OrderEditResult> applyOrderEdit({
    required OrderEdit edit,
    required String kind,
    String? targetId,
    Map<String, dynamic> args = const {},
  }) async {
    final Object? response;
    try {
      response = await _client.rpc(
        SalesQueries.rpcApplyOrderEdit,
        params: {
          'p_op_id': edit.opId,
          'p_order_id': edit.orderId,
          'p_kind': kind,
          'p_target_id': targetId,
          'p_base_version': edit.base.version,
          'p_expected': edit.base.expected,
          'p_args': args,
          'p_force': edit.base.force,
        },
      );
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST202') throw const OrderEditServerOutdated();
      rethrow;
    }
    if (response is! Map) {
      throw StateError('Respuesta inesperada de fn_apply_order_edit');
    }
    final result = OrderEditResult.fromMap(Map<String, dynamic>.from(response));
    if (!result.applied) throw OrderEditConflict(result);
    return result;
  }

  /// Versión de la cuenta en el servidor (null sin la migración).
  Future<int?> getOrderVersion(String orderId) async {
    final row = await _client
        .from('orders')
        .select('version')
        .eq('id', orderId)
        .maybeSingle();
    return (row?['version'] as num?)?.toInt();
  }

  Future<OrderEditResult> applyItemGroup({
    required String orderId,
    required String opId,
    required List<Map<String, dynamic>> actions,
    bool force = false,
  }) async {
    final Object? response;
    try {
      response = await _client.rpc(
        'fn_apply_order_item_group',
        params: {
          'p_order_id': orderId,
          'p_op_id': opId,
          'p_actions': actions,
          'p_force': force,
        },
      );
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST202') {
        throw StateError(
          'Falta aplicar la migración 20261015_0001 de ediciones agrupadas.',
        );
      }
      rethrow;
    }
    if (response is! Map) {
      throw StateError('Respuesta inválida al guardar el grupo.');
    }
    final result = OrderEditResult.fromMap(Map<String, dynamic>.from(response));
    if (!result.applied) throw OrderEditConflict(result);
    return result;
  }
  Future<OrderEditResult> _editOrThrow(
    String failure,
    Future<OrderEditResult> Function() run,
  ) async {
    try {
      return await run();
    } on OrderEditConflict {
      rethrow;
    } on OrderEditServerOutdated {
      rethrow;
    } catch (e) {
      final blocked = closedOrderErrorMessage(e);
      if (blocked != null) throw Exception(blocked);
      throw Exception('$failure: $e');
    }
  }

  /// Edición de los extras de una línea existente.
  Future<OrderEditResult> replaceOrderItemModifiers({
    required String itemId,
    required List<Map<String, dynamic>> modifiers,
    required OrderEdit edit,
  }) => _editOrThrow(
    'Error al reemplazar modificadores del item',
    () => applyOrderEdit(
      edit: edit,
      kind: 'modifiers',
      targetId: itemId,
      args: {'modifiers': modifiers},
    ),
  );

  Future<void> updateOfflineKitchenItemStatus({
    required String itemId,
    required String status,
    required DateTime at,
  }) async {
    if (status != 'preparing' && status != 'ready') {
      throw ArgumentError.value(status, 'status');
    }
    await _client
        .from('order_items')
        .update({
          'status': status,
          if (status == 'preparing') 'started_at': at.toUtc().toIso8601String(),
          if (status == 'ready') 'ready_at': at.toUtc().toIso8601String(),
        })
        .eq('id', itemId);
  }

  /// Actualizar cantidad de item
  Future<OrderEditResult> updateItemQuantity({
    required String itemId,
    required double quantity,
    required OrderEdit edit,
  }) => _editOrThrow(
    'Error al actualizar cantidad',
    () => applyOrderEdit(
      edit: edit,
      kind: 'qty',
      targetId: itemId,
      args: {'qty': quantity},
    ),
  );

  /// Actualizar notas de item
  Future<OrderEditResult> updateItemNotes({
    required String itemId,
    required String notes,
    required OrderEdit edit,
  }) => _editOrThrow(
    'Error al actualizar notas',
    () => applyOrderEdit(
      edit: edit,
      kind: 'notes',
      targetId: itemId,
      args: {'notes': notes},
    ),
  );

  /// Actualizar detalle completo del item
  Future<OrderEditResult> updateItemDetails({
    required String itemId,
    required String productName,
    required double quantity,
    required bool isTakeout,
    required double discounts,
    String? notes,
    required OrderEdit edit,
  }) async {
    try {
      return await applyOrderEdit(
        edit: edit,
        kind: 'details',
        targetId: itemId,
        args: {
          'product_name': productName,
          'qty': quantity <= 0 ? 1.0 : quantity,
          'is_takeout': isTakeout,
          'discounts': discounts,
          'notes': notes,
        },
      );
    } on OrderEditConflict {
      rethrow;
    } on OrderEditServerOutdated {
      rethrow;
    } catch (e) {
      final raw = e.toString();
      if (raw.contains('ITEM_NOT_FOUND') || raw.contains('PGRST116')) {
        throw Exception(
          'El producto ya no existe en la orden. Refresca la mesa para ver '
          'el estado actual.',
        );
      }
      throw Exception('Error al actualizar item: $e');
    }
  }

  /// Actualiza solo el descuento del item (sin tocar qty/quantity).
  Future<OrderEditResult> updateItemDiscount({
    required String itemId,
    required double discounts,
    required OrderEdit edit,
  }) => _editOrThrow(
    'Error al actualizar descuento del item',
    () => applyOrderEdit(
      edit: edit,
      kind: 'discount',
      targetId: itemId,
      args: {'discounts': discounts},
    ),
  );

  /// Actualiza descuento y notas de una línea en una sola escritura. La
  /// atribución de la promoción viaja en el marcador de [notes] (la versión
  /// viva de fn_update_item_discount_and_notes no tiene p_promotion_id).
  Future<OrderEditResult> updateItemDiscountAndNotes({
    required String itemId,
    required double discounts,
    String? notes,
    bool writePromotion = false,
    String? promotionId,
    required OrderEdit edit,
  }) => _editOrThrow(
    'Error al actualizar descuento/notas del item',
    () => applyOrderEdit(
      edit: edit,
      kind: 'discount_notes',
      targetId: itemId,
      args: {'discounts': discounts, 'notes': notes},
    ),
  );

  /// Eliminar item. Si otro equipo ya lo quitó, la intención se cumplió. El
  /// candado de cuentas facturadas (MP404) llega con su mensaje.
  Future<OrderEditResult> deleteItem({
    required String itemId,
    required OrderEdit edit,
  }) => _editOrThrow(
    'Error al eliminar item',
    () => applyOrderEdit(edit: edit, kind: 'delete', targetId: itemId),
  );

  /// Anota el motivo y el operador (PIN) de un producto que se quitó de la
  /// cuenta después de enviarse a cocina: el borrado lo registra un trigger
  /// (`order_item_removals`, migración 20260919_0002) pero no sabe por qué
  /// ni quién. El borrado ya pasó: esto solo completa el registro y nunca
  /// lanza (sin la migración, simplemente no hace nada).
  ///
  /// [isWaste] true = MERMA: el servidor mete el movimiento que cancela la
  /// devolución de stock, así el inventario refleja que el producto salió
  /// (20260920_0002).
  Future<void> noteItemRemoval({
    required String itemId,
    String? reason,
    String? employeeId,
    String? reasonCode,
    bool? isWaste,
  }) async {
    try {
      await _client.rpc(
        SalesQueries.rpcNoteItemRemoval,
        params: {
          'p_item_id': itemId,
          'p_reason': reason,
          'p_employee_id': employeeId,
          'p_reason_code': reasonCode,
          'p_is_waste': isWaste,
        },
      );
    } catch (e) {
      debugPrint('[removals] no se pudo anotar el motivo: $e');
    }
  }

  /// Cuándo se vio por última vez que `fn_order_opener_employee_id` no sirve
  /// (no existe en producción, o el cuerpo del repo sin el alias de
  /// `current_user_business_ids`, 42703). Mientras sea reciente se lee la
  /// sesión directo, sin pagar la ida y vuelta perdida en cada alta; pasado
  /// [_openerRpcRecheck] se vuelve a probar la RPC.
  static DateTime? _openerRpcMissingAt;
  static const _openerRpcRecheck = Duration(minutes: 5);

  @visibleForTesting
  static void debugResetOpenerRpcProbe() => _openerRpcMissingAt = null;

  static bool _isUnusableOpenerRpc(PostgrestException e) =>
      e.code == 'PGRST202' || e.code == '42883' || e.code == '42703';

  /// Empleado dueño de la mesa de [orderId] (prioriza
  /// `opened_by_employee_id`; si no, el empleado de quien la abrió), vía
  /// `fn_order_opener_employee_id` (20260529_0006). Null si no tiene dueño.
  ///
  /// Si la RPC no existe (producción) se lee `table_sessions.
  /// opened_by_employee_id` de la orden, como ya hace la impresión: así el
  /// mesero del PIN sigue por delante del usuario conectado. Esa lectura solo
  /// conoce al dueño con PIN: null = la mesa se abrió sin PIN.
  /// Los demás errores se propagan: el llamador decide qué hacer sin
  /// respuesta.
  Future<String?> fetchOrderOpenerEmployeeId(String orderId) async {
    final missingAt = _openerRpcMissingAt;
    final skipRpc =
        missingAt != null &&
        DateTime.now().difference(missingAt) < _openerRpcRecheck;
    if (!skipRpc) {
      try {
        final result = await _client.rpc(
          'fn_order_opener_employee_id',
          params: {'p_order_id': orderId},
        );
        _openerRpcMissingAt = null;
        final id = result?.toString();
        return (id == null || id.isEmpty) ? null : id;
      } on PostgrestException catch (e) {
        if (!_isUnusableOpenerRpc(e)) rethrow;
        _openerRpcMissingAt = DateTime.now();
      }
    }
    final row = await _client
        .from('orders')
        .select('id, table_sessions(opened_by_employee_id)')
        .eq('id', orderId)
        .maybeSingle();
    if (row == null) {
      // Sin la orden no se sabe si la mesa tiene dueño: no es "sin dueño".
      throw StateError('Orden $orderId no visible para leer su dueño.');
    }
    final raw = row['table_sessions'];
    final session = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    final id = session is Map
        ? session['opened_by_employee_id']?.toString().trim()
        : null;
    return (id == null || id.isEmpty) ? null : id;
  }

  /// Empleado del usuario autenticado en [businessId], vía
  /// `fn_current_employee_id` (20260529_0004). Null sin sesión o sin fila en
  /// `employees`. Los errores se propagan.
  Future<String?> fetchCurrentEmployeeId(String businessId) async {
    if (_client.auth.currentUser == null) return null;
    final result = await _client.rpc(
      'fn_current_employee_id',
      params: {'p_business_id': businessId},
    );
    final id = result?.toString();
    return (id == null || id.isEmpty) ? null : id;
  }

  /// Sella el autor (`order_items.created_by_employee_id`) de un ítem ya
  /// guardado sin PIN. Los errores se propagan.
  Future<void> setItemCreatedByEmployee({
    required String itemId,
    required String employeeId,
  }) async {
    await _client
        .from('order_items')
        .update({'created_by_employee_id': employeeId})
        .eq('id', itemId);
  }

  /// Deja constancia de QUIÉN autorizó con su PIN de Supervisor/Administrador
  /// el retiro que esta cuenta acaba de hacer de [itemId]
  /// (`order_item_removals.approved_by_*`, migración 20261005_0003).
  ///
  /// El servidor vuelve a validar [approverPin]: no le cree a la app. Llamar
  /// DESPUÉS de borrar o reducir, cuando la fila del registro ya existe.
  /// Devuelve el nombre del aprobador para el comprobante. Nunca lanza: sin
  /// la migración, sin red o con el retiro todavía en cola, simplemente
  /// devuelve `approved: false`.
  Future<({bool approved, String? approverName})> approveItemRemoval({
    required String itemId,
    required String approverPin,
  }) async {
    try {
      final result = await _client.rpc(
        SalesQueries.rpcApproveItemRemoval,
        params: {'p_item_id': itemId, 'p_approver_pin': approverPin},
      );
      if (result is Map && result['approved'] == true) {
        final name = result['approver_name']?.toString().trim();
        return (
          approved: true,
          approverName: name == null || name.isEmpty ? null : name,
        );
      }
      if (result is Map) {
        debugPrint('[removals] aprobación no sellada: ${result['error_code']}');
      }
    } catch (e) {
      debugPrint('[removals] no se pudo sellar el aprobador: $e');
    }
    return (approved: false, approverName: null);
  }

  /// Los motivos configurados para quitar un producto de la cuenta. Si el
  /// servidor todavía no tiene el catálogo (migración 20260920_0002), se
  /// devuelven los de fábrica: sin esto el cajero no podría borrar nada.
  Future<List<OrderItemRemovalReason>> getRemovalReasons(
    String businessId,
  ) async {
    try {
      final rows = await _client
          .from('order_item_removal_reasons')
          .select('code, label, is_waste')
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('position');
      final parsed = [
        for (final row in List<Map<String, dynamic>>.from(rows))
          ?OrderItemRemovalReason.fromRow(row),
      ];
      if (parsed.isNotEmpty) return parsed;
    } catch (e) {
      debugPrint('[removals] catálogo de motivos no disponible: $e');
    }
    return OrderItemRemovalReason.defaults;
  }

  /// Toggle takeout de item
  Future<OrderEditResult> toggleItemTakeout({
    required String itemId,
    required bool isTakeout,
    required OrderEdit edit,
  }) => _editOrThrow(
    'Error al cambiar takeout',
    () => applyOrderEdit(
      edit: edit,
      kind: 'takeout',
      targetId: itemId,
      args: {'is_takeout': isTakeout},
    ),
  );

  // ============================================================
  // 🧾 DETALLE DE ORDEN
  // ============================================================

  /// Obtener orden completa con items
  Future<Order?> getOrder(String orderId, {String? businessId}) async {
    try {
      await _assertOrderInBusinessScope(orderId, businessId: businessId);

      final data = await _client
          .from('orders')
          .select()
          .eq('id', orderId)
          .maybeSingle();

      if (data == null) return null;

      return Order.fromMap(data);
    } on OrderOutOfScopeException {
      return null;
    } catch (e) {
      throw Exception('Error al obtener orden: $e');
    }
  }

  /// Origen y cierre de la SESIÓN de [orderId] (`table_sessions.origin` y
  /// `closed_at`) dentro de [businessId]. `orders` no tiene columna origin: el
  /// `Order.origin` del bundle siempre llega como 'table', así que no sirve
  /// para saber si una orden sigue siendo venta rápida/manual. Null si la
  /// orden no existe o no es de ese negocio. Los fallos (red incluida) se
  /// propagan sin envolver para que el caller distinga la red.
  Future<({String? origin, DateTime? closedAt})?> getOrderSessionOrigin(
    String orderId, {
    required String businessId,
  }) async {
    final row = await _client
        .from('orders')
        .select('id, table_sessions!inner(origin, closed_at, business_id)')
        .eq('id', orderId)
        .eq('table_sessions.business_id', businessId)
        .maybeSingle();
    if (row == null) return null;
    final raw = row['table_sessions'];
    final session = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    if (session is! Map) return null;
    final closedAt = session['closed_at']?.toString();
    return (
      origin: session['origin']?.toString(),
      closedAt: closedAt == null ? null : DateTime.tryParse(closedAt),
    );
  }

  /// True si alguna fila del bundle trae qty no entera. Sirve para disparar
  /// el consolidate lazy (Fase 0 Toast redesign).
  bool _orderBundleHasFractionalQty(dynamic response) {
    if (response is! Map) return false;
    final items = (response['items'] as List?) ?? const [];
    for (final row in items) {
      if (row is! Map) continue;
      final raw = row['qty'] ?? row['quantity'];
      if (raw == null) continue;
      final qty = raw is num ? raw.toDouble() : double.tryParse('$raw');
      if (qty == null) continue;
      if ((qty - qty.roundToDouble()).abs() > 0.001) {
        return true;
      }
    }
    return false;
  }

  /// Obtener bundle de orden en una sola llamada RPC:
  /// order + items + checks + customer(session)
  Future<
    ({
      Order? order,
      List<OrderItem> items,
      List<OrderCheck> checks,
      String? customerId,
      String? customerName,
      String? note,
    })
  >
  getOrderBundle(String orderId, {String? businessId}) async {
    try {
      await _assertOrderInBusinessScope(orderId, businessId: businessId);

      var response = await _client.rpc(
        SalesQueries.rpcGetOrderBundle,
        params: {'p_order_id': orderId},
      );

      // Fase 0 del rediseño Toast: si la orden trae filas con qty fraccional
      // heredadas del legacy fn_split_items_equally, las consolidamos a
      // entero on-the-fly y recargamos. Es idempotente: la RPC vuelve a 0
      // filas tocadas en órdenes ya limpias, por lo que el costo es 1 RPC
      // extra sólo en órdenes afectadas.
      if (_orderBundleHasFractionalQty(response)) {
        try {
          await _client.rpc(
            SalesQueries.rpcConsolidateOrderToInteger,
            params: {'p_order_id': orderId},
          );
          response = await _client.rpc(
            SalesQueries.rpcGetOrderBundle,
            params: {'p_order_id': orderId},
          );
        } catch (_) {
          // Si el consolidate falla (DB sin la migration, permisos, etc.),
          // seguimos con la data fraccional original — la UI ya la tolera.
        }
      }

      if (response == null) {
        return (
          order: null,
          items: const <OrderItem>[],
          checks: const <OrderCheck>[],
          customerId: null,
          customerName: null,
          note: null,
        );
      }

      final payload = Map<String, dynamic>.from(response as Map);

      final orderMap = payload['order'];
      final order = orderMap is Map<String, dynamic>
          ? Order.fromMap(orderMap)
          : (orderMap is Map
                ? Order.fromMap(Map<String, dynamic>.from(orderMap))
                : null);

      final itemsRaw = (payload['items'] as List?) ?? const [];
      final itemMaps = itemsRaw
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);

      // Camino rápido: si el RPC (fn_get_order_bundle ≥ 20260605_0008) ya
      // embebió modifiers/tax_lines en cada item, abrir/recargar el pedido es
      // 1 solo viaje — los parseamos del propio item sin consultas extra.
      final hasEmbeddedRelations =
          itemMaps.isNotEmpty && itemMaps.first.containsKey('tax_lines');

      List<OrderItem> items;
      if (hasEmbeddedRelations) {
        items = itemMaps
            .map((itemMap) {
              return OrderItem.fromMap(itemMap).copyWith(
                modifiers: _parseEmbeddedModifiers(itemMap['modifiers']),
                taxLines: _parseEmbeddedTaxLines(itemMap['tax_lines']),
              );
            })
            .toList(growable: false);
      } else {
        // Retrocompat: DB sin la migración del embed → traemos modifiers y
        // tax_lines en lotes (ver _loadTaxLinesByItem) para evitar HTTP 414.
        final baseItems = itemMaps
            .map(OrderItem.fromMap)
            .toList(growable: false);

        final itemIds = baseItems
            .map((item) => item.id)
            .where((id) => id.isNotEmpty)
            .toList(growable: false);

        Map<String, List<OrderItemModifier>> modifiersByItem = const {};
        Map<String, List<OrderItemTaxLine>> taxLinesByItem = const {};
        if (itemIds.isNotEmpty) {
          // modifiers y tax_lines en paralelo (independientes).
          final relations = await Future.wait([
            _loadModifiersByItem(itemIds),
            _loadTaxLinesByItem(itemIds),
          ]);
          modifiersByItem =
              relations[0] as Map<String, List<OrderItemModifier>>;
          taxLinesByItem = relations[1] as Map<String, List<OrderItemTaxLine>>;
        }

        items = baseItems
            .map(
              (item) => item.copyWith(
                modifiers:
                    modifiersByItem[item.id] ?? const <OrderItemModifier>[],
                taxLines: taxLinesByItem[item.id] ?? const <OrderItemTaxLine>[],
              ),
            )
            .toList(growable: false);
      }

      final checksRaw = (payload['checks'] as List?) ?? const [];
      final checks = checksRaw
          .map(
            (row) => OrderCheck.fromMap(Map<String, dynamic>.from(row as Map)),
          )
          .toList(growable: false);

      return (
        order: order,
        items: items,
        checks: checks,
        customerId: payload['customer_id']?.toString(),
        customerName: payload['customer_name']?.toString(),
        note: payload['note']?.toString(),
      );
    } on OrderOutOfScopeException {
      return (
        order: null,
        items: const <OrderItem>[],
        checks: const <OrderCheck>[],
        customerId: null,
        customerName: null,
        note: null,
      );
    } catch (e) {
      throw Exception('Error al obtener bundle de orden: $e');
    }
  }

  /// Obtener items de una orden
  /// Lectura completa para comprobantes: el límite del detalle de venta no
  /// puede truncar una factura con muchas rondas.
  Future<List<OrderItem>> getAllOrderItems(
    String orderId, {
    String? businessId,
  }) async {
    const size = 250;
    final items = await getOrderItems(
      orderId,
      limit: size,
      businessId: businessId,
    );
    if (items.length < size) return items;
    final result = [...items];
    for (var offset = size; ; offset += size) {
      final data = await _client
          .from('order_items')
          .select(_itemFieldsWithVersion)
          .eq('order_id', orderId)
          .order('created_at')
          .order('id')
          .range(offset, offset + size - 1);
      final page = data.map((r) => OrderItem.fromMap(r)).toList();
      final ids = page.map((i) => i.id).toList();
      final modifiers = await _loadModifiersByItem(ids);
      final taxes = await _loadTaxLinesByItem(ids);
      result.addAll(
        page.map(
          (i) => i.copyWith(
            modifiers: modifiers[i.id] ?? [],
            taxLines: taxes[i.id] ?? [],
          ),
        ),
      );
      if (page.length < size) return result;
    }
  }
  Future<List<OrderItem>> getOrderItems(
    String orderId, {
    bool includeModifiers = true,
    int limit = 500,
    bool onlyOpen = false,
    String? businessId,
  }) async {
    try {
      await _assertOrderInBusinessScope(orderId, businessId: businessId);

      // Defensa en profundidad: si onlyOpen, validar que la orden padre
      // esté abierta. Esto evita devolver items huérfanos de órdenes
      // void/paid cuyos items no se marcaron correctamente.
      if (onlyOpen) {
        final parent = await _client
            .from('orders')
            .select('closed_at,status_ext')
            .eq('id', orderId)
            .maybeSingle();
        final closedAt = parent?['closed_at'];
        final statusExt = parent?['status_ext']?.toString();
        if (closedAt != null ||
            statusExt == 'void' ||
            statusExt == 'paid' ||
            statusExt == 'cancelled') {
          return const <OrderItem>[];
        }
      }

      Future<List<dynamic>> fetch() {
        var query = _client
            .from('order_items')
            .select(_itemFieldsWithVersion)
            .eq('order_id', orderId);
        if (onlyOpen) query = query.not('status', 'in', '(paid,void)');
        return query
            .order('created_at', ascending: true)
            .order('id')
            .limit(limit);
      }

      List<dynamic> data;
      try {
        data = await fetch();
      } on PostgrestException catch (e) {
        if (_itemVersionColumnMissing ||
            e.code != '42703' ||
            !e.message.contains('version')) {
          rethrow;
        }
        _itemVersionColumnMissing = true;
        data = await fetch();
      }
      final items = data
          .map(
            (json) => OrderItem.fromMap(Map<String, dynamic>.from(json as Map)),
          )
          .toList(growable: false);

      if (!includeModifiers || items.isEmpty) {
        return items;
      }

      final itemIds = items
          .map((item) => item.id)
          .where((id) => id.isNotEmpty)
          .toList(growable: false);
      if (itemIds.isEmpty) {
        return items;
      }

      // modifiers y tax_lines son independientes → en paralelo (1 viaje en
      // vez de 2 en serie). Cada uno se trae en lotes (ver _loadTaxLinesByItem).
      final relations = await Future.wait([
        _loadModifiersByItem(itemIds),
        _loadTaxLinesByItem(itemIds),
      ]);
      final modifiersByItem =
          relations[0] as Map<String, List<OrderItemModifier>>;
      final taxLinesByItem =
          relations[1] as Map<String, List<OrderItemTaxLine>>;

      return items
          .map(
            (item) => item.copyWith(
              modifiers:
                  modifiersByItem[item.id] ?? const <OrderItemModifier>[],
              taxLines: taxLinesByItem[item.id] ?? const <OrderItemTaxLine>[],
            ),
          )
          .toList(growable: false);
    } on OrderOutOfScopeException {
      return const <OrderItem>[];
    } catch (e) {
      throw Exception('Error al obtener items: $e');
    }
  }
  /// Elimina todos los items de un check y recalcula totales en DB
  Future<void> clearCheck(String checkId) async {
    throw UnsupportedError(
      'clearCheck() fue deshabilitado porque podia marcar items como pagados '
      'sin registrar un pago. Usa processPayment() para cobrar o deleteCheck() '
      'para eliminar la subcuenta despues de mover sus items.',
    );
  }

  Future<void> _recomputeOrderTotals(String orderId) async {
    final rows = await _client
        .from('order_items')
        .select('subtotal, discounts, tax, total')
        .eq('order_id', orderId)
        .neq('status', 'void'); // Excluir items anulados

    double subtotal = 0, discounts = 0, tax = 0, total = 0;
    for (final r in rows) {
      subtotal += (r['subtotal'] ?? 0).toDouble();
      discounts += (r['discounts'] ?? 0).toDouble();
      tax += (r['tax'] ?? 0).toDouble();
      total += (r['total'] ?? 0).toDouble();
    }

    await _client
        .from('orders')
        .update({
          'subtotal': subtotal,
          'discounts': discounts,
          'tax': tax,
          'total': total,
        })
        .eq('id', orderId);
  }

  /// Asigna (o limpia) el cliente y el tipo de comprobante a una sub-cuenta
  /// antes de que se cobre. Al pagar el check, el RPC `fn_process_payment_v3`
  /// hereda estos valores automáticamente si el modal de pago no los pisa.
  ///
  /// Pasa `customerId=null` y `customerRnc=null` para limpiar el cliente.
  /// Pasa `requestedNcfType=null` para volver al default del business.
  Future<OrderCheck> setCheckCustomerAndNcf({
    required String checkId,
    String? customerId,
    String? customerRnc,
    String? requestedNcfType,
  }) async {
    try {
      final response = await _client.rpc(
        SalesQueries.rpcSetCheckCustomerAndNcf,
        params: {
          'p_check_id': checkId,
          'p_customer_id': customerId,
          'p_customer_rnc': customerRnc,
          'p_requested_ncf_type': requestedNcfType,
        },
      );

      if (response is Map) {
        return OrderCheck.fromMap(Map<String, dynamic>.from(response));
      }
      throw Exception('Respuesta inválida del RPC setCheckCustomerAndNcf');
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('CHECK_NOT_FOUND')) {
        throw Exception('La sub-cuenta ya no existe.');
      }
      if (msg.contains('CHECK_ALREADY_CLOSED')) {
        throw Exception(
          'La sub-cuenta ya fue cobrada y no se puede modificar.',
        );
      }
      throw Exception(
        'Error al asignar cliente/comprobante a la sub-cuenta: $e',
      );
    }
  }

  /// Eliminar un check y sus items
  /// Cierra (soft-close) un sub-check si quedó sin items abiertos. Pensado
  /// para llamarse tras un delete de item: si fue el último, el check se
  /// marca `is_closed=true` para que la UI no lo siga mostrando.
  /// No toca el principal (position=1). Idempotente: si el check ya está
  /// cerrado o no existe, devuelve false sin error.
  Future<bool> closeEmptyCheckIfApplicable(String checkId) async {
    try {
      final check = await _client
          .from('order_checks')
          .select('id, position, is_closed, order_id')
          .eq('id', checkId)
          .maybeSingle();
      if (check == null) return false;
      final position = (check['position'] as num?)?.toInt() ?? 0;
      if (position <= 1) return false;
      if (check['is_closed'] == true) return false;

      final remainingRaw = await _client
          .from('order_items')
          .select('id')
          .eq('check_id', checkId)
          .not('status', 'in', '("paid","void")');
      final remaining = (remainingRaw as List).length;
      if (remaining > 0) return false;

      await _client
          .from('order_checks')
          .update({
            'is_closed': true,
            // .toUtc() obligatorio: sin él se manda la hora LOCAL sin offset y
            // Postgres la interpreta como UTC — el check queda cerrado 4 h en
            // el pasado. Era el mismo bug que dejaba sesiones "cerradas antes
            // de abrirse" (ver migración 20260814_0001).
            'closed_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', checkId);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> deleteCheck(String checkId) async {
    final check = await _client
        .from('order_checks')
        .select('order_id')
        .eq('id', checkId)
        .maybeSingle();
    if (check == null || check['order_id'] == null) return;
    final orderId = check['order_id'] as String;

    // T04: los productos NO se borran aquí (el operador ya los movió). Uno
    // que haya entrado desde otro equipo queda sin subcuenta (FK ON DELETE
    // SET NULL, que sube su versión) en vez de perderse.
    try {
      await _client.from('order_checks').delete().eq('id', checkId);
    } catch (e) {
      // Misma negativa que en deleteItem: si la subcuenta ya tiene NCF, no se
      // vacía. Se anula.
      final blocked = closedOrderErrorMessage(e);
      throw Exception(blocked ?? 'Error al eliminar la cuenta: $e');
    }
    await _recomputeOrderTotals(orderId);
  }

  /// Obtener payload compacto de una mesa (usa RPC get_table_live)
  Future<Map<String, dynamic>?> getTableLive(
    String tableId, {
    String? businessId,
  }) async {
    try {
      await _assertTableInBusinessScope(tableId, businessId: businessId);

      final res = await _client.rpc(
        'get_table_live',
        params: {'p_table_id': tableId},
      );
      if (res == null) return null;
      return Map<String, dynamic>.from(res as Map);
    } catch (e) {
      throw Exception('Error al obtener tabla (get_table_live): $e');
    }
  }

  // ============================================================
  // 🍳 ENVIAR A COCINA
  // ============================================================

  /// Confirmar pedido y enviar a cocina
  /// Ventana de fusión de comandas: un envío a cocina que ocurre dentro de
  /// este lapso del envío anterior se agrega a la MISMA comanda del KDS en
  /// vez de abrir una tarjeta nueva. Cubre el caso real de "se me olvidó
  /// agregar algo" sin fusionar rondas genuinamente distintas.
  static const kitchenMergeWindow = Duration(minutes: 2);

  /// Envía la orden a cocina.
  ///
  /// Devuelve `merged: true` cuando los ítems se agregaron a la comanda
  /// anterior en lugar de abrir una ronda nueva; el llamador lo usa para
  /// encabezar el ticket impreso como "AGREGADO A COMANDA".
  ///
  /// [allowMerge] en false fuerza ronda nueva. Lo usa el replay offline: al
  /// sincronizar, varios envíos encolados se reproducen uno detrás de otro y
  /// caerían todos dentro de la ventana, colapsando en una sola comanda
  /// rondas que en el salón sí fueron distintas.
  Future<({bool merged, DateTime roundStamp})> sendToKitchen(
    String orderId, {
    bool allowMerge = true,
  }) async {
    try {
      await _client.rpc(
        SalesQueries.rpcConfirmOrderToKitchen,
        params: {'p_order_id': orderId},
      );
      // Marca la RONDA: estampa `kitchen_sent_at` a los ítems recién enviados
      // (los que aún no lo tienen). Los de rondas previas conservan su marca,
      // así el KDS separa cada comanda en su propia tarjeta. Best-effort: un
      // fallo aquí no debe tumbar el envío a cocina.
      final round = allowMerge
          ? await _resolveRoundStamp(orderId)
          : (merged: false, stamp: DateTime.now().toUtc());
      try {
        await _client
            .from('order_items')
            .update({'kitchen_sent_at': round.stamp.toIso8601String()})
            .eq('order_id', orderId)
            .isFilter('kitchen_sent_at', null)
            .inFilter('status', ['pending', 'preparing']);
      } catch (_) {
        // La marca de ronda es best-effort; el pedido ya entró a cocina.
      }
      // Reabrir la cocina de la orden. Si una ronda anterior de esta MISMA orden
      // ya fue despachada ("Marcar todo listo" sella `orders.kitchen_done_at`),
      // la orden salió de `kds_open_orders` — que filtra `kitchen_done_at IS
      // NULL` — y esta ronda NUEVA no aparecería en el KDS en modo "esperar al
      // cocinero". Al enviar ítems nuevos hay trabajo de cocina otra vez, así
      // que limpiamos el sello. Solo escribe si estaba sellada (evita writes y
      // eventos realtime redundantes). Best-effort: no debe tumbar el envío.
      try {
        await _client
            .from('orders')
            .update({'kitchen_done_at': null})
            .eq('id', orderId)
            .not('kitchen_done_at', 'is', null);
      } catch (_) {
        // El des-sellado es best-effort; el pedido ya entró a cocina.
      }
      return (merged: round.merged, roundStamp: round.stamp);
    } catch (e) {
      throw Exception('Error al enviar a cocina: $e');
    }
  }

  /// «Enviar Pedido» de una ronda capturada: confirma a cocina SOLO
  /// [itemIds] (20261010_0002) y sella la ronda como [sendToKitchen], con su
  /// ventana de fusión. [sendToKitchen] confirma todos los borradores de la
  /// orden: una línea agregada mientras se imprimía quedaba «enviada» sin
  /// haber salido en el papel. No envuelve el error: sin la migración
  /// (PGRST202) quien llama falla con un aviso visible; nunca se confirma la
  /// orden entera en su lugar.
  Future<({bool merged, DateTime roundStamp})> confirmRoundToKitchen(
    String orderId,
    List<String> itemIds,
  ) async {
    await _client.rpc(
      SalesQueries.rpcConfirmOrderItemsToKitchen,
      params: {'p_order_id': orderId, 'p_item_ids': itemIds},
    );
    final round = await _resolveRoundStamp(orderId);
    try {
      await _client
          .from('order_items')
          .update({'kitchen_sent_at': round.stamp.toIso8601String()})
          .eq('order_id', orderId)
          .inFilter('id', itemIds)
          .isFilter('kitchen_sent_at', null)
          .inFilter('status', ['pending', 'preparing']);
    } catch (_) {
      // La marca de ronda es best-effort; las líneas ya entraron a cocina.
    }
    try {
      await _client
          .from('orders')
          .update({'kitchen_done_at': null})
          .eq('id', orderId)
          .not('kitchen_done_at', 'is', null);
    } catch (_) {
      // El des-sellado es best-effort (ver sendToKitchen).
    }
    return (merged: round.merged, roundStamp: round.stamp);
  }

  /// Replay de una comanda ya impresa por la LAN: confirma a cocina SOLO
  /// [itemIds] (20261010_0002). [sendToKitchen] confirma todos los borradores
  /// de la orden, también los agregados después de imprimir, que quedaban
  /// «enviados» sin haber salido. Ronda nueva (el replay nunca fusiona) y
  /// reabre la cocina como [sendToKitchen]. No envuelve el error: el replay
  /// distingue PGRST202 (sin la migración) para volver a [sendToKitchen].
  Future<void> confirmItemsToKitchen(
    String orderId,
    List<String> itemIds,
  ) async {
    await _client.rpc(
      SalesQueries.rpcConfirmOrderItemsToKitchen,
      params: {'p_order_id': orderId, 'p_item_ids': itemIds},
    );
    try {
      await _client
          .from('order_items')
          .update({'kitchen_sent_at': DateTime.now().toUtc().toIso8601String()})
          .eq('order_id', orderId)
          .inFilter('id', itemIds)
          .isFilter('kitchen_sent_at', null)
          .inFilter('status', ['pending', 'preparing']);
    } catch (_) {
      // La marca de ronda es best-effort; las líneas ya entraron a cocina.
    }
    try {
      await _client
          .from('orders')
          .update({'kitchen_done_at': null})
          .eq('id', orderId)
          .not('kitchen_done_at', 'is', null);
    } catch (_) {
      // El des-sellado es best-effort (ver sendToKitchen).
    }
  }

  /// Decide la marca de ronda (`kitchen_sent_at`) que llevará este envío.
  ///
  /// El KDS agrupa cada tarjeta por `orderId::kitchen_sent_at::area`
  /// (`kitchenCardKey`), así que reutilizar la marca del envío anterior hace
  /// que los ítems nuevos caigan solos en la MISMA comanda del tablero, sin
  /// tocar el KDS. Se reutiliza cuando se cumplen las DOS condiciones:
  ///
  ///   1. el envío anterior ocurrió hace menos de [kitchenMergeWindow], y
  ///   2. la cocina todavía no lo tocó (todos sus ítems siguen en 'pending').
  ///
  /// La segunda es la importante: si el cocinero ya bumpeó algo de esa ronda,
  /// se abre tarjeta nueva. Meter platos en una comanda a medio preparar haría
  /// que "Marcar todo listo" despache algo que nadie cocinó.
  ///
  /// Best-effort: ante cualquier fallo devuelve ronda nueva (el comportamiento
  /// histórico), nunca bloquea el envío a cocina.
  Future<({bool merged, DateTime stamp})> _resolveRoundStamp(
    String orderId,
  ) async {
    final now = DateTime.now().toUtc();
    try {
      final data = await _client
          .from('order_items')
          .select('kitchen_sent_at, status')
          .eq('order_id', orderId)
          .not('kitchen_sent_at', 'is', null)
          .neq('status', 'void')
          .order('kitchen_sent_at', ascending: false)
          .limit(200);
      final rows = List<Map<String, dynamic>>.from(data);

      DateTime? parseStamp(Map<String, dynamic> row) {
        final raw = row['kitchen_sent_at'];
        if (raw == null) return null;
        return DateTime.tryParse(raw.toString())?.toUtc();
      }

      DateTime? last;
      for (final row in rows) {
        final ts = parseStamp(row);
        if (ts == null) continue;
        if (last == null || ts.isAfter(last)) last = ts;
      }
      if (last == null) return (merged: false, stamp: now);

      // Diferencia en valor absoluto: entre dispositivos hay desfase de reloj
      // y una marca ligeramente en el futuro no debe romper la fusión.
      final anchor = last;
      if (now.difference(anchor).abs() > kitchenMergeWindow) {
        return (merged: false, stamp: now);
      }

      final kitchenStarted = rows.any((row) {
        final ts = parseStamp(row);
        if (ts == null || !ts.isAtSameMomentAs(anchor)) return false;
        return (row['status'] as String?) != 'pending';
      });
      if (kitchenStarted) return (merged: false, stamp: now);

      return (merged: true, stamp: anchor);
    } catch (_) {
      return (merged: false, stamp: now);
    }
  }

  /// Feature flag: cuando `kitchen_enabled = false`, los items se
  /// marcan directamente como `ready` sin pasar por cocina. Para
  /// negocios sin preparación (tiendas, kioskos, minimarkets).
  ///
  /// Update directo sobre order_items (sin RPC) porque
  /// fn_confirm_order_to_kitchen genera print_jobs de comanda, que es
  /// justo lo que queremos saltarnos.
  Future<void> markOrderItemsAsReady(String orderId) async {
    try {
      await _client
          .from('order_items')
          .update({'status': 'ready'})
          .eq('order_id', orderId)
          .inFilter('status', ['draft', 'pending', 'preparing']);
      // El status_ext de la orden lo gestionan otros triggers según el
      // flujo de pago — no lo tocamos acá para no romper checks/payments.
    } catch (e) {
      throw Exception('Error al marcar items como listos: $e');
    }
  }

  /// Fee de delivery propio (cargo EXENTO): fija `orders.delivery_fee` y
  /// recomputa el total en backend. El monto se redondea/clampa a ≥0 dentro
  /// del RPC. Ver docs/PRD_DELIVERY_FEE_PROPIO.md.
  Future<OrderEditResult> setDeliveryFee({
    required String orderId,
    required double amount,
    required OrderEdit edit,
  }) => _editOrThrow(
    'Error al fijar el fee de delivery',
    () => applyOrderEdit(
      edit: edit,
      kind: 'delivery_fee',
      args: {'amount': amount},
    ),
  );

  /// Impuestos que no se cobran en esta cuenta (fn_set_order_excluded_taxes).
  Future<OrderEditResult> setExcludedTaxes({
    required List<String> taxIds,
    String? employeeId,
    required OrderEdit edit,
  }) => _editOrThrow(
    'Error al quitar impuestos de la orden',
    () => applyOrderEdit(
      edit: edit,
      kind: 'excluded_taxes',
      args: {'tax_ids': taxIds, 'employee_id': employeeId},
    ),
  );

  // ============================================================
  // 📄 DIVISIÓN DE CUENTA (SPLIT BILL)
  // ============================================================

  /// Crear división de cuenta
  Future<List<OrderCheck>> createSplitBill({
    required String orderId,
    required int numberOfChecks,
  }) async {
    try {
      final response = await _client.rpc(
        SalesQueries.rpcCreateSplitBill,
        params: {'p_order_id': orderId, 'p_number_of_checks': numberOfChecks},
      );

      final checksData = response as List;
      return checksData.map((json) => OrderCheck.fromMap(json)).toList();
    } catch (e) {
      throw Exception('Error al crear división de cuenta: $e');
    }
  }

  /// Dividir cada item de la orden en partes iguales entre subcuentas.
  Future<List<OrderCheck>> splitItemsEqually({
    required String orderId,
    required int people,
  }) async {
    try {
      final response = await _client.rpc(
        SalesQueries.rpcSplitItemsEqually,
        params: {'p_order_id': orderId, 'p_people': people},
      );

      final checksData = response as List;
      return checksData.map((json) => OrderCheck.fromMap(json)).toList();
    } catch (e) {
      throw Exception('Error al dividir items en partes iguales: $e');
    }
  }

  /// Split bill UX (2026-05-13) — divide cada item abierto con qty>1 en
  /// N filas de qty=1 para que cada unidad sea transferible
  /// independientemente en el modal de dividir cuenta. Idempotente: si
  /// todos los items ya están en qty=1, es no-op.
  ///
  /// Retorna el número de filas nuevas creadas (qty original - 1 por
  /// cada item explotado). 0 = no había nada que dividir.
  Future<int> explodeItemsToUnits({required String orderId}) async {
    try {
      final response = await _client.rpc(
        SalesQueries.rpcExplodeItemsToUnits,
        params: {'p_order_id': orderId},
      );
      if (response == null) return 0;
      return (response as num).toInt();
    } catch (e) {
      throw Exception('Error al dividir productos en unidades: $e');
    }
  }

  /// Mover item a otro check
  Future<OrderEditResult> moveItemToCheck({
    required String itemId,
    required int checkPosition,
    required OrderEdit edit,
  }) => _editOrThrow(
    'Error al mover item a check',
    () => applyOrderEdit(
      edit: edit,
      kind: 'move',
      targetId: itemId,
      args: {'check_position': checkPosition},
    ),
  );

  /// Mover múltiples items a un mismo check (batch). Cada línea viaja con la
  /// versión que se veía: si una cambió, no se mueve ninguna.
  Future<OrderEditResult?> moveItemsToCheckBatch({
    required List<OrderItem> items,
    required int checkPosition,
    required String orderId,
    String? opId,
    bool force = false,
  }) async {
    if (items.isEmpty) return null;
    return _editOrThrow(
      'Error al mover items en lote',
      () => applyOrderEdit(
        edit: OrderEdit(
          orderId: orderId,
          opId: opId,
          base: force ? OrderEditBase.forced : OrderEditBase.ofVersion(null),
        ),
        kind: 'move_batch',
        args: {
          'check_position': checkPosition,
          'items': [
            for (final item in items) {'id': item.id, 'version': item.version},
          ],
        },
      ),
    );
  }

  /// Consolida líneas duplicadas dentro de una subcuenta. T04: lo calcula
  /// el servidor con lo vigente y bajo el candado de la orden
  /// (fn_apply_order_edit 'consolidate_check'); nunca con lo que leyó este
  /// equipo, que pisaría un cambio de otro.
  Future<OrderEditResult> consolidateCheckItems({
    required String orderId,
    required String checkId,
    bool normalizeQtyToInteger = false,
  }) {
    return _editOrThrow(
      'Error al consolidar items de subcuenta',
      () => applyOrderEdit(
        edit: OrderEdit(orderId: orderId, base: OrderEditBase.ofVersion(null)),
        kind: 'consolidate_check',
        targetId: checkId,
        args: {'normalize_qty_to_integer': normalizeQtyToInteger},
      ),
    );
  }

  Future<OrderEditResult> assignCustomerToCheck({
    required String checkId,
    required String customerId,
    required String customerName,
    String? customerRnc,
    required OrderEdit edit,
  }) {
    // El RNC se persiste por sub-cuenta (order_checks.customer_rnc) para
    // que `fn_process_payment_v3` lo herede al cobrar el check (param > check
    // > default). Necesario para emitir Crédito Fiscal por sub-cuenta.
    final rnc = customerRnc?.trim();
    return _editOrThrow(
      'Error al asignar cliente al check',
      () => applyOrderEdit(
        edit: edit,
        kind: 'check_customer',
        targetId: checkId,
        args: {
          'customer_id': customerId,
          'customer_name': customerName.trim(),
          'customer_rnc': (rnc == null || rnc.isEmpty) ? null : rnc,
        },
      ),
    );
  }

  Future<OrderEditResult> clearCustomerFromCheck(
    String checkId, {
    required OrderEdit edit,
  }) => _editOrThrow(
    'Error al limpiar cliente del check',
    () => applyOrderEdit(
      edit: edit,
      kind: 'check_customer',
      targetId: checkId,
      args: {'customer_id': null, 'customer_name': null, 'customer_rnc': null},
    ),
  );

  /// Asigna el tipo de comprobante a una sub-cuenta. Al pagar ese check, el
  /// RPC `fn_process_payment_v3` hereda este tipo si el modal de pago no lo
  /// sobrescribe. Pasa `ncfType=null` para volver al default del business.
  Future<void> setCheckNcfType({
    required String checkId,
    String? ncfType,
  }) async {
    try {
      final normalized = ncfType?.trim();
      await _client
          .from('order_checks')
          .update({
            'requested_ncf_type': (normalized == null || normalized.isEmpty)
                ? null
                : normalized,
          })
          .eq('id', checkId);
    } catch (e) {
      throw Exception('Error al asignar comprobante al check: $e');
    }
  }

  /// Obtener checks de una orden
  Future<List<OrderCheck>> getOrderChecks(
    String orderId, {
    String? businessId,
  }) async {
    try {
      await _assertOrderInBusinessScope(orderId, businessId: businessId);

      final data = await _client
          .from('order_checks')
          .select()
          .eq('order_id', orderId)
          .order('position', ascending: true);

      return data.map((json) => OrderCheck.fromMap(json)).toList();
    } on OrderOutOfScopeException {
      return const <OrderCheck>[];
    } catch (e) {
      throw Exception('Error al obtener checks: $e');
    }
  }

  // ============================================================
  // 💰 PAGOS
  // ============================================================

  /// Procesar pago
  ///
  /// `splitSequence` distingue múltiples pagos del mismo método sobre la
  /// misma orden/check (caso: tres clientes pagando 1000 cash cada uno
  /// en una orden compartida). El cliente Dart pasa 0, 1, 2... para cada
  /// split intencional; double-tap reusa el mismo valor y choca contra el
  /// unique index. Default 0 mantiene compatibilidad con callers que sólo
  /// emiten un payment por (order, check, method).
  Future<Payment> processPayment({
    required String orderId,
    String? checkId,
    required String paymentMethodId,
    required double amount,
    String? reference,
    String? customerId,
    String? customerRnc,
    String? fiscalType,
    String? cashierSessionId,
    double changeAmount = 0,
    bool closeOrder = true,
    bool closeCheck = true,
    int splitSequence = 0,
    DateTime? paidAt,
    // F4: NCF asignado offline (Hub/allocator). Solo se envía al sincronizar
    // un cobro offline que YA imprimió su comprobante; el RPC lo usa en vez de
    // generar uno nuevo. Null en cobros online (el servidor emite el NCF).
    String? offlineNcf,
  }) async {
    try {
      final response = await PerformanceDiagnostics.instance.measure(
        'rpc_pago',
        () => _client
            .rpc(
              SalesQueries.rpcProcessPayment,
              params: {
                'p_order_id': orderId,
                'p_check_id': checkId,
                'p_payment_method_id': paymentMethodId,
                'p_amount': amount,
                'p_reference': reference,
                'p_change_amount': changeAmount,
                'p_customer_id': customerId,
                'p_customer_rnc': customerRnc,
                'p_requested_ncf_type': fiscalType,
                'p_cashier_session_id': cashierSessionId,
                'p_close_order': closeOrder,
                'p_close_check': closeCheck,
                'p_split_sequence': splitSequence,
                if (paidAt != null)
                  'p_paid_at': paidAt.toUtc().toIso8601String(),
                if (offlineNcf != null && offlineNcf.isNotEmpty)
                  'p_offline_ncf': offlineNcf,
              },
            )
            .timeout(const Duration(seconds: 12)),
      );

      return await validatePaymentResponse(
        _client,
        Map<String, dynamic>.from(response as Map),
        orderId: orderId,
        checkId: checkId,
        paymentMethodId: paymentMethodId,
        splitSequence: splitSequence,
        amount: amount,
        changeAmount: changeAmount,
      );
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('CASH_SESSION_REQUIRED') ||
          msg.contains('CASH_SESSION_NOT_OPEN')) {
        rethrow;
      }
      if (msg.contains('Demasiadas colisiones de NCF')) {
        final recovered = await _recoverCompletedPaymentAfterNcfCollision(
          orderId: orderId,
          checkId: checkId,
          amount: amount,
          changeAmount: changeAmount,
          cashierSessionId: cashierSessionId,
          paymentMethodId: paymentMethodId,
          splitSequence: splitSequence,
        );
        if (recovered != null) {
          return recovered;
        }
      }

      // Recovery cuando el unique index bloquea un retry idempotente del
      // mismo split: (order_id, check_id, payment_method_id, split_sequence)
      // ya existe completed. El RPC propaga 23505 — el cliente lo recupera
      // devolviendo la fila previa, como si el insert hubiera sido exitoso.
      // Caso típico: doble-tap del usuario o retry por timeout de red.
      final isUniqueViolation =
          (e is PostgrestException && e.code == '23505') ||
          msg.contains('23505') ||
          msg.contains('payments_unique_completed_per_check_method');
      if (isUniqueViolation) {
        final recovered = await _recoverCompletedPaymentAfterUniqueViolation(
          orderId: orderId,
          checkId: checkId,
          splitSequence: splitSequence,
          amount: amount,
          paymentMethodId: paymentMethodId,
          changeAmount: changeAmount,
        );
        if (recovered != null) {
          return recovered;
        }
      }

      throw Exception(
        'No se pudo confirmar el resultado del pago. No asumas que fue cancelado: $e',
      );
    }
  }

  /// T07 (20261010_0008): sube un cobro hecho sin red con su identidad
  /// ([paymentKey], estable por acción de la cola), su caja y su fecha. Si no
  /// puede aplicarse tal cual (caja cerrada, cuenta cambiada o ya cobrada…)
  /// el servidor no lo aplica ni lo mueve: devuelve `needs_resolution` y lo
  /// guarda para decidir. Null si el servidor no tiene la migración (el
  /// llamador sube con [processPayment], como antes).
  Future<OfflinePaymentReplayResult?> replayOfflinePayment({
    required String paymentKey,
    required String orderId,
    String? checkId,
    required String paymentMethodId,
    required double amount,
    String? reference,
    String? customerId,
    String? customerRnc,
    String? fiscalType,
    String? cashierSessionId,
    double changeAmount = 0,
    bool closeOrder = true,
    bool closeCheck = true,
    int splitSequence = 0,
    DateTime? paidAt,
    String? offlineNcf,
    String? deviceId,
    String? originSessionRef,
  }) async {
    final Object? response;
    try {
      response = await _client
          .rpc(
            SalesQueries.rpcReplayOfflinePayment,
            params: {
              'p_payment_key': paymentKey,
              'p_order_id': orderId,
              'p_check_id': checkId,
              'p_payment_method_id': paymentMethodId,
              'p_amount': amount,
              'p_reference': reference,
              'p_customer_id': customerId,
              'p_customer_rnc': customerRnc,
              'p_cashier_session_id': cashierSessionId,
              'p_change_amount': changeAmount,
              'p_requested_ncf_type': fiscalType,
              'p_close_order': closeOrder,
              'p_split_sequence': splitSequence,
              'p_close_check': closeCheck,
              'p_paid_at': paidAt?.toUtc().toIso8601String(),
              'p_offline_ncf': (offlineNcf != null && offlineNcf.isNotEmpty)
                  ? offlineNcf
                  : null,
              'p_device_id': deviceId,
              'p_origin_session_ref': originSessionRef,
            },
          )
          .timeout(const Duration(seconds: 20));
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST202') return null;
      rethrow;
    }
    if (response is! Map) {
      throw StateError('Respuesta inesperada de fn_replay_offline_payment');
    }
    return OfflinePaymentReplayResult.fromMap(
      Map<String, dynamic>.from(response),
    );
  }

  /// La decisión explícita sobre un cobro «por resolver» (dueño, admin o
  /// gerente; el servidor lo valida).
  Future<OfflinePaymentReplayResult> resolveOfflinePayment({
    required String paymentKey,
    required String resolution,
    String? targetSessionId,
    String? note,
  }) async {
    final response = await _client.rpc(
      SalesQueries.rpcResolveOfflinePayment,
      params: {
        'p_payment_key': paymentKey,
        'p_resolution': resolution,
        'p_target_session_id': targetSessionId,
        'p_note': note,
      },
    );
    if (response is! Map) {
      throw StateError('Respuesta inesperada de fn_resolve_offline_payment');
    }
    return OfflinePaymentReplayResult.fromMap(
      Map<String, dynamic>.from(response),
    );
  }

  Future<Payment?> _recoverCompletedPaymentAfterUniqueViolation({
    required String orderId,
    String? checkId,
    required int splitSequence,
    required double amount,
    required String paymentMethodId,
    required double changeAmount,
  }) async {
    return recoverCompletedPayment(
      _client,
      orderId: orderId,
      checkId: checkId,
      paymentMethodId: paymentMethodId,
      splitSequence: splitSequence,
      amount: amount,
      changeAmount: changeAmount,
    );
  }

  Future<Payment?> _recoverCompletedPaymentAfterNcfCollision({
    required String orderId,
    String? checkId,
    required double amount,
    required double changeAmount,
    String? cashierSessionId,
    required String paymentMethodId,
    required int splitSequence,
  }) async {
    final payment = await recoverCompletedPayment(
      _client,
      orderId: orderId,
      checkId: checkId,
      paymentMethodId: paymentMethodId,
      splitSequence: splitSequence,
      amount: amount,
      changeAmount: changeAmount,
    );
    if (cashierSessionId != null &&
        cashierSessionId.isNotEmpty &&
        payment?.sessionId != cashierSessionId) {
      return null;
    }
    return payment;
  }

  /// Obtener pagos de una orden
  Future<List<Payment>> getOrderPayments(String orderId) async {
    try {
      final data = await _client
          .from('payments')
          .select()
          .eq('order_id', orderId)
          .order('created_at', ascending: false);

      return data.map((json) => Payment.fromMap(json)).toList();
    } catch (e) {
      throw Exception('Error al obtener pagos: $e');
    }
  }

  // ============================================================
  // 🧾 FACTURACIÓN FISCAL
  // ============================================================

  /// Crear documento fiscal
  Future<FiscalDocument> createFiscalDocument({
    required String orderId,
    required String paymentId,
    String? customerId,
    String? customerRnc,
  }) async {
    try {
      final response = await _client.rpc(
        SalesQueries.rpcCreateFiscalDocument,
        params: {
          'p_order_id': orderId,
          'p_payment_id': paymentId,
          'p_customer_id': customerId,
          'p_customer_rnc': customerRnc,
        },
      );

      return FiscalDocument.fromMap(response);
    } catch (e) {
      throw Exception('Error al crear documento fiscal: $e');
    }
  }

  /// Obtener documento fiscal de una orden
  Future<FiscalDocument?> getOrderFiscalDocument(String orderId) async {
    try {
      final data = await _client
          .from('fiscal_documents')
          .select()
          .eq('order_id', orderId)
          .maybeSingle();

      if (data == null) return null;

      return FiscalDocument.fromMap(data);
    } catch (e) {
      throw Exception('Error al obtener documento fiscal: $e');
    }
  }

  // ── Notas de venta (documento NO fiscal) ──────────────────────────────────

  /// Documento activo del contenedor realmente cobrado, sin mezclar los
  /// comprobantes de otras subcuentas de la misma orden.
  Future<FiscalDocument?> getFiscalDocumentForScope({
    required String orderId,
    String? checkId,
  }) async {
    var query = _client
        .from('fiscal_documents')
        .select()
        .eq('order_id', orderId)
        .eq('status', 'active');
    query = checkId != null && checkId.isNotEmpty
        ? query.eq('check_id', checkId)
        : query.isFilter('check_id', null);
    final row = await query
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    return row == null ? null : FiscalDocument.fromMap(row);
  }

  /// Marca el contenedor que se va a cobrar para que, al cerrarse, emita una
  /// NOTA DE VENTA en vez de un comprobante con NCF.
  ///
  /// Tiene que correr ANTES del cobro: el documento lo emite el trigger de
  /// cierre dentro del mismo RPC de pago, así que una marca puesta después
  /// llega tarde y la venta ya quemó un NCF.
  ///
  /// [checkId] no nulo marca solo esa sub-cuenta (split bill); nulo marca la
  /// orden completa.
  Future<void> markAsSalesNote({
    required String orderId,
    String? checkId,
    bool value = true,
  }) async {
    if (checkId != null && checkId.isNotEmpty) {
      await _client
          .from('order_checks')
          .update({'is_sales_note': value})
          .eq('id', checkId);
      return;
    }
    await _client
        .from('orders')
        .update({'is_sales_note': value})
        .eq('id', orderId);
  }

  /// Nota de venta emitida para un contenedor cobrado. `checkId` nulo busca la
  /// de la orden completa.
  ///
  /// Devuelve null si el servidor todavía no tiene la migración de notas de
  /// venta: el cobro ya está grabado y el ticket sale igual, solo que sin
  /// número de nota. Preferimos eso a tumbar el flujo de cobro.
  Future<SalesNote?> getSalesNote({
    required String orderId,
    String? checkId,
  }) async {
    try {
      var query = _client
          .from('sales_notes')
          .select()
          .eq('order_id', orderId)
          .eq('status', 'active');

      query = (checkId != null && checkId.isNotEmpty)
          ? query.eq('check_id', checkId)
          : query.isFilter('check_id', null);

      final data = await query
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();

      if (data == null) return null;
      return SalesNote.fromMap(data);
    } catch (e) {
      debugPrint('No se pudo leer la nota de venta: $e');
      return null;
    }
  }

  /// Obtener documento fiscal por ID
  Future<FiscalDocument?> getFiscalDocumentById(String documentId) async {
    try {
      final data = await _client
          .from('fiscal_documents')
          .select()
          .eq('id', documentId)
          .maybeSingle();

      if (data == null) return null;

      return FiscalDocument.fromMap(data);
    } catch (e) {
      throw Exception('Error al obtener documento fiscal por ID: $e');
    }
  }

  /// Anular orden y sus pagos.
  ///
  /// Devuelve los `fiscal_documents` que quedaron cancelados. Son los que
  /// necesitan nota de crédito: un NCF que ya se declaró no se borra, se
  /// reversa con una nota ([issueCreditNote]).
  Future<List<String>> annulOrder({
    required String orderId,
    String? reason,
  }) async {
    try {
      // 0. Venta a crédito con abonos: bloquear ANTES de cerrar/anular nada
      // (el trigger de payments también bloquearía, pero ya con la orden
      // cerrada como void — estado a medias).
      await _ensureCreditAnnullable(orderId);

      // 1. Obtener pagos asociados
      final paymentsRaw = await _client
          .from('payments')
          .select('id, amount, session_id')
          .eq('order_id', orderId)
          .eq('status', 'completed');

      final payments = List<Map<String, dynamic>>.from(paymentsRaw);

      // 2. Anular la orden mediante RPC (cierra orden, sesión y libera mesa)
      await _client.rpc(
        SalesQueries.rpcCloseOrderAndTable,
        params: {'p_order_id': orderId, 'p_status': 'void'},
      );

      // 3. Anular todos los ítems de la orden (Reportes usan 'void')
      await _client
          .from('order_items')
          .update({'status': 'void'})
          .eq('order_id', orderId);

      // 4. Anular pagos asociados
      // Nota: La restricción de tabla 'payments_status_check' no acepta 'void',
      // pero sí acepta 'cancelled'.
      if (payments.isNotEmpty) {
        final paymentIds = payments.map((p) => p['id'] as String).toList();
        await _client
            .from('payments')
            .update({'status': 'cancelled'})
            .inFilter('id', paymentIds);
      }

      // 5. Anular Documentos Fiscales asociados
      final cancelledDocs = await _client
          .from('fiscal_documents')
          .update(_cancelledFiscalDocumentPatch(reason))
          .eq('order_id', orderId)
          .select('id');

      // 5b. Anular la NOTA DE VENTA si la venta se documentó con una. No es un
      // comprobante fiscal: no necesita nota de crédito, solo dejar de estar
      // activa para que el historial la muestre anulada y el índice de "una
      // nota activa por contenedor" quede libre. Best-effort: un servidor sin
      // la migración de notas no puede tumbar una anulación.
      try {
        await _client
            .from('sales_notes')
            .update({
              'status': 'cancelled',
              'cancelled_at': DateTime.now().toUtc().toIso8601String(),
              if (reason != null && reason.trim().isNotEmpty)
                'cancellation_reason': reason.trim(),
            })
            .eq('order_id', orderId)
            .eq('status', 'active');
      } catch (e) {
        debugPrint('No se pudo anular la nota de venta de $orderId: $e');
      }

      // 6. Cancelar CxC abiertas de la orden (venta a crédito anulada).
      await _cancelOpenCreditsForOrder(orderId);

      return _idsOf(cancelledDocs);
    } catch (e) {
      throw Exception('Error al anular orden: $e');
    }
  }

  /// Ids de un resultado de PostgREST con `.select('id')`.
  List<String> _idsOf(dynamic rows) {
    if (rows is! List) return const [];
    return rows
        .map((r) => (r as Map<String, dynamic>)['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
  }

  /// Emite la NOTA DE CRÉDITO que reversa un comprobante fiscal anulado.
  ///
  /// Un e-CF que la DGII ya aceptó no se puede "descancelar": la única forma
  /// de reversarlo es una nota de crédito (E34) que lo referencie. Sin ella
  /// el negocio termina pagando el ITBIS de una venta que devolvió.
  ///
  /// NO lanza: si falta la secuencia E34/B04 o falla la red, devuelve el
  /// estado correspondiente y la anulación —que ya ocurrió— se queda como
  /// está. El caso queda visible en `v_fiscal_docs_pending_credit_note` y se
  /// reintenta desde el historial.
  Future<CreditNoteResult> issueCreditNote({
    required String fiscalDocumentId,
    String? reason,
  }) async {
    try {
      final res = await _client.rpc(
        'fn_issue_credit_note',
        params: {
          'p_fiscal_document_id': fiscalDocumentId,
          'p_reason': reason,
          'p_modification_code': 1,
        },
      );
      if (res is Map) {
        return CreditNoteResult.fromRpc(
          fiscalDocumentId,
          Map<String, dynamic>.from(res),
        );
      }
      return CreditNoteResult.failure(
        fiscalDocumentId,
        'Respuesta inesperada del servidor',
      );
    } catch (e) {
      return CreditNoteResult.failure(fiscalDocumentId, e);
    }
  }

  /// Comprobantes anulados que todavía NO tienen su nota de crédito.
  /// Casi siempre es que falta cargar la secuencia E34/B04 del negocio.
  Future<List<Map<String, dynamic>>> getDocsPendingCreditNote(
    String businessId, {
    int limit = 50,
  }) async {
    final rows = await _client
        .from('v_fiscal_docs_pending_credit_note')
        .select()
        .eq('business_id', businessId)
        .order('cancelled_at', ascending: false)
        .limit(limit);
    return List<Map<String, dynamic>>.from(rows as List);
  }

  // ============================================================
  // 🔐 CERRAR ORDEN
  // ============================================================

  /// Cerrar orden y sesión
  Future<void> closeOrder({
    required String orderId,
    required String status, // 'paid', 'cancelled', 'void'
  }) async {
    try {
      await _client.rpc(
        SalesQueries.rpcCloseOrderAndTable,
        params: {'p_order_id': orderId, 'p_status': status},
      );
    } catch (e) {
      throw Exception('Error al cerrar orden: $e');
    }
  }

  /// Anulación AUTOMÁTICA (replay de `void_order`, cierre de una pestaña
  /// retail): el servidor anula solo si la orden sigue abierta y sin cobros,
  /// con la fila bloqueada, así que un cobro de otra caja nunca queda anulado
  /// (20261009_0007). Devuelve 'voided', 'already_closed', 'has_payments' o
  /// 'not_found'. Sin la migración el error es PostgrestException PGRST202 y el
  /// caller recurre al camino anterior. annulOrder no la usa.
  Future<String> voidOrderIfUnpaid(String orderId) async {
    final result = await _client.rpc(
      SalesQueries.rpcVoidOrderIfUnpaid,
      params: {'p_order_id': orderId},
    );
    return result?.toString() ?? 'not_found';
  }

  /// Agrega una línea de auditoría de anulación a la nota de la sesión de
  /// [orderId]. Resuelve la sesión de la orden, lee la nota actual y le
  /// appendea `[ANULACION][stamp] actor: razón` (mismo formato que el flujo
  /// online en SalesViewModel.appendVoidAuditNote).
  ///
  /// Lo usa el replay offline de `void_order` para persistir la razón que
  /// en v1 solo quedaba en logs (gap F2.3). Best-effort: el caller no debe
  /// romper la anulación si esto falla.
  Future<void> appendVoidAuditNote({
    required String orderId,
    required String reason,
    String? userName,
    DateTime? voidedAt,
    String? businessId,
  }) async {
    final trimmed = reason.trim();
    if (trimmed.isEmpty) return;

    final orderRow = await _client
        .from('orders')
        .select('session_id')
        .eq('id', orderId)
        .maybeSingle();
    final sessionId = orderRow?['session_id']?.toString();
    if (sessionId == null || sessionId.isEmpty) return;

    final stamp = (voidedAt ?? DateTime.now()).toLocal().toIso8601String();
    final actor = (userName == null || userName.trim().isEmpty)
        ? 'Usuario'
        : userName.trim();
    await appendSessionNoteLine(
      sessionId: sessionId,
      line: '[ANULACION][$stamp] $actor: $trimmed',
      businessId: businessId,
    );
  }

  /// Agrega una línea de auditoría a la nota de la sesión (anulación, acceso
  /// a mesa ajena). T04: en una sola sentencia del servidor
  /// (fn_append_session_note); la nota nunca se reescribe entera, así dos
  /// líneas a la vez no se pierden una a la otra. No es una edición del
  /// operador: no pasa por fn_apply_order_edit (la cuenta puede estar
  /// cerrada).
  Future<void> appendSessionNoteLine({
    required String sessionId,
    required String line,
    String? businessId,
  }) async {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    try {
      await _assertSessionInBusinessScope(sessionId, businessId: businessId);
      await _client.rpc(
        SalesQueries.rpcAppendSessionNote,
        params: {'p_session_id': sessionId, 'p_line': trimmed},
      );
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST202') {
        throw Exception('Error al anotar en la cuenta: $e');
      }
      // Servidor sin 20261010_0006: la línea se agrega como antes (solo es
      // auditoría; ninguna edición del operador escribe la nota).
      final row = await _client
          .from('table_sessions')
          .select('note')
          .eq('id', sessionId)
          .maybeSingle();
      final current = (row?['note']?.toString() ?? '').trim();
      await _client
          .from('table_sessions')
          .update({'note': current.isEmpty ? trimmed : '$current\n$trimmed'})
          .eq('id', sessionId);
    } catch (e) {
      throw Exception('Error al anotar en la cuenta: $e');
    }
  }

  // ============================================================
  //  🔄 MÉTODOS DE COMPATIBILIDAD (LEGACY)
  // ============================================================

  /// Obtener detalle completo de la orden (LEGACY - usar getOrder + getOrderItems)
  Future<List<Map<String, dynamic>>> getOrderDetail(String orderId) async {
    final data = await _client
        .from('v_order_detail')
        .select()
        .eq('order_id', orderId)
        .order('check_pos', ascending: true);
    return List<Map<String, dynamic>>.from(data);
  }

  /// Contar mesas abiertas (LEGACY - usar getActiveSessions)
  Future<int> getOpenTablesCount(String businessId) async {
    final rows = await _client
        .from('orders')
        .select('session_id, table_sessions!inner(id)')
        .eq('table_sessions.business_id', businessId)
        .isFilter('table_sessions.closed_at', null)
        .isFilter('closed_at', null)
        .not('status_ext', 'in', '(paid,void)');

    final sessionIds = rows
        .map((row) => row['session_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();

    return sessionIds.length;
  }

  /// Confirmar pedido (LEGACY - usar sendToKitchen)
  Future<void> confirmOrderToKitchen(String orderId) async {
    await sendToKitchen(orderId);
  }

  /// Marcar orden como takeout (LEGACY)
  Future<OrderEditResult> markOrderTakeout({
    required String orderId,
    required bool takeout,
    required OrderEdit edit,
  }) => _editOrThrow(
    'Error al marcar la orden para llevar',
    () => applyOrderEdit(
      edit: edit,
      kind: 'order_takeout',
      args: {'is_takeout': takeout},
    ),
  );

  // ============================================================
  // 🚚 DELIVERY
  // ============================================================

  /// [allowLegacyBusinessFallback]: el usuario tiene un único negocio. Solo
  /// así es seguro caer a la firma de 3 argumentos (que elige el negocio en
  /// el servidor) cuando falta la migración 20261009_0004.
  Future<Map<String, dynamic>> openDeliveryOrder({
    required String deliveryType,
    int peopleCount = 1,
    String? businessId,
    bool allowLegacyBusinessFallback = false,
  }) async {
    final params = <String, dynamic>{
      'p_user_id': _client.auth.currentUser?.id,
      'p_delivery_type': deliveryType,
      'p_people_count': peopleCount,
    };
    final scoped = businessId != null && businessId.isNotEmpty;
    dynamic response;
    try {
      response = await _client.rpc(
        SalesQueries.rpcOpenDeliveryOrder,
        params: {...params, if (scoped) 'p_business_id': businessId},
      );
    } on PostgrestException catch (e) {
      // Servidor sin la migración 20261009_0004 (la app se publicó primero):
      // no existe la firma con p_business_id. La de 3 argumentos elige el
      // negocio en el servidor (el más antiguo del usuario): solo es segura
      // con un único negocio. Con varias sucursales podría crear el delivery
      // en otra, así que no se crea. Quitar cuando 0004 esté en producción.
      if (!scoped || e.code != 'PGRST202') rethrow;
      if (!allowLegacyBusinessFallback) {
        throw StateError(
          'Falta actualizar el servidor para crear delivery en esta sucursal '
          '(migración 20261009_0004). Avisa al administrador.',
        );
      }
      debugPrint(
        '[delivery] AVISO: el servidor no tiene fn_open_delivery_order con '
        'p_business_id (falta la migración 20261009_0004). Se usa la versión '
        'de 3 argumentos; el negocio lo elige el servidor. $e',
      );
      response = await _client.rpc(
        SalesQueries.rpcOpenDeliveryOrder,
        params: params,
      );
    }
    if (response == null) {
      throw Exception('No se pudo crear orden de delivery');
    }
    return Map<String, dynamic>.from(response as Map);
  }

  Future<List<Map<String, dynamic>>> listDeliveryOrders({
    required String businessId,
  }) async {
    final response = await _client.rpc(
      SalesQueries.rpcListDeliveryOrders,
      params: {'p_business_id': businessId},
    );
    return List<Map<String, dynamic>>.from(response as List);
  }

  Future<void> closeDeliveryOrder({
    required String orderId,
    String status = 'paid',
  }) async {
    await _client.rpc(
      SalesQueries.rpcCloseDeliveryOrder,
      params: {'p_order_id': orderId, 'p_status': status},
    );
  }

  // ===========================================================================
  // Dashboard — widgets agregados (Top productos, recientes)
  // ===========================================================================

  /// Top N productos más vendidos por cantidad, en el período dado.
  /// Suma `order_items.quantity` por `product_id`, ordena descendente.
  ///
  /// Devuelve filas con: `product_id`, `product_name`, `image_url`,
  /// `total_quantity`, `total_amount`. NULL `product_id` (= productos
  /// borrados) se filtran fuera porque ya no se pueden mostrar como item.
  ///
  /// Scope: respeta business_id vía join orders → table_sessions → zones.
  /// Status filter: solo cuenta items de órdenes 'paid'/'sent'/'served'
  /// — excluye drafts y canceladas.
  Future<List<Map<String, dynamic>>> getTopSellingProducts({
    required String businessId,
    required DateTime from,
    required DateTime to,
    int limit = 3,
  }) async {
    // Query DIRECTA (sin el RPC fn_dashboard_top_selling_products, que no está
    // desplegado en todos los entornos). Agrega las líneas de venta del rango
    // por producto y devuelve el top-N por cantidad. La imagen sale de
    // menu_items (solo para los ids del top, batch pequeño).
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);

    final itemRows = List<Map<String, dynamic>>.from(
      await _client
          .from('order_items')
          .select(
            'product_id,product_name,qty,quantity,subtotal,discounts,status',
          )
          .eq('business_id', businessId)
          .neq('status', 'void')
          .gte('created_at', fromIso)
          .lt('created_at', toIso)
          .limit(100000),
    );

    double asDouble(Object? v) => (v as num?)?.toDouble() ?? 0;

    final agg = <String, Map<String, dynamic>>{};
    for (final row in itemRows) {
      final productId = row['product_id']?.toString();
      if (productId == null || productId.isEmpty) continue;
      final qtyRaw = asDouble(row['qty']);
      final qty = qtyRaw != 0 ? qtyRaw : asDouble(row['quantity']);
      final amount = asDouble(row['subtotal']) - asDouble(row['discounts']);
      final bucket = agg.putIfAbsent(
        productId,
        () => <String, dynamic>{
          'product_id': productId,
          'product_name': row['product_name']?.toString() ?? 'Producto',
          'total_quantity': 0.0,
          'total_amount': 0.0,
        },
      );
      bucket['total_quantity'] = (bucket['total_quantity'] as double) + qty;
      bucket['total_amount'] = (bucket['total_amount'] as double) + amount;
    }

    final ranked = agg.values.toList()
      ..sort(
        (a, b) => (b['total_quantity'] as double).compareTo(
          a['total_quantity'] as double,
        ),
      );
    final top = ranked.take(limit).toList(growable: false);
    if (top.isEmpty) return const [];

    // Imagen/nombre vigente desde menu_items para los productos del top.
    final ids = top.map((e) => e['product_id'] as String).toList();
    final menuRows = List<Map<String, dynamic>>.from(
      await _client
          .from('menu_items')
          .select('id,name,image_url')
          .inFilter('id', ids),
    );
    final meta = <String, Map<String, dynamic>>{
      for (final row in menuRows)
        if (row['id'] != null) row['id'].toString(): row,
    };

    return top
        .map((row) {
          final m = meta[row['product_id']];
          final menuName = m?['name']?.toString().trim();
          return <String, dynamic>{
            'product_id': row['product_id'],
            'product_name': (menuName != null && menuName.isNotEmpty)
                ? menuName
                : row['product_name'],
            'image_url': m?['image_url'],
            'total_quantity': row['total_quantity'],
            'total_amount': row['total_amount'],
          };
        })
        .toList(growable: false);
  }

  /// Últimas N órdenes del business para el panel "Recent Orders" del
  /// dashboard. Devuelve resumen ligero: id, número visible, customer_name,
  /// total, status, created_at, items_summary (string corto con 1-2 items).
  ///
  /// Ordenado por `created_at` DESC. Por default trae las últimas 10.
  Future<List<Map<String, dynamic>>> getRecentOrders({
    required String businessId,
    int limit = 10,
  }) async {
    final response = await _client.rpc(
      'fn_dashboard_recent_orders',
      params: {'_business_id': businessId, '_limit': limit},
    );
    if (response == null) return const [];
    return List<Map<String, dynamic>>.from(response as List);
  }

  /// KPIs del "Order Summary" del dashboard: HOY vs AYER (mismo tramo
  /// del día). Devuelve hasta 2 filas — el caller las arma con
  /// [DashboardKpis.fromRpcRows].
  Future<List<Map<String, dynamic>>> getDashboardKpis({
    required String businessId,
    required DateTime todayFrom,
    required DateTime todayTo,
    required DateTime yesterdayFrom,
    required DateTime yesterdayTo,
  }) async {
    // Implementación con queries DIRECTAS (sin el RPC fn_dashboard_kpis).
    // Motivos:
    //   - El RPC scopeaba por COALESCE(zones.business_id, table_sessions.
    //     business_id); cuando esos venían NULL el dashboard mostraba 0 aunque
    //     SÍ hubiera órdenes. Aquí scopeamos por `orders.business_id` (poblado
    //     y misma fuente que get_sales_summary_v2 → los números concilian).
    //   - El RPC comparaba status_ext contra el vocabulario viejo del campo
    //     `status` ('sent'/'served'/'canceled'); el enum real es
    //     open/sent_to_kitchen/partially_paid/paid/void. Aquí usamos el correcto.
    //   - Ingreso = dinero cobrado (payments.amount - change_amount), robusto
    //     frente a orders.total = 0 en cuentas divididas.
    final lowerIso = AppTime.astToUtcIso(yesterdayFrom);
    final upperIso = AppTime.astToUtcIso(todayTo);

    // Límites como instantes UTC para clasificar cada fila por período. Las dos
    // ventanas (hoy / ayer, mismo tramo del día) no son contiguas: se sobre-pide
    // el hueco intermedio y cada fila se ubica con su created_at exacto.
    final tFrom = DateTime.parse(AppTime.astToUtcIso(todayFrom)).toUtc();
    final tTo = DateTime.parse(AppTime.astToUtcIso(todayTo)).toUtc();
    final yFrom = DateTime.parse(AppTime.astToUtcIso(yesterdayFrom)).toUtc();
    final yTo = DateTime.parse(AppTime.astToUtcIso(yesterdayTo)).toUtc();

    String? periodOf(Object? createdAtRaw) {
      final ts = DateTime.tryParse(createdAtRaw?.toString() ?? '')?.toUtc();
      if (ts == null) return null;
      if (!ts.isBefore(tFrom) && ts.isBefore(tTo)) return 'today';
      if (!ts.isBefore(yFrom) && ts.isBefore(yTo)) return 'yesterday';
      return null;
    }

    double asDouble(Object? v) => (v as num?)?.toDouble() ?? 0;

    final income = <String, double>{'today': 0, 'yesterday': 0};
    final ordersTotal = <String, int>{'today': 0, 'yesterday': 0};
    final ordersInProgress = <String, int>{'today': 0, 'yesterday': 0};
    final ordersCompleted = <String, int>{'today': 0, 'yesterday': 0};
    final itemsSold = <String, double>{'today': 0, 'yesterday': 0};

    // 1. Ingresos = pagos cobrados (misma fórmula que ventas/caja).
    final paymentRows = List<Map<String, dynamic>>.from(
      await _client
          .from('payments')
          .select('created_at,amount,change_amount,status')
          .eq('business_id', businessId)
          .gte('created_at', lowerIso)
          .lt('created_at', upperIso)
          .limit(50000),
    );
    for (final row in paymentRows) {
      final status = row['status']?.toString();
      if (status != null && status != 'completed') continue;
      final period = periodOf(row['created_at']);
      if (period == null) continue;
      income[period] =
          income[period]! +
          (asDouble(row['amount']) - asDouble(row['change_amount']));
    }

    // 2. Órdenes: total (no void), en curso y completadas. Vocabulario del
    //    enum order_status real.
    const inProgress = {'open', 'sent_to_kitchen', 'partially_paid'};
    final orderRows = List<Map<String, dynamic>>.from(
      await _client
          .from('orders')
          .select('created_at,status_ext')
          .eq('business_id', businessId)
          .gte('created_at', lowerIso)
          .lt('created_at', upperIso)
          .limit(50000),
    );
    for (final row in orderRows) {
      final period = periodOf(row['created_at']);
      if (period == null) continue;
      final status = row['status_ext']?.toString() ?? 'open';
      if (status == 'void') continue;
      ordersTotal[period] = ordersTotal[period]! + 1;
      if (inProgress.contains(status)) {
        ordersInProgress[period] = ordersInProgress[period]! + 1;
      } else if (status == 'paid') {
        ordersCompleted[period] = ordersCompleted[period]! + 1;
      }
    }

    // 3. Items vendidos (líneas no anuladas).
    final itemRows = List<Map<String, dynamic>>.from(
      await _client
          .from('order_items')
          .select('created_at,qty,quantity,status')
          .eq('business_id', businessId)
          .neq('status', 'void')
          .gte('created_at', lowerIso)
          .lt('created_at', upperIso)
          .limit(100000),
    );
    for (final row in itemRows) {
      final period = periodOf(row['created_at']);
      if (period == null) continue;
      final qtyRaw = asDouble(row['qty']);
      itemsSold[period] =
          itemsSold[period]! +
          (qtyRaw != 0 ? qtyRaw : asDouble(row['quantity']));
    }

    return [
      for (final period in const ['today', 'yesterday'])
        {
          'period': period,
          'income': income[period],
          'orders_total': ordersTotal[period],
          'orders_in_progress': ordersInProgress[period],
          'orders_completed': ordersCompleted[period],
          'items_sold': itemsSold[period],
        },
    ];
  }
}
