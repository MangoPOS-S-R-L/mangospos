// Comanda de los pedidos que entran por un canal externo (Pincer, y mañana
// Uber Eats o PedidosYa).
//
// EL PROBLEMA QUE RESUELVE
//   Un pedido que nace por API no tiene quién le imprima la comanda: los bytes
//   ESC/POS los arma esta app, no el servidor. El KDS lo ve solo —la ingesta
//   deja los ítems en 'pending'— pero el papel no sale.
//
// CÓMO LO HACEN LOS AGREGADORES, Y POR QUÉ SE COPIA
//   El pedido se ve en cocina AL INSTANTE y la impresión va aparte, reintentando.
//   Que falle el papel nunca puede esconder el pedido. Por eso esto es un worker
//   con su propia cola y no un paso dentro de la ingesta.
//
// POR QUÉ POLLING Y NO REALTIME
//   Un pedido que entra con el socket caído se perdería para siempre. El timer
//   se recupera solo: al siguiente tick lo ve igual. Mismo criterio que
//   `CloudPrintQueueWorker`.
//
// POR QUÉ NO HAY "TABLET DESIGNADA"
//   Todas las tablets en el shell de ventas corren este worker y el claim de
//   `fn_claim_external_orders_to_print` es atómico: solo una gana cada pedido.
//   Designar una sola sería un punto único de falla — apagada esa, no hay
//   comanda. Así, si una se queda sin batería, otra cubre.
//
// La primera impresión NO lleva el sello de REIMPRESION: sale por
// `reprintComandaTicket(asReprint: false)` porque los ítems ya están en
// 'pending' y `sendOrderToKitchen` solo mira los que están en 'draft'.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'device_identity.dart';

class ExternalOrderPrintWorker {
  ExternalOrderPrintWorker(this._ref);

  final Ref _ref;
  Timer? _timer;
  bool _tickInFlight = false;

  // 12s: un pedido de delivery no puede esperar medio minuto por su comanda,
  // y a la vez no tiene sentido martillar la base cuando no entra nada.
  static const Duration _interval = Duration(seconds: 12);

  // Por tick. Con el claim repartido entre las tablets, entre todas drenan
  // rápido aunque entren varios pedidos juntos en hora pico.
  static const int _batchPerTick = 5;

  void start() {
    if (_timer != null) return;
    if (kIsWeb) return; // Web no imprime por socket TCP directo.
    _timer = Timer.periodic(_interval, (_) => _safeTick());
    // Primer barrido inmediato: si la app estuvo cerrada, no esperar el tick.
    Future.microtask(_safeTick);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _safeTick() async {
    if (_tickInFlight) return;
    _tickInFlight = true;
    try {
      await _tick();
    } catch (e, st) {
      debugPrint('[ExtOrderPrint] tick error: $e\n$st');
    } finally {
      _tickInFlight = false;
    }
  }

  Future<void> _tick() async {
    final supabase = Supabase.instance.client;
    if (supabase.auth.currentUser == null) return;

    // El negocio ACTIVO de la sesión, no "el primero de user_businesses": un
    // dueño con varias sucursales imprimiría las comandas de otro local.
    final businessId = _ref.read(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) return;

    final deviceId = await DeviceIdentity.getOrCreateId(businessId);

    final List<dynamic> claimed;
    try {
      claimed = await supabase.rpc(
        'fn_claim_external_orders_to_print',
        params: {
          'p_business_id': businessId,
          'p_device_id': deviceId,
          'p_limit': _batchPerTick,
        },
      );
    } catch (e) {
      // Sin la migración aplicada esto falla en cada tick. No rompemos nada:
      // el pedido sigue viéndose en el KDS, solo no sale el papel.
      debugPrint('[ExtOrderPrint] no se pudo reclamar: $e');
      return;
    }
    if (claimed.isEmpty) return;

    final printing = PrintingService(supabase);
    final sales = SalesRepository(supabase);

    for (final raw in claimed) {
      final row = raw as Map<String, dynamic>;
      final extRowId = (row['external_order_row'] as String?)?.trim();
      final orderId = (row['order_id'] as String?)?.trim();
      final number = (row['external_number'] as String?)?.trim();
      final attempts = (row['attempts'] as num?)?.toInt() ?? 1;
      if (extRowId == null || orderId == null || orderId.isEmpty) continue;

      try {
        final items = await sales.getOrderItems(orderId);
        final itemIds = items
            .where((item) => item.status != 'void')
            .map((item) => item.id)
            .toList(growable: false);

        if (itemIds.isEmpty) {
          // Orden sin ítems vivos: no hay comanda que sacar. Se cierra como
          // impresa para que no quede dando vueltas en la cola.
          await _finish(supabase, extRowId, true, null);
          continue;
        }

        final report = await printing.reprintComandaTicket(
          orderId: orderId,
          businessId: businessId,
          itemIds: itemIds,
          asReprint: false, // es la comanda original, no un duplicado
          // Estable por pedido + intento: dos tablets no sacan el mismo papel,
          // y un reintento sí puede volver a encolarse.
          idempotencyTag: 'ext-$extRowId-$attempts',
        );

        // `areasPrinted` son las que respondieron directo; las escaladas
        // quedaron en el cloud queue, que otra terminal drena. Las dos cuentan
        // como despachadas: reintentar sacaría el papel dos veces. Lo que sí
        // es fallo real es que ningún área tuviera impresora.
        final despachadas =
            report.areasPrinted + report.areasEscalatedToQueue.length;
        final ok = despachadas > 0;
        await _finish(
          supabase,
          extRowId,
          ok,
          ok
              ? null
              : 'Sin impresora para las áreas del pedido'
                    '${report.areasWithoutReadyPrinter.isEmpty ? '' : ' (${report.areasWithoutReadyPrinter.join(', ')})'}',
        );
        debugPrint(
          '[ExtOrderPrint] pedido ${number ?? extRowId}: '
          '${ok ? 'comanda despachada a $despachadas área(s)' : 'sin impresora'}'
          ' (intento $attempts)',
        );
      } catch (e) {
        await _finish(supabase, extRowId, false, e.toString());
        debugPrint('[ExtOrderPrint] pedido ${number ?? extRowId} falló: $e');
      }
    }
  }

  Future<void> _finish(
    SupabaseClient sb,
    String extRowId,
    bool ok,
    String? error,
  ) async {
    try {
      await sb.rpc(
        'fn_mark_external_order_printed',
        params: {
          'p_external_order_row': extRowId,
          'p_ok': ok,
          'p_error': error,
        },
      );
    } catch (e) {
      // Si no se pudo cerrar el intento, el claim vence a los 2 minutos y otra
      // tablet lo retoma. Peor sería quedarnos sin registrar el fallo.
      debugPrint('[ExtOrderPrint] no se pudo cerrar el intento: $e');
    }
  }
}

/// Provider singleton. Igual que `cloudPrintQueueWorkerProvider`: la app llama
/// `.start()` al entrar al shell de ventas y `onDispose` lo detiene.
final externalOrderPrintWorkerProvider = Provider<ExternalOrderPrintWorker>((
  ref,
) {
  final worker = ExternalOrderPrintWorker(ref);
  ref.onDispose(worker.stop);
  return worker;
});
