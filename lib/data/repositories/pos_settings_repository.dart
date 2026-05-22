import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final posSettingsRepositoryProvider = Provider<PosSettingsRepository>(
  (ref) => PosSettingsRepository(Supabase.instance.client),
);

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

  /// Modo compacto: un solo modal con efectivo + tarjeta + transferencia.
  /// Comportamiento actual del POS.
  static const String cashCloseCompact = 'compact';

  /// Modo detallado: wizard de 3 pasos (efectivo / tarjeta + transferencia /
  /// revision). Ambos modos son a ciegas durante el conteo.
  static const String cashCloseDetailed = 'detailed';

  final SupabaseClient _client;

  Future<String> getCashCloseMode(String businessId) async {
    try {
      final row = await _client
          .from('business_settings')
          .select('cash_close_mode')
          .eq('business_id', businessId)
          .maybeSingle();

      final raw = row?['cash_close_mode']?.toString();
      return raw == cashCloseDetailed ? cashCloseDetailed : cashCloseCompact;
    } catch (_) {
      return cashCloseCompact;
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
      final row = await _client
          .from('business_settings')
          .select('allow_recount')
          .eq('business_id', businessId)
          .maybeSingle();
      return row?['allow_recount'] == true;
    } catch (_) {
      return false;
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
      final row = await _client
          .from('business_settings')
          .select('prompt_people_count_on_table_open')
          .eq('business_id', businessId)
          .maybeSingle();

      return row?['prompt_people_count_on_table_open'] == true;
    } catch (_) {
      return false;
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

  Future<String> getReceiptItemDisplayMode(String businessId) async {
    final cached = _receiptModeCache[businessId];
    if (cached != null &&
        DateTime.now().difference(cached.cachedAt) < _receiptModeCacheTtl) {
      return cached.mode;
    }

    try {
      final row = await _client
          .from('business_settings')
          .select('receipt_item_display_mode')
          .eq('business_id', businessId)
          .maybeSingle();

      final mode = row?['receipt_item_display_mode']?.toString();
      final normalized = mode == receiptItemsSeparate
          ? receiptItemsSeparate
          : receiptItemsGrouped;
      _receiptModeCache[businessId] = _CachedReceiptMode(
        normalized,
        DateTime.now(),
      );
      return normalized;
    } catch (_) {
      return receiptItemsGrouped;
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

  /// Printing v2 — Slice B: lee los flags de multi-copia automática para
  /// pre-cuenta y recibo. Default false si la fila no existe o falla.
  /// Cuando true, el orchestrator imprime en TODAS las impresoras del
  /// tipo paralelo (sin picker, sin fijada).
  Future<({bool precheck, bool receipt})> getPrintMultiCopyModes(
    String businessId,
  ) async {
    try {
      final row = await _client
          .from('business_settings')
          .select(
              'print_precheck_multi_copy, print_receipt_multi_copy')
          .eq('business_id', businessId)
          .maybeSingle();
      final precheck = row?['print_precheck_multi_copy'] == true;
      final receipt = row?['print_receipt_multi_copy'] == true;
      return (precheck: precheck, receipt: receipt);
    } catch (_) {
      return (precheck: false, receipt: false);
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
    try {
      final row = await _client
          .from('business_settings')
          .select('kitchen_banner_dine_in, kitchen_banner_takeout')
          .eq('business_id', businessId)
          .maybeSingle();
      final dineIn = row?['kitchen_banner_dine_in'] != false;
      final takeout = row?['kitchen_banner_takeout'] != false;
      return (dineIn: dineIn, takeout: takeout);
    } catch (_) {
      return (dineIn: true, takeout: true);
    }
  }

  // Feature flags por negocio (2026-05-13).

  /// Carga los feature flags del negocio. Si la fila no existe o la
  /// query falla, devuelve defaults (todo prendido = legacy).
  Future<BusinessFeatures> getBusinessFeatures(String businessId) async {
    try {
      final row = await _client
          .from('business_settings')
          .select(
            'sales_mode_table_enabled, sales_mode_manual_enabled, '
            'sales_mode_quick_enabled, sales_mode_delivery_enabled, '
            'kitchen_enabled, barcode_enabled, inventory_mode, '
            'multimesero_enabled, transfers_require_approval, '
            'kitchen_banner_dine_in, kitchen_banner_takeout',
          )
          .eq('business_id', businessId)
          .maybeSingle();

      if (row == null) return BusinessFeatures.defaults;
      return BusinessFeatures.fromMap(row);
    } catch (_) {
      return BusinessFeatures.defaults;
    }
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
    }, onConflict: 'business_id');
  }
}

class _CachedReceiptMode {
  const _CachedReceiptMode(this.mode, this.cachedAt);

  final String mode;
  final DateTime cachedAt;
}
