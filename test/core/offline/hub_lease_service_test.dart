import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/offline/hub/hub_lease_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Tests de la lease del Hub (failover manual, H7).
///
/// Lo que protege: este sistema no tiene idempotencia del lado del servidor. Si
/// el respaldo se promueve y el Hub viejo vuelve, los dos subirían las mismas
/// operaciones y Supabase las aplicaría dos veces — venta doble, NCF doble.
void main() {
  HubLeaseService servicio({
    dynamic respuesta,
    Object? lanza,
    void Function(Map<String, dynamic>)? vio,
  }) =>
      HubLeaseService(
        deviceId: () async => 'equipo-A',
        rpc: (fn, params) async {
          expect(fn, 'fn_hub_lease_acquire');
          vio?.call(params);
          if (lanza != null) throw lanza;
          return respuesta;
        },
      );

  group('acquire', () {
    test('lease propia → held', () async {
      final r = await servicio(
        respuesta: {'held': true, 'device_id': 'equipo-A', 'epoch': 3},
      ).acquire('biz-1');
      expect(r.status, HubLeaseStatus.held);
      expect(r.holderDeviceId, 'equipo-A');
      expect(r.epoch, 3);
    });

    test('lease de otro equipo → heldByOther, con quién la tiene', () async {
      final r = await servicio(
        respuesta: {'held': false, 'device_id': 'equipo-B', 'epoch': 4},
      ).acquire('biz-1');
      expect(r.status, HubLeaseStatus.heldByOther);
      expect(r.holderDeviceId, 'equipo-B');
    });

    test('manda negocio, equipo y force', () async {
      late Map<String, dynamic> params;
      await servicio(
        respuesta: {'held': true, 'device_id': 'equipo-A', 'epoch': 1},
        vio: (p) => params = p,
      ).acquire('biz-1', force: true);
      expect(params, {
        'p_business_id': 'biz-1',
        'p_device_id': 'equipo-A',
        'p_force': true,
      });
    });

    test('sin force, force va en false', () async {
      late Map<String, dynamic> params;
      await servicio(
        respuesta: {'held': true, 'device_id': 'equipo-A'},
        vio: (p) => params = p,
      ).acquire('biz-1');
      expect(params['p_force'], isFalse);
    });

    test('promoción forzada informa a quién se le quitó', () async {
      final r = await servicio(
        respuesta: {
          'held': true,
          'device_id': 'equipo-A',
          'epoch': 5,
          'taken_from': 'equipo-B',
        },
      ).acquire('biz-1', force: true);
      expect(r.takenFromDeviceId, 'equipo-B');
    });

    test('RPC inexistente (PGRST202) → unavailable', () async {
      final r = await servicio(
        lanza: const PostgrestException(message: 'not found', code: 'PGRST202'),
      ).acquire('biz-1');
      expect(r.status, HubLeaseStatus.unavailable);
    });

    test('firma inexistente (42883) → unavailable', () async {
      final r = await servicio(
        lanza: const PostgrestException(message: 'no existe', code: '42883'),
      ).acquire('biz-1');
      expect(r.status, HubLeaseStatus.unavailable);
    });

    test('otro error (sin red, acceso) → error', () async {
      final r = await servicio(
        lanza: const PostgrestException(message: 'denied', code: '42501'),
      ).acquire('biz-1');
      expect(r.status, HubLeaseStatus.error);
    });

    test('respuesta que no es un objeto → error, no crash', () async {
      final r = await servicio(respuesta: 'basura').acquire('biz-1');
      expect(r.status, HubLeaseStatus.error);
    });
  });

  // El uplink falla ABIERTO ante la migración sin aplicar: si fallara cerrado,
  // un local con app nueva y BD vieja no subiría nunca más.
  group('decideHubUplink', () {
    test('lease propia → subir', () {
      expect(
        decideHubUplink(const HubLeaseResult(status: HubLeaseStatus.held)),
        HubUplinkDecision.proceed,
      );
    });

    test('migración sin aplicar → subir como antes', () {
      expect(
        decideHubUplink(
          const HubLeaseResult(status: HubLeaseStatus.unavailable),
        ),
        HubUplinkDecision.proceed,
      );
    });

    test('error (sin red) → no subir en esta vuelta', () {
      expect(
        decideHubUplink(const HubLeaseResult(status: HubLeaseStatus.error)),
        HubUplinkDecision.skipRetryLater,
      );
    });

    // EL CASO QUE EVITA LA VENTA DOBLE.
    test('lease de otro (respaldo promovido) → no subir y ceder', () {
      expect(
        decideHubUplink(
          const HubLeaseResult(status: HubLeaseStatus.heldByOther),
        ),
        HubUplinkDecision.stepDown,
      );
    });
  });

  // La promoción falla CERRADA: promover sin candado es el escenario de venta
  // doble que la lease existe para impedir.
  group('canPromoteWithLease', () {
    test('solo con la lease tomada', () {
      expect(
        canPromoteWithLease(const HubLeaseResult(status: HubLeaseStatus.held)),
        isTrue,
      );
    });

    test('migración sin aplicar → NO promover', () {
      expect(
        canPromoteWithLease(
          const HubLeaseResult(status: HubLeaseStatus.unavailable),
        ),
        isFalse,
      );
    });

    test('sin red → NO promover', () {
      expect(
        canPromoteWithLease(const HubLeaseResult(status: HubLeaseStatus.error)),
        isFalse,
      );
    });

    test('lease de otro → NO promover', () {
      expect(
        canPromoteWithLease(
          const HubLeaseResult(status: HubLeaseStatus.heldByOther),
        ),
        isFalse,
      );
    });
  });

  // EL BUG LATENTE que activó el arreglo de la réplica: syncHubOpLog corre en
  // todo equipo, y el respaldo —con el op-log lleno de copias— subía cada 3
  // minutos en paralelo con el Hub. La lease sola no lo tapaba: sin fila, el
  // primero que confirma se la queda, y podía ser el respaldo.
  group('hubUplinkAllowedForRole', () {
    test('el Hub sube', () {
      expect(hubUplinkAllowedForRole(HubDeviceRole.hub), isTrue);
    });

    test('el respaldo NO sube: sus copias duplicarían las ventas', () {
      expect(hubUplinkAllowedForRole(HubDeviceRole.hubBackup), isFalse);
    });

    test('una caja NO sube el op-log del Hub', () {
      expect(hubUplinkAllowedForRole(HubDeviceRole.pos), isFalse);
    });
  });
}
