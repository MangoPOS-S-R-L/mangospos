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

  const BusinessFeatures({
    this.salesModeTableEnabled = true,
    this.salesModeManualEnabled = true,
    this.salesModeQuickEnabled = true,
    this.salesModeDeliveryEnabled = true,
    this.kitchenEnabled = true,
    this.barcodeEnabled = true,
    this.inventoryMode = InventoryMode.none,
  });

  /// Defaults aplicados cuando no hay fila en business_settings o
  /// cuando la query falla. Todo prendido = comportamiento legacy.
  /// Inventario default `none` para no asumir tracking en negocios
  /// que históricamente no lo usaban.
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
            'kitchen_enabled, barcode_enabled, inventory_mode',
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
    }, onConflict: 'business_id');
  }
}

class _CachedReceiptMode {
  const _CachedReceiptMode(this.mode, this.cachedAt);

  final String mode;
  final DateTime cachedAt;
}
