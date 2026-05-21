// Repositorios data-layer de Printing v2 (Fase 1).
//
// Tres clases focalizadas (en lugar de inflar PrintingRepository que ya tiene
// >2000 líneas):
//   - MenuItemPrintAreaRepository   → N:M productos ↔ áreas.
//   - DevicePrinterBindingRepository → device ↔ impresora (USB/BT).
//   - PrinterHealthRepository       → status granular + RPC fn_report_printer_health.
//   - DeviceAgentRepository         → device_agents extendida + RPC heartbeat v2.
//   - PrintJobV2Repository          → claim/printed/failed via RPCs nuevas.
//
// Convenciones:
//   - Constructor recibe SupabaseClient explícitamente (testing friendly).
//   - Métodos retornan tipos del data-layer, no Map crudos.
//   - Errores se propagan como excepciones (PostgrestException, etc.) —
//     el caller decide cómo manejarlos.
//   - Sin caché compartida estática (a diferencia del legacy PrintingRepository)
//     para evitar test flakiness; si se necesita caché, el llamador la maneja.

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/printing_models.dart';
import '../models/printing_v2.dart';

// ═════════════════════════════════════════════════════════════════════════════
// 1) MenuItemPrintAreaRepository
// ═════════════════════════════════════════════════════════════════════════════

/// CRUD sobre la tabla `menu_item_print_areas`. Cuando hay filas para un
/// menu_item, el orchestrator las usa como fuente de verdad (ignora el
/// legacy `menu_items.print_area_code`).
class MenuItemPrintAreaRepository {
  final SupabaseClient _client;

  MenuItemPrintAreaRepository(this._client);

  /// Devuelve las áreas asignadas a un producto vía N:M. Hace join con
  /// `print_areas` para retornar objetos completos.
  Future<List<PrintArea>> getAreasForMenuItem(String menuItemId) async {
    final rows = await _client
        .from('menu_item_print_areas')
        .select(
          'print_area_id, print_areas!inner(id, business_id, name, code, is_active, color, display_order)',
        )
        .eq('menu_item_id', menuItemId);

    return (rows as List<dynamic>)
        .map((row) => PrintArea.fromMap(
              Map<String, dynamic>.from(
                  (row as Map)['print_areas'] as Map),
            ))
        .toList(growable: false);
  }

  /// Devuelve los IDs de áreas de un producto (más liviano que getAreasForMenuItem
  /// cuando solo se necesita comprobar pertenencia).
  Future<List<String>> getAreaIdsForMenuItem(String menuItemId) async {
    final rows = await _client
        .from('menu_item_print_areas')
        .select('print_area_id')
        .eq('menu_item_id', menuItemId);

    return (rows as List<dynamic>)
        .map((row) => (row as Map)['print_area_id'].toString())
        .toList(growable: false);
  }

  /// Reemplaza atómicamente el set de áreas de un producto. Borra las que
  /// no están en [newAreaIds] e inserta las nuevas. Si [newAreaIds] está
  /// vacío, deja al producto sin áreas N:M (cae al legacy print_area_code).
  Future<void> setAreasForMenuItem(
    String menuItemId,
    List<String> newAreaIds,
  ) async {
    final unique = newAreaIds.toSet().toList(growable: false);

    // 1) borrar las que ya no están
    if (unique.isEmpty) {
      await _client
          .from('menu_item_print_areas')
          .delete()
          .eq('menu_item_id', menuItemId);
      return;
    }

    await _client
        .from('menu_item_print_areas')
        .delete()
        .eq('menu_item_id', menuItemId)
        .not('print_area_id', 'in', '(${unique.map((id) => '"$id"').join(',')})');

    // 2) upsert de las nuevas
    final payload = unique
        .map((areaId) => {
              'menu_item_id': menuItemId,
              'print_area_id': areaId,
            })
        .toList(growable: false);

    await _client.from('menu_item_print_areas').upsert(payload);
  }

  Future<void> addArea(String menuItemId, String printAreaId) async {
    await _client.from('menu_item_print_areas').upsert({
      'menu_item_id': menuItemId,
      'print_area_id': printAreaId,
    });
  }

  Future<void> removeArea(String menuItemId, String printAreaId) async {
    await _client
        .from('menu_item_print_areas')
        .delete()
        .eq('menu_item_id', menuItemId)
        .eq('print_area_id', printAreaId);
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// 2) DevicePrinterBindingRepository
// ═════════════════════════════════════════════════════════════════════════════

/// CRUD sobre `device_printer_bindings`. Vincula un device físico al
/// dueño de una impresora USB/BT — el orchestrator usa el binding para
/// poner `target_device_id` en los print_jobs.
class DevicePrinterBindingRepository {
  final SupabaseClient _client;

  DevicePrinterBindingRepository(this._client);

  /// Bindings activos para un device (las impresoras que este device puede
  /// imprimir físicamente).
  Future<List<DevicePrinterBinding>> getBindingsForDevice(
      String deviceId) async {
    final rows = await _client
        .from('device_printer_bindings')
        .select()
        .eq('device_id', deviceId);

    return (rows as List<dynamic>)
        .map((row) =>
            DevicePrinterBinding.fromMap(Map<String, dynamic>.from(row as Map)))
        .toList(growable: false);
  }

  /// Bindings de una impresora (típicamente 1 — solo un device por impresora
  /// USB/BT con `is_local_owner = true`).
  Future<List<DevicePrinterBinding>> getBindingsForPrinter(
      String printerId) async {
    final rows = await _client
        .from('device_printer_bindings')
        .select()
        .eq('printer_id', printerId);

    return (rows as List<dynamic>)
        .map((row) =>
            DevicePrinterBinding.fromMap(Map<String, dynamic>.from(row as Map)))
        .toList(growable: false);
  }

  /// Crea/actualiza un binding. Usa upsert por (device_id, printer_id).
  Future<void> bind({
    required String deviceId,
    required String printerId,
    bool isLocalOwner = true,
    String? notes,
  }) async {
    await _client.from('device_printer_bindings').upsert({
      'device_id': deviceId,
      'printer_id': printerId,
      'is_local_owner': isLocalOwner,
      'notes': notes,
    });
  }

  Future<void> unbind({
    required String deviceId,
    required String printerId,
  }) async {
    await _client
        .from('device_printer_bindings')
        .delete()
        .eq('device_id', deviceId)
        .eq('printer_id', printerId);
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// 3) PrinterHealthRepository
// ═════════════════════════════════════════════════════════════════════════════

/// Lectura del estado de salud + reporte de health vía RPC.
///
/// El INSERT/UPDATE de la tabla `printer_health` se hace siempre por la RPC
/// `fn_report_printer_health` (security definer) — esta clase no expone
/// escritura directa.
class PrinterHealthRepository {
  final SupabaseClient _client;

  PrinterHealthRepository(this._client);

  Future<PrinterHealthRecord?> getHealth(String printerId) async {
    final row = await _client
        .from('printer_health')
        .select()
        .eq('printer_id', printerId)
        .maybeSingle();

    if (row == null) return null;
    return PrinterHealthRecord.fromMap(Map<String, dynamic>.from(row));
  }

  /// Health de todas las impresoras de un business. Hace inner join con
  /// `printers` para filtrar por business sin necesidad de RPC extra.
  Future<List<PrinterHealthRecord>> getHealthForBusiness(
      String businessId) async {
    final rows = await _client
        .from('printer_health')
        .select(
          'printer_id, status, last_checked_at, consecutive_failures, last_probed_by_device_id, details, updated_at, printers!inner(business_id)',
        )
        .eq('printers.business_id', businessId);

    return (rows as List<dynamic>)
        .map((row) => PrinterHealthRecord.fromMap(
            Map<String, dynamic>.from(row as Map)))
        .toList(growable: false);
  }

  /// Reporta el status actual de una impresora. Llamado por el agent
  /// después de cada health probe.
  Future<void> reportHealth({
    required String printerId,
    required PrinterHealthStatus status,
    String? deviceId,
    Map<String, dynamic> details = const {},
  }) async {
    await _client.rpc('fn_report_printer_health', params: {
      'p_printer_id': printerId,
      'p_status': status.wireName,
      'p_device_id': deviceId,
      'p_details': details,
    });
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// 4) DeviceAgentRepository
// ═════════════════════════════════════════════════════════════════════════════

/// Lectura de la tabla `device_agents` extendida + RPC heartbeat v2.
///
/// El `printer_heartbeat_scheduler.dart` actual ya llama la RPC con la
/// firma vieja (`p_id`, `p_agent_url`). Esta clase expone una versión que
/// además puede enviar la metadata nueva (agent_version, os, etc.) sin
/// romper al scheduler existente — los nuevos campos quedan en NULL si no
/// se proveen.
class DeviceAgentRepository {
  final SupabaseClient _client;

  DeviceAgentRepository(this._client);

  Future<DeviceAgent?> getAgent(String deviceId) async {
    final row = await _client
        .from('device_agents')
        .select()
        .eq('id', deviceId)
        .maybeSingle();

    if (row == null) return null;
    return DeviceAgent.fromMap(Map<String, dynamic>.from(row));
  }

  /// Todos los agents de un business ordenados por heartbeat reciente
  /// primero. Útil para dashboards.
  Future<List<DeviceAgent>> getAgentsForBusiness(String businessId) async {
    final rows = await _client
        .from('device_agents')
        .select()
        .eq('business_id', businessId)
        .order('last_heartbeat_at', ascending: false, nullsFirst: false);

    return (rows as List<dynamic>)
        .map((row) =>
            DeviceAgent.fromMap(Map<String, dynamic>.from(row as Map)))
        .toList(growable: false);
  }

  /// Heartbeat con metadata v2. Compatible con la versión legacy: si
  /// solo se pasan `deviceId` y `agentUrl`, el comportamiento es idéntico
  /// al `printer_heartbeat_scheduler.dart` actual.
  Future<void> reportHeartbeat({
    required String deviceId,
    String? agentUrl,
    String? agentVersion,
    String? os,
    String? hostname,
    List<String>? availableTransports,
    Map<String, dynamic>? metadata,
  }) async {
    await _client.rpc('fn_device_agent_heartbeat', params: {
      'p_id': deviceId,
      if (agentUrl != null) 'p_agent_url': agentUrl,
      if (agentVersion != null) 'p_agent_version': agentVersion,
      if (os != null) 'p_os': os,
      if (hostname != null) 'p_hostname': hostname,
      if (availableTransports != null)
        'p_available_transports': availableTransports,
      if (metadata != null) 'p_metadata': metadata,
    });
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// 5) PrintJobV2Repository
// ═════════════════════════════════════════════════════════════════════════════

/// Wrappers sobre las RPCs `fn_claim_print_job`, `fn_mark_print_job_printed`
/// y `fn_mark_print_job_failed` (v2). El INSERT del job sigue siendo
/// responsabilidad de quien encola (orchestrator o flujo legacy de
/// `printing_repository.dart`).
class PrintJobV2Repository {
  final SupabaseClient _client;

  PrintJobV2Repository(this._client);

  /// Claim atómico: marca el job como `in_progress` si todavía está en
  /// `pending` o `retry`. Retorna `true` si el claim fue exitoso (este
  /// device se ganó el job), `false` si otro agent lo tomó antes o el job
  /// ya está en otro estado.
  Future<bool> claim({
    required String jobId,
    required String deviceId,
  }) async {
    final result = await _client.rpc('fn_claim_print_job', params: {
      'p_job_id': jobId,
      'p_device_id': deviceId,
    });
    return result == true;
  }

  /// Marca el job como impreso exitosamente.
  Future<void> markPrinted(String jobId) async {
    await _client.rpc('fn_mark_print_job_printed', params: {
      'p_job_id': jobId,
    });
  }

  /// Marca el job como fallido. La RPC decide si lo deja en `retry` (con
  /// backoff exponencial) o lo manda a `dead` si superó `max_attempts`.
  /// Retorna el nuevo status string (`retry` o `dead`).
  Future<String> markFailed({
    required String jobId,
    required String error,
    String? transport,
  }) async {
    final result = await _client.rpc('fn_mark_print_job_failed', params: {
      'p_job_id': jobId,
      'p_error': error,
      if (transport != null) 'p_transport': transport,
    });
    return result?.toString() ?? 'retry';
  }
}
