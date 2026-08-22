// Fase 3 Proveedores — la capa de datos de la relación comercial.
//
// El CRUD de proveedores ya vivía en `InventoryRepository` y ahí se queda: es
// la ficha de contacto y no cambió. Lo que se agrega acá es lo OTRO — cuánto
// le compraste, a qué precio, cuánto le debés y qué te provee— que no es una
// tabla más sino el cruce de cuatro.
//
// Dos reglas de esta capa:
//
//   1. **Nada obligatorio es opcional, nada opcional es obligatorio.** El
//      catálogo y las órdenes son la pantalla; las deudas, los vínculos y las
//      condiciones estructuradas son señales de apoyo. Si una señal falla
//      (migración sin aplicar, vista ausente, permiso), la pantalla se dibuja
//      sin ella en vez de caerse entera.
//
//   2. **Ningún `inFilter` sin trocear.** PostgREST arma la consulta en la
//      URL: con más de ~200 ids el servidor contesta 414 y la lectura se
//      pierde EN SILENCIO. Los ids van en lotes de [_kInFilterBatch].

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../presentation/inventory/state/inventory_state.dart';
import '../../presentation/inventory/state/supplier_overview_state.dart';

/// Ids por lote en un `inFilter`. 150 uuids ≈ 5,7 KB de URL: entra cómodo
/// bajo el límite de cualquier proxy razonable.
const int _kInFilterBatch = 150;

/// Cuántos meses de historia de compra alimentan la lista. Doce es el año
/// comercial: por debajo, un proveedor estacional parece muerto.
const int _kSpendMonths = 12;

class SuppliersRepository {
  final SupabaseClient _client;

  SuppliersRepository(this._client);

  /// `null` = todavía no se probó. Se recuerda por sesión para no repetir la
  /// consulta cara cada vez que se entra a la pantalla.
  bool? _termsSupported;
  bool? _linksSupported;
  bool? _creditsSupported;

  bool get termsSupported => _termsSupported == true;
  bool get linksSupported => _linksSupported == true;

  static const _supplierColumnsBase =
      'id, name, rnc, contact_name, phone, email, address, '
      'payment_terms, notes, is_active, created_at';

  static const _supplierColumnsFull =
      '$_supplierColumnsBase, payment_terms_type, payment_terms_days, '
      'payment_terms_from, min_order_amount, lead_time_days';

  /// True si el esquema todavía no tiene lo que se pidió.
  ///
  /// Los cuatro códigos NO son intercambiables y hay que cubrir los cuatro:
  ///   - `42703` — Postgres, columna inexistente. Es lo que devuelve un
  ///     SELECT.
  ///   - `PGRST204` — PostgREST, «no encuentro esa columna en su caché de
  ///     esquema». Es lo que devuelve un INSERT/UPDATE, y por eso mirar sólo
  ///     42703 dejaba la ESCRITURA sin red de contención.
  ///   - `42P01` / `PGRST205` — la tabla entera no existe.
  ///
  /// Deliberadamente NO incluye permisos ni red. Confundirlos apagaría la
  /// función para toda la sesión por un corte de wifi, y la pantalla diría
  /// «este negocio no tiene la tabla» cuando sí la tiene.
  static bool _isSchemaGap(Object e) =>
      e is PostgrestException &&
      (e.code == '42703' ||
          e.code == 'PGRST204' ||
          e.code == '42P01' ||
          e.code == 'PGRST205');

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  // ── Catálogo ─────────────────────────────────────────────────────────────

  /// Proveedores del negocio con sus condiciones estructuradas cuando el
  /// esquema las tiene.
  Future<List<InventorySupplierDetail>> getSuppliers(String businessId) async {
    if (_termsSupported != false) {
      try {
        final response = await _client
            .from('suppliers')
            .select(_supplierColumnsFull)
            .eq('business_id', businessId)
            .order('name');
        _termsSupported = true;
        return List<Map<String, dynamic>>.from(response)
            .map(InventorySupplierDetail.fromMap)
            .toList(growable: false);
      } catch (e) {
        if (!_isSchemaGap(e)) rethrow;
        _termsSupported = false;
        debugPrint(
          '[proveedores] sin condiciones estructuradas: falta la migración '
          '20260819_0003_supplier_terms_and_items',
        );
      }
    }
    final response = await _client
        .from('suppliers')
        .select(_supplierColumnsBase)
        .eq('business_id', businessId)
        .order('name');
    return List<Map<String, dynamic>>.from(response)
        .map(InventorySupplierDetail.fromMap)
        .toList(growable: false);
  }

  /// Catálogo liviano de insumos para el selector de «Vincular insumo».
  /// Vacío si la lectura falla: el diálogo lo dice en vez de quedarse girando.
  Future<List<InventoryItemSummary>> getItemCatalog(String businessId) async {
    final items = await _itemCatalogOrEmpty(businessId);
    return items.map((item) => item.asSummary()).toList(growable: false);
  }

  // ── La lista ─────────────────────────────────────────────────────────────

  /// La lista completa: cada proveedor con su volumen de compra, su deuda,
  /// su cumplimiento y qué provee.
  ///
  /// Cuatro lecturas en paralelo detrás del catálogo. Las tres de apoyo
  /// (órdenes, deudas, vínculos) devuelven vacío si fallan: sin ellas la
  /// pantalla sigue siendo el CRUD de siempre, que es exactamente lo que era
  /// antes de esta fase.
  Future<SuppliersOverview> getSuppliersOverview(String businessId) async {
    final suppliers = await getSuppliers(businessId);
    if (suppliers.isEmpty) {
      return SuppliersOverview.build(
        suppliers: const [],
        termsSupported: termsSupported,
        linksSupported: linksSupported,
      );
    }

    final results = await Future.wait<dynamic>([
      _ordersOrEmpty(businessId),
      _payablesOrEmpty(businessId),
      _itemCatalogOrEmpty(businessId),
      _declaredLinksOrEmpty(businessId),
    ]);

    final orders = results[0] as List<SupplierOrderRow>;
    final payables = results[1] as List<SupplierPayableRow>;
    final catalog = results[2] as List<_CatalogItem>;
    final links = results[3] as List<_LinkRow>;

    final itemNames = <String, String>{
      for (final item in catalog) item.id: item.name,
    };

    // «Provee» sale de dos lados: lo declarado en `supplier_items` y lo que
    // ya se decidió en la ficha del insumo (`preferred_supplier_id`). El
    // segundo existe desde antes y sería raro que la lista lo ignorara.
    final supplies = <String, List<String>>{};
    final seen = <String, Set<String>>{};
    void add(String supplierId, String itemId) {
      final names = supplies[supplierId] ??= <String>[];
      final ids = seen[supplierId] ??= <String>{};
      if (!ids.add(itemId)) return;
      names.add(itemNames[itemId] ?? 'Insumo');
    }

    for (final link in links) {
      add(link.supplierId, link.itemId);
    }
    final preferredCounts = <String, int>{};
    for (final item in catalog) {
      final preferred = item.preferredSupplierId;
      if (preferred == null || preferred.isEmpty) continue;
      preferredCounts[preferred] = (preferredCounts[preferred] ?? 0) + 1;
      add(preferred, item.id);
    }

    for (final names in supplies.values) {
      names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }

    return SuppliersOverview.build(
      suppliers: suppliers,
      orders: orders,
      payables: payables,
      supplies: supplies,
      preferredCounts: preferredCounts,
      termsSupported: termsSupported,
      linksSupported: linksSupported,
    );
  }

  /// Órdenes de los últimos [_kSpendMonths] meses. Señal de apoyo.
  Future<List<SupplierOrderRow>> _ordersOrEmpty(
    String businessId, {
    String? supplierId,
    int limit = 2000,
  }) async {
    final since = DateTime.now().subtract(
      const Duration(days: 31 * _kSpendMonths),
    );
    try {
      var query = _client
          .from('purchase_orders')
          .select(
            'id, supplier_id, status, total, created_at, received_date, '
            'expected_date, order_number, invoice_number',
          )
          .eq('business_id', businessId)
          .gte('created_at', since.toUtc().toIso8601String());
      if (supplierId != null) query = query.eq('supplier_id', supplierId);
      final response = await query
          .order('created_at', ascending: false)
          .limit(limit);
      return List<Map<String, dynamic>>.from(response)
          .map(SupplierOrderRow.fromMap)
          .whereType<SupplierOrderRow>()
          .toList(growable: false);
    } catch (e) {
      debugPrint('[proveedores] no se pudieron leer las órdenes: $e');
      return const [];
    }
  }

  /// Cuentas por pagar abiertas. `supplier_credits` llega con el módulo de
  /// Créditos (20260714_0002): sin él, la columna «Por pagar» queda en cero
  /// en vez de tumbar la lista.
  Future<List<SupplierPayableRow>> _payablesOrEmpty(
    String businessId, {
    String? supplierId,
  }) async {
    if (_creditsSupported == false) return const [];
    try {
      var query = _client
          .from('supplier_credits')
          .select(
            'supplier_id, purchase_order_id, invoice_number, ncf, '
            'original_amount, balance, due_date, status, created_at',
          )
          .eq('business_id', businessId)
          .inFilter('status', const ['pending', 'partial', 'overdue']);
      if (supplierId != null) query = query.eq('supplier_id', supplierId);
      final response = await query.order('due_date', ascending: true);
      _creditsSupported = true;
      return List<Map<String, dynamic>>.from(response)
          .map(SupplierPayableRow.fromMap)
          .whereType<SupplierPayableRow>()
          .toList(growable: false);
    } catch (e) {
      // Sólo un hueco de esquema apaga la señal para el resto de la sesión.
      if (_isSchemaGap(e)) _creditsSupported = false;
      debugPrint('[proveedores] no se pudieron leer las cuentas por pagar: $e');
      return const [];
    }
  }

  /// Catálogo liviano de insumos: sólo lo que la lista necesita para nombrar
  /// lo que cada proveedor provee.
  Future<List<_CatalogItem>> _itemCatalogOrEmpty(String businessId) async {
    Future<List<_CatalogItem>> fetch(String columns, {bool preferred = true}) async {
      final response = await _client
          .from('inventory_items')
          .select(columns)
          .eq('business_id', businessId)
          .order('name');
      return List<Map<String, dynamic>>.from(response)
          .map((row) => _CatalogItem.fromMap(row, withPreferred: preferred))
          .toList(growable: false);
    }

    try {
      return await fetch('id, name, sku, unit, preferred_supplier_id');
    } catch (e) {
      if (_isSchemaGap(e)) {
        // `preferred_supplier_id` llega con 20260813_0001.
        try {
          return await fetch('id, name, sku, unit', preferred: false);
        } catch (inner) {
          debugPrint('[proveedores] no se pudo leer el catálogo: $inner');
          return const [];
        }
      }
      debugPrint('[proveedores] no se pudo leer el catálogo: $e');
      return const [];
    }
  }

  /// Vínculos declarados en `supplier_items`. Vacío mientras la migración
  /// 20260819_0003 no esté aplicada.
  Future<List<_LinkRow>> _declaredLinksOrEmpty(
    String businessId, {
    String? supplierId,
  }) async {
    if (_linksSupported == false) return const [];
    try {
      var query = _client
          .from('supplier_items')
          .select(
            'id, supplier_id, inventory_item_id, supplier_code, '
            'purchase_unit, pack_size, last_price, min_order_qty, notes',
          )
          .eq('business_id', businessId)
          .eq('is_active', true);
      if (supplierId != null) query = query.eq('supplier_id', supplierId);
      final response = await query;
      _linksSupported = true;
      return List<Map<String, dynamic>>.from(
        response,
      ).map(_LinkRow.fromMap).toList(growable: false);
    } catch (e) {
      if (_isSchemaGap(e)) {
        _linksSupported = false;
        debugPrint(
          '[proveedores] sin vínculos proveedor↔insumo: falta la migración '
          '20260819_0003_supplier_terms_and_items',
        );
      } else {
        // Red o permisos: la pantalla se dibuja sin la columna «Provee»
        // declarada, pero NO se declara el esquema incompleto.
        debugPrint('[proveedores] no se pudieron leer los vínculos: $e');
      }
      return const [];
    }
  }

  // ── El detalle ───────────────────────────────────────────────────────────

  /// El interior de un proveedor: qué provee, con qué historia de precio,
  /// sus órdenes y su cuenta corriente.
  Future<SupplierDetail> getSupplierDetail({
    required String businessId,
    required String supplierId,
  }) async {
    final suppliers = await getSuppliers(businessId);
    final supplier = suppliers.firstWhere(
      (s) => s.id == supplierId,
      orElse: () => throw StateError('El proveedor ya no existe.'),
    );

    final results = await Future.wait<dynamic>([
      _ordersOrEmpty(businessId, supplierId: supplierId, limit: 400),
      _payablesOrEmpty(businessId, supplierId: supplierId),
      _declaredLinksOrEmpty(businessId, supplierId: supplierId),
      _itemCatalogOrEmpty(businessId),
    ]);

    final orders = results[0] as List<SupplierOrderRow>;
    final payables = results[1] as List<SupplierPayableRow>;
    final links = results[2] as List<_LinkRow>;
    final catalog = results[3] as List<_CatalogItem>;

    final catalogById = <String, InventoryItemSummary>{
      for (final item in catalog) item.id: item.asSummary(),
    };
    final preferredItemIds = <String>{
      for (final item in catalog)
        if (item.preferredSupplierId == supplierId) item.id,
    };

    final orderIds = await _orderIdsOf(businessId, supplierId);
    final lines = await _purchaseLinesOrEmpty(orderIds);

    final overview = SuppliersOverview.build(
      suppliers: [supplier],
      orders: orders,
      payables: payables,
      supplies: {
        supplierId: [
          for (final link in links) catalogById[link.itemId]?.name ?? 'Insumo',
        ],
      },
      preferredCounts: {supplierId: preferredItemIds.length},
      termsSupported: termsSupported,
      linksSupported: linksSupported,
    ).suppliers.first;

    return SupplierDetail.build(
      overview: overview,
      declared: links
          .map(
            (link) => SupplierItemLink(
              itemId: link.itemId,
              itemName: catalogById[link.itemId]?.name ?? 'Insumo',
              sku: catalogById[link.itemId]?.sku ?? '',
              unit: catalogById[link.itemId]?.unit ?? '',
              supplierCode: link.supplierCode,
              purchaseUnit: link.purchaseUnit.isNotEmpty
                  ? link.purchaseUnit
                  : (catalogById[link.itemId]?.purchaseUnit ?? ''),
              listPrice: link.lastPrice,
              linked: true,
            ),
          )
          .toList(growable: false),
      lines: lines,
      orders: orders,
      payables: payables,
      preferredItemIds: preferredItemIds,
      catalog: catalogById,
      linksSupported: linksSupported,
    );
  }

  /// Ids de TODAS las órdenes del proveedor (no sólo las de 12 meses): la
  /// historia de precio de un insumo que se compra dos veces al año necesita
  /// mirar más atrás que la lista.
  Future<List<_OrderStamp>> _orderIdsOf(
    String businessId,
    String supplierId,
  ) async {
    try {
      final response = await _client
          .from('purchase_orders')
          .select('id, created_at, received_date, status')
          .eq('business_id', businessId)
          .eq('supplier_id', supplierId)
          .neq('status', 'cancelled')
          .order('created_at', ascending: false)
          .limit(400);
      return List<Map<String, dynamic>>.from(response)
          .map(_OrderStamp.fromMap)
          .whereType<_OrderStamp>()
          .toList(growable: false);
    } catch (e) {
      debugPrint('[proveedores] no se pudieron leer las órdenes: $e');
      return const [];
    }
  }

  /// Líneas de las órdenes, en lotes. Vienen ordenadas de la compra más
  /// reciente a la más vieja, que es lo que [SupplierDetail.build] espera.
  Future<List<SupplierPurchaseLine>> _purchaseLinesOrEmpty(
    List<_OrderStamp> orders,
  ) async {
    if (orders.isEmpty) return const [];
    final stampById = <String, _OrderStamp>{for (final o in orders) o.id: o};
    final ids = stampById.keys.toList(growable: false);
    final rows = <Map<String, dynamic>>[];

    try {
      for (var start = 0; start < ids.length; start += _kInFilterBatch) {
        final end = start + _kInFilterBatch;
        final batch = ids.sublist(start, end > ids.length ? ids.length : end);
        final response = await _client
            .from('purchase_order_items')
            .select(
              'purchase_order_id, inventory_item_id, unit_cost, '
              'quantity_ordered, quantity_received',
            )
            .inFilter('purchase_order_id', batch);
        rows.addAll(List<Map<String, dynamic>>.from(response));
      }
    } catch (e) {
      debugPrint('[proveedores] no se pudieron leer las líneas: $e');
      return const [];
    }

    final lines = <SupplierPurchaseLine>[];
    for (final row in rows) {
      final itemId = row['inventory_item_id']?.toString();
      if (itemId == null || itemId.isEmpty) continue;
      final stamp = stampById[row['purchase_order_id']?.toString() ?? ''];
      lines.add(
        SupplierPurchaseLine(
          itemId: itemId,
          unitCost: _toDouble(row['unit_cost']),
          quantity: _toDouble(row['quantity_received']) > 0
              ? _toDouble(row['quantity_received'])
              : _toDouble(row['quantity_ordered']),
          at: stamp?.at,
        ),
      );
    }

    lines.sort((a, b) {
      final ad = a.at ?? DateTime(1970);
      final bd = b.at ?? DateTime(1970);
      return bd.compareTo(ad);
    });
    return lines;
  }

  // ── Escrituras ───────────────────────────────────────────────────────────

  /// Alta o edición de la ficha, con las condiciones estructuradas cuando el
  /// esquema las soporta.
  ///
  /// Devuelve el id del proveedor. En un esquema viejo los campos nuevos se
  /// descartan y el resto se guarda igual: perder el plazo estructurado es
  /// molesto, perder la ficha entera es un bug.
  Future<String> saveSupplier({
    required String businessId,
    String? supplierId,
    required String name,
    String? rnc,
    String? contactName,
    String? phone,
    String? email,
    String? address,
    String? paymentTerms,
    String? notes,
    bool isActive = true,
    String? termsType,
    int? termsDays,
    String? termsFrom,
    double? minOrderAmount,
    int? leadTimeDays,
  }) async {
    final base = <String, dynamic>{
      'name': name,
      'rnc': rnc,
      'contact_name': contactName,
      'phone': phone,
      'email': email,
      'address': address,
      'payment_terms': paymentTerms,
      'notes': notes,
      'is_active': isActive,
    };
    final extended = <String, dynamic>{
      ...base,
      'payment_terms_type': termsType,
      // 0 y no null a propósito. `payment_terms_days` nació en la migración
      // 20260811_0001 como `int not null default 0`: mandarle null revienta
      // con 23502 en cualquier negocio que la haya aplicado, y ese error NO
      // es un hueco de esquema — se propagaría y la ficha no se guardaría.
      // El 0 además significa lo correcto: sin tipo, el resolvedor lo ignora
      // (ver SupplierTerms.fromSupplier) porque no distingue «contado» de
      // «sin configurar».
      'payment_terms_days': termsDays ?? 0,
      'payment_terms_from': termsFrom,
      'min_order_amount': minOrderAmount,
      'lead_time_days': leadTimeDays,
    };

    Future<String> write(Map<String, dynamic> body) async {
      if (supplierId != null) {
        await _client.from('suppliers').update(body).eq('id', supplierId);
        return supplierId;
      }
      // En el alta los nulos se quitan para no pisar defaults del esquema;
      // en la edición se MANDAN, porque vaciar un campo es una acción.
      final insert = Map<String, dynamic>.from(body)
        ..removeWhere((_, value) => value == null || value == '')
        ..['business_id'] = businessId;
      final response = await _client
          .from('suppliers')
          .insert(insert)
          .select('id')
          .single();
      return Map<String, dynamic>.from(response)['id'].toString();
    }

    if (_termsSupported != false) {
      try {
        final id = await write(extended);
        _termsSupported = true;
        return id;
      } catch (e) {
        // Sólo si faltan las columnas. Un error de red o una violación de
        // restricción tienen que llegar a la pantalla, no convertirse en un
        // guardado silencioso a medias.
        if (!_isSchemaGap(e)) rethrow;
        _termsSupported = false;
      }
    }
    return write(base);
  }

  /// Declara que este proveedor provee este insumo, con el código que él usa.
  ///
  /// Devuelve `false` cuando el esquema todavía no tiene `supplier_items`: la
  /// pantalla lo distingue de un fallo real y ofrece marcar el preferido en
  /// la ficha del insumo, que sí existe desde antes.
  Future<bool> linkItem({
    required String businessId,
    required String supplierId,
    required String itemId,
    String? supplierCode,
    String? purchaseUnit,
    double? packSize,
    double? listPrice,
    double? minOrderQty,
    String? notes,
  }) async {
    if (_linksSupported == false) return false;
    try {
      await _client.from('supplier_items').upsert({
        'business_id': businessId,
        'supplier_id': supplierId,
        'inventory_item_id': itemId,
        'supplier_code': supplierCode,
        'purchase_unit': purchaseUnit,
        'pack_size': packSize,
        'last_price': listPrice,
        'min_order_qty': minOrderQty,
        'notes': notes,
        'is_active': true,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'supplier_id,inventory_item_id');
      _linksSupported = true;
      return true;
    } catch (e) {
      if (_isSchemaGap(e)) {
        _linksSupported = false;
        return false;
      }
      rethrow;
    }
  }

  /// Quita el vínculo. No borra nada del insumo ni de las órdenes: sólo deja
  /// de declarar que este proveedor lo provee.
  Future<bool> unlinkItem({
    required String supplierId,
    required String itemId,
  }) async {
    if (_linksSupported == false) return false;
    try {
      await _client
          .from('supplier_items')
          .delete()
          .eq('supplier_id', supplierId)
          .eq('inventory_item_id', itemId);
      return true;
    } catch (e) {
      if (_isSchemaGap(e)) {
        _linksSupported = false;
        return false;
      }
      rethrow;
    }
  }

  /// Marca (o desmarca, con [supplierId] en null) al proveedor preferido del
  /// insumo. Es lo que hace que «Sugerencias de reorden» sepa a quién
  /// comprarle, y existe desde 20260813_0001.
  Future<bool> setPreferredSupplier({
    required String itemId,
    String? supplierId,
  }) async {
    try {
      await _client
          .from('inventory_items')
          .update({'preferred_supplier_id': supplierId})
          .eq('id', itemId);
      return true;
    } catch (e) {
      if (_isSchemaGap(e)) {
        debugPrint(
          '[proveedores] sin suplidor preferido: falta la migración '
          '20260813_0001_preferred_supplier',
        );
        return false;
      }
      rethrow;
    }
  }

  /// Proveedores del negocio que ya tienen ese RNC, excluyendo [exceptId].
  ///
  /// El número va a la factura fiscal y al 606: dos fichas con el mismo RNC
  /// son el mismo contribuyente cargado dos veces. La regla también vive en
  /// la base (índice único de 20260819_0003), pero ahí sólo se crea cuando
  /// los datos ya están limpios — así que la validación de la pantalla no es
  /// redundante todavía.
  Future<List<String>> findRncDuplicates({
    required String businessId,
    required String rnc,
    String? exceptId,
  }) async {
    final digits = rnc.replaceAll(RegExp(r'[^0-9A-Za-z]'), '');
    if (digits.isEmpty) return const [];
    try {
      final response = await _client
          .from('suppliers')
          .select('id, name, rnc')
          .eq('business_id', businessId)
          .not('rnc', 'is', null);
      return List<Map<String, dynamic>>.from(response)
          .where((row) {
            if (row['id']?.toString() == exceptId) return false;
            final other = (row['rnc']?.toString() ?? '').replaceAll(
              RegExp(r'[^0-9A-Za-z]'),
              '',
            );
            return other.isNotEmpty &&
                other.toUpperCase() == digits.toUpperCase();
          })
          .map((row) => row['name']?.toString() ?? 'Proveedor')
          .toList(growable: false);
    } catch (e) {
      debugPrint('[proveedores] no se pudo validar el RNC: $e');
      return const [];
    }
  }
}

// ── Filas internas ─────────────────────────────────────────────────────────

class _CatalogItem {
  final String id;
  final String name;
  final String sku;
  final String unit;
  final String? preferredSupplierId;

  const _CatalogItem({
    required this.id,
    required this.name,
    this.sku = '',
    this.unit = '',
    this.preferredSupplierId,
  });

  factory _CatalogItem.fromMap(
    Map<String, dynamic> map, {
    bool withPreferred = true,
  }) => _CatalogItem(
    id: map['id']?.toString() ?? '',
    name: map['name']?.toString() ?? 'Insumo',
    sku: map['sku']?.toString() ?? '',
    unit: map['unit']?.toString() ?? '',
    preferredSupplierId: withPreferred
        ? map['preferred_supplier_id']?.toString()
        : null,
  );

  InventoryItemSummary asSummary() => InventoryItemSummary(
    id: id,
    sku: sku,
    name: name,
    description: '',
    unit: unit,
    cost: 0,
    minStock: 0,
    maxStock: null,
    isActive: true,
    stock: 0,
  );
}

class _LinkRow {
  final String supplierId;
  final String itemId;
  final String supplierCode;
  final String purchaseUnit;
  final double? lastPrice;

  const _LinkRow({
    required this.supplierId,
    required this.itemId,
    this.supplierCode = '',
    this.purchaseUnit = '',
    this.lastPrice,
  });

  factory _LinkRow.fromMap(Map<String, dynamic> map) => _LinkRow(
    supplierId: map['supplier_id']?.toString() ?? '',
    itemId: map['inventory_item_id']?.toString() ?? '',
    supplierCode: map['supplier_code']?.toString() ?? '',
    purchaseUnit: map['purchase_unit']?.toString() ?? '',
    lastPrice: map['last_price'] == null
        ? null
        : SuppliersRepository._toDouble(map['last_price']),
  );
}

class _OrderStamp {
  final String id;
  final DateTime? at;

  const _OrderStamp({required this.id, this.at});

  static _OrderStamp? fromMap(Map<String, dynamic> map) {
    final id = map['id']?.toString();
    if (id == null || id.isEmpty) return null;
    // La fecha de RECEPCIÓN es la del precio: una orden creada en enero y
    // recibida en marzo se pagó a precio de marzo.
    final received = DateTime.tryParse(map['received_date']?.toString() ?? '');
    final created = DateTime.tryParse(map['created_at']?.toString() ?? '');
    return _OrderStamp(id: id, at: received ?? created);
  }
}
