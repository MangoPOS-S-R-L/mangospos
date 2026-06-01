import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/session/session_controller.dart';
import '../../network/connectivity_service.dart';
import '../../storage/storage_service.dart';
import '../offline_pos_service.dart';
import 'hub_client.dart';
import 'hub_mode.dart';

/// Resuelve el [HubMode] del terminal a partir de la conectividad y la
/// alcanzabilidad de un Hub Local (F3a). Reacciona a los cambios de
/// conexión re-evaluando el modo.
///
/// Mientras [kHubModeEnabled] sea `false`, NUNCA sondea la LAN: el modo
/// alterna solo entre `cloud` (con red) y `solo` (sin red), es decir el
/// comportamiento actual. Ningún call-site consume este provider todavía,
/// así que en runtime es inerte hasta que F3b lo cablee.
class HubModeController extends StateNotifier<HubMode> {
  HubModeController(this._ref) : super(HubMode.cloud) {
    _init();
  }

  final Ref _ref;
  final ConnectivityService _connectivity = ConnectivityService();
  final HubClient _hubClient = HubClient();
  StreamSubscription<bool>? _sub;

  /// URL del Hub alcanzable cuando [state] == [HubMode.hub]; null en otro caso.
  String? _reachableHubUrl;
  String? get reachableHubUrl => _reachableHubUrl;

  void _init() {
    unawaited(refresh());
    _sub = _connectivity.connectionStream.listen((_) => unawaited(refresh()));
  }

  Future<void> refresh() async {
    final connected = _connectivity.isConnected;
    var hubReachable = false;

    if (!connected && kHubModeEnabled) {
      final businessId = _ref.read(sessionProvider).activeBusinessId;
      final configured = await _readConfiguredHubUrl(businessId);
      final url = await _hubClient.findReachableHub(
        businessId: businessId,
        configuredUrl: configured,
      );
      _reachableHubUrl = url;
      hubReachable = url != null;
    } else {
      _reachableHubUrl = null;
    }

    final mode = resolveHubMode(
      isConnected: connected,
      hubReachable: hubReachable,
    );

    // Cablea/desconecta el enrutado de mutaciones al Hub (F3b-3): en modo
    // hub, OfflinePosService.enqueueAction enviará las ops al Hub alcanzable;
    // en cloud/solo se limpia y vuelve al encolado local puro.
    final hubUrl = _reachableHubUrl;
    if (mode == HubMode.hub && hubUrl != null) {
      OfflinePosService().setHubUploader(
        (businessId, op) => _hubClient.postOp(
          hubUrl,
          {...op, 'business_id': businessId},
        ),
      );
    } else {
      OfflinePosService().setHubUploader(null);
    }

    if (mode != state) state = mode;
  }

  Future<String?> _readConfiguredHubUrl(String? businessId) async {
    if (businessId == null || businessId.isEmpty) return null;
    final storage = await StorageService.getInstance();
    return storage.read('hub_primary_url_$businessId');
  }

  @override
  void dispose() {
    _sub?.cancel();
    _hubClient.dispose();
    super.dispose();
  }
}

final hubModeProvider =
    StateNotifierProvider<HubModeController, HubMode>((ref) {
  return HubModeController(ref);
});
