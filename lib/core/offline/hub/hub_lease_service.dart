import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/device_utils.dart';
import 'hub_config.dart' show HubDeviceRole;

/// Resultado de confirmar o tomar la lease del Hub.
enum HubLeaseStatus {
  /// La lease es de este equipo (o no existía y ahora lo es).
  held,

  /// La lease es de OTRO equipo: este no puede subir.
  heldByOther,

  /// La RPC no existe: la migración 20260914_0050 no está aplicada.
  unavailable,

  /// No se pudo confirmar (sin red, error del servidor).
  error,
}

@immutable
class HubLeaseResult {
  const HubLeaseResult({
    required this.status,
    this.holderDeviceId,
    this.epoch,
    this.takenFromDeviceId,
    this.error,
  });

  final HubLeaseStatus status;

  /// Equipo que tiene la lease según el servidor.
  final String? holderDeviceId;
  final int? epoch;

  /// En una promoción forzada, el equipo al que se le quitó la lease.
  final String? takenFromDeviceId;
  final Object? error;
}

/// Qué hace el uplink del Hub con el resultado de la lease.
enum HubUplinkDecision {
  /// Subir normal.
  proceed,

  /// No subir en esta vuelta; se reintenta en la siguiente.
  skipRetryLater,

  /// Otro equipo fue promovido: no subir y dejar de actuar como Hub.
  stepDown,
}

/// Decisión del uplink. Pura, para poder probarla sin Supabase.
///
/// La asimetría con [canPromoteWithLease] es deliberada:
///
/// - Aquí `unavailable` (migración sin aplicar) **sigue adelante**. Si fallara
///   cerrado, un local con la app nueva y la BD vieja dejaría de subir para
///   siempre y las ventas se quedarían en el disco del Hub. Seguir es exactamente
///   el comportamiento de antes de existir la lease.
/// - `error` no sube en esta vuelta: casi siempre es falta de red, y en ese caso
///   el uplink fallaría igual. El drenaje reintenta a los pocos segundos.
HubUplinkDecision decideHubUplink(HubLeaseResult result) {
  switch (result.status) {
    case HubLeaseStatus.held:
    case HubLeaseStatus.unavailable:
      return HubUplinkDecision.proceed;
    case HubLeaseStatus.error:
      return HubUplinkDecision.skipRetryLater;
    case HubLeaseStatus.heldByOther:
      return HubUplinkDecision.stepDown;
  }
}

/// ¿Se puede completar la promoción manual? Solo con la lease tomada de verdad.
///
/// A diferencia del uplink, aquí la migración sin aplicar **bloquea**: promover
/// un respaldo sin candado en el servidor es precisamente el escenario en que el
/// Hub viejo vuelve y los dos suben lo mismo — venta doble, inventario doble y
/// NCF doble. Mejor no promover que promover a ciegas.
bool canPromoteWithLease(HubLeaseResult result) =>
    result.status == HubLeaseStatus.held;

/// ¿Este equipo puede subir el op-log del Hub? Solo si su ROL es Hub.
///
/// Es el candado que va ANTES de la lease, y cierra un bug latente que activó
/// el arreglo de la réplica: `syncHubOpLog` corre en todo equipo cada pocos
/// minutos. Mientras la réplica no funcionaba, el op-log del respaldo estaba
/// vacío. Con la réplica viva, el respaldo tiene copias de todo — sin este
/// candado las subiría en paralelo con el Hub y cada venta se aplicaría dos
/// veces. Y la lease no basta: sin fila, el primero que confirma se la queda, y
/// ese podía ser el respaldo pasivo.
///
/// La promoción manual cambia el rol a Hub, así que un respaldo promovido pasa
/// este candado sin excepciones especiales.
bool hubUplinkAllowedForRole(HubDeviceRole role) => role == HubDeviceRole.hub;

/// Confirma o toma la lease del Hub Local en Supabase (`fn_hub_lease_acquire`).
///
/// Por qué existe: este sistema no tiene idempotencia del lado del servidor. La
/// deduplicación de las operaciones offline vive en el disco de cada equipo,
/// así que si dos equipos suben el mismo op-log —el Hub viejo que vuelve y el
/// respaldo que se promovió— Supabase lo aplica dos veces. La lease hace que
/// solo uno tenga derecho a subir.
class HubLeaseService {
  HubLeaseService({
    Future<dynamic> Function(String fn, Map<String, dynamic> params)? rpc,
    Future<String> Function()? deviceId,
  })  : _rpc = rpc,
        _deviceId = deviceId;

  final Future<dynamic> Function(String fn, Map<String, dynamic> params)? _rpc;
  final Future<String> Function()? _deviceId;

  static const String _fn = 'fn_hub_lease_acquire';

  Future<dynamic> _call(Map<String, dynamic> params) {
    final injected = _rpc;
    if (injected != null) return injected(_fn, params);
    return Supabase.instance.client.rpc(_fn, params: params);
  }

  Future<String> _myDeviceId() => (_deviceId ?? DeviceUtils.getDeviceId)();

  /// Confirma que la lease es de este equipo. Con [force] (promoción manual) se
  /// la quita a quien la tenga.
  Future<HubLeaseResult> acquire(
    String businessId, {
    bool force = false,
  }) async {
    try {
      final device = await _myDeviceId();
      final raw = await _call({
        'p_business_id': businessId,
        'p_device_id': device,
        'p_force': force,
      });
      if (raw is! Map) {
        return HubLeaseResult(
          status: HubLeaseStatus.error,
          error: StateError('respuesta inesperada de $_fn: $raw'),
        );
      }
      final held = raw['held'] == true;
      return HubLeaseResult(
        status: held ? HubLeaseStatus.held : HubLeaseStatus.heldByOther,
        holderDeviceId: raw['device_id']?.toString(),
        epoch: (raw['epoch'] as num?)?.toInt(),
        takenFromDeviceId: raw['taken_from']?.toString(),
      );
    } catch (e) {
      if (isMissingFunctionError(e)) {
        debugPrint(
          '[HubLease] $_fn no existe (¿migración 20260914_0050 sin aplicar?). '
          'El uplink sigue sin lease, como antes; la promoción queda bloqueada.',
        );
        return const HubLeaseResult(status: HubLeaseStatus.unavailable);
      }
      return HubLeaseResult(status: HubLeaseStatus.error, error: e);
    }
  }

  /// PostgREST contesta `PGRST202` cuando no encuentra la función en su caché
  /// de esquema, y Postgres `42883` cuando no existe con esa firma. Mismo
  /// criterio que ya usa `InventoryRepository`.
  @visibleForTesting
  static bool isMissingFunctionError(Object e) =>
      e is PostgrestException && (e.code == 'PGRST202' || e.code == '42883');
}
