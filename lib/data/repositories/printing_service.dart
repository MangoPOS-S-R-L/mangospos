// lib/data/repositories/printing_service.dart
import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/printing_models.dart';
import '../models/sales_models.dart';
import '../../core/network/connectivity_service.dart';
import '../../core/offline/offline_catalog_service.dart';
import '../../core/offline/offline_pos_service.dart';
import '../../core/storage/storage_service.dart';
import '../../core/printing/bluetooth_print_service.dart';
import '../../core/printing/ble_printer_connection_manager.dart';
import '../../core/printing/printerless_mode.dart';
import '../../services/printing/print_ticket_service.dart';
import '../../presentation/sales/state/sales_state.dart';
import 'pos_settings_repository.dart';
import 'printing_repository.dart';
import 'sales_repository.dart';

/// Resultado del intento de impresión de una comanda por área. Mismo
/// espíritu que [PrintOutcome] pero a nivel cocina:
///   - `directSuccess`: al menos una impresora del área aceptó el job
///     directo (TCP/USB/agent local).
///   - `escalatedToCloud`: todas las impresoras del área fallaron en
///     directo y el job se encoló en Supabase. El worker lo procesará
///     con retry/failover.
enum KitchenPrintOutcome {
  directSuccess,
  escalatedToCloud,
}

/// Resultado consolidado de enviar una orden completa a cocina. La UI
/// usa `escalatedAreas` para mostrar el snackbar amigable cuando una o
/// más áreas tuvieron que escalar al worker.
class KitchenSendResult {
  /// areaCode → dispatch id local (legacy).
  final Map<String, String> dispatchIds;

  /// Áreas que imprimieron directo (path feliz).
  final List<String> directAreas;

  /// Áreas donde la(s) impresora(s) no respondió y el job entró al
  /// cloud queue. La UI puede informar al cajero sin alarmas.
  final List<String> escalatedAreas;

  const KitchenSendResult({
    required this.dispatchIds,
    required this.directAreas,
    required this.escalatedAreas,
  });

  bool get hadAnyEscalation => escalatedAreas.isNotEmpty;
  bool get allDirect => escalatedAreas.isEmpty && directAreas.isNotEmpty;
}

/// Resultado de imprimir el ticket LISTO ("Imprimir al marcar listo").
/// Permite que el KDS avise cuando el ticket no salió porque el área no
/// tiene una impresora con la bandera `prints_receipts` activa, en vez de
/// fallar en silencio.
class ReadyPrintReport {
  /// Áreas que sí imprimieron (o escalaron) el ticket de listos.
  final int areasPrinted;

  /// Códigos de área que se saltaron por NO tener impresora de "listos"
  /// configurada (`prints_receipts = true`).
  final List<String> areasWithoutReadyPrinter;

  const ReadyPrintReport({
    required this.areasPrinted,
    required this.areasWithoutReadyPrinter,
  });

  static const empty = ReadyPrintReport(
    areasPrinted: 0,
    areasWithoutReadyPrinter: [],
  );

  bool get nothingPrinted => areasPrinted == 0;
  bool get missingReadyPrinter => areasWithoutReadyPrinter.isNotEmpty;
}

/// 🖨️ Servicio de Impresión con Agrupación por Departamento
/// Maneja la lógica de envío de órdenes a diferentes áreas de impresión
class NoAssignedKitchenPrinterException implements Exception {
  final List<String> areaCodes;

  const NoAssignedKitchenPrinterException(this.areaCodes);

  @override
  String toString() {
    if (areaCodes.isEmpty) {
      return 'NO_ASSIGNED_KITCHEN_PRINTER';
    }
    return 'NO_ASSIGNED_KITCHEN_PRINTER:${areaCodes.join(",")}';
  }
}

/// Lanzada cuando hay items sin `print_area_code` asignado al intentar
/// enviar a cocina. Lleva los nombres de los productos afectados para
/// que el caller pueda mostrar mensaje claro al admin: "Asigna un area
/// de impresion a estos productos en Productos → Editar".
class ItemsWithoutPrintAreaException implements Exception {
  final List<String> productNames;

  const ItemsWithoutPrintAreaException(this.productNames);

  @override
  String toString() {
    if (productNames.isEmpty) {
      return 'Hay productos sin área de impresión asignada. Edítalos y '
          'elige un área en Productos → Editar.';
    }
    final preview = productNames.take(5).join(', ');
    final extra = productNames.length > 5
        ? ' y ${productNames.length - 5} más'
        : '';
    return 'Productos sin área de impresión asignada: $preview$extra. '
        'Edítalos y elige un área en Productos → Editar.';
  }
}

/// Lanzada cuando un item trae un `print_area_code` que no corresponde a
/// ningún area configurada para el negocio. Casos típicos: area renombrada
/// o desactivada después de que el producto fue creado, o el code
/// `kitchen_hot` heredado que ya no existe como area.
class UnknownPrintAreaCodeException implements Exception {
  final String areaCode;

  const UnknownPrintAreaCodeException(this.areaCode);

  @override
  String toString() {
    return 'El area de impresión "$areaCode" no está configurada para '
        'este negocio. Crea esa área en Ajustes → Impresoras → Áreas o '
        'reasigna los productos a un área existente.';
  }
}

class PrintingService {
  final SupabaseClient _client;
  late final PrintingRepository _printingRepo;
  late final SalesRepository _salesRepo;
  final OfflinePosService _offlinePos = OfflinePosService();

  PrintingService(this._client) {
    _printingRepo = PrintingRepository(_client);
    _salesRepo = SalesRepository(_client);
  }

  /// Enviar orden a cocina con agrupación automática por departamento.
  ///
  /// Retorna [KitchenSendResult] con detalle por área para que la UI
  /// pueda diferenciar:
  ///   - Áreas que imprimieron directo (camino feliz).
  ///   - Áreas que escalaron al worker (la impresora no respondió pero
  ///     el ticket está en cola — snackbar amigable, no alarma).
  Future<KitchenSendResult> sendOrderToKitchen({
    required String orderId,
    required String businessId,
    String? fallbackTableName,
    String? fallbackWaiterName,
    // Ítems que el DEVICE ya sabe enviados aunque el server aún los tenga
    // en draft (se imprimieron por el camino local/offline y su replay no
    // ha corrido). Sin esto, el envío online reimprimía la comanda ENTERA
    // (rondas viejas + nuevas) cuando el server iba atrasado — caso real
    // Android 2026-07-25.
    Set<String> excludeItemIds = const {},
    // Áreas ya impresas localmente (replay offline): se marcan en server
    // pero NO se vuelven a imprimir.
    Set<String> excludeAreaCodes = const {},
    // En false fuerza ronda nueva en el KDS (sin fusionar con la comanda
    // anterior). El replay offline lo apaga: reproduce envíos encolados
    // seguidos y fusionaría rondas que en el salón fueron distintas.
    bool allowKitchenMerge = true,
  }) async {
    try {
      // 1. Obtener información de la orden
      final orderFuture = _salesRepo.getOrder(orderId);
      final itemsFuture = _salesRepo.getOrderItems(
        orderId,
        includeModifiers: true,
      );
      final orderDataFuture = _getOrderDisplayData(
        orderId,
        fallbackTableName: fallbackTableName,
        fallbackWaiterName: fallbackWaiterName,
      );
      final businessNameFuture = _getBusinessName(businessId);
      final receiptItemDisplayModeFuture = PosSettingsRepository(
        _client,
      ).getReceiptItemDisplayMode(businessId);
      final kitchenBannersFuture = PosSettingsRepository(
        _client,
      ).getKitchenBanners(businessId);
      final order = await orderFuture;
      if (order == null) {
        throw Exception('Orden no encontrada');
      }

      // 2. Obtener items de la orden
      final items = await itemsFuture;

      final draftItems = items
          .where((item) => item.status == 'draft' || item.status == 'open')
          .where((item) => !excludeItemIds.contains(item.id))
          .toList(growable: false);

      if (draftItems.isEmpty) {
        throw Exception('No hay items nuevos pendientes de enviar a cocina');
      }

      if (items.isEmpty) {
        throw Exception('La orden no tiene items');
      }

      // 3. Obtener información adicional para el ticket
      final orderData = await orderDataFuture;
      final businessName = await businessNameFuture;
      final receiptItemDisplayMode = await receiptItemDisplayModeFuture;
      final kitchenBanners = await kitchenBannersFuture;

      // 4. Agrupar items por área de impresión
      final itemsByArea = await _groupItemsByPrintArea(
        draftItems,
        businessId: businessId,
      );

      // 5. Resolver áreas e impresoras antes de marcar la orden.
      final printersByAreaCode = <String, List<PrinterConfig>>{};
      final areasByCode = <String, PrintArea>{};
      final resolvedAreas = await Future.wait(
        itemsByArea.keys.map((areaCode) async {
          final area = await _ensureAreaForCode(businessId, areaCode);
          final printers = await _getOrderPrintersWithOfflineFallback(
            businessId: businessId,
            areaId: area.id,
            areaCode: areaCode,
          );
          return (areaCode: areaCode, area: area, printers: printers);
        }),
      );

      for (final resolved in resolvedAreas) {
        areasByCode[resolved.areaCode] = resolved.area;
        printersByAreaCode[resolved.areaCode] = resolved.printers;
      }

      // Si no hay impresoras configuradas para "enviar a cocina",
      // la orden igual debe pasar a cocina; simplemente se omite la impresión.

      // 6. Marcar orden como enviada a cocina. `merged` indica que estos
      // ítems se sumaron a la comanda anterior (misma tarjeta del KDS), no
      // que abrieron una ronda nueva → el ticket sale marcado "AGREGADO".
      final sendResult = await _salesRepo.sendToKitchen(
        orderId,
        allowMerge: allowKitchenMerge,
      );

      final createdJobs = <String, String>{}; // areaCode -> local dispatch id
      final directAreas = <String>[];
      final escalatedAreas = <String>[];

      // Modo sin impresora: la orden entra al KDS igual, pero no se manda
      // papel a ninguna área. No abrimos modales aquí a propósito — el
      // mesero envía muchas rondas seguidas y la cocina ya ve todo en el
      // KDS. Ver core/printing/printerless_mode.dart.
      //
      // OJO: acá manda el flag del NEGOCIO, no el override del device. La
      // impresora de cocina es compartida — que esta tablet no tenga
      // impresora propia no significa que la cocina no deba recibir su
      // comanda.
      final printerless = await PrinterlessMode.businessEnabled(businessId);

      for (final entry in itemsByArea.entries) {
        final areaCode = entry.key;
        final areaItems = entry.value;

        // Área ya impresa localmente (replay): marcada arriba vía
        // sendToKitchen, sin reimpresión.
        if (excludeAreaCodes.contains(areaCode)) {
          continue;
        }

        if (printerless) {
          // Se reporta como "directa" para que la UI no muestre alarma de
          // escalado: no hay nada pendiente, simplemente no hubo papel.
          directAreas.add(areaCode);
          continue;
        }

        areasByCode[areaCode] ??= await _ensureAreaForCode(
          businessId,
          areaCode,
        );

        final printers = printersByAreaCode[areaCode] ?? const [];
        if (printers.isEmpty) {
          continue;
        }

        final dispatchId = _createLocalDispatchId(areaCode);
        createdJobs[areaCode] = dispatchId;

        final ticket = PrintTicketService.generateKitchenTicket(
          order: order,
          items: areaItems,
          tableName: orderData['tableName']?.toString() ?? 'N/A',
          waiterName: orderData['waiterName']?.toString(),
          cashierName: _resolveCashierName(),
          customerName: orderData['customerName']?.toString(),
          businessName: businessName,
          areaCode: areaCode,
          receiptItemDisplayMode: receiptItemDisplayMode,
          showDineInBanner: kitchenBanners.dineIn,
          showTakeoutBanner: kitchenBanners.takeout,
          isAddition: sendResult.merged,
        );

        final outcome = await _dispatchKitchenTicket(
          printers: printers,
          bytes: ticket.escPosCommands,
          areaCode: areaCode,
          fallbackData: {
            'title': 'COMANDA ${orderData['tableName'] ?? 'COCINA'}',
            'body':
                'Orden ${orderData['orderNumber'] ?? ''}\n'
                'Mesa: ${orderData['tableName'] ?? 'N/A'}\n'
                'Mesero: ${orderData['waiterName'] ?? 'N/A'}\n'
                'Cliente: ${orderData['customerName'] ?? 'N/A'}',
          },
          businessId: businessId,
          orderId: orderId,
        );

        if (outcome == KitchenPrintOutcome.escalatedToCloud) {
          escalatedAreas.add(areaCode);
        } else {
          directAreas.add(areaCode);
        }
      }

      return KitchenSendResult(
        dispatchIds: createdJobs,
        directAreas: directAreas,
        escalatedAreas: escalatedAreas,
      );
    } on NoAssignedKitchenPrinterException {
      rethrow;
    } on ItemsWithoutPrintAreaException {
      rethrow;
    } on UnknownPrintAreaCodeException {
      rethrow;
    } catch (e) {
      throw Exception('Error al enviar orden a cocina: $e');
    }
  }

  Future<KitchenPrintOutcome> _dispatchKitchenTicket({
    required List<PrinterConfig> printers,
    required List<int> bytes,
    required String areaCode,
    required Map<String, dynamic> fallbackData,
    // Sprint 1.3.b: necesarios para fallback al cloud queue cuando los
    // intentos directos fallan. Si NO se pasan, el comportamiento es el
    // legacy (los errores se propagan sin escalado a cloud).
    String? businessId,
    String? orderId,
  }) async {
    final errors = <String>[];
    String? firstDirectPrinterId;
    bool anyEscalated = false;

    for (final printer in printers) {
      try {
        final outcome = await _printKitchenTicketToPrinter(
          printer: printer,
          bytes: bytes,
          areaCode: areaCode,
          fallbackData: fallbackData,
          businessId: businessId,
          orderId: orderId,
        );
        if (outcome == KitchenPrintOutcome.directSuccess) {
          firstDirectPrinterId ??= printer.id;
        } else {
          anyEscalated = true;
        }
      } catch (e) {
        errors.add('${printer.name}: $e');
      }
    }

    if (firstDirectPrinterId != null) {
      if (errors.isNotEmpty) {
        debugPrint(
          '⚠️ Impresión parcial en área $areaCode. Impresora exitosa: $firstDirectPrinterId. Errores: ${errors.join(' | ')}',
        );
      }
      return KitchenPrintOutcome.directSuccess;
    }

    if (anyEscalated) {
      // Nadie imprimió directo pero al menos una pudo escalar al cloud
      // queue. El cajero verá un snackbar amigable.
      return KitchenPrintOutcome.escalatedToCloud;
    }

    if (errors.isNotEmpty) {
      throw Exception(errors.join(' | '));
    }

    // No había impresoras configuradas pero tampoco hubo errores. Tratamos
    // como directo (la orden se envió a cocina sin imprimir físicamente
    // — caso típico de "área sin impresora asignada").
    return KitchenPrintOutcome.directSuccess;
  }

  /// Convierte bytes ESC/POS a hex string para almacenar en print_jobs.
  String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Future<KitchenPrintOutcome> _printKitchenTicketToPrinter({
    required PrinterConfig printer,
    required List<int> bytes,
    required String areaCode,
    required Map<String, dynamic> fallbackData,
    String? businessId,
    String? orderId,
  }) async {
    // Sprint 1.3.b: el switch interno mantiene los 3 niveles de intento
    // directo (TCP/agent HTTP, USB directo/agent, BT directo). Si TODOS
    // los caminos directos fallan, el catch general escala el job al
    // cloud queue — el agent (Sprint 1.2) lo retomará con backoff
    // exponencial. Solo aplica si tenemos businessId (comportamiento
    // legacy preservado cuando se llama sin contexto).
    try {
      switch (printer.type) {
        case 'network':
          final ip = printer.ipAddress?.trim();
          if (ip == null || ip.isEmpty) {
            throw Exception('La impresora de red no tiene IP configurada.');
          }
          debugPrint(
            '🖨️ Ruta seleccionada -> NETWORK assigned printer ${printer.name} (${printer.id}) @ $ip:${printer.port ?? 9100}',
          );
          if (kIsWeb) {
            await _printingRepo.printRawViaAgent(
              ip: ip,
              port: printer.port ?? 9100,
              data: bytes,
            );
            return KitchenPrintOutcome.directSuccess;
          }
          // ─── PREFLIGHT (paridad con el test de página) ────────────
          // Si la IP cacheada no responde a una sonda TCP corta, releer
          // la fila fresca en BD ANTES de quemar los 4 intentos contra
          // una IP muerta (era el caso "el test imprime pero la comanda
          // no": el cache de impresoras por área servía una IP vieja).
          // Sin recovery por MAC aquí: en impresora de cocina compartida
          // la sonda puede fallar por puerto ocupado por otra tablet y
          // el escaneo LAN metería segundos de latencia — los retries
          // con jitter de abajo ya cubren ese caso.
          final targetIp = await _printingRepo.resolveReachableNetworkIp(
            printer: printer,
            cachedIp: ip,
            includeMacRecovery: false,
          );
          try {
            // attempts:4 (vs 2 por defecto) — en un setup multi-tablet a una
            // impresora de cocina COMPARTIDA, el puerto 9100 puede estar
            // ocupado varios segundos por otra tablet. Con jitter + lock por
            // IP (ver printRawDirectTcp), 4 intentos dan margen para ganar el
            // puerto y que la comanda NO se pierda antes de caer al fallback
            // de agente/cloud (que en solo-tablets no existe / no se drena).
            await _printingRepo.printRawDirectTcp(
              ip: targetIp,
              port: printer.port ?? 9100,
              data: bytes,
              attempts: 4,
            );
          } on PrintLikelyDeliveredException catch (e) {
            // Los bytes se enviaron (RST post-flush, normal en térmicas): la
            // comanda muy probablemente ya imprimió. NO usar el agente como
            // fallback — re-imprimiría la MISMA comanda (era el doble print).
            debugPrint(
              'ℹ️ ${printer.name}: conexión cerrada tras enviar (post-flush); '
              'no se reintenta para evitar comanda duplicada: $e',
            );
          } catch (e) {
            debugPrint(
              '⚠️ Direct TCP failed for ${printer.name}, using LAN agent fallback: $e',
            );
            await _printingRepo.printRawViaAgent(
              ip: targetIp,
              port: printer.port ?? 9100,
              data: bytes,
            );
          }
          return KitchenPrintOutcome.directSuccess;
        case 'usb':
          debugPrint(
            '🖨️ Ruta seleccionada -> LOCAL/USB assigned printer ${printer.name} (${printer.id}) path=${printer.devicePath ?? 'n/a'}',
          );
          if (kIsWeb) {
            if (!await _printingRepo.isAgentUp()) {
              throw Exception(
                'La impresora USB está asignada, pero este flujo necesita el Agente Local activo en la PC donde está conectada.',
              );
            }
            await _printingRepo.printRawViaAgentToPrinter(
              printer: printer,
              data: bytes,
              meta: const {'source': 'kitchen_order'},
            );
            return KitchenPrintOutcome.directSuccess;
          }

          try {
            await _printingRepo.printRawDirectUsb(printer: printer, data: bytes);
          } catch (e) {
            debugPrint(
              '⚠️ Direct USB failed for ${printer.name}, using local agent fallback: $e',
            );
            if (!await _printingRepo.isAgentUp()) rethrow;
            await _printingRepo.printRawViaAgentToPrinter(
              printer: printer,
              data: bytes,
              meta: const {'source': 'kitchen_order'},
            );
          }
          return KitchenPrintOutcome.directSuccess;
        case 'bluetooth':
          debugPrint(
            '🖨️ Ruta seleccionada -> BLUETOOTH direct GATT ${printer.name} (${printer.id})',
          );
          // PRD 5 F3: impresión BT directa via flutter_blue_plus.
          if (kIsWeb) {
            throw Exception(
              'La impresión Bluetooth no está disponible desde la Web.',
            );
          }
          final btId = (printer.mac ?? printer.devicePath ?? '').trim();
          if (btId.isEmpty) {
            throw Exception(
              'La impresora Bluetooth no tiene identificador para conectarse.',
            );
          }
          // En Android/iOS usamos la conexión PERSISTENTE (PRD BT — Fase 1/2 +
          // transporte Classic): reutiliza el enlace vivo (Classic/RFCOMM o
          // BLE, auto-elegido) en vez de conectar/desconectar por ticket, y
          // encola el job si la impresora está reconectando. En macOS/Windows
          // se mantiene el camino per-job de printRaw.
          if (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS) {
            // Misma clave de idempotencia que el cloud fallback → si el ticket
            // se reintenta, la cola lo deduplica y no se duplica el papel.
            final jobId = (orderId != null && orderId.isNotEmpty)
                ? 'kitchen-$orderId-$areaCode-${printer.id}'
                : 'kitchen-${DateTime.now().microsecondsSinceEpoch}'
                    '-$areaCode-${printer.id}';
            final result = await BlePrinterConnectionManager.instance
                .printOrEnqueue(address: btId, data: bytes, jobId: jobId);
            if (result == BlePrintResult.failed) {
              throw Exception(
                'No se pudo enviar el ticket a la impresora Bluetooth.',
              );
            }
            // printed o queued: aceptado. El manager es dueño del reintento y
            // del vaciado, así que NO caemos al fallback de cloud (que para
            // impresoras BT en solo-tablets no se drena, y evita doble print).
            return KitchenPrintOutcome.directSuccess;
          }
          await BluetoothPrintService.printRaw(remoteId: btId, data: bytes);
          return KitchenPrintOutcome.directSuccess;
        default:
          throw Exception('Tipo de impresora no soportado: ${printer.type}.');
      }
    } catch (e) {
      // FALLBACK FINAL: si tenemos businessId, escalamos al cloud queue.
      // El agent retomará con retry/backoff. Si no, propagamos error
      // legacy.
      if (businessId == null || businessId.isEmpty) {
        rethrow;
      }
      try {
        final idempotencyKey = (orderId != null && orderId.isNotEmpty)
            ? 'kitchen-$orderId-$areaCode-${printer.id}'
            : null;
        await _printingRepo.enqueuePrintJobToCloud(
          businessId: businessId,
          dataHex: _bytesToHex(bytes),
          kind: 'kitchen_order',
          areaCode: areaCode,
          printerId: printer.id,
          ip: printer.ipAddress,
          port: printer.port,
          idempotencyKey: idempotencyKey,
        );
        debugPrint(
          '🆘 Cloud queue fallback OK para ${printer.name}: agent retomará. (original: $e)',
        );
        // Importante: NO rethrow. El job ya está encolado; el cajero NO
        // ve error. Se imprimirá cuando la impresora vuelva o falla tras
        // 5 retries (entonces aparece en dashboard como failed).
        return KitchenPrintOutcome.escalatedToCloud;
      } catch (cloudErr) {
        debugPrint(
          '❌ Cloud queue fallback FALLÓ: $cloudErr (intento directo: $e)',
        );
        // Propagamos el error original (es más informativo para el cajero).
        rethrow;
      }
    }
  }

  /// Agrupa items por su `print_area_code` para enrutarlos a las
  /// impresoras correctas.
  ///
  /// Printing v2 (Slice 4.C): un producto puede tener MÚLTIPLES áreas
  /// asignadas vía `menu_item_print_areas` (N:M). Lookup batch para no
  /// hacer N queries.
  ///
  /// Estrategia de resolución por item:
  ///   1. Si productId está poblado, mirar el mapa N:M (solo online; sin
  ///      red se salta para no colgar).
  ///   2. Fallback legacy: `item.printAreaCode` (1-de-1). Si está poblado,
  ///      usarlo como única área del item.
  ///   3. Catálogo OFFLINE (ítems optimistas agregados sin red, que no
  ///      traen área): N:M del snapshot o `print_area_code` del producto.
  ///   4. Último recurso: 'kitchen_hot' — el mismo default que aplica
  ///      `fn_add_item_from_menu` en el server al insertar el item.
  Future<Map<String, List<OrderItem>>> _groupItemsByPrintArea(
    List<OrderItem> items, {
    String? businessId,
  }) async {
    final productIds = items
        .map((i) => i.productId)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);

    // Lookup batch del N:M. Si la query falla o la tabla está vacía,
    // el map queda vacío y todo cae al legacy print_area_code. Offline se
    // salta directo (colgaría sin timeout); el fallback al catálogo local
    // de abajo cubre el ruteo.
    final nmCodesByMenuItemId = <String, List<String>>{};
    if (productIds.isNotEmpty && ConnectivityService().isConnected) {
      try {
        final rows = await _client
            .from('menu_item_print_areas')
            .select('menu_item_id, print_areas!inner(code, is_active)')
            .inFilter('menu_item_id', productIds)
            .timeout(const Duration(seconds: 8));

        for (final row in (rows as List<dynamic>)) {
          final r = Map<String, dynamic>.from(row as Map);
          final mid = r['menu_item_id']?.toString();
          final areaMap = r['print_areas'] as Map?;
          if (mid == null || areaMap == null) continue;
          final isActive = areaMap['is_active'] != false;
          if (!isActive) continue;
          final code = areaMap['code']?.toString();
          if (code == null || code.isEmpty) continue;
          nmCodesByMenuItemId.putIfAbsent(mid, () => <String>[]).add(code);
        }
      } catch (e) {
        debugPrint('groupItemsByPrintArea: N:M lookup falló, fallback '
            'a print_area_code legacy: $e');
      }
    }

    final itemsByArea = <String, List<OrderItem>>{};
    final unresolved = <OrderItem>[];

    for (final item in items) {
      List<String> codesForItem;

      // 1) N:M (preferido si hay asignaciones).
      final pid = item.productId;
      if (pid != null && pid.isNotEmpty &&
          (nmCodesByMenuItemId[pid]?.isNotEmpty ?? false)) {
        codesForItem = nmCodesByMenuItemId[pid]!;
      } else {
        // 2) Legacy print_area_code (1-de-1).
        final legacyCode = item.printAreaCode?.trim();
        if (legacyCode != null && legacyCode.isNotEmpty) {
          codesForItem = [legacyCode];
        } else {
          // 3) Sin dato en el item (típico: ítem OPTIMISTA agregado
          //    offline — nunca pasó por el server que le copia el área).
          //    Se resuelve abajo contra el catálogo offline.
          unresolved.add(item);
          continue;
        }
      }

      for (final code in codesForItem) {
        itemsByArea.putIfAbsent(code, () => <OrderItem>[]).add(item);
      }
    }

    // Fallback catálogo offline: el snapshot guarda print_area_code y las
    // áreas N:M de cada menu_item. Último recurso: 'kitchen_hot', el MISMO
    // default que aplica fn_add_item_from_menu en el server al insertar —
    // así el ruteo offline es fiel al online. Antes estos ítems lanzaban
    // ItemsWithoutPrintAreaException y "Enviar a cocina" offline moría
    // completo (sin comanda y sin marcar los ítems como enviados).
    if (unresolved.isNotEmpty) {
      final catalogCodes = await _printAreaCodesFromCatalog(
        businessId: businessId,
        productIds: unresolved
            .map((i) => i.productId)
            .whereType<String>()
            .toSet(),
      );
      for (final item in unresolved) {
        final codes = catalogCodes[item.productId] ?? const ['kitchen_hot'];
        for (final code in codes) {
          itemsByArea.putIfAbsent(code, () => <OrderItem>[]).add(item);
        }
      }
    }

    return itemsByArea;
  }

  /// Resuelve áreas de impresión por producto desde el snapshot del catálogo
  /// offline: primero las N:M (`menu_item_print_areas`), si no el legacy
  /// `print_area_code`. Best-effort: mapa vacío si no hay snapshot.
  Future<Map<String, List<String>>> _printAreaCodesFromCatalog({
    required String? businessId,
    required Set<String> productIds,
  }) async {
    final result = <String, List<String>>{};
    if (businessId == null || businessId.isEmpty || productIds.isEmpty) {
      return result;
    }
    try {
      final snapshot = await OfflineCatalogService().loadSnapshot(businessId);
      if (snapshot == null) return result;
      for (final product in snapshot.products) {
        final pid = product['id']?.toString();
        if (pid == null || !productIds.contains(pid)) continue;

        final nmCodes = <String>[];
        final nmRaw = product['menu_item_print_areas'];
        if (nmRaw is List) {
          for (final entry in nmRaw) {
            if (entry is! Map) continue;
            final areaMap = entry['print_areas'];
            if (areaMap is! Map) continue;
            if (areaMap['is_active'] == false) continue;
            final code = areaMap['code']?.toString();
            if (code != null && code.isNotEmpty) nmCodes.add(code);
          }
        }
        if (nmCodes.isNotEmpty) {
          result[pid] = nmCodes;
          continue;
        }
        final legacy = product['print_area_code']?.toString().trim();
        if (legacy != null && legacy.isNotEmpty) {
          result[pid] = [legacy];
        }
      }
    } catch (e) {
      debugPrint('printAreaCodesFromCatalog: fallo leyendo snapshot: $e');
    }
    return result;
  }

  /// Obtener datos de la orden para mostrar en el ticket
  Future<Map<String, dynamic>> _getOrderDisplayData(
    String orderId, {
    String? fallbackTableName,
    String? fallbackWaiterName,
  }) async {
    try {
      final data = await _client
          .from('orders')
          .select('''
            *,
            table_sessions(
              people_count,
              customer_name,
              dining_tables(code, label),
              waiter:profiles!waiter_user_id(full_name),
              opener:profiles!opened_by(full_name)
            )
          ''')
          .eq('id', orderId)
          .maybeSingle();

      if (data == null) {
        throw Exception('Orden no encontrada');
      }

      final tableSession = data['table_sessions'] as Map<String, dynamic>?;
      final diningTable =
          tableSession?['dining_tables'] as Map<String, dynamic>?;

      // Cliente de la mesa (table_sessions.customer_name). El mesero lo
      // captura al abrir la mesa; se muestra en la comanda para que
      // cocina identifique el cliente.
      final customerName = (tableSession?['customer_name'] as String?)
          ?.trim();

      // Resolver nombre de la mesa
      String? resolvedTableName;
      final tableCode = diningTable?['code']?.toString().trim();
      final tableLabel = diningTable?['label']?.toString().trim();
      if (tableCode != null && tableCode.isNotEmpty) {
        resolvedTableName = tableCode;
      } else if (tableLabel != null && tableLabel.isNotEmpty) {
        resolvedTableName = tableLabel;
      }

      // Resolver mesero. Llamamos la RPC `fn_order_opener_name` que
      // prioriza `table_sessions.opened_by_employee_id` (PIN multimesero)
      // sobre `opened_by` (auth user) y bypassa RLS — los SELECTs
      // embebidos arriba pueden fallar en lecturas de `profiles` para
      // cajeros con permisos restringidos. Si la RPC devuelve null,
      // caemos a los datos embebidos como segundo nivel y al fallback
      // del caller como tercero.
      //
      // Importante para multimesero: la regla del producto es "el ticket
      // siempre dice quién ABRIÓ la mesa, no quién está agregando items
      // ahora", para que precuenta/factura/comanda sean consistentes.
      String? resolvedWaiterName;
      try {
        final rpcResult = await _client
            .rpc('fn_order_opener_name', params: {'p_order_id': orderId});
        final rpcName = rpcResult?.toString().trim();
        if (rpcName != null && rpcName.isNotEmpty) {
          resolvedWaiterName = rpcName;
        }
      } catch (e) {
        debugPrint('[audit] fn_order_opener_name falló en printing: $e');
      }

      if (resolvedWaiterName == null) {
        final waiterUser = tableSession?['waiter'] as Map<String, dynamic>?;
        final openerUser = tableSession?['opener'] as Map<String, dynamic>?;
        final waiterFullName = waiterUser?['full_name']?.toString().trim();
        final openerFullName = openerUser?['full_name']?.toString().trim();
        if (openerFullName != null && openerFullName.isNotEmpty) {
          resolvedWaiterName = openerFullName;
        } else if (waiterFullName != null && waiterFullName.isNotEmpty) {
          resolvedWaiterName = waiterFullName;
        }
      }

      return {
        'orderNumber':
            data['order_number']?.toString() ??
            data['id'].toString().substring(0, 8).toUpperCase(),
        'tableName': resolvedTableName ?? fallbackTableName,
        'waiterName': resolvedWaiterName ?? fallbackWaiterName,
        'customerName': (customerName != null && customerName.isNotEmpty)
            ? customerName
            : null,
        'peopleCount': tableSession?['people_count'] ?? 1,
        'createdAt': data['created_at'] != null
            ? DateTime.tryParse(data['created_at'].toString())
            : DateTime.now(),
      };
    } catch (e) {
      debugPrint('Error al obtener datos de orden: $e');
      return {
        'orderNumber': '',
        'tableName': null,
        'waiterName': null,
        'customerName': null,
        'peopleCount': 1,
        'createdAt': DateTime.now().toIso8601String(),
      };
    }
  }

  /// Resuelve el nombre del cajero/usuario activo para imprimir en el
  /// header y footer de la comanda. Cascada: metadata.full_name →
  /// metadata.name → metadata.display_name. Si nada de eso existe,
  /// devolvemos null y el ticket omite el bloque CAJERO.
  ///
  /// NO usamos email como fallback: los tickets impresos son
  /// documentos físicos que pueden quedar a la vista del cliente,
  /// y exponer info sensible del personal (email corporativo) no
  /// corresponde. Si no hay nombre, mejor omitir la línea.
  String? _resolveCashierName() {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return null;
      final metadata = user.userMetadata ?? const <String, dynamic>{};
      final raw = (metadata['full_name'] ??
              metadata['name'] ??
              metadata['display_name'] ??
              '')
          .toString()
          .trim();
      return raw.isEmpty ? null : raw;
    } catch (_) {
      return null;
    }
  }

  /// Nombre del negocio para el encabezado del ticket, con cache en disco:
  /// cada lectura online lo persiste y sin internet (o con la red colgada)
  /// se usa el último valor. Antes devolvía null offline y el ticket salía
  /// sin nombre — o peor, el fetch colgaba la comanda entera.
  Future<String?> _getBusinessName(String businessId) async {
    final cacheKey = 'printing_business_name_$businessId';
    Future<String?> cached() async {
      try {
        final storage = await StorageService.getInstance();
        final value = await storage.read(cacheKey);
        return (value == null || value.isEmpty) ? null : value;
      } catch (_) {
        return null;
      }
    }

    if (!ConnectivityService().isConnected) return cached();
    try {
      final data = await _client
          .from('businesses')
          .select('business_name, branch_name')
          .eq('id', businessId)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));

      final businessName = data?['business_name']?.toString().trim();
      final branchName = data?['branch_name']?.toString().trim();
      final resolved = (businessName != null && businessName.isNotEmpty)
          ? businessName
          : ((branchName != null && branchName.isNotEmpty)
              ? branchName
              : null);
      if (resolved != null) {
        try {
          final storage = await StorageService.getInstance();
          await storage.write(cacheKey, resolved);
        } catch (_) {}
      }
      return resolved;
    } catch (_) {
      return cached();
    }
  }

  /// Resuelve un area de impresión por código. Solo lookup — no crea
  /// areas automáticamente (el admin debe crearlas explícitamente en
  /// Ajustes → Impresoras → Áreas). Si no existe, lanza
  /// [UnknownPrintAreaCodeException] con el código ofensivo.
  Future<PrintArea> _ensureAreaForCode(
    String businessId,
    String areaCode,
  ) async {
    final existing = await _printingRepo.getPrintAreaByCode(
      businessId: businessId,
      code: areaCode,
    );
    if (existing != null) return existing;
    throw UnknownPrintAreaCodeException(areaCode);
  }

  Future<Map<String, String>> sendLocalOrderToKitchen({
    required String businessId,
    required CurrentOrderState localState,
    String tableName = 'LOCAL',
    String? waiterName,
    String? businessName,
  }) async {
    final order = localState.order;
    if (order == null) {
      throw Exception('No hay orden local para imprimir');
    }

    final draftItems = localState.items
        .where((item) => item.status == 'draft' || item.status == 'open')
        .toList(growable: false);
    if (draftItems.isEmpty) {
      throw Exception('No hay items locales pendientes de imprimir');
    }

    final itemsByArea = await _groupItemsByPrintArea(
      draftItems,
      businessId: businessId,
    );
    final resolvedBusinessName =
        await _getBusinessName(businessId) ?? businessName;
    final receiptItemDisplayMode = await PosSettingsRepository(
      _client,
    ).getReceiptItemDisplayMode(businessId);
    final kitchenBanners = await PosSettingsRepository(
      _client,
    ).getKitchenBanners(businessId);
    final createdJobs = <String, String>{};

    // Recolectamos áreas sin cache para reportarlas todas juntas al
    // final, en vez de fallar en la primera. Las que sí tienen cache se
    // imprimen normalmente. Los items de áreas sin impresora se encolan
    // como print jobs offline para que el worker los despache al sync.
    final areasSinImpresora = <String>[];

    // Modo sin impresora: ninguna área necesita impresora cacheada. Se
    // marcan todas como despachadas para que el replay online solo marque
    // los ítems en el server y no intente reimprimir. Igual que en el
    // camino online, decide el flag del NEGOCIO (impresora compartida).
    final printerless = await PrinterlessMode.businessEnabled(businessId);

    for (final entry in itemsByArea.entries) {
      final areaCode = entry.key;
      if (printerless) {
        createdJobs[areaCode] = _createLocalDispatchId(areaCode);
        continue;
      }
      final printers = await _readCachedOrderPrinters(
        businessId: businessId,
        areaCode: areaCode,
      );
      if (printers.isEmpty) {
        await _offlinePos.enqueuePrintJob(
          businessId: businessId,
          job: {
            'order_id': order.id,
            'area_code': areaCode,
            'reason': 'missing_cached_printer',
            'items': entry.value.map((item) => item.productName).toList(),
          },
        );
        areasSinImpresora.add(areaCode);
        continue;
      }

      final ticket = PrintTicketService.generateKitchenTicket(
        order: order,
        items: entry.value,
        tableName: tableName,
        waiterName: waiterName,
        cashierName: _resolveCashierName(),
        // Modo offline / pre-confirmación: el customer viene del state
        // local que el cajero capturó al abrir la mesa.
        customerName: localState.customerName,
        businessName: resolvedBusinessName,
        areaCode: areaCode,
        receiptItemDisplayMode: receiptItemDisplayMode,
        showDineInBanner: kitchenBanners.dineIn,
        showTakeoutBanner: kitchenBanners.takeout,
      );

      final dispatchId = _createLocalDispatchId(areaCode);
      createdJobs[areaCode] = dispatchId;

      await _dispatchKitchenTicket(
        printers: printers,
        bytes: ticket.escPosCommands,
        areaCode: areaCode,
        fallbackData: {
          'title': 'COMANDA $tableName',
          'body':
              'Orden local ${order.id}\n'
              'Mesa: $tableName\n'
              'Mesero: ${waiterName ?? 'N/A'}',
        },
        businessId: businessId,
        orderId: order.id,
      );
    }

    // Si quedaron áreas sin impresora cacheada (caso típico: prewarm
    // del login todavía no cubrió esta área, o el cajero está en un
    // device nuevo), intentamos resolver ONLINE inline antes de fallar.
    // Si funciona, imprimimos ahora; si no, encolamos y devolvemos un
    // error específico con los códigos de área faltantes.
    if (areasSinImpresora.isNotEmpty) {
      final stillMissing = <String>[];
      for (final areaCode in areasSinImpresora) {
        try {
          final area = await _ensureAreaForCode(businessId, areaCode);
          final printers = await _getOrderPrintersWithOfflineFallback(
            businessId: businessId,
            areaId: area.id,
            areaCode: areaCode,
          );
          if (printers.isEmpty) {
            stillMissing.add(areaCode);
            continue;
          }
          final itemsForArea = itemsByArea[areaCode] ?? const <OrderItem>[];
          final ticket = PrintTicketService.generateKitchenTicket(
            order: order,
            items: itemsForArea,
            tableName: tableName,
            waiterName: waiterName,
            cashierName: _resolveCashierName(),
            customerName: localState.customerName,
            businessName: resolvedBusinessName,
            areaCode: areaCode,
            receiptItemDisplayMode: receiptItemDisplayMode,
            showDineInBanner: kitchenBanners.dineIn,
            showTakeoutBanner: kitchenBanners.takeout,
          );
          final dispatchId = _createLocalDispatchId(areaCode);
          createdJobs[areaCode] = dispatchId;
          await _dispatchKitchenTicket(
            printers: printers,
            bytes: ticket.escPosCommands,
            areaCode: areaCode,
            fallbackData: {
              'title': 'COMANDA $tableName',
              'body':
                  'Orden local ${order.id}\n'
                  'Mesa: $tableName\n'
                  'Mesero: ${waiterName ?? 'N/A'}',
            },
            businessId: businessId,
            orderId: order.id,
          );
        } catch (e) {
          debugPrint(
            '[kitchen-local] fallback online falló para $areaCode: $e',
          );
          stillMissing.add(areaCode);
        }
      }

      if (stillMissing.isNotEmpty) {
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'confirm_local_order',
            'order_id': order.id,
            'origin': localState.origin,
            'item_count': draftItems.length,
            // El replay reimprime SOLO las áreas que quedaron sin impresora;
            // las ya impresas localmente solo se marcan (sin duplicar papel).
            'printed_areas': createdJobs.keys.toList(growable: false),
            'missing_areas': stillMissing,
          },
        );
        throw Exception(
          'No hay impresora asignada para: ${stillMissing.join(", ")}. '
          'Ve a Ajustes > Impresión y asigna una mientras estás online, '
          'luego vuelve a tocar "Enviar Pedido".',
        );
      }
    }

    await _offlinePos.enqueueAction(
      businessId: businessId,
      action: {
        'type': 'confirm_local_order',
        'order_id': order.id,
        'origin': localState.origin,
        'item_count': draftItems.length,
        // Todo salió impreso local: el replay solo debe MARCAR los items en
        // server (sin reimprimir la comanda — antes re-despachaba todas las
        // áreas = comanda duplicada al sincronizar).
        'printed_areas': createdJobs.keys.toList(growable: false),
      },
    );

    return createdJobs;
  }

  /// Reimprimir orden en un área específica
  /// Reimprimir items específicos
  Future<void> reprintItems({
    required String orderId,
    required String businessId,
    required List<OrderItem> items,
  }) async {
    try {
      final order = await _salesRepo.getOrder(orderId);
      if (order == null) throw Exception('Orden no encontrada');

      final businessName = await _getBusinessName(businessId);
      final receiptItemDisplayMode = await PosSettingsRepository(
        _client,
      ).getReceiptItemDisplayMode(businessId);
      final kitchenBanners = await PosSettingsRepository(
        _client,
      ).getKitchenBanners(businessId);
      final orderData = await _getOrderDisplayData(orderId);
      final itemsByArea = await _groupItemsByPrintArea(
        items,
        businessId: businessId,
      );

      for (final entry in itemsByArea.entries) {
        final areaCode = entry.key;
        final areaItems = entry.value;

        final area = await _ensureAreaForCode(businessId, areaCode);
        final printers = await _getOrderPrintersWithOfflineFallback(
          businessId: businessId,
          areaId: area.id,
          areaCode: areaCode,
        );

        if (printers.isEmpty) continue;

        final ticket = PrintTicketService.generateKitchenTicket(
          order: order,
          items: areaItems,
          tableName: orderData['tableName']?.toString() ?? 'N/A',
          waiterName: orderData['waiterName']?.toString(),
          cashierName: _resolveCashierName(),
          customerName: orderData['customerName']?.toString(),
          businessName: businessName,
          areaCode: areaCode,
          isReprint: true,
          receiptItemDisplayMode: receiptItemDisplayMode,
          showDineInBanner: kitchenBanners.dineIn,
          showTakeoutBanner: kitchenBanners.takeout,
        );

        await _dispatchKitchenTicket(
          printers: printers,
          bytes: ticket.escPosCommands,
          areaCode: areaCode,
          fallbackData: {
            'title': 'REIMPRESIÓN ${orderData['tableName'] ?? 'COCINA'}',
            'body': 'Orden ${orderData['orderNumber'] ?? ''}',
          },
          businessId: businessId,
          orderId: orderId,
        );
      }
    } on ItemsWithoutPrintAreaException {
      rethrow;
    } on UnknownPrintAreaCodeException {
      rethrow;
    } catch (e) {
      throw Exception('Error al reimprimir items: $e');
    }
  }

  Future<String> reprintOrderInArea({
    required String orderId,
    required String businessId,
    required String areaCode,
  }) async {
    await reprintItems(
      orderId: orderId,
      businessId: businessId,
      items: await _salesRepo.getOrderItems(orderId, includeModifiers: true),
    );
    return _createLocalDispatchId(areaCode);
  }

  String _createLocalDispatchId(String areaCode) {
    return 'LAN-$areaCode-${DateTime.now().microsecondsSinceEpoch}';
  }

  Future<ReadyPrintReport> printReadyOrderTicket({
    required String orderId,
    required String businessId,
    required List<String> itemIds,
    // Impresión a petición explícita del usuario (modal del KDS al completar
    // la comanda círculo a círculo): si el área no tiene impresora con
    // "Imprimir al marcar listo" activo, cae a sus impresoras normales de
    // comanda en vez de saltarse el área. El despacho automático ("Marcar
    // todo listo") NO usa este fallback — ahí manda la configuración.
    bool fallbackToAreaPrinters = false,
  }) async {
    try {
      final order = await _salesRepo.getOrder(orderId);
      if (order == null) throw Exception('Orden no encontrada');

      final items = await _salesRepo.getOrderItems(
        orderId,
        includeModifiers: true,
      );
      final readyItems = items
          .where((item) => itemIds.contains(item.id))
          .toList(growable: false);
      if (readyItems.isEmpty) return ReadyPrintReport.empty;

      final orderData = await _getOrderDisplayData(orderId);
      final businessName = await _getBusinessName(businessId);
      final receiptItemDisplayMode = await PosSettingsRepository(
        _client,
      ).getReceiptItemDisplayMode(businessId);
      final kitchenBanners = await PosSettingsRepository(
        _client,
      ).getKitchenBanners(businessId);
      final itemsByArea = await _groupItemsByPrintArea(
        readyItems,
        businessId: businessId,
      );

      var areasPrinted = 0;
      final areasWithoutReadyPrinter = <String>[];

      for (final entry in itemsByArea.entries) {
        final areaCode = entry.key;
        final areaItems = entry.value;
        final area = await _ensureAreaForCode(businessId, areaCode);
        var printers = await _getReadyPrintersWithOfflineFallback(
          businessId: businessId,
          areaId: area.id,
          areaCode: areaCode,
        );
        if (printers.isEmpty && fallbackToAreaPrinters) {
          try {
            printers = await _printingRepo.getPrintersForArea(area.id);
          } catch (_) {
            // Se reporta abajo como área sin impresora.
          }
        }
        if (printers.isEmpty) {
          // El área no tiene impresora con "Imprimir al marcar listo" activo
          // (ni impresora normal, si se pidió el fallback).
          areasWithoutReadyPrinter.add(areaCode);
          continue;
        }

        final ticket = PrintTicketService.generateKitchenTicket(
          order: order,
          items: areaItems,
          tableName: orderData['tableName']?.toString() ?? 'N/A',
          waiterName: orderData['waiterName']?.toString(),
          cashierName: _resolveCashierName(),
          customerName: orderData['customerName']?.toString(),
          businessName: businessName,
          areaCode: areaCode,
          isReprint: true,
          receiptItemDisplayMode: receiptItemDisplayMode,
          showDineInBanner: kitchenBanners.dineIn,
          showTakeoutBanner: kitchenBanners.takeout,
        );

        await _dispatchKitchenTicket(
          printers: printers,
          bytes: ticket.escPosCommands,
          areaCode: areaCode,
          fallbackData: {
            'title': 'LISTO ${orderData['tableName'] ?? 'COCINA'}',
            'body':
                'Orden ${orderData['orderNumber'] ?? ''}\n'
                'Mesa: ${orderData['tableName'] ?? 'N/A'}\n'
                'Estado: LISTO',
          },
          businessId: businessId,
          orderId: orderId,
        );
        areasPrinted++;
      }

      return ReadyPrintReport(
        areasPrinted: areasPrinted,
        areasWithoutReadyPrinter: areasWithoutReadyPrinter,
      );
    } on ItemsWithoutPrintAreaException {
      rethrow;
    } on UnknownPrintAreaCodeException {
      rethrow;
    } catch (e) {
      throw Exception('Error al imprimir comandas de listos: $e');
    }
  }

  /// Reimprime la COMANDA de una tarjeta del KDS (los ítems dados) en las
  /// impresoras NORMALES de comanda de cada área, con la marca REIMPRESIÓN.
  /// A diferencia de [printReadyOrderTicket] (ticket de "listo"), esto
  /// re-saca la comanda de cocina tal cual — para cuando el papel se perdió
  /// o hay dudas de qué llevaba, sin re-enviar la orden (que crearía otra
  /// ronda). Funciona también con ítems ya despachados/pagados (reimpresión
  /// desde "Completados hoy"). Devuelve el mismo reporte: áreas impresas +
  /// áreas sin impresora asignada.
  Future<ReadyPrintReport> reprintComandaTicket({
    required String orderId,
    required String businessId,
    required List<String> itemIds,
    // Área de la TARJETA que se está reimprimiendo (el KDS separa una tarjeta
    // por estación). Si viene y el agrupado la contiene, la reimpresión sale
    // SOLO por esa área — reimprimir la comanda del Bar no debe re-sacar el
    // papel de Cocina. Null (p. ej. desde "Completados hoy", que agrupa la
    // orden completa) = todas las áreas de los ítems.
    String? onlyAreaCode,
  }) async {
    try {
      final order = await _salesRepo.getOrder(orderId);
      if (order == null) throw Exception('Orden no encontrada');

      final items = await _salesRepo.getOrderItems(
        orderId,
        includeModifiers: true,
      );
      final targetItems = items
          .where((item) => itemIds.contains(item.id))
          .toList(growable: false);
      if (targetItems.isEmpty) return ReadyPrintReport.empty;

      final orderData = await _getOrderDisplayData(orderId);
      final businessName = await _getBusinessName(businessId);
      final receiptItemDisplayMode = await PosSettingsRepository(
        _client,
      ).getReceiptItemDisplayMode(businessId);
      final kitchenBanners = await PosSettingsRepository(
        _client,
      ).getKitchenBanners(businessId);
      var itemsByArea = await _groupItemsByPrintArea(
        targetItems,
        businessId: businessId,
      );
      // Fail-open: si el área pedida no aparece en el agrupado (resolución
      // N:M distinta a la del tablero), se reimprime en todas antes que en
      // ninguna.
      if (onlyAreaCode != null && itemsByArea.containsKey(onlyAreaCode)) {
        itemsByArea = {onlyAreaCode: itemsByArea[onlyAreaCode]!};
      }

      var areasPrinted = 0;
      final areasWithoutPrinter = <String>[];

      for (final entry in itemsByArea.entries) {
        final areaCode = entry.key;
        final areaItems = entry.value;
        // Un área con problema (código sin fila en print_areas, impresora
        // inalcanzable) NO debe tumbar la reimpresión de las demás áreas:
        // se reporta y se sigue con la siguiente.
        try {
          final area = await _ensureAreaForCode(businessId, areaCode);
          final printers = await _getOrderPrintersWithOfflineFallback(
            businessId: businessId,
            areaId: area.id,
            areaCode: areaCode,
          );
          if (printers.isEmpty) {
            areasWithoutPrinter.add(areaCode);
            continue;
          }

          final ticket = PrintTicketService.generateKitchenTicket(
            order: order,
            items: areaItems,
            tableName: orderData['tableName']?.toString() ?? 'N/A',
            waiterName: orderData['waiterName']?.toString(),
            cashierName: _resolveCashierName(),
            customerName: orderData['customerName']?.toString(),
            businessName: businessName,
            areaCode: areaCode,
            isReprint: true,
            receiptItemDisplayMode: receiptItemDisplayMode,
            showDineInBanner: kitchenBanners.dineIn,
            showTakeoutBanner: kitchenBanners.takeout,
          );

          await _dispatchKitchenTicket(
            printers: printers,
            bytes: ticket.escPosCommands,
            areaCode: areaCode,
            fallbackData: {
              'title': 'REIMPRESION ${orderData['tableName'] ?? 'COCINA'}',
              'body':
                  'Orden ${orderData['orderNumber'] ?? ''}\n'
                  'Mesa: ${orderData['tableName'] ?? 'N/A'}\n'
                  'REIMPRESION de comanda',
            },
            businessId: businessId,
            orderId: orderId,
          );
          areasPrinted++;
        } catch (e) {
          debugPrint('⚠️ Reimpresión de comanda falló en área $areaCode: $e');
          areasWithoutPrinter.add(areaCode);
        }
      }

      return ReadyPrintReport(
        areasPrinted: areasPrinted,
        areasWithoutReadyPrinter: areasWithoutPrinter,
      );
    } on ItemsWithoutPrintAreaException {
      rethrow;
    } on UnknownPrintAreaCodeException {
      rethrow;
    } catch (e) {
      throw Exception('Error al reimprimir la comanda: $e');
    }
  }

  /// Precarga el cache de impresoras de TODAS las print_areas del business.
  /// Pensado para llamarse al login/online-startup: garantiza que, si el
  /// cajero pierde la red después, [sendLocalOrderToKitchen] encuentre
  /// impresoras cacheadas para cada área sin importar si ya había impreso
  /// a ese área antes desde este device.
  ///
  /// Fail-safe: si la red falla a mitad del prewarm, las áreas ya
  /// procesadas quedan cacheadas y las restantes se intentarán en el
  /// próximo prewarm. No lanza — devuelve la lista de areaCodes que
  /// quedaron cacheados con éxito para que el caller pueda log/notify.
  Future<List<String>> prewarmPrinterCache({
    required String businessId,
  }) async {
    final cached = <String>[];
    try {
      final areas = await _printingRepo.getPrintAreas(businessId);
      for (final area in areas) {
        try {
          final orderPrinters = await _printingRepo.getOrderPrintersForArea(
            area.id,
          );
          await _cacheOrderPrinters(
            businessId: businessId,
            areaCode: area.code,
            printers: orderPrinters,
          );
          final readyPrinters = await _printingRepo.getReadyPrintersForArea(
            area.id,
          );
          await _cacheReadyPrinters(
            businessId: businessId,
            areaCode: area.code,
            printers: readyPrinters,
          );
          cached.add(area.code);
        } catch (e) {
          debugPrint(
            '⚠️ prewarmPrinterCache: falló para área ${area.code}: $e',
          );
        }
      }
    } catch (e) {
      debugPrint('⚠️ prewarmPrinterCache: no se pudo listar áreas: $e');
    }
    return cached;
  }

  Future<List<PrinterConfig>> _getOrderPrintersWithOfflineFallback({
    required String businessId,
    required String areaId,
    required String areaCode,
  }) async {
    try {
      final printers = await _printingRepo.getOrderPrintersForArea(areaId);
      await _cacheOrderPrinters(
        businessId: businessId,
        areaCode: areaCode,
        printers: printers,
      );
      return printers;
    } catch (e) {
      debugPrint('⚠️ Usando cache local de impresoras para $areaCode: $e');
      return _readCachedOrderPrinters(
        businessId: businessId,
        areaCode: areaCode,
      );
    }
  }

  Future<void> _cacheOrderPrinters({
    required String businessId,
    required String areaCode,
    required List<PrinterConfig> printers,
  }) async {
    final storage = await StorageService.getInstance();
    await storage.writeList(
      'printing_cached_printers_${businessId}_$areaCode',
      printers.map((printer) => printer.toMap()).toList(growable: false),
    );
  }

  Future<List<PrinterConfig>> _getReadyPrintersWithOfflineFallback({
    required String businessId,
    required String areaId,
    required String areaCode,
  }) async {
    try {
      final printers = await _printingRepo.getReadyPrintersForArea(areaId);
      await _cacheReadyPrinters(
        businessId: businessId,
        areaCode: areaCode,
        printers: printers,
      );
      return printers;
    } catch (e) {
      debugPrint(
        '⚠️ Usando cache local de impresoras READY para $areaCode: $e',
      );
      return _readCachedReadyPrinters(
        businessId: businessId,
        areaCode: areaCode,
      );
    }
  }

  Future<List<PrinterConfig>> _readCachedOrderPrinters({
    required String businessId,
    required String areaCode,
  }) async {
    final storage = await StorageService.getInstance();
    final cached = await storage.readList(
      'printing_cached_printers_${businessId}_$areaCode',
    );
    if (cached == null) return const [];
    return cached
        .map(
          (row) => PrinterConfig.fromMap(Map<String, dynamic>.from(row as Map)),
        )
        .toList(growable: false);
  }

  Future<void> _cacheReadyPrinters({
    required String businessId,
    required String areaCode,
    required List<PrinterConfig> printers,
  }) async {
    final storage = await StorageService.getInstance();
    await storage.writeList(
      'printing_cached_ready_printers_${businessId}_$areaCode',
      printers.map((printer) => printer.toMap()).toList(growable: false),
    );
  }

  Future<List<PrinterConfig>> _readCachedReadyPrinters({
    required String businessId,
    required String areaCode,
  }) async {
    final storage = await StorageService.getInstance();
    final cached = await storage.readList(
      'printing_cached_ready_printers_${businessId}_$areaCode',
    );
    if (cached == null) return const [];
    return cached
        .map(
          (row) => PrinterConfig.fromMap(Map<String, dynamic>.from(row as Map)),
        )
        .toList(growable: false);
  }

  /// Obtener resumen de impresión de una orden
  Future<Map<String, dynamic>> getOrderPrintSummary(String orderId) async {
    try {
      final items = await _salesRepo.getOrderItems(orderId);
      final itemsByArea = await _groupItemsByPrintArea(items);

      final summary = <String, dynamic>{};

      for (final entry in itemsByArea.entries) {
        summary[entry.key] = {
          'itemCount': entry.value.length,
          'items': entry.value.map((i) => i.productName).toList(),
        };
      }

      return summary;
    } on ItemsWithoutPrintAreaException {
      rethrow;
    } on UnknownPrintAreaCodeException {
      rethrow;
    } catch (e) {
      throw Exception('Error al obtener resumen: $e');
    }
  }
}
