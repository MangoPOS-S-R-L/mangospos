import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/core/utils/display_name_utils.dart';
import '../models/payment_models.dart';
import '../utils/payment_amount_utils.dart';

class CashRegisterException implements Exception {
  final String errorCode;
  final String message;
  final int? openTablesCount;

  const CashRegisterException({
    required this.errorCode,
    required this.message,
    this.openTablesCount,
  });

  @override
  String toString() => message;
}

class CashierRepository {
  final SupabaseClient _client;
  CashierRepository(this._client);

  Future<List<PaymentMethod>> getPaymentMethods(String businessId) async {
    final data = await _client
        .from('payment_methods')
        .select()
        .eq('business_id', businessId)
        .eq('is_active', true)
        .order('position', ascending: true);
    return data.map((json) => PaymentMethod.fromMap(json)).toList();
  }

  Future<CashRegisterSession> requireActiveSession() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) {
      throw Exception(
        'No hay sesión de caja abierta. Por favor, abre una sesión antes de procesar pagos.',
      );
    }

    // Defensive: si hay 2+ sesiones abiertas para el mismo user (drift por
    // bug previo de cierre), tomamos la más reciente en lugar de crashear
    // con PostgrestException 406. Idem en las otras getActive* abajo.
    final data = await _client
        .from('cash_register_sessions')
        .select()
        .eq('user_id', userId)
        .eq('status', 'open')
        .isFilter('closed_at', null)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();

    if (data == null) {
      throw Exception(
        'No hay sesión de caja abierta. Por favor, abre una sesión antes de procesar pagos.',
      );
    }

    return CashRegisterSession.fromMap(data);
  }

  Future<Map<String, dynamic>> openSession({
    required String cashRegisterId,
    required String userId,
    required double startAmount,
    required String deviceId,
    String? deviceName,
  }) async {
    final response = Map<String, dynamic>.from(
      await _client.rpc(
        'fn_open_cash_session',
        params: {
          'p_cash_register_id': cashRegisterId,
          'p_user_id': userId,
          'p_start_amount': startAmount,
          'p_device_id': deviceId,
          'p_device_name': deviceName,
        },
      ),
    );

    final success = response['success'] as bool? ?? true;
    if (!success) {
      throw CashRegisterException(
        errorCode: response['error_code']?.toString() ?? 'CONFLICT',
        message: response['error']?.toString() ?? 'Error al abrir la caja.',
      );
    }

    return response;
  }

  Future<Map<String, dynamic>> closeSession({
    required String sessionId,
    required double endAmount,
    String? notes,
    bool forceWithOpenTables = false,
  }) async {
    try {
      final response = Map<String, dynamic>.from(
        await _client.rpc(
          'fn_close_cash_session',
          params: {
            'p_session_id': sessionId,
            'p_end_amount': endAmount,
            'p_notes': notes,
            'p_force_with_open_tables': forceWithOpenTables,
          },
        ),
      );

      final success = response['success'] as bool? ?? true;
      if (!success) {
        throw CashRegisterException(
          errorCode: response['error_code']?.toString() ?? 'UNKNOWN_ERROR',
          message: response['error']?.toString() ?? 'Error al cerrar la caja.',
          openTablesCount: response['open_tables_count'] as int?,
        );
      }

      return response;
    } on PostgrestException catch (e) {
      if (e.message.contains('OPEN_TABLES_EXIST')) {
        throw const CashRegisterException(
          errorCode: 'OPEN_TABLES_EXIST',
          message:
              'Existen órdenes abiertas sin cobrar. Debes cobrarlas o anularlas antes de cerrar.',
        );
      }
      if (e.message.contains('SESSION_ALREADY_CLOSED')) {
        throw const CashRegisterException(
          errorCode: 'SESSION_ALREADY_CLOSED',
          message: 'Esta sesión de caja ya fue cerrada.',
        );
      }
      throw CashRegisterException(
        errorCode: e.code ?? 'DATABASE_ERROR',
        message: 'Error de base de datos: ${e.message}',
      );
    } catch (e) {
      if (e is CashRegisterException) rethrow;
      throw CashRegisterException(
        errorCode: 'UNKNOWN_ERROR',
        message: 'Ocurrió un error inesperado al cerrar la caja: $e',
      );
    }
  }

  /// Inserta el desglose firmado del cierre detallado.
  ///
  /// La tabla tiene UNIQUE en `cash_register_session_id` y un trigger de
  /// inmutabilidad post-firma. Si la sesión ya tiene un row firmado,
  /// PostgreSQL rechaza con violation o con el error del trigger.
  Future<void> recordDetailedCashClose({
    required String sessionId,
    required String businessId,
    required String userId,
    required int cashAmount,
    required double cardAmount,
    required double transferAmount,
    required Map<String, dynamic> denominations,
    required double openingFloat,
    String? supervisorNote,
  }) async {
    await _client.from('cash_count_blind').insert({
      'cash_register_session_id': sessionId,
      'business_id': businessId,
      'cash_amount': cashAmount,
      'card_amount': cardAmount,
      'transfer_amount': transferAmount,
      'denominations': denominations,
      'opening_float': openingFloat,
      'supervisor_note': supervisorNote,
      'signed_by_user_id': userId,
    });
  }

  /// Marca el modo de UX usado al cerrar la sesión.
  ///
  /// Idempotente: si ya estaba seteado, se sobrescribe (no rompe nada porque
  /// el CHECK acepta los dos valores).
  Future<void> markSessionCloseMode({
    required String sessionId,
    required String mode,
  }) async {
    await _client
        .from('cash_register_sessions')
        .update({'close_mode_used': mode})
        .eq('id', sessionId);
  }

  Future<Map<String, dynamic>> getSessionSummary(String sessionId) async {
    final response = Map<String, dynamic>.from(
      await _client.rpc(
        'fn_get_cash_session_summary',
        params: {'p_session_id': sessionId},
      ),
    );

    final success = response['success'] as bool? ?? true;
    if (!success) {
      throw CashRegisterException(
        errorCode: response['error_code']?.toString() ?? 'UNKNOWN_ERROR',
        message: response['error']?.toString() ?? 'Error al obtener el resumen de caja.',
      );
    }

    return response;
  }

  Future<List<Map<String, dynamic>>> getCashRegisters(String businessId) async {
    final response = await _client
        .from('cash_registers')
        .select()
        .eq('business_id', businessId)
        .eq('is_active', true);
    return List<Map<String, dynamic>>.from(response);
  }

  Future<Map<String, dynamic>> createCashRegister({
    required String businessId,
    required String name,
  }) async {
    final response = await _client
        .from('cash_registers')
        .insert({'business_id': businessId, 'name': name, 'is_active': true})
        .select()
        .single();
    return Map<String, dynamic>.from(response);
  }

  Future<Map<String, dynamic>?> getLastSession(String cashRegisterId) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return null;

    final response = await _client
        .from('cash_register_sessions')
        .select()
        .eq('cash_register_id', cashRegisterId)
        .eq('user_id', userId)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    return response;
  }

  Future<CashRegisterSession?> getCurrentUserActiveSession() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return null;

    final data = await _client
        .from('cash_register_sessions')
        .select()
        .eq('user_id', userId)
        .eq('status', 'open')
        .isFilter('closed_at', null)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();

    if (data == null) return null;
    return CashRegisterSession.fromMap(data);
  }

  Future<CashRegisterSession?> getDeviceActiveSession(String deviceId) async {
    final data = await _client
        .from('cash_register_sessions')
        .select()
        .eq('device_id', deviceId)
        .eq('status', 'open')
        .isFilter('closed_at', null)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();

    if (data == null) return null;
    return CashRegisterSession.fromMap(data);
  }

  /// Busca la sesión abierta de un cash_register, sin filtrar por user.
  /// Permite que cualquier empleado del local sepa si la caja del register
  /// está operativa para vender. El cierre sigue restringido al dueño.
  Future<CashRegisterSession?> getActiveSessionForRegister(
    String cashRegisterId,
  ) async {
    final data = await _client
        .from('cash_register_sessions')
        .select()
        .eq('cash_register_id', cashRegisterId)
        .eq('status', 'open')
        .isFilter('closed_at', null)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();

    if (data == null) return null;
    return CashRegisterSession.fromMap(data);
  }

  Future<List<CashRegisterSession>> getSessionsByRegister(
    String cashRegisterId, {
    int limit = 20,
  }) async {
    final data = await _client
        .from('cash_register_sessions')
        .select()
        .eq('cash_register_id', cashRegisterId)
        .order('opened_at', ascending: false)
        .limit(limit);

    return data.map((json) => CashRegisterSession.fromMap(json)).toList();
  }

  Future<List<CashTransaction>> getSessionTransactions(String sessionId) async {
    final data = await _client
        .from('cash_transactions')
        .select()
        .eq('session_id', sessionId)
        .order('created_at', ascending: false);

    return data.map((json) => CashTransaction.fromMap(json)).toList();
  }

  Future<List<Map<String, dynamic>>> getSessionPaymentsDetailed(
    String sessionId,
  ) async {
    final paymentsRaw = await _client
        .from('payments')
        .select(
          'id, order_id, check_id, payment_method_id, amount, change_amount, reference, status, session_id, created_at, fiscal_documents(ncf_number, ncf_type, customer_rnc, customer_name)',
        )
        .eq('session_id', sessionId)
        .inFilter('status', ['completed', 'void', 'cancelled'])
        .order('created_at', ascending: false);

    final payments = List<Map<String, dynamic>>.from(paymentsRaw);
    if (payments.isEmpty) return const [];

    final methodIds = payments
        .map((p) => p['payment_method_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);
    final orderIds = payments
        .map((p) => p['order_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);
    final checkIds = payments
        .map((p) => p['check_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final methods = methodIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _client
                .from('payment_methods')
                .select('id, name, code')
                .inFilter('id', methodIds),
          );
    final methodsById = {for (final m in methods) m['id']?.toString() ?? '': m};

    final orders = orderIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _client
                .from('orders')
                .select('id, session_id')
                .inFilter('id', orderIds),
          );
    final ordersById = {for (final o in orders) o['id']?.toString() ?? '': o};

    final checks = checkIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _client
                .from('order_checks')
                .select('id, label, position')
                .inFilter('id', checkIds),
          );
    final checksById = {for (final c in checks) c['id']?.toString() ?? '': c};

    final tableSessionIds = orders
        .map((o) => o['session_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final tableSessions = tableSessionIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _client
                .from('table_sessions')
                .select(
                  'id, customer_name, table_id, business_id, opened_by, waiter:profiles!opened_by(full_name)',
                )
                .inFilter('id', tableSessionIds),
          );
    final tableSessionsById = {
      for (final s in tableSessions) s['id']?.toString() ?? '': s,
    };

    final tableIds = tableSessions
        .map((s) => s['table_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);
    final openerIds = tableSessions
        .map((s) => s['opened_by']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final businessIds = tableSessions
        .map((s) => s['business_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final employees = openerIds.isEmpty || businessIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _client
                .from('employees')
                .select('user_id, business_id, first_name')
                .inFilter('user_id', openerIds)
                .inFilter('business_id', businessIds),
          );
    final employeeNamesByKey = {
      for (final employee in employees)
        '${employee['business_id']}|${employee['user_id']}':
            preferredDisplayName(firstName: employee['first_name']?.toString()),
    };

    final tables = tableIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _client
                .from('dining_tables')
                .select('id, code')
                .inFilter('id', tableIds),
          );
    final tablesById = {for (final t in tables) t['id']?.toString() ?? '': t};

    return payments
        .map((payment) {
          final paymentMethodId =
              payment['payment_method_id']?.toString() ?? '';
          final orderId = payment['order_id']?.toString();
          final checkId = payment['check_id']?.toString();

          final method = methodsById[paymentMethodId];
          final order = orderId == null ? null : ordersById[orderId];
          final check = checkId == null ? null : checksById[checkId];
          final sessionIdForOrder = order?['session_id']?.toString();
          final tableSession = sessionIdForOrder == null
              ? null
              : tableSessionsById[sessionIdForOrder];
          final table = tableSession == null
              ? null
              : tablesById[tableSession['table_id']?.toString() ?? ''];

          final fiscal = payment['fiscal_documents'];
          final fiscalData = fiscal is List && fiscal.isNotEmpty
              ? fiscal.first
              : (fiscal is Map ? fiscal : null);
          final waiterProfileName =
              (tableSession?['waiter'] as Map?)?['full_name']?.toString();
          final waiterNameKey =
              '${tableSession?['business_id']}|${tableSession?['opened_by']}';
          final waiterName =
              employeeNamesByKey[waiterNameKey] ??
              preferredDisplayName(
                fullName: waiterProfileName,
                fallback: 'Servicio',
              );

          return <String, dynamic>{
            ...payment,
            'method_name': method?['name'],
            'method_code': method?['code'],
            'net_amount': netPaymentAmount(
              payment['amount'],
              payment['change_amount'],
            ),
            'customer_name':
                fiscalData?['customer_name'] ?? tableSession?['customer_name'],
            'customer_tax_id': fiscalData?['customer_rnc'],
            'ncf_number': fiscalData?['ncf_number'],
            'ncf_type_name': fiscalData?['ncf_type'],
            'waiter_name': waiterName,
            'table_code': table?['code'],
            'check_label': check?['label'],
            'check_position': check?['position'],
          };
        })
        .toList(growable: false);
  }

  Future<CashTransaction> createManualTransaction({
    required String sessionId,
    required double amount,
    required String type,
    String? description,
  }) async {
    final data = await _client
        .from('cash_transactions')
        .insert({
          'session_id': sessionId,
          'amount': amount,
          'type': type,
          'description': description,
        })
        .select()
        .single();

    return CashTransaction.fromMap(data);
  }

  /// Get the receipt printer ID assigned to a cash register.
  Future<String?> getRegisterPrinterId(String cashRegisterId) async {
    final data = await _client
        .from('cash_registers')
        .select('receipt_printer_id')
        .eq('id', cashRegisterId)
        .maybeSingle();
    return data?['receipt_printer_id'] as String?;
  }

  /// Assign a receipt printer to a cash register (admin only).
  Future<void> updateRegisterPrinter({
    required String cashRegisterId,
    required String? printerId,
  }) async {
    await _client
        .from('cash_registers')
        .update({'receipt_printer_id': printerId})
        .eq('id', cashRegisterId);
  }

  /// Get all cash registers for a business with their printer info.
  Future<List<Map<String, dynamic>>> getCashRegistersWithPrinter(String businessId) async {
    final data = await _client
        .from('cash_registers')
        .select('id, name, is_active, receipt_printer_id')
        .eq('business_id', businessId)
        .order('created_at');
    return List<Map<String, dynamic>>.from(data);
  }

  /// Lista paginada de comprobantes (fiscal_documents) — 1 row por factura.
  ///
  /// Source de verdad: `fiscal_documents`. Cada comprobante representa una
  /// factura emitida (con su NCF). Esta tabla distingue correctamente los
  /// dos flujos de split del POS:
  ///
  ///   - **Split bill (check-based)**: una orden con N sub-cuentas
  ///     (`order_checks`). Cada check, al pagarse, emite SU PROPIO NCF →
  ///     N fiscal_documents → N filas en este listado.
  ///
  ///   - **Split payment (full-order)**: una orden sin checks, cobrada con
  ///     varios métodos (efectivo + tarjeta + transferencia). UNA sola
  ///     factura, N payments asociados → 1 fila en este listado, los
  ///     métodos se muestran como agregado ("Mixto: Efectivo + Tarjeta").
  ///
  /// `check_id` se preserva en el row tomándolo del payment representativo
  /// (`fd.payment_id`) — así la reimpresión filtra correctamente cuando es
  /// un comprobante de un check vs de una orden completa.
  ///
  /// Payments sin `fiscal_document_id` (raros, sólo si el trigger falló)
  /// NO aparecen en este listado.
  Future<({List<Map<String, dynamic>> payments, int totalCount})> getGlobalSalesHistoryPaged({
    required String businessId,
    int page = 1,
    int pageSize = 20,
    DateTime? from,
    DateTime? to,
    String? searchTerm,
  }) async {
    final fromIndex = (page - 1) * pageSize;
    final toIndex = fromIndex + pageSize - 1;

    var query = _client
        .from('fiscal_documents')
        .select(
          'id, business_id, order_id, payment_id, ncf_number, ncf_type, '
          'customer_name, customer_rnc, total, status, ecf_status, '
          'is_electronic, created_at',
        )
        .eq('business_id', businessId);

    if (from != null) {
      query = query.gte('created_at', from.toIso8601String());
    }
    if (to != null) {
      query = query.lt('created_at', to.toIso8601String());
    }

    if (searchTerm != null && searchTerm.isNotEmpty) {
      final term = searchTerm.replaceAll(',', '\\,');
      // Pre-fetch fd_ids por reference de payments (campos opcionales como
      // número de autorización de tarjeta). Después se agregan a la cláusula OR.
      final fdIdsByRefRaw = await _client
          .from('payments')
          .select('fiscal_document_id')
          .eq('business_id', businessId)
          .not('fiscal_document_id', 'is', null)
          .ilike('reference', '%$searchTerm%');
      final fdIdsByRef = List<Map<String, dynamic>>.from(fdIdsByRefRaw)
          .map((row) => row['fiscal_document_id']?.toString())
          .whereType<String>()
          .toSet()
          .toList(growable: false);

      final clauses = <String>[
        'ncf_number.ilike.%$term%',
        'customer_name.ilike.%$term%',
        'customer_rnc.ilike.%$term%',
      ];
      if (fdIdsByRef.isNotEmpty) {
        clauses.add('id.in.(${fdIdsByRef.join(',')})');
      }
      query = query.or(clauses.join(','));
    }

    final response = await query
        .order('created_at', ascending: false)
        .range(fromIndex, toIndex)
        .count(CountOption.exact);

    final fdRows = List<Map<String, dynamic>>.from(response.data);
    final totalCount = response.count;

    if (fdRows.isEmpty) {
      return (
        payments: <Map<String, dynamic>>[],
        totalCount: totalCount,
      );
    }

    // Pre-resolución: orders → table_sessions → waiter (igual que antes),
    // y payments asociados a cada fd (para `check_id`, métodos agregados,
    // y fallback de id de acción).
    final orderIds = fdRows
        .map((fd) => fd['order_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final tableSessionsRaw = orderIds.isEmpty
        ? []
        : await _client
            .from('orders')
            .select(
              'id, session_id, table_sessions!inner('
              'id, customer_name, table_id, business_id, opened_by, '
              'waiter:profiles!opened_by(full_name))',
            )
            .inFilter('id', orderIds);

    final tableSessionsByOrderId = {
      for (final row in tableSessionsRaw)
        row['id'].toString(): row['table_sessions']
    };

    final tableIds = tableSessionsRaw
        .map((s) => (s['table_sessions'] as Map?)?['table_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final tablesRaw = tableIds.isEmpty
        ? []
        : await _client
            .from('dining_tables')
            .select('id, code')
            .inFilter('id', tableIds);
    final tablesById = {for (final t in tablesRaw) t['id'].toString(): t};

    // Payments por fd: necesarios para preservar check_id (split bill) y
    // mostrar agregado de métodos en split payment.
    final fdIds = fdRows.map((fd) => fd['id'].toString()).toList(growable: false);
    final paymentsForFdsRaw = fdIds.isEmpty
        ? []
        : await _client
            .from('payments')
            .select(
              'id, fiscal_document_id, check_id, payment_method_id, '
              'amount, change_amount, status, '
              'payment_methods(code, name)',
            )
            .inFilter('fiscal_document_id', fdIds);
    final paymentsByFd = <String, List<Map<String, dynamic>>>{};
    for (final row in paymentsForFdsRaw) {
      final fdId = row['fiscal_document_id']?.toString();
      if (fdId == null) continue;
      paymentsByFd.putIfAbsent(fdId, () => []).add(
        Map<String, dynamic>.from(row),
      );
    }

    final enriched = fdRows.map((fd) {
      final fdId = fd['id'].toString();
      final orderId = fd['order_id']?.toString();
      final tableSession = orderId == null
          ? null
          : tableSessionsByOrderId[orderId] as Map?;
      final tableCode = tableSession == null
          ? null
          : tablesById[tableSession['table_id']?.toString()]?['code'];
      final waiter = (tableSession?['waiter'] as Map?)?['full_name']
          ?.toString();

      final relatedPayments = paymentsByFd[fdId] ?? const [];

      // Representative payment: preferimos el que apunta `fd.payment_id`
      // (el que creó el NCF). Si por alguna razón no está en el set
      // recuperado, caemos al primero de la lista.
      final pivotPaymentId = fd['payment_id']?.toString();
      final pivot = relatedPayments.firstWhere(
        (p) => p['id']?.toString() == pivotPaymentId,
        orElse: () => relatedPayments.isNotEmpty
            ? relatedPayments.first
            : const <String, dynamic>{},
      );
      final actionPaymentId = (pivot['id']?.toString()) ?? pivotPaymentId;
      final checkId = pivot['check_id']?.toString();

      // Status para la UI (mantiene el contrato del consumer existente):
      //   - fd.status == 'cancelled' → 'cancelled' (tachado, indicador rojo).
      //   - de lo contrario, derivamos de los payments: si TODOS están
      //     anulados, 'cancelled'; si no, 'completed'.
      final fdStatus = fd['status']?.toString();
      final allPaymentsCancelled = relatedPayments.isNotEmpty &&
          relatedPayments.every((p) {
            final s = p['status']?.toString();
            return s == 'cancelled' || s == 'void';
          });
      final uiStatus = (fdStatus == 'cancelled' || allPaymentsCancelled)
          ? 'cancelled'
          : 'completed';

      // Agregado de métodos para mostrar en el listado.
      final methodNames = relatedPayments
          .map((p) => (p['payment_methods'] as Map?)?['name']?.toString())
          .whereType<String>()
          .toSet()
          .toList(growable: false);
      final methodSummary = switch (methodNames.length) {
        0 => null,
        1 => methodNames.first,
        _ => 'Mixto (${methodNames.join(' + ')})',
      };

      return {
        // Ancla para acciones (reimprimir, anular). Cae al payment que creó
        // el NCF; si no, al primer payment relacionado. La lógica de
        // annulación existente sigue funcionando sobre este id.
        'id': actionPaymentId,
        'fiscal_document_id': fdId,
        'order_id': fd['order_id'],
        // check_id viene del representative payment. Para split bill apunta
        // al check específico; para split payment es null. Esto preserva el
        // flujo de reimpresión por cuenta dividida.
        'check_id': checkId,
        'business_id': fd['business_id'],
        'amount': fd['total'],
        'net_amount': fd['total'],
        'status': uiStatus,
        'created_at': fd['created_at'],
        'customer_name': fd['customer_name'] ?? tableSession?['customer_name'],
        'customer_tax_id': fd['customer_rnc'],
        'ncf_number': fd['ncf_number'],
        'ncf_type_name': fd['ncf_type'],
        'ecf_status': fd['ecf_status'],
        'is_electronic': fd['is_electronic'],
        'table_code': tableCode,
        'waiter_name': waiter ?? 'Servicio',
        'payment_method_summary': methodSummary,
      };
    }).toList();

    return (payments: enriched, totalCount: totalCount);
  }
}
