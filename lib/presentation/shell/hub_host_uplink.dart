import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/network/connectivity_service.dart';
import '../../core/offline/hub/hub_config.dart';
import '../../core/offline/hub/hub_lease_service.dart';
import '../../core/offline/hub/hub_mode_controller.dart';
import '../../core/offline/offline_pos_service.dart';
import '../../data/repositories/cashier_repository.dart';
import '../../data/repositories/inventory_repository.dart';
import '../../data/repositories/printing_service.dart';
import '../../data/repositories/sales_repository.dart';
import '../../services/session/session_controller.dart';

/// Cuando ESTE equipo es el Hub host y tiene internet, drena su op-log a
/// Supabase cada pocos segundos (no cada 3 min como el sync general). Así las
/// ediciones que mandan las cajas por LAN (borrar ítem, cambiar cantidad,
/// notas, takeout…) llegan al servidor casi al instante y el cobro del cashier
/// en la caja principal es exacto (no cobra un ítem que el mesero borró).
///
/// Agregar ítems ya es tiempo real (proxy `/hub/proxy/add-item`); esto cubre el
/// resto de mutaciones, que viajan por el op-log. Vive en presentación (usa los
/// repos) y lo mantiene vivo el shell. Inerte salvo en modo hubHost + online.
class HubHostUplink {
  HubHostUplink(this._ref) {
    _sub = _ref.listen<TerminalMode>(
      hubModeProvider,
      (_, mode) => _apply(mode),
      fireImmediately: true,
    );
  }

  final Ref _ref;
  ProviderSubscription<TerminalMode>? _sub;
  Timer? _timer;
  bool _busy = false;
  DateTime? _lastLeaseCheck;

  static const Duration _interval = Duration(seconds: 4);
  static const Duration _leaseHeartbeat = Duration(seconds: 60);

  void _apply(TerminalMode mode) {
    if (mode == TerminalMode.hubHost) {
      _timer ??= Timer.periodic(_interval, (_) => unawaited(_drain()));
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _drain() async {
    if (_busy) return;
    if (!ConnectivityService().isConnected) return;
    final businessId = _ref.read(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) return;
    _busy = true;
    try {
      final client = Supabase.instance.client;
      // syncHubOpLog sale temprano si el op-log está vacío → barato en idle.
      final result = await OfflinePosService().syncHubOpLog(
        businessId: businessId,
        salesRepository: SalesRepository(client),
        printingService: PrintingService(client),
        inventoryRepository: InventoryRepository(client),
        cashierRepository: CashierRepository(client),
      );
      var leaseLost = result.leaseLostToDeviceId != null;

      // H7: latido de la lease. syncHubOpLog solo la consulta cuando hay algo
      // que subir; sin esto, un Hub viejo que vuelve con el op-log al día no se
      // enteraría de que promovieron a otro y seguiría recibiendo ventas de las
      // cajas que aún apuntan a él — ventas que ya no podría subir.
      final now = DateTime.now();
      if (!leaseLost &&
          (_lastLeaseCheck == null ||
              now.difference(_lastLeaseCheck!) >= _leaseHeartbeat)) {
        _lastLeaseCheck = now;
        final gate = await OfflinePosService().checkHubLease(businessId);
        leaseLost = gate.decision == HubUplinkDecision.stepDown;
      }

      // Otro equipo fue promovido a Hub y este ya quedó como respaldo: recargar
      // la config saca el modo de hubHost ahora mismo (se apaga este drenaje y
      // el servidor se re-evalúa) en vez de esperar a que alguien abra Ajustes.
      if (leaseLost) {
        unawaited(
          _ref.read(hubModeProvider.notifier).reloadConfigAndRefresh(),
        );
      }
    } catch (e) {
      debugPrint('[HubHostUplink] drenaje falló (ignorado): $e');
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    _sub?.close();
    _timer?.cancel();
    _timer = null;
  }
}

final hubHostUplinkProvider = Provider<HubHostUplink>((ref) {
  final u = HubHostUplink(ref);
  ref.onDispose(u.dispose);
  return u;
});
