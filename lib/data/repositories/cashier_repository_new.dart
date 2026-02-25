import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/payment_models.dart';

/// 💰 Repositorio de Caja y Pagos
class CashierRepository {
  final SupabaseClient _client;

  CashierRepository(this._client);

  // ============================================================
  // 💳 MÉTODOS DE PAGO
  // ============================================================

  /// Obtener métodos de pago activos
  Future<List<PaymentMethod>> getPaymentMethods(String businessId) async {
    try {
      final data = await _client
          .from('payment_methods')
          .select()
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('position', ascending: true);

      return data.map((json) => PaymentMethod.fromMap(json)).toList();
    } catch (e) {
      throw Exception('Error al obtener métodos de pago: $e');
    }
  }

  // ============================================================
  // 💰 SESIONES DE CAJA
  // ============================================================

  /// Obtener sesión de caja activa del usuario actual
  Future<CashRegisterSession?> getCurrentUserActiveSession() async {
    try {
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
    } catch (e) {
      throw Exception('Error al obtener sesión activa: $e');
    }
  }

  /// Abrir sesión de caja
  Future<CashRegisterSession> openCashRegisterSession({
    required String cashRegisterId,
    required double startAmount,
    String? notes,
  }) async {
    try {
      final userId = _client.auth.currentUser?.id;
      if (userId == null) {
        throw Exception('Usuario no autenticado');
      }

      final data = await _client
          .from('cash_register_sessions')
          .insert({
            'cash_register_id': cashRegisterId,
            'user_id': userId,
            'start_amount': startAmount,
            'status': 'open',
            'notes': notes,
          })
          .select()
          .single();

      return CashRegisterSession.fromMap(data);
    } catch (e) {
      throw Exception('Error al abrir sesión de caja: $e');
    }
  }

  /// Cerrar sesión de caja
  Future<void> closeCashRegisterSession({
    required String sessionId,
    required double endAmount,
    String? notes,
  }) async {
    try {
      await _client.rpc(
        'fn_close_cash_session',
        params: {
          'p_session_id': sessionId,
          'p_end_amount': endAmount,
          'p_notes': notes,
        },
      );
    } catch (e) {
      throw Exception('Error al cerrar sesión de caja: $e');
    }
  }

  /// Obtener transacciones de una sesión
  Future<List<CashTransaction>> getSessionTransactions(String sessionId) async {
    try {
      final data = await _client
          .from('cash_transactions')
          .select()
          .eq('session_id', sessionId)
          .order('created_at', ascending: false);

      return data.map((json) => CashTransaction.fromMap(json)).toList();
    } catch (e) {
      throw Exception('Error al obtener transacciones: $e');
    }
  }

  /// Registrar transacción manual (gasto, retiro, depósito)
  Future<CashTransaction> createManualTransaction({
    required String sessionId,
    required double amount,
    required String type,
    String? description,
  }) async {
    try {
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
    } catch (e) {
      throw Exception('Error al crear transacción: $e');
    }
  }

  // ============================================================
  // 📊 RESUMEN DE CAJA
  // ============================================================

  /// Obtener resumen de efectivo en sesión
  Future<Map<String, double>> getSessionCashSummary(String sessionId) async {
    try {
      final transactions = await getSessionTransactions(sessionId);

      double sales = 0;
      double expenses = 0;
      double withdrawals = 0;
      double deposits = 0;

      for (final tx in transactions) {
        switch (tx.type) {
          case 'sale':
            sales += tx.amount;
            break;
          case 'expense':
            expenses += tx.amount;
            break;
          case 'withdrawal':
            withdrawals += tx.amount;
            break;
          case 'deposit':
            deposits += tx.amount;
            break;
        }
      }

      final session = await _client
          .from('cash_register_sessions')
          .select('start_amount')
          .eq('id', sessionId)
          .single();

      final startAmount = (session['start_amount'] ?? 0).toDouble();
      final expectedCash =
          startAmount + sales + deposits - expenses - withdrawals;

      return {
        'start_amount': startAmount,
        'sales': sales,
        'expenses': expenses,
        'withdrawals': withdrawals,
        'deposits': deposits,
        'expected_cash': expectedCash,
      };
    } catch (e) {
      throw Exception('Error al obtener resumen de caja: $e');
    }
  }

  // ============================================================
  // 🔍 VALIDACIONES
  // ============================================================

  /// Validar que hay sesión de caja abierta
  Future<bool> hasActiveSession() async {
    final session = await getCurrentUserActiveSession();
    return session != null && session.isOpen;
  }

  /// Validar y obtener sesión activa (lanza excepción si no hay)
  Future<CashRegisterSession> requireActiveSession() async {
    final session = await getCurrentUserActiveSession();
    if (session == null || !session.isOpen) {
      throw Exception(
        'No hay sesión de caja abierta. Por favor, abre una sesión antes de procesar pagos.',
      );
    }
    return session;
  }
}
