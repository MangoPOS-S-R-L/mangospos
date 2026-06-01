import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/ncf_offline_allocator.dart';
import 'package:mangopos/core/offline/offline_ncf_service.dart';

/// Tests de la decisión de asignación de NCF (F4): online/offline, Hub vs
/// local, agotamiento → provisional. Colaboradores inyectados (sin red/BD).
void main() {
  const range = NcfRange(
    ncfType: 'B02',
    serie: 'C1',
    prefix: 'B02',
    rangeStart: 1,
    rangeEnd: 100,
  );
  const hubAssignment = NcfAssignment(
    ncf: 'B0200000005',
    number: 5,
    ncfType: 'B02',
    serie: 'C1',
  );
  const localAssignment = NcfAssignment(
    ncf: 'B0200000009',
    number: 9,
    ncfType: 'B02',
    serie: 'C1',
  );

  OfflineNcfService build({
    required bool connected,
    NcfRange? rangeResult = range,
    NcfAssignment? hub,
    NcfAssignment? local,
    bool enabled = true,
  }) {
    return OfflineNcfService(
      enabled: enabled,
      isConnected: () => connected,
      resolveRange: () async => rangeResult,
      allocateViaHub: (_) async => hub,
      allocateLocal: (_) async => local,
    );
  }

  test('flag apagado → null (comportamiento de hoy)', () async {
    final s = build(connected: false, hub: hubAssignment, enabled: false);
    expect(await s.allocate(), isNull);
  });

  test('con internet → null (el server emite)', () async {
    final s = build(connected: true, hub: hubAssignment);
    expect(await s.allocate(), isNull);
  });

  test('offline + Hub → asigna por el Hub', () async {
    final s = build(connected: false, hub: hubAssignment, local: localAssignment);
    final r = await s.allocate();
    expect(r, hubAssignment); // gana el Hub
  });

  test('offline + sin Hub → fallback local', () async {
    final s = build(connected: false, hub: null, local: localAssignment);
    expect(await s.allocate(), localAssignment);
  });

  test('offline + sin rango asignado → null (provisional)', () async {
    final s = build(connected: false, rangeResult: null, hub: hubAssignment);
    expect(await s.allocate(), isNull);
  });

  test('offline + Hub y local agotados → null (provisional)', () async {
    final s = build(connected: false, hub: null, local: null);
    expect(await s.allocate(), isNull);
  });
}
