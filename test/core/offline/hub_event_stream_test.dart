import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_event_stream.dart';

/// Tests del helper puro de HubEventStream (F3c-2): conversión http→ws.
void main() {
  group('HubEventStream.wsUrlFor', () {
    test('http → ws con la ruta del feed', () {
      expect(
        HubEventStream.wsUrlFor('http://192.168.1.5:4000').toString(),
        'ws://192.168.1.5:4000/hub/events',
      );
    });

    test('https → wss', () {
      expect(
        HubEventStream.wsUrlFor('https://hub.local:4000').toString(),
        'wss://hub.local:4000/hub/events',
      );
    });

    test('tolera barra final', () {
      expect(
        HubEventStream.wsUrlFor('http://h:4000/').toString(),
        'ws://h:4000/hub/events',
      );
    });
  });
}
