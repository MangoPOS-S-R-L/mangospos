// PRD-Azul-Subscriptions §7 — Repository de billing.
//
// Único punto de acceso a las tablas/vistas azul_ desde la app Flutter.
// La UI nunca consulta directamente: pasa por providers que envuelven este repo.
//
// IMPORTANTE: este repo solo lee tablas/vistas con RLS. Las mutaciones (crear
// session, cobrar, void) las ejecuta el backend vía Edge Functions o cron.
// Acá invocamos las funciones — no hay UPDATE/INSERT directos desde el cliente.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/billing_charge.dart';
import '../models/billing_payment_method.dart';
import '../models/billing_plan.dart';
import '../models/billing_state.dart';

final billingRepositoryProvider = Provider<BillingRepository>(
  (ref) => BillingRepository(Supabase.instance.client),
);

/// DEBUG (solo pruebas): si se compila con `--dart-define=AZUL_LOCAL_FN=...`,
/// la tokenización se enruta a la Edge Function corriendo en local (deno run)
/// en vez del VPS, para evitar el bloqueo de Incapsula a la IP del VPS en el
/// ambiente de pruebas de Azul. Vacío en builds normales → ruta de producción.
const String _kAzulLocalFnBase = String.fromEnvironment('AZUL_LOCAL_FN');

class BillingRepository {
  final SupabaseClient _client;

  BillingRepository(this._client);

  // -------------------------------------------------------------------------
  // Lecturas
  // -------------------------------------------------------------------------

  /// Catálogo de planes activos ordenados por display_order.
  /// La RLS `plans_select_visible` permite ver activos + el plan al que está
  /// suscrito el usuario aunque esté desactivado.
  Future<List<BillingPlan>> listAvailablePlans() async {
    final rows = await _client
        .from('plans')
        .select()
        .eq('is_active', true)
        .order('display_order', ascending: true);
    return (rows as List)
        .map((j) => BillingPlan.fromJson(j as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Estado de billing para el business — busca la membership que es
  /// is_billing_anchor=true. Si no existe, devuelve null.
  Future<BillingState?> getBillingStateForBusiness(String businessId) async {
    final row = await _client
        .from('memberships')
        .select('''
          id, user_id, business_id, plan_id, is_billing_anchor, billing_status,
          trial_ends_at, current_period_start, current_period_end,
          next_billing_date, consent_granted_at, current_attempt_number,
          suspended_at, cancelled_at, cancellation_reason, created_at,
          plan:plans(*),
          last_successful_charge:azul_charges_public!last_successful_charge_id(*),
          last_failed_charge:azul_charges_public!last_failed_charge_id(*)
        ''')
        .eq('business_id', businessId)
        .eq('is_billing_anchor', true)
        .maybeSingle();
    if (row == null) return null;
    return BillingState.fromJson(row);
  }

  /// Stream Realtime del estado de billing — cualquier UPDATE en la fila
  /// de membership re-emite el nuevo BillingState. Permite que la UI
  /// reaccione cuando el cron registra un nuevo cobro, o cuando el callback
  /// inserta un payment_method y dispara el cambio de billing_status.
  Stream<BillingState?> watchBillingStateForBusiness(String businessId) async* {
    yield await getBillingStateForBusiness(businessId);
    final stream = _client
        .from('memberships')
        .stream(primaryKey: ['id'])
        .eq('business_id', businessId);
    await for (final _ in stream) {
      yield await getBillingStateForBusiness(businessId);
    }
  }

  /// Método de pago default del business. Null si no hay tarjeta tokenizada.
  Future<BillingPaymentMethod?> getDefaultPaymentMethod(String businessId) async {
    final row = await _client
        .from('azul_payment_methods_public')
        .select()
        .eq('business_id', businessId)
        .eq('is_default', true)
        .maybeSingle();
    if (row == null) return null;
    return BillingPaymentMethod.fromJson(row);
  }

  Stream<BillingPaymentMethod?> watchDefaultPaymentMethod(String businessId) async* {
    yield await getDefaultPaymentMethod(businessId);
    final stream = _client
        .from('azul_payment_methods')
        .stream(primaryKey: ['id'])
        .eq('business_id', businessId);
    await for (final _ in stream) {
      yield await getDefaultPaymentMethod(businessId);
    }
  }

  /// Lista de cobros recientes ordenados del más reciente al más viejo.
  Future<List<BillingCharge>> listCharges(
    String businessId, {
    int limit = 24,
  }) async {
    final rows = await _client
        .from('azul_charges_public')
        .select()
        .eq('business_id', businessId)
        .order('attempted_at', ascending: false)
        .limit(limit);
    return (rows as List)
        .map((j) => BillingCharge.fromJson(j as Map<String, dynamic>))
        .toList(growable: false);
  }

  // -------------------------------------------------------------------------
  // Mutaciones — invocan Edge Functions, no DB directa
  // -------------------------------------------------------------------------

  /// Llama a la Edge Function `azul-create-tokenization-session`. La función
  /// crea una sesión, devuelve la URL del Payment Page (HTML auto-submit
  /// servido por la Edge Function `azul-payment-form`), y la app abre esa URL.
  ///
  /// Devuelve la URL que debe abrirse en browser.
  Future<TokenizationSessionResult> createTokenizationSession({
    required String businessId,
    String intentType = 'tokenize_and_verify',
  }) async {
    final response = await _client.functions.invoke(
      'azul-create-tokenization-session',
      body: {
        'business_id': businessId,
        'intent_type': intentType,
        'client_surface': 'flutter_app',
      },
    );
    final data = response.data;
    if (data is! Map<String, dynamic>) {
      throw BillingRepositoryException(
        'Respuesta inválida al crear sesión de tokenización',
      );
    }
    if (data.containsKey('error')) {
      final err = data['error'] as Map<String, dynamic>;
      throw BillingRepositoryException(
        err['message']?.toString() ?? 'Error al crear sesión',
        code: err['code']?.toString(),
      );
    }
    return TokenizationSessionResult(
      sessionId: data['session_id'] as String,
      orderNumber: data['order_number'] as String,
      paymentPageUrl: data['payment_page_url'] as String,
      expiresAt: DateTime.parse(data['expires_at'] as String),
      reused: (data['reused'] as bool?) ?? false,
    );
  }

  /// Tokeniza una tarjeta in-app vía la Edge Function `azul-tokenize-card`
  /// (ProcessDataVault). La app NUNCA persiste el PAN/CVV: los manda a la
  /// función, que guarda solo el token. Devuelve el método de pago creado.
  Future<TokenizedCardResult> tokenizeCard({
    required String businessId,
    required String cardNumber,
    required String expiration, // AAAAMM
    required String cvc,
    bool makeDefault = true,
  }) async {
    if (_kAzulLocalFnBase.isNotEmpty) {
      return _tokenizeViaLocal(
        businessId: businessId,
        cardNumber: cardNumber,
        expiration: expiration,
        cvc: cvc,
        makeDefault: makeDefault,
      );
    }
    final dynamic data;
    try {
      final response = await _client.functions.invoke(
        'azul-tokenize-card',
        body: {
          'business_id': businessId,
          'card_number': cardNumber.replaceAll(RegExp(r'\s+'), ''),
          'expiration': expiration,
          'cvc': cvc,
          'make_default': makeDefault,
        },
      );
      data = response.data;
    } on FunctionException catch (e) {
      throw _tokenizeError(e.details);
    }

    if (data is! Map<String, dynamic>) {
      throw BillingRepositoryException('Respuesta inválida al tokenizar la tarjeta');
    }
    if (data['ok'] != true || data.containsKey('error')) {
      throw _tokenizeError(data);
    }
    return TokenizedCardResult(
      paymentMethodId: data['payment_method_id'] as String,
      brand: data['brand']?.toString() ?? '',
      cardNumberMasked: data['card_number_masked']?.toString() ?? '',
      expiration: data['expiration']?.toString() ?? expiration,
      isDefault: (data['is_default'] as bool?) ?? makeDefault,
    );
  }

  /// DEBUG: tokeniza llamando directamente a la función local (ver
  /// [_kAzulLocalFnBase]). Manda el JWT del usuario como Bearer; la función
  /// local valida el token contra el auth server real (SUPABASE_URL de prod).
  /// El path `/azul-tokenize-card` lo ignora `Deno.serve` (responde a cualquier
  /// path), solo importa el método POST.
  Future<TokenizedCardResult> _tokenizeViaLocal({
    required String businessId,
    required String cardNumber,
    required String expiration,
    required String cvc,
    required bool makeDefault,
  }) async {
    final token = _client.auth.currentSession?.accessToken;
    if (token == null) {
      throw BillingRepositoryException('Sesión no disponible para tokenizar');
    }
    final uri = Uri.parse('$_kAzulLocalFnBase/azul-tokenize-card');
    http.Response resp;
    try {
      resp = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'business_id': businessId,
          'card_number': cardNumber.replaceAll(RegExp(r'\s+'), ''),
          'expiration': expiration,
          'cvc': cvc,
          'make_default': makeDefault,
        }),
      );
    } catch (e) {
      throw BillingRepositoryException('No se pudo contactar la función local: $e');
    }
    final dynamic data = resp.body.isNotEmpty ? jsonDecode(resp.body) : null;
    if (resp.statusCode != 200 || data is! Map<String, dynamic> || data['ok'] != true) {
      throw _tokenizeError(data);
    }
    return TokenizedCardResult(
      paymentMethodId: data['payment_method_id'] as String,
      brand: data['brand']?.toString() ?? '',
      cardNumberMasked: data['card_number_masked']?.toString() ?? '',
      expiration: data['expiration']?.toString() ?? expiration,
      isDefault: (data['is_default'] as bool?) ?? makeDefault,
    );
  }

  BillingRepositoryException _tokenizeError(dynamic details) {
    if (details is Map) {
      final err = details['error'];
      if (err is Map) {
        return BillingRepositoryException(
          err['message']?.toString() ?? 'No se pudo tokenizar la tarjeta',
          code: err['code']?.toString(),
        );
      }
      final detail = details['detail'];
      final m = (detail is Map)
          ? (detail['response_message'] ?? detail['error_description'])
          : (details['response_message'] ?? details['error_description']);
      if (m != null) return BillingRepositoryException(m.toString());
    }
    return BillingRepositoryException('No se pudo tokenizar la tarjeta');
  }

  // -------------------------------------------------------------------------
  // Cálculos client-side (preview UI, no son fuente de verdad)
  // -------------------------------------------------------------------------

  /// Preview de prorrateo para cambio de plan, calculado localmente para
  /// mostrar al usuario antes de confirmar. El cobro real lo hace el backend
  /// con su propia lógica — este número es informativo.
  ///
  /// Fórmula PRD §8.7 (lineal):
  ///   diasRestantes = M - N + 1
  ///   creditoNoUsadoA = P_A * diasRestantes / M
  ///   cargoProrrateadoB = P_B * diasRestantes / M
  ///   ajuste = cargoProrrateadoB - creditoNoUsadoA
  ProrationPreview previewProration({
    required BillingPlan currentPlan,
    required BillingPlan newPlan,
    required DateTime today,
  }) {
    if (currentPlan.id == newPlan.id) {
      return const ProrationPreview(
        adjustmentCents: 0,
        currencyCode: 'DOP',
        kind: ProrationKind.same,
        daysRemaining: 0,
        daysInMonth: 30,
      );
    }
    final lastDayOfMonth = DateTime(today.year, today.month + 1, 0).day;
    final daysRemaining = lastDayOfMonth - today.day + 1;

    final creditA = (currentPlan.priceCentsMonthly * daysRemaining) ~/ lastDayOfMonth;
    final chargeB = (newPlan.priceCentsMonthly * daysRemaining) ~/ lastDayOfMonth;
    final adjustment = chargeB - creditA;

    final ProrationKind kind;
    if (adjustment > 0) {
      kind = ProrationKind.upgrade;
    } else if (adjustment < 0) {
      kind = ProrationKind.downgrade;
    } else {
      kind = ProrationKind.same;
    }

    return ProrationPreview(
      adjustmentCents: adjustment,
      currencyCode: newPlan.currencyCode,
      kind: kind,
      daysRemaining: daysRemaining,
      daysInMonth: lastDayOfMonth,
    );
  }
}

class TokenizationSessionResult {
  final String sessionId;
  final String orderNumber;
  final String paymentPageUrl;
  final DateTime expiresAt;
  final bool reused;

  const TokenizationSessionResult({
    required this.sessionId,
    required this.orderNumber,
    required this.paymentPageUrl,
    required this.expiresAt,
    required this.reused,
  });
}

class TokenizedCardResult {
  final String paymentMethodId;
  final String brand;
  final String cardNumberMasked;
  final String expiration; // AAAAMM
  final bool isDefault;

  const TokenizedCardResult({
    required this.paymentMethodId,
    required this.brand,
    required this.cardNumberMasked,
    required this.expiration,
    required this.isDefault,
  });

  /// Últimos 4 dígitos a partir del enmascarado que devuelve Azul.
  String get last4 {
    final digits = cardNumberMasked.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.length >= 4 ? digits.substring(digits.length - 4) : digits;
  }
}

enum ProrationKind { upgrade, downgrade, same }

class ProrationPreview {
  final int adjustmentCents;
  final String currencyCode;
  final ProrationKind kind;
  final int daysRemaining;
  final int daysInMonth;

  const ProrationPreview({
    required this.adjustmentCents,
    required this.currencyCode,
    required this.kind,
    required this.daysRemaining,
    required this.daysInMonth,
  });

  String get formattedAdjustment {
    final abs = adjustmentCents.abs();
    final whole = abs ~/ 100;
    final cents = abs % 100;
    final wholeStr = whole.toString().replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );
    final symbol = currencyCode == 'DOP' ? r'RD$' : currencyCode;
    return '$symbol $wholeStr.${cents.toString().padLeft(2, '0')}';
  }
}

class BillingRepositoryException implements Exception {
  final String message;
  final String? code;
  BillingRepositoryException(this.message, {this.code});
  @override
  String toString() => 'BillingRepositoryException($code): $message';
}
