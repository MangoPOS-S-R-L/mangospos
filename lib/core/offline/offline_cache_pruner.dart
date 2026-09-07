import 'package:flutter/foundation.dart';

import '../storage/storage_service.dart';

/// Borra los caches de LECTURA que quedaron de negocios que este equipo ya no
/// usa.
///
/// Por qué existe (medido el 2026-09-07 en un equipo real): el plist de
/// SharedPreferences pesaba **34 MB**, y SharedPreferences no es una base de
/// datos — carga el archivo ENTERO en memoria al primer acceso, en cada
/// arranque, muchas veces sobre una tablet barata.
///
/// El conteo de claves engañaba. Medido por TAMAÑO, el 86% eran caches de
/// lectura de negocios que no son el activo:
///
///   offline_catalog_                 7.24 MB (40%) en 18 claves
///   offline_reports_fiscal_summary_  5.98 MB (33%) en 15
///   offline_inventory_snapshot_      2.42 MB (13%) en 25
///
/// Los 214 borradores de orden (`offline_snapshot_`), que a simple vista
/// parecían el problema por ser los más numerosos, pesaban 0.70 MB — 3.8%.
///
/// **Qué NO toca, y por qué importa.** Solo se poda lo que se puede volver a
/// bajar del servidor. Todo lo que puede contener trabajo NO SUBIDO se queda:
/// borradores de orden, la cola offline, los mapas de ids, el op-log del Hub y
/// el roster. Borrar cualquiera de esos es exactamente el bug de "las cuentas
/// desaparecen" y la regla de no perder pendientes al cerrar sesión.
///
/// Tampoco toca el negocio ACTIVO: sus caches son los que hacen falta en la
/// próxima caída de red.
class OfflineCachePruner {
  OfflineCachePruner({StorageService? storage}) : _injected = storage;

  final StorageService? _injected;
  Future<StorageService> get _storage async =>
      _injected ?? await StorageService.getInstance();

  /// Familias de cache de LECTURA, todas con forma `<prefijo><businessId>`.
  /// Reconstruibles desde el servidor: perderlas cuesta una consulta, no un
  /// dato. Es la misma familia que ya borra el botón "Limpiar caché del
  /// sistema", pero acotada por negocio y automática.
  @visibleForTesting
  static const readCachePrefixes = <String>[
    'offline_catalog_',
    'offline_reports_fiscal_summary_',
    'offline_reports_sales_summary_',
    'offline_reports_cash_summary_',
    'offline_inventory_snapshot_',
    'offline_zones_snapshot_',
    'offline_business_settings_',
    'offline_dashboard_kpis_',
    'offline_dashboard_recent_orders_',
    'offline_dashboard_top_products_',
    'offline_dashboard_inventory_alerts_',
    'printing_cached_printers_',
    'printing_cached_ready_printers_',
  ];

  /// Prefijos que NUNCA se podan, ni aunque sean de otro negocio: pueden
  /// contener trabajo que todavía no subió a Supabase.
  ///
  /// Está como lista explícita —y no solo como "lo que no está en la de
  /// arriba"— para que agregar una familia nueva al podador obligue a mirar
  /// esta lista primero.
  @visibleForTesting
  static const neverPrunePrefixes = <String>[
    'offline_snapshot_', // borradores de orden
    'offline_queue_', // cola offline
    'offline_print_queue_',
    'offline_order_map_',
    'offline_item_map_',
    'offline_cash_session_map_',
    'offline_completed_ops_',
    'offline_completed_fingerprints_',
    'hub_oplog_', // op-log del Hub (legacy en SP)
    'mp_offline_roster_', // roster: sin él no hay login offline
    'retail_carts_index_',
  ];

  /// Borra los caches de lectura de todos los negocios menos [activeBusinessId].
  ///
  /// Best-effort y fuera del camino crítico: si algo falla, no pasa nada — el
  /// cache sobrante solo ocupa espacio. Devuelve cuántas claves se borraron.
  Future<int> pruneOtherBusinesses(String activeBusinessId) async {
    if (activeBusinessId.isEmpty) return 0;

    var borradas = 0;
    try {
      final storage = await _storage;
      for (final prefix in readCachePrefixes) {
        final keys = await storage.getKeysByPrefix(prefix);
        for (final key in keys) {
          if (key.contains(activeBusinessId)) continue; // el activo se queda
          if (_isProtected(key)) continue; // cinturón y tirantes
          await storage.delete(key);
          borradas++;
        }
      }
      if (borradas > 0) {
        debugPrint(
          '[OfflineCachePruner] $borradas caches de lectura de otros negocios '
          'borrados. Los borradores, la cola y el roster no se tocan.',
        );
      }
    } catch (e) {
      debugPrint('[OfflineCachePruner] poda falló (no crítico): $e');
    }
    return borradas;
  }

  /// Doble verificación por si una familia de [readCachePrefixes] llegara a
  /// solaparse con una protegida. Barato y evita un desastre silencioso.
  static bool _isProtected(String key) =>
      neverPrunePrefixes.any(key.startsWith);
}
