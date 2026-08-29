// PRD-Azul-Subscriptions §7 — Repository de billing.
//
// Único punto de acceso a las tablas/vistas azul_ desde la app Flutter.
// La UI nunca consulta directamente: pasa por providers que envuelven este repo.
//
// IMPORTANTE: este repo solo lee tablas/vistas con RLS. Las mutaciones (crear
// session, cobrar, void) las ejecuta el backend vía Edge Functions o cron.
// Acá invocamos las funciones — no hay UPDATE/INSERT directos desde el cliente.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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
    final row = await _fetchBillingRow(businessId);
    if (row == null) return null;
    return BillingState.fromJson(row);
  }

  Future<Map<String, dynamic>?> _fetchBillingRow(String businessId) {
    return _client
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
  }

  /// Stream del estado de billing — cualquier UPDATE en la fila de membership
  /// re-emite el nuevo BillingState. Permite que la UI reaccione cuando el
  /// cron registra un nuevo cobro, o cuando el callback inserta un
  /// payment_method y dispara el cambio de billing_status.
  Stream<BillingState?> watchBillingStateForBusiness(String businessId) {
    return _watchTable<BillingState?>(
      table: 'memberships',
      businessId: businessId,
      load: () async {
        final row = await _fetchBillingRow(businessId);
        if (row == null) return (_kEmptySignature, null);
        return (jsonEncode(row), BillingState.fromJson(row));
      },
    );
  }

  /// Método de pago default del business. Null si no hay tarjeta tokenizada.
  Future<BillingPaymentMethod?> getDefaultPaymentMethod(
    String businessId,
  ) async {
    final row = await _fetchDefaultPaymentMethodRow(businessId);
    if (row == null) return null;
    return BillingPaymentMethod.fromJson(row);
  }

  Future<Map<String, dynamic>?> _fetchDefaultPaymentMethodRow(
    String businessId,
  ) {
    return _client
        .from('azul_payment_methods_public')
        .select()
        .eq('business_id', businessId)
        .eq('is_default', true)
        .maybeSingle();
  }

  Stream<BillingPaymentMethod?> watchDefaultPaymentMethod(String businessId) {
    // Se lee de la vista `_public` (enmascarada) pero se escucha la tabla:
    // Realtime solo publica cambios de tablas.
    return _watchTable<BillingPaymentMethod?>(
      table: 'azul_payment_methods',
      businessId: businessId,
      load: () async {
        final row = await _fetchDefaultPaymentMethodRow(businessId);
        if (row == null) return (_kEmptySignature, null);
        return (jsonEncode(row), BillingPaymentMethod.fromJson(row));
      },
    );
  }

  /// Firma de "no hay fila". Cualquier JSON real empieza con `{`, así que no
  /// colisiona con un payload legítimo.
  static const String _kEmptySignature = '<null>';

  /// Cuánto esperamos por una lectura antes de darla por perdida. Sin esto,
  /// una petición que nunca resuelve deja la pantalla girando para siempre y
  /// sin manera de salir.
  static const Duration _readTimeout = Duration(seconds: 20);

  /// Cada cuánto releer cuando Realtime no está disponible.
  static const Duration _fallbackPollInterval = Duration(seconds: 45);

  /// Fallos seguidos del canal Realtime tras los cuales lo damos por perdido.
  static const int _maxRealtimeErrors = 3;

  /// "Valor actual + refresco cuando la tabla cambia", blindado.
  ///
  /// Antes esto era un `async*` con `await for` sobre `.stream()`. El cliente
  /// de Supabase mete un ERROR en ese stream cuando el canal Realtime da
  /// `channelError` o `timedOut` (ver `supabase_stream_builder.dart`), y ese
  /// error terminaba el generador: la pantalla de suscripción quedaba trabada
  /// —girando o en error— hasta reiniciar la app. Acá:
  ///
  ///   * un fallo del canal Realtime NO mata el stream, solo se registra;
  ///   * si Realtime no levanta, se cae a un poll lento para no quedar ciegos
  ///     ante el alta de una tarjeta o un cambio de estado;
  ///   * las re-emisiones idénticas se descartan. Realtime reenvía el snapshot
  ///     completo en cada reconexión y cada reenvío repintaba la pantalla
  ///     entera (parpadeo y taps que se pierden);
  ///   * un refresco que falla cuando ya hay dato en pantalla se ignora: es
  ///     preferible el dato de hace un minuto a vaciar la vista.
  Stream<T> _watchTable<T>({
    required String table,
    required String businessId,
    required Future<(String, T)> Function() load,
  }) {
    final controller = StreamController<T>();
    StreamSubscription<List<Map<String, dynamic>>>? realtimeSub;
    Timer? fallbackPoll;
    String? lastSignature;
    var emitted = false;
    var busy = false;
    var queued = false;
    var realtimeErrors = 0;

    Future<void> push() async {
      if (controller.isClosed) return;
      if (busy) {
        // Un refresco ya está en vuelo; se encola uno solo al final para no
        // disparar N consultas por una ráfaga de eventos.
        queued = true;
        return;
      }
      busy = true;
      try {
        final (signature, value) = await load().timeout(_readTimeout);
        if (controller.isClosed) return;
        if (!emitted || signature != lastSignature) {
          lastSignature = signature;
          emitted = true;
          controller.add(value);
        }
      } catch (e, st) {
        if (!emitted && !controller.isClosed) {
          controller.addError(e, st);
          // Sin dato que mostrar, la vista queda en error: el poll es la única
          // vía para que se recupere sola cuando vuelva la red.
          fallbackPoll ??= Timer.periodic(
            _fallbackPollInterval,
            (_) => push(),
          );
        } else {
          debugPrint('[Billing] refresco de $table falló: $e');
        }
      } finally {
        busy = false;
        if (queued && !controller.isClosed) {
          queued = false;
          unawaited(push());
        }
      }
    }

    controller.onListen = () {
      unawaited(push());
      try {
        realtimeSub = _client
            .from(table)
            .stream(primaryKey: ['id'])
            .eq('business_id', businessId)
            .listen(
              (_) => push(),
              onError: (Object e) {
                realtimeErrors++;
                // Solo el primero: el canal reintenta con backoff y si la
                // tabla no está publicada falla para siempre — no llenamos la
                // consola con el mismo error cada pocos segundos.
                if (realtimeErrors == 1) {
                  debugPrint('[Billing] realtime $table: $e');
                }
                fallbackPoll ??= Timer.periodic(
                  _fallbackPollInterval,
                  (_) => push(),
                );
                // Tras varios fallos seguidos damos el canal por perdido y lo
                // cerramos. Si la tabla no está en la publication
                // `supabase_realtime`, reintentar es una tormenta de joins que
                // nunca va a prosperar; el poll ya cubre el refresco.
                if (realtimeErrors >= _maxRealtimeErrors) {
                  final sub = realtimeSub;
                  realtimeSub = null;
                  unawaited(sub?.cancel() ?? Future<void>.value());
                  debugPrint(
                    '[Billing] realtime $table desactivado tras '
                    '$realtimeErrors fallos; sigo por poll.',
                  );
                }
              },
              onDone: () {
                fallbackPoll ??= Timer.periodic(
                  _fallbackPollInterval,
                  (_) => push(),
                );
              },
            );
      } catch (e) {
        debugPrint('[Billing] no se pudo abrir realtime en $table: $e');
        fallbackPoll ??= Timer.periodic(_fallbackPollInterval, (_) => push());
      }
    };

    controller.onCancel = () async {
      fallbackPoll?.cancel();
      fallbackPoll = null;
      await realtimeSub?.cancel();
      realtimeSub = null;
      await controller.close();
    };

    return controller.stream;
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
      throw BillingRepositoryException(
        'Respuesta inválida al tokenizar la tarjeta',
      );
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
      throw BillingRepositoryException(
        'No se pudo contactar la función local: $e',
      );
    }
    final dynamic data = resp.body.isNotEmpty ? jsonDecode(resp.body) : null;
    if (resp.statusCode != 200 ||
        data is! Map<String, dynamic> ||
        data['ok'] != true) {
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

  /// Cobra la suscripción AHORA ("Pagar sistema") con la tarjeta default, vía la
  /// Edge Function `azul-charge-now` (que autoriza al dueño y delega en
  /// `azul-charge-subscription` con service_role). Devuelve el resultado.
  ///
  /// No lanza por tarjeta declinada (HTTP 200, `ok:false`) — eso viene en el
  /// [ChargeNowResult]. Lanza [BillingRepositoryException] en errores reales
  /// (sin tarjeta, suspendido, red, etc.).
  Future<ChargeNowResult> chargeNow({required String businessId}) async {
    final dynamic data;
    try {
      final response = await _client.functions.invoke(
        'azul-charge-now',
        body: {'business_id': businessId},
      );
      data = response.data;
    } on FunctionException catch (e) {
      throw _chargeError(e.details);
    }

    if (data is! Map<String, dynamic>) {
      throw BillingRepositoryException('Respuesta inválida del cobro');
    }
    if (data.containsKey('error')) {
      throw _chargeError(data);
    }
    final approved = data['ok'] == true;
    return ChargeNowResult(
      approved: approved,
      status:
          data['status']?.toString() ?? (approved ? 'approved' : 'declined'),
      chargeId: data['charge_id']?.toString(),
      isoCode: data['iso_code']?.toString(),
      azulOrderId: data['azul_order_id']?.toString(),
      responseMessage: data['response_message']?.toString(),
      idempotent: data['idempotent'] == true,
    );
  }

  BillingRepositoryException _chargeError(dynamic details) {
    if (details is Map) {
      final err = details['error'];
      if (err is Map) {
        return BillingRepositoryException(
          err['message']?.toString() ?? 'No se pudo procesar el cobro',
          code: err['code']?.toString(),
        );
      }
      final m = details['response_message'] ?? details['message'];
      if (m != null) return BillingRepositoryException(m.toString());
    }
    return BillingRepositoryException('No se pudo procesar el cobro');
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

    final creditA =
        (currentPlan.priceCentsMonthly * daysRemaining) ~/ lastDayOfMonth;
    final chargeB =
        (newPlan.priceCentsMonthly * daysRemaining) ~/ lastDayOfMonth;
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

/// Resultado de un cobro manual de la suscripción ([BillingRepository.chargeNow]).
class ChargeNowResult {
  /// `true` si Azul aprobó (IsoCode 00).
  final bool approved;

  /// Estado de la charge: 'approved' | 'declined' | 'error'.
  final String status;
  final String? chargeId;
  final String? isoCode;
  final String? azulOrderId;
  final String? responseMessage;

  /// `true` si el período ya estaba cobrado y se devolvió sin recobrar.
  final bool idempotent;

  const ChargeNowResult({
    required this.approved,
    required this.status,
    required this.chargeId,
    required this.isoCode,
    required this.azulOrderId,
    required this.responseMessage,
    required this.idempotent,
  });
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
