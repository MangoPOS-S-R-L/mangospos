import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/currency/usd_display_settings.dart';
import '../../core/offline/business_settings_offline_cache.dart';

export '../../core/currency/usd_display_settings.dart';

final posSettingsRepositoryProvider = Provider<PosSettingsRepository>(
  (ref) => PosSettingsRepository(Supabase.instance.client),
);

/// Provider del modo de presentación del descuento por negocio. Wrap del
/// getter cacheado del repo en un `FutureProvider.family` para que la UI
/// del cart pueda `ref.watch` sin acoplarse a FutureBuilder. La primera
/// invocación pega Supabase; las siguientes (dentro de 5 min) caen al
/// cache in-memory del repo.
final discountDisplayModeProvider =
    FutureProvider.family<String, String>((ref, businessId) async {
  if (businessId.isEmpty) {
    return PosSettingsRepository.discountPreDiscount;
  }
  final repo = ref.read(posSettingsRepositoryProvider);
  return repo.getDiscountDisplayMode(businessId);
});

/// Provider de la lista de routes ocultos del header por business. El
/// shell hace `ref.watch` para refiltrar destinos cuando el owner cambia
/// la config en ajustes. Default `[]` si la columna aún no existe.
final headerDestinationsDisabledProvider =
    FutureProvider.family<List<String>, String>((ref, businessId) async {
  if (businessId.isEmpty) return const <String>[];
  final repo = ref.read(posSettingsRepositoryProvider);
  return repo.getHeaderDestinationsDisabled(businessId);
});

/// Provider del flag "abrir gaveta en efectivo". El flow de pago lo
/// consulta cada vez que cobra cash para decidir si dispara la kick.
/// Default `false` si la columna aún no existe.
final openDrawerOnCashProvider =
    FutureProvider.family<bool, String>((ref, businessId) async {
  if (businessId.isEmpty) return false;
  final repo = ref.read(posSettingsRepositoryProvider);
  return repo.getOpenDrawerOnCash(businessId);
});

/// Niveles de inventario que el admin puede elegir.
///   - [none]: módulo oculto, sin tracking de stock. Default histórico.
///   - [basic]: 1:1 menu_item → inventory_item con stock por unidad.
///   - [advanced]: recetas completas (BOM) — cada menu_item descuenta
///     varios ingredientes con qty y unit configurables.
enum InventoryMode { none, basic, advanced }

extension InventoryModeX on InventoryMode {
  String get wireValue {
    switch (this) {
      case InventoryMode.none:
        return 'none';
      case InventoryMode.basic:
        return 'basic';
      case InventoryMode.advanced:
        return 'advanced';
    }
  }

  /// True cuando el módulo de Inventario debe estar visible (basic y
  /// advanced). El cajero ve la sección y puede consultar stock; los
  /// reportes están vivos.
  bool get isEnabled => this != InventoryMode.none;

  /// True cuando el admin puede editar recetas/BOM. Solo en advanced
  /// se expone el editor de ingredientes por menu_item.
  bool get hasRecipeEditor => this == InventoryMode.advanced;
}

InventoryMode _inventoryModeFromWire(String? raw) {
  switch (raw) {
    case 'basic':
      return InventoryMode.basic;
    case 'advanced':
      return InventoryMode.advanced;
    case 'none':
    default:
      return InventoryMode.none;
  }
}

// Las franjas (banners inversos) de la comanda de cocina se controlan
// con dos switches independientes: uno para la sección "PARA COMER AQUI"
// (items dine-in) y otro para "PARA LLEVAR" (items takeout). Cada
// switch decide si la franja se imprime para SU sección — los items
// siempre se separan por isTakeout. Las 4 combinaciones cubren todos
// los casos prácticos sin forzar opciones excluyentes:
//   ON  + ON  → ambas franjas (default, legacy)
//   ON  + OFF → solo franja en dine-in
//   OFF + ON  → solo franja en takeout (cocinero asume dine-in)
//   OFF + OFF → sin franjas, todos los items pelados
//
// Hubo una iteración previa con un enum `KitchenTicketSectionMode` de
// 4 valores excluyentes. La migración 20260518_0003 backfilleó los
// valores a estos dos booleanos; la columna vieja queda huérfana en BD
// para rollback.

/// Feature flags por negocio. Default: todo prendido (preserva el
/// comportamiento histórico del POS). El admin puede apagar lo que
/// no usa desde Ajustes → Modos de negocio.
class BusinessFeatures {
  final bool salesModeTableEnabled;
  final bool salesModeManualEnabled;
  final bool salesModeQuickEnabled;
  final bool salesModeDeliveryEnabled;
  final bool kitchenEnabled;
  final bool barcodeEnabled;
  final InventoryMode inventoryMode;
  final bool multimeseroEnabled;
  final bool transfersRequireApproval;
  final bool kitchenBannerDineIn;
  final bool kitchenBannerTakeout;

  /// Si true, los pedidos de delivery muestran un campo opcional de
  /// dirección de entrega. Default false (opt-in).
  final bool deliveryAddressEnabled;

  /// "Para llevar por defecto" por modo: cuando es true, las órdenes
  /// nuevas de ese modo arrancan marcadas para llevar (is_takeout). No
  /// aplica a mesas. Todos default false (opt-in).
  final bool defaultTakeoutQuick;
  final bool defaultTakeoutManual;
  final bool defaultTakeoutDelivery;

  const BusinessFeatures({
    this.salesModeTableEnabled = true,
    this.salesModeManualEnabled = true,
    this.salesModeQuickEnabled = true,
    this.salesModeDeliveryEnabled = true,
    this.kitchenEnabled = true,
    this.barcodeEnabled = true,
    this.inventoryMode = InventoryMode.none,
    this.multimeseroEnabled = false,
    this.transfersRequireApproval = false,
    this.kitchenBannerDineIn = true,
    this.kitchenBannerTakeout = true,
    this.deliveryAddressEnabled = false,
    this.defaultTakeoutQuick = false,
    this.defaultTakeoutManual = false,
    this.defaultTakeoutDelivery = false,
  });

  /// Defaults aplicados cuando no hay fila en business_settings o
  /// cuando la query falla. Todo prendido = comportamiento legacy.
  /// Inventario default `none` para no asumir tracking en negocios
  /// que históricamente no lo usaban.
  /// Multimesero default `false`: feature opt-in.
  static const BusinessFeatures defaults = BusinessFeatures();

  factory BusinessFeatures.fromMap(Map<String, dynamic> map) {
    return BusinessFeatures(
      salesModeTableEnabled: map['sales_mode_table_enabled'] != false,
      salesModeManualEnabled: map['sales_mode_manual_enabled'] != false,
      salesModeQuickEnabled: map['sales_mode_quick_enabled'] != false,
      salesModeDeliveryEnabled: map['sales_mode_delivery_enabled'] != false,
      kitchenEnabled: map['kitchen_enabled'] != false,
      barcodeEnabled: map['barcode_enabled'] != false,
      inventoryMode: _inventoryModeFromWire(map['inventory_mode']?.toString()),
      multimeseroEnabled: map['multimesero_enabled'] == true,
      transfersRequireApproval: map['transfers_require_approval'] == true,
      // Default `true` cuando la columna no viene en el SELECT o vale
      // NULL: preserva el comportamiento histórico (ambas franjas).
      kitchenBannerDineIn: map['kitchen_banner_dine_in'] != false,
      kitchenBannerTakeout: map['kitchen_banner_takeout'] != false,
      deliveryAddressEnabled: map['delivery_address_enabled'] == true,
      defaultTakeoutQuick: map['default_takeout_quick'] == true,
      defaultTakeoutManual: map['default_takeout_manual'] == true,
      defaultTakeoutDelivery: map['default_takeout_delivery'] == true,
    );
  }

  BusinessFeatures copyWith({
    bool? salesModeTableEnabled,
    bool? salesModeManualEnabled,
    bool? salesModeQuickEnabled,
    bool? salesModeDeliveryEnabled,
    bool? kitchenEnabled,
    bool? barcodeEnabled,
    InventoryMode? inventoryMode,
    bool? multimeseroEnabled,
    bool? transfersRequireApproval,
    bool? kitchenBannerDineIn,
    bool? kitchenBannerTakeout,
    bool? deliveryAddressEnabled,
    bool? defaultTakeoutQuick,
    bool? defaultTakeoutManual,
    bool? defaultTakeoutDelivery,
  }) {
    return BusinessFeatures(
      salesModeTableEnabled:
          salesModeTableEnabled ?? this.salesModeTableEnabled,
      salesModeManualEnabled:
          salesModeManualEnabled ?? this.salesModeManualEnabled,
      salesModeQuickEnabled:
          salesModeQuickEnabled ?? this.salesModeQuickEnabled,
      salesModeDeliveryEnabled:
          salesModeDeliveryEnabled ?? this.salesModeDeliveryEnabled,
      kitchenEnabled: kitchenEnabled ?? this.kitchenEnabled,
      barcodeEnabled: barcodeEnabled ?? this.barcodeEnabled,
      inventoryMode: inventoryMode ?? this.inventoryMode,
      multimeseroEnabled: multimeseroEnabled ?? this.multimeseroEnabled,
      transfersRequireApproval:
          transfersRequireApproval ?? this.transfersRequireApproval,
      kitchenBannerDineIn: kitchenBannerDineIn ?? this.kitchenBannerDineIn,
      kitchenBannerTakeout: kitchenBannerTakeout ?? this.kitchenBannerTakeout,
      deliveryAddressEnabled:
          deliveryAddressEnabled ?? this.deliveryAddressEnabled,
      defaultTakeoutQuick: defaultTakeoutQuick ?? this.defaultTakeoutQuick,
      defaultTakeoutManual: defaultTakeoutManual ?? this.defaultTakeoutManual,
      defaultTakeoutDelivery:
          defaultTakeoutDelivery ?? this.defaultTakeoutDelivery,
    );
  }

  /// Helper: ¿al menos un modo de venta está prendido? Útil para no
  /// dejar el sidebar 100% vacío por error de configuración. Si todo
  /// está apagado, la UI asume venta rápida (mínimo viable).
  bool get hasAnySalesMode =>
      salesModeTableEnabled ||
      salesModeManualEnabled ||
      salesModeQuickEnabled ||
      salesModeDeliveryEnabled;
}

class PosSettingsRepository {
  PosSettingsRepository(this._client);

  static const String receiptItemsGrouped = 'grouped';
  static const String receiptItemsSeparate = 'separate';
  static const Duration _receiptModeCacheTtl = Duration(minutes: 5);
  static final Map<String, _CachedReceiptMode> _receiptModeCache = {};

  /// Modo A: subtotal pre-descuento, ITBIS al % real del subtotal, descuento
  /// como línea sustractiva. Match con el ticket impreso histórico. Default.
  static const String discountPreDiscount = 'pre_discount';

  /// Modo B: subtotal derivado del total post-descuento (total / (1+tasa)),
  /// ITBIS recomputado, descuento como nota informativa fuera del sum.
  static const String discountPostDiscount = 'post_discount';
  static const Duration _discountModeCacheTtl = Duration(minutes: 5);
  static final Map<String, _CachedDiscountMode> _discountModeCache = {};

  /// Cache de la lista de routes ocultos del header. Misma estrategia
  /// que las demás settings — TTL corto para que el cambio se vea
  /// rápido sin pegar Supabase en cada render del shell.
  static const Duration _headerDisabledCacheTtl = Duration(minutes: 5);
  static final Map<String, _CachedStringList> _headerDisabledCache = {};

  /// Cache del flag "abrir gaveta en efectivo".
  static const Duration _openDrawerCacheTtl = Duration(minutes: 5);
  static final Map<String, _CachedBool> _openDrawerCache = {};

  /// Modo compacto: un solo modal con efectivo + tarjeta + transferencia.
  /// Comportamiento actual del POS.
  static const String cashCloseCompact = 'compact';

  /// Modo detallado: wizard de 3 pasos (efectivo / tarjeta + transferencia /
  /// revision). Ambos modos son a ciegas durante el conteo.
  static const String cashCloseDetailed = 'detailed';

  final SupabaseClient _client;
  final BusinessSettingsOfflineCache _settingsCache =
      BusinessSettingsOfflineCache();

  /// F6-3: lee la fila COMPLETA de `business_settings` y la cachea en disco
  /// (fire-and-forget) para que los getters tengan fallback offline. Los
  /// getters parsean su columna del row que esto devuelve.
  Future<Map<String, dynamic>?> _fetchAndCacheRow(String businessId) async {
    final row = await _client
        .from('business_settings')
        .select()
        .eq('business_id', businessId)
        .maybeSingle();
    if (row == null) return null;
    final map = Map<String, dynamic>.from(row);
    unawaited(_settingsCache.saveRow(businessId: businessId, row: map));
    return map;
  }

  /// Fila cacheada de `business_settings` (o null). Fallback offline de los
  /// getters: parsean su columna de aquí en vez de caer al default ciego.
  Future<Map<String, dynamic>?> _cachedRow(String businessId) =>
      _settingsCache.loadRow(businessId);

  /// F6-3: refresher proactivo para el OfflineSyncCoordinator — baja y cachea
  /// la config del negocio al reconectar/periódicamente. Best-effort.
  Future<void> refreshBusinessSettings(String businessId) async {
    await _fetchAndCacheRow(businessId);
  }

  Future<String> getCashCloseMode(String businessId) async {
    String parse(Map<String, dynamic>? row) {
      final raw = row?['cash_close_mode']?.toString();
      return raw == cashCloseDetailed ? cashCloseDetailed : cashCloseCompact;
    }

    try {
      return parse(await _fetchAndCacheRow(businessId));
    } catch (_) {
      return parse(await _cachedRow(businessId));
    }
  }

  Future<void> setCashCloseMode({
    required String businessId,
    required String mode,
  }) async {
    final normalized = mode == cashCloseDetailed
        ? cashCloseDetailed
        : cashCloseCompact;

    await _client.from('business_settings').upsert({
      'business_id': businessId,
      'cash_close_mode': normalized,
    }, onConflict: 'business_id');
  }

  /// Flag por negocio: si TRUE, durante el cierre de caja el cajero
  /// puede usar el botón "Volver a contar" / "Recontar" para limpiar
  /// los montos y empezar el flujo de nuevo (siempre antes de firmar).
  /// Default `false` (preserva comportamiento legacy).
  Future<bool> getAllowRecount(String businessId) async {
    try {
      final row = await _fetchAndCacheRow(businessId);
      return row?['allow_recount'] == true;
    } catch (_) {
      return (await _cachedRow(businessId))?['allow_recount'] == true;
    }
  }

  Future<void> setAllowRecount({
    required String businessId,
    required bool enabled,
  }) async {
    await _client.from('business_settings').upsert({
      'business_id': businessId,
      'allow_recount': enabled,
    }, onConflict: 'business_id');
  }

  /// Flag por negocio: si TRUE, el ticket de cierre de caja incluye un
  /// desglose de "Ventas por área de producción" para el periodo de la
  /// sesión. Default `false` (no cambia el ticket sin opt-in). Tolerante a
  /// que la columna aún no exista (cae a false).
  Future<bool> getCashClosePrintSalesByArea(String businessId) async {
    try {
      final row = await _fetchAndCacheRow(businessId);
      return row?['cash_close_print_sales_by_area'] == true;
    } catch (_) {
      return (await _cachedRow(businessId))?['cash_close_print_sales_by_area'] ==
          true;
    }
  }

  Future<void> setCashClosePrintSalesByArea({
    required String businessId,
    required bool enabled,
  }) async {
    await _client.from('business_settings').upsert({
      'business_id': businessId,
      'cash_close_print_sales_by_area': enabled,
    }, onConflict: 'business_id');
  }

  /// Auditoría: registra un evento "Volver a contar" en `audit_logs`.
  /// Captura los montos previos al reset para que el admin pueda ver
  /// patrones (e.g. cuánto varió el cajero entre conteos). Tolerante a
  /// fallos: si la inserción falla, no propaga la excepción para no
  /// bloquear al cajero por un error de auditoría.
  Future<void> recordCashRecount({
    required String businessId,
    required String sessionId,
    required double cashTotal,
    required double cardTotal,
    required double transferTotal,
  }) async {
    try {
      final userId = _client.auth.currentUser?.id;
      await _client.from('audit_logs').insert({
        'business_id': businessId,
        'user_id': userId,
        'action': 'cash_recount',
        'ref_table': 'cash_register_sessions',
        'ref_id': sessionId,
        'reason': jsonEncode({
          'cash': cashTotal,
          'card': cardTotal,
          'transfer': transferTotal,
        }),
      });
    } catch (_) {
      // Silencioso: el reconteo en sí es más importante que su auditoría.
    }
  }

  /// Devuelve el número de reconteos registrados para una sesión de
  /// caja. Se usa al imprimir el reporte de cierre para mostrar
  /// "Reconteos: N" en las estadísticas del turno.
  Future<int> getCashRecountCount(String sessionId) async {
    try {
      final rows = await _client
          .from('audit_logs')
          .select('id')
          .eq('action', 'cash_recount')
          .eq('ref_table', 'cash_register_sessions')
          .eq('ref_id', sessionId);
      return (rows as List).length;
    } catch (_) {
      return 0;
    }
  }

  Future<bool> getPromptPeopleCountOnTableOpen(String businessId) async {
    try {
      final row = await _fetchAndCacheRow(businessId);
      return row?['prompt_people_count_on_table_open'] == true;
    } catch (_) {
      return (await _cachedRow(businessId))?[
              'prompt_people_count_on_table_open'] ==
          true;
    }
  }

  Future<void> setPromptPeopleCountOnTableOpen({
    required String businessId,
    required bool enabled,
  }) async {
    await _client.from('business_settings').upsert({
      'business_id': businessId,
      'prompt_people_count_on_table_open': enabled,
    }, onConflict: 'business_id');
  }

  /// Toggle "pedir dirección de entrega" en delivery. Cuando es true, los
  /// pedidos de delivery muestran un campo opcional de dirección. Default
  /// false (opt-in). Con fallback al cache offline.
  Future<bool> getDeliveryAddressEnabled(String businessId) async {
    try {
      final row = await _fetchAndCacheRow(businessId);
      return row?['delivery_address_enabled'] == true;
    } catch (_) {
      return (await _cachedRow(businessId))?['delivery_address_enabled'] ==
          true;
    }
  }

  Future<void> setDeliveryAddressEnabled({
    required String businessId,
    required bool enabled,
  }) async {
    await _client.from('business_settings').upsert({
      'business_id': businessId,
      'delivery_address_enabled': enabled,
    }, onConflict: 'business_id');
  }

  Future<String> getReceiptItemDisplayMode(String businessId) async {
    final cached = _receiptModeCache[businessId];
    if (cached != null &&
        DateTime.now().difference(cached.cachedAt) < _receiptModeCacheTtl) {
      return cached.mode;
    }

    String parse(Map<String, dynamic>? row) {
      final mode = row?['receipt_item_display_mode']?.toString();
      return mode == receiptItemsSeparate
          ? receiptItemsSeparate
          : receiptItemsGrouped;
    }

    try {
      final normalized = parse(await _fetchAndCacheRow(businessId));
      _receiptModeCache[businessId] = _CachedReceiptMode(
        normalized,
        DateTime.now(),
      );
      return normalized;
    } catch (_) {
      return parse(await _cachedRow(businessId));
    }
  }

  Future<void> setReceiptItemDisplayMode({
    required String businessId,
    required String mode,
  }) async {
    final normalized = mode == receiptItemsSeparate
        ? receiptItemsSeparate
        : receiptItemsGrouped;

    await _client.from('business_settings').upsert({
      'business_id': businessId,
      'receipt_item_display_mode': normalized,
    }, onConflict: 'business_id');
    _receiptModeCache[businessId] = _CachedReceiptMode(
      normalized,
      DateTime.now(),
    );
  }

  /// Modo de presentación del descuento en facturas (modal historial +
  /// ticket impreso). Default `discountPreDiscount` cuando la columna aún
  /// no existe (pre-migración) o la query falla — preserva el render
  /// histórico para clientes que no toquen el toggle.
  Future<String> getDiscountDisplayMode(String businessId) async {
    final cached = _discountModeCache[businessId];
    if (cached != null &&
        DateTime.now().difference(cached.cachedAt) < _discountModeCacheTtl) {
      return cached.mode;
    }

    String parse(Map<String, dynamic>? row) {
      final mode = row?['discount_display_mode']?.toString();
      return mode == discountPostDiscount
          ? discountPostDiscount
          : discountPreDiscount;
    }

    try {
      final normalized = parse(await _fetchAndCacheRow(businessId));
      _discountModeCache[businessId] = _CachedDiscountMode(
        normalized,
        DateTime.now(),
      );
      return normalized;
    } catch (_) {
      return parse(await _cachedRow(businessId));
    }
  }

  Future<void> setDiscountDisplayMode({
    required String businessId,
    required String mode,
  }) async {
    final normalized = mode == discountPostDiscount
        ? discountPostDiscount
        : discountPreDiscount;

    await _client.from('business_settings').upsert({
      'business_id': businessId,
      'discount_display_mode': normalized,
    }, onConflict: 'business_id');
    _discountModeCache[businessId] = _CachedDiscountMode(
      normalized,
      DateTime.now(),
    );
  }

  /// Routes de destinos del header ocultados por el owner/admin. Default
  /// `[]` si la columna aún no existe (pre-migración) o si la query
  /// falla — preserva el comportamiento histórico (nada oculto).
  Future<List<String>> getHeaderDestinationsDisabled(String businessId) async {
    final cached = _headerDisabledCache[businessId];
    if (cached != null &&
        DateTime.now().difference(cached.cachedAt) <
            _headerDisabledCacheTtl) {
      return cached.value;
    }

    List<String> parse(Map<String, dynamic>? row) {
      final raw = row?['header_destinations_disabled'];
      return raw is List
          ? raw.map((e) => e.toString()).toList(growable: false)
          : const <String>[];
    }

    try {
      final list = parse(await _fetchAndCacheRow(businessId));
      _headerDisabledCache[businessId] = _CachedStringList(
        list,
        DateTime.now(),
      );
      return list;
    } catch (_) {
      return parse(await _cachedRow(businessId));
    }
  }

  Future<void> setHeaderDestinationsDisabled({
    required String businessId,
    required List<String> routes,
  }) async {
    // Dedup + normalización (trim) para evitar duplicados accidentales
    // si la UI guarda dos veces. Mantenemos el orden de inserción.
    final seen = <String>{};
    final normalized = <String>[];
    for (final r in routes) {
      final trimmed = r.trim();
      if (trimmed.isEmpty) continue;
      if (seen.add(trimmed)) normalized.add(trimmed);
    }

    await _client.from('business_settings').upsert({
      'business_id': businessId,
      'header_destinations_disabled': normalized,
    }, onConflict: 'business_id');
    _headerDisabledCache[businessId] = _CachedStringList(
      normalized,
      DateTime.now(),
    );
  }

  /// Flag "abrir gaveta en efectivo". Default `false` si la columna aún
  /// no existe (pre-migración) o la query falla — preserva el
  /// comportamiento de negocios sin gaveta física.
  Future<bool> getOpenDrawerOnCash(String businessId) async {
    final cached = _openDrawerCache[businessId];
    if (cached != null &&
        DateTime.now().difference(cached.cachedAt) < _openDrawerCacheTtl) {
      return cached.value;
    }

    try {
      final row = await _fetchAndCacheRow(businessId);
      final value = row?['open_drawer_on_cash'] == true;
      _openDrawerCache[businessId] = _CachedBool(value, DateTime.now());
      return value;
    } catch (_) {
      return (await _cachedRow(businessId))?['open_drawer_on_cash'] == true;
    }
  }

  Future<void> setOpenDrawerOnCash({
    required String businessId,
    required bool enabled,
  }) async {
    await _client.from('business_settings').upsert({
      'business_id': businessId,
      'open_drawer_on_cash': enabled,
    }, onConflict: 'business_id');
    _openDrawerCache[businessId] = _CachedBool(enabled, DateTime.now());
  }

  /// Printing v2 — Slice B: lee los flags de multi-copia automática para
  /// pre-cuenta y recibo. Default false si la fila no existe o falla.
  /// Cuando true, el orchestrator imprime en TODAS las impresoras del
  /// tipo paralelo (sin picker, sin fijada).
  Future<({bool precheck, bool receipt})> getPrintMultiCopyModes(
    String businessId,
  ) async {
    ({bool precheck, bool receipt}) parse(Map<String, dynamic>? row) => (
          precheck: row?['print_precheck_multi_copy'] == true,
          receipt: row?['print_receipt_multi_copy'] == true,
        );

    try {
      return parse(await _fetchAndCacheRow(businessId));
    } catch (_) {
      return parse(await _cachedRow(businessId));
    }
  }

  Future<void> setPrintMultiCopy({
    required String businessId,
    required String kind, // 'precheck' | 'receipt'
    required bool enabled,
  }) async {
    final column = kind == 'precheck'
        ? 'print_precheck_multi_copy'
        : 'print_receipt_multi_copy';
    await _client.from('business_settings').upsert({
      'business_id': businessId,
      column: enabled,
    }, onConflict: 'business_id');
  }

  /// Devuelve los dos flags de franjas de la comanda como un record. Si
  /// la fila no existe o la query falla, default a (true, true) para
  /// preservar el comportamiento legacy. Patrón gemelo a
  /// `getReceiptItemDisplayMode`; `printing_service` lo consume sin
  /// acoplarse al modelo `BusinessFeatures` completo.
  Future<({bool dineIn, bool takeout})> getKitchenBanners(
    String businessId,
  ) async {
    ({bool dineIn, bool takeout}) parse(Map<String, dynamic>? row) => (
          dineIn: row?['kitchen_banner_dine_in'] != false,
          takeout: row?['kitchen_banner_takeout'] != false,
        );

    try {
      return parse(await _fetchAndCacheRow(businessId));
    } catch (_) {
      return parse(await _cachedRow(businessId));
    }
  }

  // Feature flags por negocio (2026-05-13).

  /// Carga los feature flags del negocio. Si la fila no existe o la
  /// query falla, devuelve defaults (todo prendido = legacy).
  Future<BusinessFeatures> getBusinessFeatures(String businessId) async {
    BusinessFeatures parse(Map<String, dynamic>? row) => row == null
        ? BusinessFeatures.defaults
        : BusinessFeatures.fromMap(row);

    try {
      return parse(await _fetchAndCacheRow(businessId));
    } catch (_) {
      return parse(await _cachedRow(businessId));
    }
  }

  /// PRD 6 — Settings de moneda secundaria USD (display-only).
  /// Devuelve los 5 campos relevantes para mostrar el equivalente USD
  /// en checkout y recibos. Si la fila no existe o algo falla, retorna
  /// `enabled = false` que es el comportamiento legacy (no muestra
  /// nada).
  Future<UsdDisplaySettings> getUsdDisplaySettings(String businessId) async {
    UsdDisplaySettings parse(Map<String, dynamic>? row) => row == null
        ? const UsdDisplaySettings.disabled()
        : UsdDisplaySettings.fromMap(row);

    try {
      return parse(await _fetchAndCacheRow(businessId));
    } catch (_) {
      return parse(await _cachedRow(businessId));
    }
  }

  /// PRD 6 — Actualiza la config de USD. El trigger en DB pone
  /// `usd_rate_updated_at` automáticamente cuando `usd_rate` cambia.
  Future<void> setUsdDisplaySettings({
    required String businessId,
    required UsdDisplaySettings settings,
  }) async {
    await _client.from('business_settings').upsert({
      'business_id': businessId,
      'usd_display_enabled': settings.enabled,
      'usd_symbol': settings.symbol,
      // Supabase serializa Decimal a string para el numeric(10,4) en DB.
      'usd_rate': settings.rate?.toString(),
      'usd_symbol_position': settings.symbolPosition,
    }, onConflict: 'business_id');
  }

  /// Upsert atómico de los flags. La UI de admin envía el set completo
  /// al guardar; preferimos no hacer parciales para evitar inconsistencias
  /// si dos admins editan en simultáneo.
  Future<void> setBusinessFeatures({
    required String businessId,
    required BusinessFeatures features,
  }) async {
    await _client.from('business_settings').upsert({
      'business_id': businessId,
      'sales_mode_table_enabled': features.salesModeTableEnabled,
      'sales_mode_manual_enabled': features.salesModeManualEnabled,
      'sales_mode_quick_enabled': features.salesModeQuickEnabled,
      'sales_mode_delivery_enabled': features.salesModeDeliveryEnabled,
      'kitchen_enabled': features.kitchenEnabled,
      'barcode_enabled': features.barcodeEnabled,
      'inventory_mode': features.inventoryMode.wireValue,
      'multimesero_enabled': features.multimeseroEnabled,
      'transfers_require_approval': features.transfersRequireApproval,
      'kitchen_banner_dine_in': features.kitchenBannerDineIn,
      'kitchen_banner_takeout': features.kitchenBannerTakeout,
      'delivery_address_enabled': features.deliveryAddressEnabled,
      'default_takeout_quick': features.defaultTakeoutQuick,
      'default_takeout_manual': features.defaultTakeoutManual,
      'default_takeout_delivery': features.defaultTakeoutDelivery,
    }, onConflict: 'business_id');
  }
}

class _CachedReceiptMode {
  const _CachedReceiptMode(this.mode, this.cachedAt);

  final String mode;
  final DateTime cachedAt;
}

class _CachedDiscountMode {
  const _CachedDiscountMode(this.mode, this.cachedAt);

  final String mode;
  final DateTime cachedAt;
}

class _CachedStringList {
  const _CachedStringList(this.value, this.cachedAt);

  final List<String> value;
  final DateTime cachedAt;
}

class _CachedBool {
  const _CachedBool(this.value, this.cachedAt);

  final bool value;
  final DateTime cachedAt;
}
