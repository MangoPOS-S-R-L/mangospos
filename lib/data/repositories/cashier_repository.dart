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
  /// inmutabilidad post-firma. Si la sesión ya tiene un row firmado con
  /// el mismo attempt_number, PostgreSQL rechaza con violation. Para el
  /// reconteo el caller pasa `attemptNumber: 2` y se inserta como fila
  /// nueva (la anterior queda intacta como evidencia).
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
    int attemptNumber = 1,
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
      'attempt_number': attemptNumber,
    });
  }

  /// Cuántos conteos firmados existen para la sesión (1 o 2). 0 si la
  /// sesión aún no fue cerrada. Útil para decidir si el botón "Volver
  /// a contar" debe mostrarse (solo si count < 2) y para asignar el
  /// próximo attempt_number al firmar.
  Future<int> getCashCloseAttemptCount(String sessionId) async {
    try {
      final rows = await _client
          .from('cash_count_blind')
          .select('id')
          .eq('cash_register_session_id', sessionId);
      return (rows as List).length;
    } catch (_) {
      return 0;
    }
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

  /// Busca sesiones abiertas del usuario actual ESCOPEADAS a un business
  /// específico. Necesario para que un owner con varias sucursales pueda
  /// abrir caja en una sucursal aunque tenga caja abierta en otra (la
  /// migración 20260509_0002 relajó Rule B server-side para owners). El
  /// chequeo `getCurrentUserActiveSession()` sin filtro de business
  /// bloquearía aunque el backend lo permita.
  Future<CashRegisterSession?> getCurrentUserActiveSessionForBusiness({
    required String businessId,
  }) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return null;

    // Inner join sobre cash_registers para filtrar por business_id.
    final data = await _client
        .from('cash_register_sessions')
        .select('*, cash_registers!inner(business_id)')
        .eq('user_id', userId)
        .eq('status', 'open')
        .eq('cash_registers.business_id', businessId)
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

  /// Sprint Caja Pro — Crea un movimiento manual (deposit/withdrawal/
  /// expense) vía RPC `fn_cash_transaction_create`. La RPC valida que
  /// la sesión esté abierta, que la razón exista en el catálogo del
  /// negocio, y que se haya pasado `approvedBy` si la razón o el monto
  /// lo exigen.
  ///
  /// El INSERT directo a `cash_transactions` se mantuvo durante
  /// la transición pero los nuevos call sites deben pasar `reasonCode`
  /// y, cuando aplique, `approvedBy`.
  Future<CashTransaction> createManualTransaction({
    required String sessionId,
    required double amount,
    required String type,
    required String reasonCode,
    String? description,
    String? createdBy,
    String? approvedBy,
  }) async {
    try {
      final response = await _client.rpc(
        'fn_cash_transaction_create',
        params: {
          'p_session_id': sessionId,
          'p_type': type,
          'p_amount': amount,
          'p_reason_code': reasonCode,
          'p_description': description,
          'p_created_by':
              createdBy ?? _client.auth.currentUser?.id,
          'p_approved_by': approvedBy,
        },
      );
      if (response is Map) {
        return CashTransaction.fromMap(Map<String, dynamic>.from(response));
      }
      // Fallback defensivo: si la RPC retorna lista (algunas configs).
      if (response is List && response.isNotEmpty) {
        return CashTransaction.fromMap(
          Map<String, dynamic>.from(response.first as Map),
        );
      }
      throw CashRegisterException(
        errorCode: 'EMPTY_RESPONSE',
        message: 'No se pudo registrar el movimiento.',
      );
    } catch (e) {
      // Mapear errores comunes de la RPC a mensajes para el cajero.
      final msg = e.toString();
      if (msg.contains('APPROVAL_REQUIRED')) {
        throw CashRegisterException(
          errorCode: 'APPROVAL_REQUIRED',
          message:
              'Este movimiento requiere autorización con PIN de supervisor.',
        );
      }
      if (msg.contains('REASON_NOT_FOUND')) {
        throw CashRegisterException(
          errorCode: 'REASON_NOT_FOUND',
          message:
              'La razón seleccionada no está configurada para este negocio.',
        );
      }
      if (msg.contains('REASON_WRONG_TYPE')) {
        throw CashRegisterException(
          errorCode: 'REASON_WRONG_TYPE',
          message: 'Esta razón no aplica al tipo de movimiento elegido.',
        );
      }
      if (msg.contains('SESSION_NOT_OPEN')) {
        throw CashRegisterException(
          errorCode: 'SESSION_NOT_OPEN',
          message: 'La caja ya no está abierta. Recargá la pantalla.',
        );
      }
      rethrow;
    }
  }

  /// Sprint Caja Pro Fase D — Marca la sesión cerrada con
  /// `variance_flagged=true` para que el dashboard pueda filtrar
  /// cierres que superaron el umbral configurado. Se llama post-close
  /// como fire-and-forget; si falla no rompe el cierre.
  Future<void> markSessionVarianceFlagged(String sessionId) async {
    await _client
        .from('cash_register_sessions')
        .update({'variance_flagged': true})
        .eq('id', sessionId);
  }

  /// Sprint Caja Pro Fase D — Lee el umbral configurado por el negocio
  /// para alertar sobre varianza al cerrar. Si la diferencia absoluta
  /// excede este monto, la UI pide confirmación + nota antes de cerrar.
  /// 0 = sin umbral (no se alerta).
  Future<double> getVarianceAlertThreshold(String businessId) async {
    try {
      final row = await _client
          .from('business_settings')
          .select('cash_variance_alert_threshold')
          .eq('business_id', businessId)
          .maybeSingle();
      final v = row?['cash_variance_alert_threshold'];
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v) ?? 0;
      return 0;
    } catch (_) {
      return 0;
    }
  }

  /// Sprint Caja Pro Fase D — Lee la vista `v_cash_sessions_health`
  /// para el dashboard del admin. Devuelve todas las sesiones del
  /// negocio (abiertas y cerradas recientes) con saldo vivo + bandera
  /// `needs_attention`.
  Future<List<Map<String, dynamic>>> getCashSessionsHealth({
    required String businessId,
    bool openOnly = false,
  }) async {
    var query = _client
        .from('v_cash_sessions_health')
        .select()
        .eq('business_id', businessId);
    if (openOnly) {
      query = query.eq('status', 'open');
    }
    final response = await query.order('opened_at', ascending: false);
    return List<Map<String, dynamic>>.from(response);
  }

  /// Sprint Caja Pro Fase D — Force-close por manager/admin/owner.
  /// El monto contado puede ser null (no se hizo arqueo físico) — el
  /// backend deja `difference = null` en ese caso.
  Future<Map<String, dynamic>> forceCloseSession({
    required String sessionId,
    double? endAmount,
    required String reason,
  }) async {
    final response = await _client.rpc(
      'fn_force_close_cash_session',
      params: {
        'p_session_id': sessionId,
        'p_end_amount': endAmount,
        'p_reason': reason,
        'p_forced_by': _client.auth.currentUser?.id,
      },
    );
    if (response is Map) return Map<String, dynamic>.from(response);
    if (response is List && response.isNotEmpty) {
      return Map<String, dynamic>.from(response.first as Map);
    }
    return <String, dynamic>{};
  }

  /// Sprint Caja Pro — Lista las razones activas configuradas para un
  /// negocio. Si `appliesTo` se pasa, filtra solo las que aplican a ese
  /// tipo de movimiento (o universales, que aplican a cualquier tipo).
  Future<List<Map<String, dynamic>>> getCashTransactionReasons({
    required String businessId,
    String? appliesTo,
  }) async {
    var query = _client
        .from('cash_transaction_reasons')
        .select('id, code, label, applies_to, requires_pin')
        .eq('business_id', businessId)
        .eq('is_active', true);

    final response = await query.order('label', ascending: true);
    final all = List<Map<String, dynamic>>.from(response);
    if (appliesTo == null) return all;
    return all
        .where((r) =>
            r['applies_to'] == null || r['applies_to'] == appliesTo)
        .toList(growable: false);
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
          'id, business_id, order_id, payment_id, check_id, ncf_number, '
          'ncf_type, customer_name, customer_rnc, '
          'subtotal, taxable_amount, itbis_amount, service_fee, total, '
          'status, ecf_status, is_electronic, created_at',
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
        // Desglose del fd para el modal de detalle / reimpresión. Antes
        // estos campos solo se cargaban por separado; ahora viajan junto
        // a la fila para que el modal pueda mostrar la factura completa.
        'subtotal': fd['subtotal'],
        'taxable_amount': fd['taxable_amount'],
        'itbis_amount': fd['itbis_amount'],
        'service_fee': fd['service_fee'],
        'total': fd['total'],
        'status': uiStatus,
        'created_at': fd['created_at'],
        'customer_name': fd['customer_name'] ?? tableSession?['customer_name'],
        'customer_tax_id': fd['customer_rnc'],
        'customer_rnc': fd['customer_rnc'],
        'ncf_number': fd['ncf_number'],
        'ncf_type': fd['ncf_type'],
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
