import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'package:flutter/foundation.dart';
import '../../../presentation/cashier/viewmodel/cashier_viewmodel.dart';
import '../../../services/session/session_controller.dart';
import '../../network/connectivity_service.dart';
import '../../utils/device_utils.dart';
import '../offline_pos_service.dart';
import 'hub_baseline_service.dart';
import 'hub_client.dart';
import 'hub_config.dart';
import 'hub_mode.dart';
import 'hub_read_cache.dart';
import 'hub_auto_setup.dart';
import 'hub_lease_service.dart';
import 'hub_lan_token.dart';

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
  Future<void>? _refreshing;
  bool _refreshingReadCache = false;
  DateTime? _lastReadCacheAt;

  // Network continuity is automatic for every business, including legacy cloud.
  final NetworkPolicy _policy = NetworkPolicy.hub;
  HubDeviceRole _role = HubDeviceRole.pos;
  late final HubAutoSetup _autoSetup = HubAutoSetup(
    readRole: _hubConfig.getDeviceRole,
    writeRole: _hubConfig.setDeviceRole,
    acquireLease: (biz) => HubLeaseService().acquire(biz),
    readToken: HubLanTokenService.instance.tokenFor,
  );
  String? get preparationStatus => _autoSetup.status;

  final HubBaselineService _baseline = HubBaselineService();

  /// Última captura del baseline, para no rehacerla en cada tick de 20s.
  DateTime? _lastBaselineAt;

  /// Cada cuánto se refresca la foto de las órdenes ya abiertas. Corto porque
  /// su valor entero depende de qué tan fresca esté cuando se caiga la red, y
  /// son 3 consultas acotadas SOLO en el equipo Hub.
  static const Duration _baselineInterval = Duration(minutes: 2);

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
      const Duration(seconds: 5),
      (_) => unawaited(refresh()),
    );
  }

  /// Recarga la política del local (Supabase/cache) + el rol del dispositivo
  /// (local) y re-evalúa el modo. La UI de Ajustes la llama tras cambiar la
  /// política o el rol para que el efecto sea inmediato.
  Future<void> reloadConfigAndRefresh() async {
    if (mounted) await refresh();
  }

  /// Re-evalúa el modo con la config CACHEADA (barato: solo re-sondea la
  /// alcanzabilidad del Hub si aplica). Lo disparan la conexión y el timer.
  Future<void> refresh() async {
    final pending = _refreshing;
    if (pending != null) return pending;
    final future = _refresh();
    _refreshing = future;
    try {
      await future;
    } catch (e) {
      debugPrint('[HubAutoSetup] preparacion pendiente: $e');
    } finally {
      _refreshing = null;
    }
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final pos = OfflinePosService();

    if (!kHubModeEnabled) {
      pos.setHubUploader(null);
      final m = _connectivity.isConnected
          ? TerminalMode.cloud
          : TerminalMode.solo;
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

    var canHost = false;
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      final role = _ref.read(sessionProvider).activeRole;
      canHost = role == PosRole.cajero;
      if (!canHost &&
          (role == PosRole.administrador || role == PosRole.supervisor)) {
        final cash = _ref.read(cashierViewModelProvider).lastSession;
        canHost =
            cash?['status'] == 'open' &&
            cash?['closed_at'] == null &&
            cash?['device_id'] == await DeviceUtils.getDeviceId();
      }
    }
    _role = await _autoSetup.prepare(
      businessId,
      online: _connectivity.isConnected,
      canHost: canHost,
    );
    if (!mounted) return;

    final connected = _connectivity.isConnected;
    var hubReachable = false;
    String? reachableUrl;

    // Solo una CAJA (no el propio Hub) necesita descubrir/alcanzar el Hub.
    if (_policy == NetworkPolicy.hub && _role != HubDeviceRole.hub) {
      final configured =
          _reachableHubUrl ?? await _hubConfig.getHubUrl(businessId);
      final url = await _hubClient.findReachableHub(
        businessId: businessId,
        configuredUrl: configured,
        scanFallback: true,
      );
      reachableUrl = url;
      hubReachable = url != null;
      if (url != null && url != configured) {
        await _hubConfig.setHubUrl(businessId, url);
      }
    }

    if (!mounted || _ref.read(sessionProvider).activeBusinessId != businessId) {
      return;
    }
    _reachableHubUrl = reachableUrl;

    final mode = resolveTerminalMode(
      policy: _policy,
      role: _role,
      isConnected: connected,
      hubReachable: hubReachable,
    );

    _wireUploader(pos, mode, businessId);
    if (mode != state) state = mode;

    unawaited(_captureBaselineIfDue(mode, connected, businessId));
    if (mode == TerminalMode.hubClient && reachableUrl != null) {
      unawaited(_refreshReadCache(businessId, reachableUrl));
    }
  }

  Future<void> _refreshReadCache(String businessId, String url) async {
    if (_refreshingReadCache) return;
    final last = _lastReadCacheAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 1)) {
      return;
    }
    _refreshingReadCache = true;
    try {
      final snapshot = await _hubClient.getReadCache(
        url,
        businessId: businessId,
      );
      if (!mounted || snapshot == null) return;
      await HubReadCache().import(businessId, snapshot);
      _lastReadCacheAt = DateTime.now();
    } catch (_) {
      // Keep the last usable copy and retry on the next hub probe.
    } finally {
      _refreshingReadCache = false;
    }
  }

  /// Refresca la foto de las órdenes YA abiertas mientras este equipo es el Hub
  /// y TIENE internet.
  ///
  /// El momento importa: cuando la red se cae ya no se puede consultar nada, así
  /// que la foto tiene que existir de antes. Es la misma idea de la bajada
  /// proactiva de F6 — sin esto, una mesa abierta por otra caja antes del corte
  /// se veía ocupada en el grid pero salía VACÍA al abrirla.
  ///
  /// Best-effort y fuera del camino crítico: `refresh()` no espera por esto.
  Future<void> _captureBaselineIfDue(
    TerminalMode mode,
    bool connected,
    String businessId,
  ) async {
    if (mode != TerminalMode.hubHost || !connected) return;
    final last = _lastBaselineAt;
    if (last != null && DateTime.now().difference(last) < _baselineInterval) {
      return;
    }
    _lastBaselineAt = DateTime.now();
    await _baseline.capture(businessId);
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
        pos.setHubUploader((biz, op) => pos.appendToLocalHubOpLog(biz, op));
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

final hubModeProvider = StateNotifierProvider<HubModeController, TerminalMode>((
  ref,
) {
  ref.watch(sessionProvider.select((session) => session.activeBusinessId));
  return HubModeController(ref);
});
