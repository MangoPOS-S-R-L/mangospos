import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/network/connectivity_service.dart';
import '../../core/offline/hub/hub_config.dart';
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

  static const Duration _interval = Duration(seconds: 4);

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
      await OfflinePosService().syncHubOpLog(
        businessId: businessId,
        salesRepository: SalesRepository(client),
        printingService: PrintingService(client),
        inventoryRepository: InventoryRepository(client),
        cashierRepository: CashierRepository(client),
      );
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
