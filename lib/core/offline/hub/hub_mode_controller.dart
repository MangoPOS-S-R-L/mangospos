import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../data/repositories/pos_settings_repository.dart';
import '../../../services/session/session_controller.dart';
import '../../network/connectivity_service.dart';
import '../offline_pos_service.dart';
import 'hub_client.dart';
import 'hub_config.dart';
import 'hub_mode.dart';

/// Resuelve el [TerminalMode] del dispositivo (H4) a partir de la POLÍTICA del
/// local (`business_settings.network_mode`), el ROL de este equipo
/// (device-level) y la conectividad/alcanzabilidad del Hub. Cablea el enrutado
/// de mutaciones:
///   - hubClient → `HubClient.postOp` al Hub remoto (por LAN).
///   - hubHost   → `OfflinePosService.appendToLocalHubOpLog` (mis propias
///                 mutaciones al op-log local que sirve el servidor en-proceso).
///   - cloud/solo → sin uploader (encolado local puro, comportamiento actual).
///
/// Reacciona a cambios de conexión y a un timer periódico. La política/rol se
/// cachean y se recargan en el arranque y cuando la UI de Ajustes llama
/// [reloadConfigAndRefresh] (para no consultar Supabase en cada tick).
///
/// Mientras [kHubModeEnabled] sea `false`, NUNCA hay Hub: el modo alterna solo
/// entre `cloud` (con red) y `solo` (sin red) y el uploader queda nulo — es
/// decir, el comportamiento actual, sin tocar nada.
class HubModeController extends StateNotifier<TerminalMode> {
  HubModeController(this._ref) : super(TerminalMode.cloud) {
    _init();
  }

  final Ref _ref;
  final ConnectivityService _connectivity = ConnectivityService();
  final HubClient _hubClient = HubClient();
  final HubConfigService _hubConfig = HubConfigService();
  StreamSubscription<bool>? _sub;
  Timer? _timer;

  NetworkPolicy _policy = NetworkPolicy.cloud;
  HubDeviceRole _role = HubDeviceRole.pos;

  /// URL del Hub alcanzable cuando este equipo es un cliente en modo hub; null
  /// en otro caso. Lo usan las rutas de lectura (grid del salón) en H4c.
  String? _reachableHubUrl;
  String? get reachableHubUrl => _reachableHubUrl;

  TerminalMode get mode => state;
  NetworkPolicy get policy => _policy;
  HubDeviceRole get role => _role;

  void _init() {
    unawaited(reloadConfigAndRefresh());
    _sub = _connectivity.connectionStream.listen((_) => unawaited(refresh()));
    // La política/rol/alcanzabilidad del Hub puede cambiar sin un evento de
    // conexión → re-evaluar periódicamente (reusa la config cacheada).
    _timer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(refresh()),
    );
  }

  /// Recarga la política del local (Supabase/cache) + el rol del dispositivo
  /// (local) y re-evalúa el modo. La UI de Ajustes la llama tras cambiar la
  /// política o el rol para que el efecto sea inmediato.
  Future<void> reloadConfigAndRefresh() async {
    if (kHubModeEnabled) {
      final businessId = _ref.read(sessionProvider).activeBusinessId;
      if (businessId != null && businessId.isNotEmpty) {
        try {
          final raw = await _ref
              .read(posSettingsRepositoryProvider)
              .getNetworkMode(businessId);
          _policy = networkPolicyFromString(raw);
        } catch (_) {
          // Sin poder leer la política, conservamos la cacheada (default cloud).
        }
        _role = await _hubConfig.getDeviceRole(businessId);
      }
    }
    await refresh();
  }

  /// Re-evalúa el modo con la config CACHEADA (barato: solo re-sondea la
  /// alcanzabilidad del Hub si aplica). Lo disparan la conexión y el timer.
  Future<void> refresh() async {
    final pos = OfflinePosService();

    if (!kHubModeEnabled) {
      pos.setHubUploader(null);
      final m = _connectivity.isConnected ? TerminalMode.cloud : TerminalMode.solo;
      if (m != state) state = m;
      return;
    }

    final businessId = _ref.read(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) {
      pos.setHubUploader(null);
      _reachableHubUrl = null;
      if (state != TerminalMode.cloud) state = TerminalMode.cloud;
      return;
    }

    final connected = _connectivity.isConnected;
    var hubReachable = false;
    _reachableHubUrl = null;

    // Solo una CAJA (no el propio Hub) necesita descubrir/alcanzar el Hub.
    if (_policy == NetworkPolicy.hub && _role != HubDeviceRole.hub) {
      final configured = await _hubConfig.getHubUrl(businessId);
      final url = await _hubClient.findReachableHub(
        businessId: businessId,
        configuredUrl: configured,
      );
      _reachableHubUrl = url;
      hubReachable = url != null;
    }

    final mode = resolveTerminalMode(
      policy: _policy,
      role: _role,
      isConnected: connected,
      hubReachable: hubReachable,
    );

    _wireUploader(pos, mode, businessId);
    if (mode != state) state = mode;
  }

  void _wireUploader(
    OfflinePosService pos,
    TerminalMode mode,
    String businessId,
  ) {
    switch (mode) {
      case TerminalMode.hubClient:
        final url = _reachableHubUrl;
        if (url != null) {
          pos.setHubUploader(
            (biz, op) => _hubClient.postOp(url, {...op, 'business_id': biz}),
          );
        } else {
          pos.setHubUploader(null);
        }
        break;
      case TerminalMode.hubHost:
        // Soy el Hub: mis propias mutaciones van al op-log local compartido
        // (lo sirve /hub/salon y lo drena syncHubOpLog hacia Supabase), no a la
        // cola por-device ni directo a Supabase.
        pos.setHubUploader(
          (biz, op) => pos.appendToLocalHubOpLog(biz, op),
        );
        break;
      case TerminalMode.cloud:
      case TerminalMode.solo:
        pos.setHubUploader(null);
        break;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    _hubClient.dispose();
    super.dispose();
  }
}

final hubModeProvider =
    StateNotifierProvider<HubModeController, TerminalMode>((ref) {
  return HubModeController(ref);
});
