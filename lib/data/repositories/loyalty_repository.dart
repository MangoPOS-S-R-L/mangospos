import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/friendly_error.dart';
import '../models/loyalty_models.dart';

/// Error de las tarjetas de sellos con el mensaje ya listo para pantalla.
class LoyaltyException implements Exception {
  const LoyaltyException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

/// Tarjetas de sellos («cada N compras, 1 gratis»). Mig 20260930_0053.
///
/// Los sellos no se guardan: el servidor los calcula de las ventas cobradas
/// del cliente. Por eso todo lo que cambia saldos (canjear, quitar premio,
/// ajustar) pasa por RPC que validan en el servidor.
class LoyaltyRepository {
  LoyaltyRepository(this._client);

  final SupabaseClient _client;

  static const _programsTable = 'loyalty_stamp_programs';
  static const _adjustmentsTable = 'loyalty_stamp_adjustments';

  static const _messages = <String, String>{
    'NOT_ENOUGH_STAMPS':
        'El cliente no tiene sellos suficientes para ese premio.',
    'ITEM_ALREADY_DISCOUNTED':
        'Ese producto ya tiene un descuento, oferta o cortesía. Elige otra '
        'línea.',
    'ITEM_NOT_OPEN': 'Esa línea ya se cobró o se anuló.',
    'ITEM_NOT_FOR_CUSTOMER':
        'Esa línea es de otra subcuenta o de otro cliente.',
    'ITEM_NOT_IN_PROGRAM': 'Ese producto no suma en esta tarjeta.',
    'ITEM_NOT_FOUND': 'No se encontró la línea. Recarga la cuenta.',
    'ITEM_HAS_NO_PRICE': 'Esa línea no tiene precio.',
    'LOYALTY_INVALID_UNITS': 'Cantidad de unidades gratis no válida.',
    'LOYALTY_PROGRAM_NOT_FOUND': 'La tarjeta no existe o está desactivada.',
    'CUSTOMER_NOT_FOUND': 'El cliente no es de este negocio.',
    'LOYALTY_ACCESS_DENIED': 'No tienes acceso a este negocio.',
    'LOYALTY_ADJUST_DENIED':
        'No tienes permiso para ajustar sellos (requiere «Crear o editar '
        'clientes»).',
    'LOYALTY_REASON_REQUIRED': 'Escribe el motivo del ajuste.',
    'LOYALTY_INVALID_STAMPS': 'Cantidad de sellos no válida.',
    'NO_LOYALTY_REWARD': 'Esa línea no tiene premio.',
    'LOYALTY_TARGETS_INVALID':
        'Algún producto o categoría no es de este negocio.',
    'AUTH_REQUIRED': 'Tu sesión venció. Inicia sesión de nuevo.',
  };

  static const migrationMissing =
      'Falta aplicar en la base de datos la migración de tarjetas de sellos '
      '(20260930_0053).';

  /// Traduce cualquier error a [LoyaltyException] con mensaje en español.
  static LoyaltyException mapError(Object error) {
    if (error is LoyaltyException) return error;
    final raw = error.toString();
    for (final entry in _messages.entries) {
      if (raw.contains(entry.key)) {
        return LoyaltyException(entry.value, code: entry.key);
      }
    }
    if (error is PostgrestException) {
      final code = error.code ?? '';
      // Función o tabla inexistente: la migración no está aplicada.
      if (code == 'PGRST202' ||
          code == 'PGRST205' ||
          code == '42883' ||
          code == '42P01') {
        return const LoyaltyException(migrationMissing, code: 'MIGRATION');
      }
      if (code == '42501' || raw.contains('row-level security')) {
        return const LoyaltyException(
          'No tienes permiso para configurar tarjetas de sellos (requiere '
          '«Gestionar descuentos y propinas»).',
          code: '42501',
        );
      }
      if (code == '23514') {
        return const LoyaltyException(
          'Revisa los datos: nombre, sellos (de 2 a 100) y al menos un '
          'producto o categoría.',
          code: '23514',
        );
      }
    }
    return LoyaltyException(FriendlyError.from(error));
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e) {
      throw mapError(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Programas
  // ---------------------------------------------------------------------------

  Future<List<LoyaltyStampProgram>> getPrograms(String businessId) {
    return _guard(() async {
      final rows = await _client
          .from(_programsTable)
          .select(
            'id, business_id, name, target_scope, target_ids, '
            'stamps_required, count_mode, starts_at, is_active',
          )
          .eq('business_id', businessId)
          .order('is_active', ascending: false)
          .order('name');
      return List<Map<String, dynamic>>.from(
        rows,
      ).map(LoyaltyStampProgram.fromMap).toList(growable: false);
    });
  }

  /// Crea ([id] null) o edita un programa.
  Future<void> saveProgram({
    String? id,
    required String businessId,
    required String name,
    required String targetScope,
    required List<String> targetIds,
    required int stampsRequired,
    required String countMode,
    required DateTime startsAt,
    required bool isActive,
  }) {
    return _guard(() async {
      final payload = <String, dynamic>{
        'business_id': businessId,
        'name': name.trim(),
        'target_scope': targetScope,
        'target_ids': targetIds,
        'stamps_required': stampsRequired,
        'count_mode': countMode,
        'starts_at': startsAt.toUtc().toIso8601String(),
        'is_active': isActive,
      };
      if (id == null) {
        await _client.from(_programsTable).insert(payload);
      } else {
        // `.select()` para detectar el UPDATE que RLS filtra en silencio
        // (0 filas y 200 OK): sin permiso, eso NO debe verse como guardado.
        final rows = await _client
            .from(_programsTable)
            .update(payload)
            .eq('id', id)
            .select('id');
        if ((rows as List).isEmpty) {
          throw const LoyaltyException(
            'No tienes permiso para configurar tarjetas de sellos (requiere '
            '«Gestionar descuentos y propinas»).',
            code: '42501',
          );
        }
      }
    });
  }

  Future<void> setProgramActive(String id, bool isActive) {
    return _guard(() async {
      final rows = await _client
          .from(_programsTable)
          .update({'is_active': isActive})
          .eq('id', id)
          .select('id');
      if ((rows as List).isEmpty) {
        throw const LoyaltyException(
          'No tienes permiso para configurar tarjetas de sellos (requiere '
          '«Gestionar descuentos y propinas»).',
          code: '42501',
        );
      }
    });
  }

  Future<List<LoyaltyTargetOption>> getProducts(String businessId) {
    return _guard(() async {
      final rows = await _client
          .from('menu_items')
          .select('id, name, category_id')
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('name');
      return List<Map<String, dynamic>>.from(rows)
          .map(
            (m) => LoyaltyTargetOption(
              id: m['id'].toString(),
              name: (m['name'] ?? '').toString(),
              categoryId: m['category_id']?.toString(),
            ),
          )
          .toList(growable: false);
    });
  }

  Future<List<LoyaltyTargetOption>> getCategories(String businessId) {
    return _guard(() async {
      final rows = await _client
          .from('categories')
          .select('id, name')
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('name');
      return List<Map<String, dynamic>>.from(rows)
          .map(
            (m) => LoyaltyTargetOption(
              id: m['id'].toString(),
              name: (m['name'] ?? '').toString(),
            ),
          )
          .toList(growable: false);
    });
  }

  // ---------------------------------------------------------------------------
  // Tarjetas del cliente
  // ---------------------------------------------------------------------------

  Future<List<LoyaltyCard>> getCustomerCards(String customerId) {
    return _guard(() async {
      final result = await _client.rpc(
        'fn_loyalty_customer_cards',
        params: {'p_customer_id': customerId},
      );
      if (result is! List) return const <LoyaltyCard>[];
      return result
          .whereType<Map>()
          .map((m) => LoyaltyCard.fromMap(Map<String, dynamic>.from(m)))
          .toList(growable: false);
    });
  }

  /// Pone [units] unidades gratis en la línea [orderItemId] (cuenta abierta).
  Future<void> redeemReward({
    required String programId,
    required String customerId,
    required String orderItemId,
    int units = 1,
  }) {
    return _guard(() async {
      await _client.rpc(
        'fn_loyalty_redeem_reward',
        params: {
          'p_program_id': programId,
          'p_customer_id': customerId,
          'p_order_item_id': orderItemId,
          'p_units': units,
        },
      );
    });
  }

  /// Quita el premio de una línea abierta; los sellos vuelven.
  Future<void> cancelReward(String orderItemId) {
    return _guard(() async {
      await _client.rpc(
        'fn_loyalty_cancel_reward',
        params: {'p_order_item_id': orderItemId},
      );
    });
  }

  /// Suma (o resta) sellos a mano: cargar la tarjeta física, corregir.
  Future<void> adjustStamps({
    required String programId,
    required String customerId,
    required int stamps,
    required String reason,
  }) {
    return _guard(() async {
      await _client.rpc(
        'fn_loyalty_adjust_stamps',
        params: {
          'p_program_id': programId,
          'p_customer_id': customerId,
          'p_stamps': stamps,
          'p_reason': reason.trim(),
        },
      );
    });
  }

  Future<List<LoyaltyAdjustment>> getAdjustments({
    required String customerId,
    required String programId,
    int limit = 20,
  }) {
    return _guard(() async {
      final rows = await _client
          .from(_adjustmentsTable)
          .select('id, stamps, reason, created_at')
          .eq('customer_id', customerId)
          .eq('program_id', programId)
          .order('created_at', ascending: false)
          .limit(limit);
      return List<Map<String, dynamic>>.from(
        rows,
      ).map(LoyaltyAdjustment.fromMap).toList(growable: false);
    });
  }
}
