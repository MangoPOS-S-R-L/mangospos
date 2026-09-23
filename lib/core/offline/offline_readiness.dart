import 'dart:convert';

enum OfflineReadinessAction { bindDevice }

/// Estado de las copias que usa ventas en ESTE equipo. No hace peticiones de
/// red ni considera una descarga exitosa como prueba de persistencia.
class OfflineReadinessCheck {
  const OfflineReadinessCheck(
    this.label,
    this.ready,
    this.detail, {
    this.action,
  });
  final String label;
  final bool ready;
  final String detail;
  final OfflineReadinessAction? action;
}

class OfflineReadiness {
  const OfflineReadiness({required this.checks, required this.checkedAt});
  final List<OfflineReadinessCheck> checks;
  final DateTime checkedAt;
  bool get ready => checks.isNotEmpty && checks.every((c) => c.ready);
  int get missingCount => checks.where((c) => !c.ready).length;
}

class OfflineReadinessInspector {
  const OfflineReadinessInspector({
    required this.read,
    required this.checkAccess,
  });
  final Future<String?> Function(String key) read;
  final Future<OfflineReadinessCheck> Function(String businessId) checkAccess;

  Future<Object?> _load(String key) async {
    try {
      final raw = await read(key);
      return raw == null ? null : jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  List<Map>? _rows(Object? value) {
    if (value is! List || value.any((row) => row is! Map)) return null;
    return value.cast<Map>();
  }

  bool _usablePrinter(Map printer, String businessId) {
    if (printer['business_id'] != businessId ||
        printer['is_active'] == false ||
        (printer['id']?.toString().isEmpty ?? true)) {
      return false;
    }
    bool hasValue(Object? value) =>
        value?.toString().trim().isNotEmpty ?? false;
    return switch (printer['type']) {
      'network' => hasValue(printer['ip_address'] ?? printer['ip']),
      'bluetooth' => hasValue(printer['mac'] ?? printer['device_path']),
      'usb' => hasValue(printer['device_path']),
      _ => false,
    };
  }

  Future<OfflineReadiness> inspect(String businessId) async {
    final checks = <OfflineReadinessCheck>[];
    final catalog = await _load('offline_catalog_$businessId');
    final products = _rows(catalog is Map ? catalog['products'] : null);
    final validProducts =
        products != null &&
        products.isNotEmpty &&
        products.every(
          (p) =>
              (p['id']?.toString().isNotEmpty ?? false) &&
              (p['name']?.toString().isNotEmpty ?? false) &&
              p['price'] is num,
        );
    checks.add(
      OfflineReadinessCheck(
        'Productos y precios',
        validProducts,
        validProducts
            ? '${products.length} productos guardados en este equipo.'
            : 'Descarga el catálogo de este negocio.',
      ),
    );

    final taxes = await _load('offline_business_taxes_$businessId');
    final taxRows = _rows(taxes is Map ? taxes['rows'] : null);
    final validTaxes =
        taxRows != null &&
        taxRows.every((t) => t['id'] != null && t['rate'] is num);
    checks.add(
      OfflineReadinessCheck(
        'Impuestos',
        validTaxes,
        validTaxes
            ? 'Configuración de impuestos guardada.'
            : 'Falta una copia válida de los impuestos.',
      ),
    );

    final options = await _load('offline_item_options_$businessId');
    final modifiers = options is Map ? options['modifier_items'] : null;
    final groups = options is Map ? options['groups'] : null;
    final combos = options is Map ? options['combo_items'] : null;
    var missingOptions = 0;
    for (final p in products ?? <Map>[]) {
      final id = p['id']?.toString();
      final links = modifiers is Map ? modifiers[id] : null;
      final validLinks = _rows(links);
      if (validLinks == null ||
          validLinks.any(
            (link) => groups is! Map || groups[link['group_id']] is! Map,
          )) {
        missingOptions++;
      } else if (p['item_type'] == 'combo' &&
          _rows(combos is Map ? combos[id] : null) == null) {
        missingOptions++;
      }
    }
    final optionsReady = validProducts && missingOptions == 0;
    checks.add(
      OfflineReadinessCheck(
        'Modificadores y combos',
        optionsReady,
        optionsReady
            ? 'Opciones guardadas para los productos descargados.'
            : !validProducts
            ? 'Descarga primero el catálogo de productos.'
            : 'Faltan opciones de $missingOptions productos. Actualiza las descargas.',
      ),
    );

    final settings = await _load('offline_business_settings_$businessId');
    final row = settings is Map ? settings['row'] : null;
    checks.add(
      OfflineReadinessCheck(
        'Configuración del negocio',
        row is Map,
        row is Map
            ? 'Configuración guardada.'
            : 'Falta descargar la configuración.',
      ),
    );

    final zoneData = await _load('offline_zones_snapshot_$businessId');
    final zones = _rows(zoneData is Map ? zoneData['zones'] : null);
    final missingZones = <String>[];
    for (final zone in zones ?? <Map>[]) {
      final id = zone['id'];
      final tables = await _load('offline_zone_tables_snapshot_$id');
      if (id == null || _rows(tables is Map ? tables['rows'] : null) == null) {
        missingZones.add(zone['name']?.toString() ?? 'Zona sin nombre');
      }
    }
    final zonesReady = zones != null && missingZones.isEmpty;
    checks.add(
      OfflineReadinessCheck(
        'Zonas y mesas',
        zonesReady,
        zonesReady
            ? 'Mesas guardadas de ${zones.length} zonas.'
            : zones == null
            ? 'Falta descargar las zonas.'
            : 'Faltan mesas de: ${missingZones.join(', ')}.',
      ),
    );

    final areas = <String>{};
    for (final product in products ?? <Map>[]) {
      final codes = <String>{};
      for (final link in _rows(product['menu_item_print_areas']) ?? <Map>[]) {
        final area = link['print_areas'];
        if (area is Map && area['is_active'] != false) {
          final code = area['code']?.toString().trim() ?? '';
          if (code.isNotEmpty) codes.add(code);
        }
      }
      if (codes.isEmpty) {
        final legacy = product['print_area_code']?.toString().trim() ?? '';
        codes.add(legacy.isEmpty ? 'kitchen_hot' : legacy);
      }
      areas.addAll(codes);
    }
    final missingAreas = <String>[];
    final printerless = row is Map && row['printerless_kitchen'] == true;
    if (!printerless) {
      for (final area in areas) {
        final printers = _rows(
          await _load('printing_cached_printers_${businessId}_$area'),
        );
        if (printers == null ||
            !printers.any((p) => _usablePrinter(p, businessId))) {
          missingAreas.add(area);
        }
      }
    }
    final printersReady = row is Map && validProducts && missingAreas.isEmpty;
    checks.add(
      OfflineReadinessCheck(
        'Rutas de cocina',
        printersReady,
        printerless
            ? 'Cocina configurada sin impresión. Comprueba la conexión con la pantalla.'
            : printersReady
            ? 'Asignaciones guardadas. Comprueba que las impresoras estén conectadas.'
            : 'Faltan impresoras guardadas para: ${missingAreas.isEmpty ? 'las áreas del catálogo' : missingAreas.join(', ')}. Revisa Ajustes > Impresión.',
      ),
    );

    try {
      checks.add(await checkAccess(businessId));
    } catch (_) {
      checks.add(
        const OfflineReadinessCheck(
          'Acceso con PIN',
          false,
          'No se pudo verificar el acceso guardado.',
        ),
      );
    }
    return OfflineReadiness(
      checks: List.unmodifiable(checks),
      checkedAt: DateTime.now(),
    );
  }
}
