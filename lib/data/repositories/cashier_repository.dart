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

    final data = await _client
        .from('cash_register_sessions')
        .select()
        .eq('user_id', userId)
        .eq('status', 'open')
        .isFilter('closed_at', null)
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

  /// Get global sales history for a business with pagination and optional filters.
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
        .from('payments')
        .select(
          'id, order_id, check_id, payment_method_id, amount, change_amount, reference, status, session_id, created_at, business_id, fiscal_documents(ncf_number, ncf_type, customer_rnc, customer_name)',
        )
        .eq('business_id', businessId)
        .inFilter('status', ['completed', 'void', 'cancelled']);

    if (from != null) {
      query = query.gte('created_at', from.toIso8601String());
    }
    if (to != null) {
      query = query.lt('created_at', to.toIso8601String());
    }

    if (searchTerm != null && searchTerm.isNotEmpty) {
      // Pre-fetch payment IDs from fiscal_documents matching NCF or customer fields
      final fiscalRaw = await _client
          .from('fiscal_documents')
          .select('payment_id')
          .eq('business_id', businessId)
          .or('ncf_number.ilike.%$searchTerm%,customer_name.ilike.%$searchTerm%,customer_rnc.ilike.%$searchTerm%');

      final fiscalIds = List<Map<String, dynamic>>.from(fiscalRaw)
          .map((r) => r['payment_id']?.toString())
          .whereType<String>()
          .toSet()
          .toList(growable: false);

      if (fiscalIds.isNotEmpty) {
        query = query.or('reference.ilike.%$searchTerm%,id.in.(${fiscalIds.join(',')})');
      } else {
        query = query.ilike('reference', '%$searchTerm%');
      }
    }

    final response = await query
        .order('created_at', ascending: false)
        .range(fromIndex, toIndex)
        .count(CountOption.exact);

    final paymentsRaw = List<Map<String, dynamic>>.from(response.data);
    final totalCount = response.count;

    if (paymentsRaw.isEmpty) return (payments: <Map<String, dynamic>>[], totalCount: totalCount);

    // Enrich data as in getSessionPaymentsDetailed
    final orderIds = paymentsRaw
        .map((p) => p['order_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);
    
    final tableSessionsRaw = orderIds.isEmpty
        ? []
        : await _client
            .from('orders')
            .select('id, session_id, table_sessions!inner(id, customer_name, table_id, business_id, opened_by, waiter:profiles!opened_by(full_name))')
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

    final enriched = paymentsRaw.map((payment) {
      final orderId = payment['order_id']?.toString();
      final tableSession = orderId == null ? null : tableSessionsByOrderId[orderId] as Map?;
      final tableCode = tableSession == null ? null : tablesById[tableSession['table_id']?.toString()]?['code'];
      final fiscal = payment['fiscal_documents'];
      final fiscalData = fiscal is List && fiscal.isNotEmpty
          ? fiscal.first
          : (fiscal is Map ? fiscal : null);

      return {
        ...payment,
        'net_amount': netPaymentAmount(payment['amount'], payment['change_amount']),
        'customer_name': fiscalData?['customer_name'] ?? tableSession?['customer_name'],
        'customer_tax_id': fiscalData?['customer_rnc'],
        'ncf_number': fiscalData?['ncf_number'],
        'ncf_type_name': fiscalData?['ncf_type'],
        'table_code': tableCode,
        'waiter_name': (tableSession?['waiter'] as Map?)?['full_name']?.toString() ?? 'Servicio',
      };
    }).toList();

    return (payments: enriched, totalCount: totalCount);
  }
}
