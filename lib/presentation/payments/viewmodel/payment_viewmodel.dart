import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:decimal/decimal.dart';

import '../../../core/currency/usd_conversion.dart';
import '../../../core/network/connectivity_service.dart';
import '../../../core/offline/ncf_offline_allocator.dart' show NcfAssignment;
import '../../../core/offline/offline_ncf_service.dart';
import '../../../core/offline/offline_pos_service.dart';
import '../../../core/tax/tax_exceptions.dart';
import '../../../data/models/bank_account.dart';
import '../../../data/models/payment_models.dart';
import '../../../data/models/sales_models.dart';
import '../../../data/repositories/cashier_repository.dart';
import '../../../data/repositories/credits_repository.dart';
import '../../../data/repositories/pos_settings_repository.dart';
import '../../../data/repositories/sales_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../../../services/session/session_controller.dart';
import '../../sales/viewmodel/sales_viewmodel.dart'; // Import para usar salesRepositoryProvider
import '../state/payment_state.dart';

// Providers
final cashierRepositoryProvider = Provider<CashierRepository>(
  (ref) => CashierRepository(Supabase.instance.client),
);

final paymentViewModelProvider =
    StateNotifierProvider.autoDispose<PaymentViewModel, PaymentState>(
      (ref) => PaymentViewModel(
        ref.read(cashierRepositoryProvider),
        ref.read(salesRepositoryProvider),
        ref,
      ),
    );

/// 💰 ViewModel para gestión de pagos
class PaymentViewModel extends StateNotifier<PaymentState> {
  final CashierRepository _cashierRepo;
  final SalesRepository _salesRepo;
  final Ref _ref;
  final ConnectivityService _connectivity = ConnectivityService();
  final OfflinePosService _offlinePos = OfflinePosService();

  PaymentViewModel(this._cashierRepo, this._salesRepo, this._ref)
    : super(const PaymentState()) {
    unawaited(_connectivity.initialize());
  }

  /// Guard sincronico para `processPayment`. `state.processingPayment` se ve
  /// en el siguiente frame; este flag bloquea double-tap dentro del mismo
  /// frame antes de cualquier `await`.
  bool _processingLocal = false;

  @override
  void dispose() {
    _connectivity.dispose();
    super.dispose();
  }

  String _cleanError(Object e) {
    final raw = e.toString();
    if (raw.contains('Demasiadas colisiones de NCF')) {
      return 'No se pudo emitir el comprobante fiscal de este negocio porque su numeracion entra en conflicto con otra configuracion fiscal. Revisa Ajustes > Fiscal.';
    }
    if (raw.contains('No hay secuencia NCF disponible para tipo') ||
        raw.contains('Secuencia NCF agotada para tipo')) {
      return 'El negocio no tiene una secuencia fiscal activa para el tipo de comprobante seleccionado. Revisa Ajustes > Fiscal.';
    }
    if (raw.contains('ORDER_ALREADY_CLOSED') ||
        raw.contains('CHECK_ALREADY_CLOSED')) {
      return 'Esta cuenta ya fue cobrada. Refresca el historial para ver el comprobante.';
    }
    if (e is TimeoutException || e is SocketException) {
      return 'Error de conexion con el servidor.';
    }
    if (e is PostgrestException) {
      final message = e.message.trim();
      final details = (e.details ?? '').toString().trim();
      final hint = (e.hint ?? '').toString().trim();
      final combined = [
        if (message.isNotEmpty) message,
        if (details.isNotEmpty) details,
        if (hint.isNotEmpty) hint,
      ].join(' - ');
      return combined.isEmpty ? 'Error de conexion con el servidor.' : combined;
    }
    final msg = e.toString();
    const prefixes = ['Exception: '];
    for (final prefix in prefixes) {
      if (msg.startsWith(prefix)) {
        return msg.substring(prefix.length);
      }
    }
    return msg;
  }

  // ============================================================
  // 🚀 INICIALIZACIÓN
  // ============================================================

  /// Inicializar pago para una orden completa
  Future<void> initializeForOrder(Order order) async {
    await _initializePayment(order: order, totalToPay: order.total);
  }

  /// Inicializar pago para un check específico (split bill)
  Future<void> initializeForCheck(Order order, OrderCheck check) async {
    await _initializePayment(
      order: order,
      check: check,
      totalToPay: check.total,
    );
  }

  Future<void> _initializePayment({
    required Order order,
    OrderCheck? check,
    required double totalToPay,
  }) async {
    state = state.copyWith(
      loading: true,
      error: null,
      order: order,
      check: check,
      totalToPay: totalToPay,
      offlineQueued: false,
    );

    try {
      CashRegisterSession? cashSession;
      if (_connectivity.isConnected) {
        cashSession = await _cashierRepo.requireActiveSession();
      }

      final businessId = await resolveBusinessIdOrNull(
        Supabase.instance.client,
        'auto',
      );

      if (businessId == null) {
        throw Exception('No se pudo identificar el negocio');
      }

      // Venta a crédito: solo visible con permiso. El seed del método
      // 'credit' es best-effort para negocios creados antes de la migración.
      final canSellCredit = _ref
          .read(sessionProvider.notifier)
          .hasPermission('creditos.vender');
      if (_connectivity.isConnected && canSellCredit) {
        await CreditsRepository(
          Supabase.instance.client,
        ).ensureCreditPaymentMethod(businessId);
      }

      var methods = <PaymentMethod>[];
      if (_connectivity.isConnected) {
        methods = await _cashierRepo.getPaymentMethods(businessId);
      }

      final fixedMethods = _getFixedPaymentMethods(businessId);
      for (final fixed in fixedMethods) {
        if (!methods.any((m) => m.code == fixed.code)) {
          methods = [...methods, fixed];
        }
      }

      if (!canSellCredit) {
        methods = methods.where((m) => !m.isCredit).toList();
      }

      methods.sort((a, b) => a.position.compareTo(b.position));

      // Cargar tipos de comprobante disponibles para este business.
      // - availableNcfTypes: filtra ncf_sequences activas con rango disponible.
      // - selectedNcfType: usa default_ncf_type del business como base.
      // - ecfEnabled: true si hay alguna sequence Exx en disponibles.
      List<String> availableNcfTypes = const [];
      String? selectedNcfType;
      bool ecfEnabled = false;
      if (_connectivity.isConnected) {
        try {
          final config = await _loadFiscalConfig(businessId);
          availableNcfTypes = config.types;
          selectedNcfType = config.defaultType;
          ecfEnabled = config.ecfEnabled;
        } catch (_) {
          // Fail-soft: si no se cargan tipos, el cobro queda con default
          // del backend (B02). No tumbamos el flujo de cobro por esto.
        }
      }

      // Si estamos cobrando una sub-cuenta y el cajero asignó cliente/NCF
      // a ese check antes del cobro, los heredamos como pre-llenado del
      // modal. El cajero puede cambiarlos antes de confirmar el pago.
      // Si el check no tiene asignación, caemos al default del business.
      String? prefilledCustomerId;
      String? prefilledCustomerRnc;
      String? prefilledNcfType = selectedNcfType;

      if (check != null) {
        if (check.customerId != null && check.customerId!.isNotEmpty) {
          prefilledCustomerId = check.customerId;
        }
        if (check.customerRnc != null && check.customerRnc!.isNotEmpty) {
          prefilledCustomerRnc = check.customerRnc;
        }
        if (check.requestedNcfType != null &&
            check.requestedNcfType!.isNotEmpty &&
            availableNcfTypes.contains(check.requestedNcfType)) {
          prefilledNcfType = check.requestedNcfType;
        }
      }

      state = state.copyWith(
        loading: false,
        order: order,
        check: check,
        totalToPay: totalToPay,
        paymentMethods: methods,
        cashSession: cashSession,
        availableNcfTypes: availableNcfTypes,
        selectedNcfType: prefilledNcfType,
        customerId: prefilledCustomerId,
        customerRnc: prefilledCustomerRnc,
        ecfEnabled: ecfEnabled,
        error: _connectivity.isConnected
            ? null
            : 'Modo offline: el pago se guardará para sincronizar luego.',
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: _cleanError(e));
    }
  }

  /// Carga la configuración fiscal del business: tipos disponibles, default,
  /// y si tiene e-CF habilitado. Fail-soft: si la query falla devuelve config
  /// vacía (el backend caerá al default 'B02').
  Future<({List<String> types, String? defaultType, bool ecfEnabled})>
      _loadFiscalConfig(String businessId) async {
    final sb = Supabase.instance.client;

    // 1. fiscal_settings: default_ncf_type del business.
    final fs = await sb
        .from('fiscal_settings')
        .select('default_ncf_type, ecf_enabled')
        .eq('business_id', businessId)
        .maybeSingle();

    final defaultType = fs?['default_ncf_type'] as String?;

    // 2. ncf_sequences activas con rango disponible.
    final sequences = await sb
        .from('ncf_sequences')
        .select('ncf_type, current_number, range_end')
        .eq('business_id', businessId)
        .eq('is_active', true);

    final types = <String>{};
    for (final row in (sequences as List).cast<Map<String, dynamic>>()) {
      final type = row['ncf_type']?.toString();
      final current = (row['current_number'] as num?)?.toInt() ?? 0;
      final end = (row['range_end'] as num?)?.toInt() ?? 0;
      if (type == null || type.isEmpty) continue;
      // Solo incluir si todavía hay rango disponible.
      if (current >= end) continue;
      types.add(type);
    }

    // Orden estable: B0x primero, luego E3x/E4x.
    final sortedTypes = types.toList()
      ..sort((a, b) {
        // 'B' antes que 'E'
        final aPrefix = a.isNotEmpty ? a[0] : '';
        final bPrefix = b.isNotEmpty ? b[0] : '';
        if (aPrefix != bPrefix) return aPrefix.compareTo(bPrefix);
        return a.compareTo(b);
      });

    final ecfEnabled = (fs?['ecf_enabled'] == true) ||
        sortedTypes.any((t) => t.startsWith('E'));

    // Default fallback: si default_ncf_type no está en disponibles, usar el
    // primero (preferentemente Exx si ecf habilitado, sino B02).
    String? resolvedDefault = defaultType;
    if (resolvedDefault == null || !sortedTypes.contains(resolvedDefault)) {
      if (sortedTypes.isNotEmpty) {
        resolvedDefault = sortedTypes.firstWhere(
          (t) => ecfEnabled ? t.startsWith('E') : t.startsWith('B'),
          orElse: () => sortedTypes.first,
        );
      }
    }

    return (
      types: sortedTypes,
      defaultType: resolvedDefault,
      ecfEnabled: ecfEnabled,
    );
  }

  /// Cambia el tipo de comprobante seleccionado para este cobro.
  /// Si el tipo nuevo NO requiere RNC, se preserva el customer si existe
  /// (por si el usuario alterna entre E31 y E32 sin perder lo escrito).
  void selectNcfType(String type) {
    if (state.selectedNcfType == type) return;
    state = state.copyWith(selectedNcfType: type);
  }

  /// Invoca `emit-document` en modo SYNC: emite el doc inmediatamente y
  /// devuelve el snapshot actualizado del fiscal_document para que el ticket
  /// pueda imprimirse con QR + codigo de seguridad sin necesidad de un
  /// segundo round-trip a Supabase.
  ///
  /// Se aplica timeout de [timeout] (default 8s) — Alanube responde tipico
  /// en 1-3s, DGII puede tardar mas pero solo necesitamos el `securityCode`
  /// para armar el QR (lo cual ya viene en el response sync de Alanube,
  /// independiente de DGII).
  ///
  /// Retorna el FiscalDocument con `ecf_status` actualizado:
  /// - `sent` o `accepted` → tenemos `ecf_security_code` → ticket sale con QR.
  /// - `rejected` → DGII rechazo, ticket sale sin QR + mensaje de error.
  /// - `pending` (timeout) → emit no termino a tiempo, retornamos null y el
  ///   ticket sale con "EN PROCESO". El cron de respaldo + el webhook van a
  ///   actualizar la fila eventualmente.
  ///
  /// Norma DGII 01-2020: la representacion impresa que se le da al cliente
  /// debe incluir el QR. Por eso esta llamada bloquea el cierre de cobro;
  /// si llegamos a producir muchos timeouts, hay que evaluar contingencia
  /// (downgrade a B02) en una proxima iteracion.
  Future<FiscalDocument?> _emitDocumentSync({
    required String fiscalDocumentId,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    // Pasamos fiscal_document_id en el body para que el Edge Function nuevo
    // procese SOLO ese doc (modo sync). El Edge Function viejo ignora el
    // body y procesa batch — igual de util porque el doc nuevo va a estar
    // entre los pending de la queue.
    final t0 = DateTime.now();
    debugPrint('[emit-sync] START doc=$fiscalDocumentId timeout=${timeout.inSeconds}s');
    try {
      final res = await Supabase.instance.client.functions
          .invoke(
            'emit-document',
            body: {'fiscal_document_id': fiscalDocumentId},
          )
          .timeout(timeout);
      final dt = DateTime.now().difference(t0).inMilliseconds;
      debugPrint(
        '[emit-sync] OK status=${res.status} dt=${dt}ms '
        'data=${res.data?.toString().substring(0, (res.data?.toString().length ?? 0).clamp(0, 300))}',
      );
    } on TimeoutException {
      final dt = DateTime.now().difference(t0).inMilliseconds;
      debugPrint('[emit-sync] TIMEOUT después de ${dt}ms');
      // Timeout: el cron de respaldo + webhook eventualmente van a actualizar.
    } catch (e) {
      final dt = DateTime.now().difference(t0).inMilliseconds;
      debugPrint('[emit-sync] ERROR dt=${dt}ms exception=$e');
      // Error de red / 5xx: idem timeout, falla suave.
    }

    // Re-fetch unconditional. Esto funciona con AMBAS versiones del Edge
    // Function (la vieja batch, la nueva sync per-doc) — solo nos importa
    // el estado actual del doc en DB despues del intento.
    try {
      final refreshed = await _salesRepo.getOrderFiscalDocument(state.order!.id);
      debugPrint(
        '[emit-sync] REFETCH status=${refreshed?.ecfStatus} '
        'sec=${refreshed?.ecfSecurityCode ?? "null"}',
      );
      return refreshed;
    } catch (e) {
      debugPrint('[emit-sync] REFETCH ERROR: $e');
      return null;
    }
  }

  // ============================================================
  // 💳 SELECCIÓN DE MÉTODO DE PAGO
  // ============================================================

  void selectPaymentMethod(PaymentMethod method) {
    state = state.copyWith(
      selectedMethod: method,
      amountReceived: method.isCash ? 0 : state.totalToPay,
      change: 0,
      reference: null,
      // Cambiar método siempre limpia la cuenta bancaria seleccionada
      // (era válida solo para 'transfer'). Sentinel `null` explícito
      // para forzar el clear en copyWith.
      selectedBankAccount: null,
    );
  }

  /// Selector usado por el modal cuando el método activo es
  /// transferencia. El cajero elige a cuál cuenta del negocio llegó la
  /// transacción; persistimos el id en payments.bank_account_id al
  /// confirmar el pago.
  void setBankAccount(BankAccount? account) {
    state = state.copyWith(selectedBankAccount: account);
  }

  // ============================================================
  // 💵 PAGO EN EFECTIVO
  // ============================================================

  void setAmountReceived(double amount) {
    final change = amount - state.totalToPay;
    state = state.copyWith(
      amountReceived: amount,
      change: change > 0 ? change : 0,
    );
  }

  void addToAmountReceived(double amount) {
    setAmountReceived(state.amountReceived + amount);
  }

  void setExactAmount() {
    setAmountReceived(state.totalToPay);
  }

  void clearAmountReceived() {
    state = state.copyWith(amountReceived: 0, change: 0);
  }

  // ============================================================
  // 📝 REFERENCIA Y CLIENTE
  // ============================================================

  void setReference(String? reference) {
    state = state.copyWith(reference: reference);
  }

  void setCustomer({
    String? customerId,
    String? customerRnc,
    String? customerName,
  }) {
    state = state.copyWith(
      customerId: customerId,
      customerRnc: customerRnc,
      customerName: customerName,
    );
  }

  // ============================================================
  // ✅ PROCESAR PAGO
  // ============================================================

  Future<void> processPayment() async {
    // PRD 1: bloqueo fail-loud. Si la configuración fiscal no se pudo cargar
    // para el negocio actual, no permitimos procesar el pago.
    final taxConfigError = _ref.read(currentOrderProvider).taxConfigError;
    if (taxConfigError != null) {
      final blocked = PaymentBlockedException(
        'No se puede procesar el pago: configuración fiscal no disponible. '
        'Detalle: $taxConfigError. Contactá al administrador.',
      );
      state = state.copyWith(error: _cleanError(blocked));
      return;
    }

    if (!state.canProcessPayment) {
      state = state.copyWith(
        error: 'No se puede procesar el pago. Verifica los datos.',
      );
      return;
    }

    // Guard sincronico antes de await: bloquea double-tap en el mismo frame
    // (Riverpod expone state.processingPayment recien tras rebuild). Backend
    // tambien tiene guard atomico (20260509_0001), esto solo evita disparar
    // el RPC duplicado innecesariamente.
    if (_processingLocal || state.processingPayment) return;
    _processingLocal = true;

    state = state.copyWith(processingPayment: true, error: null);

    // Venta a crédito: validación previa (cliente con crédito habilitado y
    // dentro del límite). El trigger de BD es el backstop; aquí damos el
    // mensaje amigable. Requiere conexión — el fiao no se cobra offline
    // porque no podemos validar el límite ni crear la CxC hasta el sync.
    if (state.isCreditPayment) {
      String? creditError;
      if (!_connectivity.isConnected) {
        creditError =
            'La venta a crédito no está disponible sin conexión.';
      } else if (state.customerId == null || state.customerId!.isEmpty) {
        creditError = 'Selecciona el cliente para la venta a crédito.';
      } else {
        try {
          final businessId = await resolveBusinessIdOrNull(
            Supabase.instance.client,
            'auto',
          );
          final standing = await CreditsRepository(
            Supabase.instance.client,
          ).getCustomerCreditStanding(
            businessId: businessId ?? '',
            customerId: state.customerId!,
          );
          if (!standing.creditEnabled) {
            creditError =
                'El cliente no tiene crédito habilitado. Actívalo en su '
                'ficha (Clientes).';
          } else if (!standing.canTake(state.totalToPay)) {
            final available = standing.availableCredit ?? 0;
            creditError =
                'Límite de crédito excedido. Disponible: '
                '${available.toStringAsFixed(2)}';
          }
        } catch (e) {
          creditError =
              'No se pudo validar el crédito del cliente: ${_cleanError(e)}';
        }
      }
      if (creditError != null) {
        _processingLocal = false;
        state = state.copyWith(processingPayment: false, error: creditError);
        return;
      }
    }

    final orderId = state.order!.id;
    final checkId = state.check?.id;
    final methodId = state.selectedMethod!.id;
    final amount = state.amountReceived > 0
        ? state.amountReceived
        : state.totalToPay;
    final reference = state.reference;
    final customerId = state.customerId;
    final customerRnc = state.customerRnc;

    try {
      var payment = await _salesRepo.processPayment(
        orderId: orderId,
        checkId: checkId,
        paymentMethodId: methodId,
        amount: amount,
        reference: reference,
        customerId: customerId,
        customerRnc: customerRnc,
        cashierSessionId: state.cashSession?.id,
        changeAmount: state.change,
        // Tipo de comprobante seleccionado en el modal. Si es null, el RPC
        // backend cae al default_ncf_type del business (típicamente B02).
        fiscalType: state.selectedNcfType,
      );

      // PRD 6 §6.4: snapshot de tasa y equivalente USD para auditoría.
      // Se hace post-RPC con UPDATE idempotente (solo si el snapshot
      // aún es NULL — primera venta de este order). El RPC fiscal no
      // se toca; este es un side-effect best-effort para reportes
      // futuros. Si falla, el cobro sigue siendo válido.
      try {
        final businessId = await resolveBusinessIdOrNull(
          Supabase.instance.client,
          'auto',
        );
        if (businessId != null && businessId.isNotEmpty) {
          final usdSettings = await PosSettingsRepository(
            Supabase.instance.client,
          ).getUsdDisplaySettings(businessId);
          if (usdSettings.isUsable && usdSettings.rate != null) {
            final equivalent = calculateUsdEquivalent(
              dopTotal: Decimal.parse(amount.toStringAsFixed(2)),
              usdRate: usdSettings.rate,
            );
            if (equivalent != null) {
              await Supabase.instance.client
                  .from('orders')
                  .update({
                    'usd_rate_snapshot': usdSettings.rate.toString(),
                    'usd_equivalent': equivalent.toString(),
                  })
                  .eq('id', orderId)
                  .isFilter('usd_rate_snapshot', null);
            }
          }
        }
      } catch (e) {
        // Best-effort: no romper el cobro por un fallo de auditoría.
        debugPrint('PRD 6: no se pudo guardar snapshot USD: $e');
      }

      // Si el método es transferencia y el cajero seleccionó una cuenta
      // bancaria, escribimos el id en `payments.bank_account_id`. Lo
      // hacemos como UPDATE puntual post-RPC en vez de meterlo dentro
      // del RPC fiscal (zona sensible) — el round-trip extra vale la
      // pena para no tocar el motor de cobro.
      final selectedBank = state.selectedBankAccount;
      // Nota: usamos isTransferPayment (defensivo: matchea code o name)
      // pero también permitimos guardar la cuenta si el cajero la
      // seleccionó aunque la heurística de método transfer no haya
      // matcheado — la presencia de selectedBank es suficiente intent.
      if (selectedBank != null) {
        try {
          await Supabase.instance.client
              .from('payments')
              .update({'bank_account_id': selectedBank.id})
              .eq('id', payment.id);
          payment = payment.copyWith(bankAccountId: selectedBank.id);
        } catch (e) {
          // No bloquear el cobro por esto. La transferencia ya quedó
          // registrada; solo perdimos la trazabilidad de qué cuenta
          // recibió. Se puede corregir manual desde reportes.
          debugPrint('No se pudo asociar bank_account al payment: $e');
        }
      }

      FiscalDocument? fiscalDoc;
      try {
        fiscalDoc = await _salesRepo.getOrderFiscalDocument(orderId);
      } catch (_) {}

      // Para e-CF: invocamos emit-document SYNC y esperamos al security_code
      // antes de cerrar el flujo de cobro. Asi el ticket impreso al cliente
      // sale con QR valido (Norma DGII 01-2020). Si Alanube tarda mas de
      // 8s, el ticket sale con "EN PROCESO" y el cron + webhook actualizan
      // despues — el cobro no se traba.
      //
      // Mantenemos el state con processingPayment=true durante la espera
      // para que el spinner del modal siga visible al usuario.
      if (fiscalDoc != null && fiscalDoc.isElectronic) {
        final emitted = await _emitDocumentSync(
          fiscalDocumentId: fiscalDoc.id,
        );
        if (emitted != null) {
          fiscalDoc = emitted;
        }
      }

      state = state.copyWith(
        processingPayment: false,
        paymentProcessed: true,
        processedPayment: payment,
        fiscalDocument: fiscalDoc,
        offlineQueued: false,
      );
    } catch (e) {
      // Encolar también ante error de TRANSPORTE aunque `isConnected` siga en
      // true (ventana "conectado pero malo"): el clasificador cubre
      // Socket/Timeout + ClientException/handshake/connection reset/closed,
      // que antes se escapaban y perdían el cobro. El replay de
      // process_payment es idempotente (fn_process_payment_v3 devuelve el pago
      // existente si ya se cerró), así que reencolar es seguro.
      final shouldQueueOffline =
          !_connectivity.isConnected ||
          orderId.startsWith('local-order-') ||
          OfflinePosService.isTransportError(e);
      if (!shouldQueueOffline) {
        state = state.copyWith(
          processingPayment: false,
          error: 'Error al procesar pago: ${_cleanError(e)}',
        );
        return;
      }

      try {
        final businessId = await resolveBusinessIdOrNull(
          Supabase.instance.client,
          'auto',
        );
        if (businessId == null || businessId.isEmpty) {
          throw Exception('No se pudo identificar el negocio');
        }

        // Capturamos el momento del cobro offline. Este timestamp viaja en
        // el payload y, al sincronizar, el RPC fn_process_payment_v3 lo usa
        // como payments.created_at (vía p_paid_at). Así el reporte de
        // ventas, el cierre de caja y el fiscal_document quedan fechados
        // en la venta real, no en el sync.
        final paidAtOffline = DateTime.now().toUtc();

        // F4 (gated): si es serie de PAPEL y hay Hub alcanzable, asignamos el
        // NCF ahora para imprimir el comprobante en el acto. Si no, recibo
        // provisional (NCF al sincronizar) — comportamiento de hoy.
        final offlineNcf = await _allocateOfflineNcf(
          businessId: businessId,
          ncfType: state.selectedNcfType,
        );

        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'process_payment',
            'origin': state.order?.id.startsWith('local-order-') == true
                ? 'offline'
                : 'remote',
            'order_id': orderId,
            'check_id': checkId,
            'payment_method_id': methodId,
            'payment_method_code': state.selectedMethod?.code,
            'payment_method_name': state.selectedMethod?.name,
            'amount': amount,
            'reference': reference,
            'customer_id': customerId,
            'customer_rnc': customerRnc,
            'cashier_session_id': state.cashSession?.id,
            'change_amount': state.change,
            'paid_at': paidAtOffline.toIso8601String(),
            // F4: el NCF asignado offline (y su tipo) viajan para que el
            // server registre el fiscal_document con ESE número al sincronizar.
            if (offlineNcf != null) 'offline_ncf': offlineNcf.ncf,
            if (offlineNcf != null)
              'requested_ncf_type': state.selectedNcfType,
          },
        );

        final businessPaymentId =
            'local-payment-${DateTime.now().millisecondsSinceEpoch}';
        final localPayment = Payment(
          id: businessPaymentId,
          businessId: businessId,
          orderId: orderId,
          checkId: checkId,
          paymentMethodId: methodId,
          paymentMethodCode: state.selectedMethod?.code,
          paymentMethodName: state.selectedMethod?.name,
          amount: amount,
          reference: reference,
          changeAmount: state.change,
          status: 'pending',
          sessionId: state.cashSession?.id,
          createdAt: paidAtOffline.toLocal(),
        );

        // F4: si se asignó NCF offline, construimos un FiscalDocument local
        // para que el caller imprima el comprobante con su NCF en el acto. Los
        // montos definitivos los recompone el server al sincronizar; aquí el
        // número/tipo es lo que importa (la impresión toma los montos del
        // pedido, no de este documento).
        final localFiscalDoc = offlineNcf == null
            ? null
            : FiscalDocument(
                id: 'local-fd-$businessPaymentId',
                businessId: businessId,
                orderId: orderId,
                paymentId: businessPaymentId,
                ncfType: offlineNcf.ncfType,
                ncfNumber: offlineNcf.ncf,
                customerRnc: customerRnc,
                customerName: 'Consumidor Final',
                subtotal: amount,
                taxableAmount: amount,
                itbisAmount: 0,
                total: amount,
                status: 'active',
                issuedAt: paidAtOffline.toLocal(),
                isElectronic: false,
              );

        state = state.copyWith(
          processingPayment: false,
          paymentProcessed: true,
          processedPayment: localPayment,
          fiscalDocument: localFiscalDoc,
          offlineQueued: true,
          error: offlineNcf != null
              ? 'Comprobante emitido offline · NCF ${offlineNcf.ncf}. '
                  'Pendiente de sincronizar.'
              : 'Pago guardado en local. Pendiente de sincronizar.',
        );
      } catch (offlineError) {
        state = state.copyWith(
          processingPayment: false,
          error: 'Error al guardar pago offline: ${_cleanError(offlineError)}',
        );
      }
    } finally {
      _processingLocal = false;
    }
  }

  /// F4 (gated): intenta asignar un NCF de **papel** offline para este cobro.
  /// Delega en [allocateOfflineNcfPaper] (composición modelo b: serie central
  /// + Hub asignador). Null → recibo provisional.
  Future<NcfAssignment?> _allocateOfflineNcf({
    required String businessId,
    required String? ncfType,
  }) {
    return allocateOfflineNcfPaper(
      client: Supabase.instance.client,
      businessId: businessId,
      ncfType: ncfType,
      isConnected: () => _connectivity.isConnected,
    );
  }

  // ============================================================
  // 🔄 RESET
  // ============================================================

  void reset() {
    state = const PaymentState();
  }

  // ============================================================
  // 🔒 MÉTODOS FIJOS
  // ============================================================

  List<PaymentMethod> _getFixedPaymentMethods(String businessId) {
    return [
      PaymentMethod(
        id: 'cash',
        businessId: businessId,
        name: 'Efectivo',
        code: 'cash',
        isActive: true,
        requiresReference: false,
        icon: 'cash',
        position: 1,
      ),
      PaymentMethod(
        id: 'card',
        businessId: businessId,
        name: 'Tarjeta',
        code: 'card',
        isActive: true,
        requiresReference: true,
        icon: 'card',
        position: 2,
      ),
      PaymentMethod(
        id: 'transfer',
        businessId: businessId,
        name: 'Transferencia',
        code: 'transfer',
        isActive: true,
        requiresReference: true,
        icon: 'transfer',
        position: 3,
      ),
    ];
  }
}
