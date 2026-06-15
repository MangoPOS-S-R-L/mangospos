// Sprint 2.2 — Descubrimiento de print agents en LAN vía mDNS/Bonjour.
//
// El agent Node.js anuncia `_mangoprint._tcp` (ver
// `agent/src/discovery/mdns_advertiser.js`). Este servicio escanea la
// LAN, encuentra esos anuncios, y retorna una lista de hubs disponibles.
//
// Casos cubiertos:
//   - 1 hub en LAN → la tablet se auto-configura.
//   - N hubs (multi-caja) → la UI pide al cajero cuál usar.
//   - 0 hubs (mDNS bloqueado por router corporativo) → caller cae a
//     IP manual via SharedPreferences / device_agents.
//
// El `businessId` filtro permite que tablets de un negocio solo vean
// hubs de SU negocio (importante para futuros casos multi-tenant en
// la misma red, como un food court).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:multicast_dns/multicast_dns.dart';

import 'package:mangopos/core/network/android_net_lock.dart';

class DiscoveredAgent {
  /// Nombre legible (`AGENT_NAME` o derivado de `AGENT_ID`).
  final String name;

  /// Host resuelto (IP o hostname `.local`). Para HTTP, mejor usar `ip`.
  final String host;

  /// IPv4 resuelta. Null si no se pudo resolver A record.
  final String? ip;

  /// Puerto donde el agent escucha (LOCAL_PORT, default 4000).
  final int port;

  /// `agent_uuid` (TXT record) — UUID en `device_agents.id`.
  final String? agentUuid;

  /// `business_id` (TXT record). Tablet filtra para mostrar solo hubs
  /// de su negocio.
  final String? businessId;

  /// `version` (TXT record).
  final String? version;

  /// `cloud_queue` (TXT record) — true si el agent soporta cloud queue.
  final bool cloudQueue;

  const DiscoveredAgent({
    required this.name,
    required this.host,
    required this.port,
    this.ip,
    this.agentUuid,
    this.businessId,
    this.version,
    this.cloudQueue = false,
  });

  /// URL HTTP completa para enviar requests al agent.
  /// Prefiere IP sobre host `.local` por compatibilidad con Windows que
  /// no resuelve mDNS en todos los runtimes.
  String get baseUrl {
    final h = (ip != null && ip!.isNotEmpty) ? ip! : host;
    return 'http://$h:$port';
  }

  @override
  String toString() =>
      'DiscoveredAgent($name @ $baseUrl, business=$businessId, uuid=$agentUuid, cq=$cloudQueue)';
}

class AgentDiscovery {
  static const String _serviceType = '_mangoprint._tcp.local';

  /// Escanea la LAN por agents. Devuelve la primera tanda que llegue
  /// hasta `timeout`. Si NO se encuentra ninguno, lista vacía.
  ///
  /// Si `businessIdFilter` está seteado, filtra hubs cuyo TXT
  /// `business_id` no coincida.
  ///
  /// Resiliente: si mDNS falla por permisos / red corporativa, retorna
  /// lista vacía sin throw — el caller cae a IP manual.
  Future<List<DiscoveredAgent>> discover({
    Duration timeout = const Duration(seconds: 4),
    String? businessIdFilter,
  }) async {
    final results = <String, DiscoveredAgent>{};

    final client = MDnsClient(
      rawDatagramSocketFactory: (dynamic host, int port, {bool reuseAddress = true, bool reusePort = false, int ttl = 1}) {
        return RawDatagramSocket.bind(
          host,
          port,
          reuseAddress: true,
          reusePort: false,
          ttl: ttl,
        );
      },
    );

    // Android descarta multicast entrante sin un MulticastLock activo: sin
    // esto el anuncio `_mangoprint._tcp` del hub no llega y el caller cae a
    // IP manual aunque el agente esté en la misma LAN.
    await AndroidNetLock.acquireMulticastLock();
    try {
      await client.start();

      final ptrStream = client
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer(_serviceType),
          )
          .timeout(
            timeout,
            onTimeout: (sink) => sink.close(),
          );

      await for (final ptr in ptrStream) {
        try {
          final srvList = await client
              .lookup<SrvResourceRecord>(
                ResourceRecordQuery.service(ptr.domainName),
              )
              .toList();
          if (srvList.isEmpty) continue;
          final srv = srvList.first;

          final txtList = await client
              .lookup<TxtResourceRecord>(
                ResourceRecordQuery.text(ptr.domainName),
              )
              .toList();
          final txtMap = <String, String>{};
          for (final txt in txtList) {
            for (final line in txt.text.split('\n')) {
              final eq = line.indexOf('=');
              if (eq < 0) continue;
              txtMap[line.substring(0, eq).trim()] =
                  line.substring(eq + 1).trim();
            }
          }

          if (businessIdFilter != null && businessIdFilter.isNotEmpty) {
            final hubBiz = txtMap['business_id'] ?? '';
            // ESTRICTO: si el filtro está activo y el hub no anuncia
            // business_id, o anuncia uno distinto, se excluye. La versión
            // anterior incluía hubs "legacy" sin business_id por
            // compatibilidad, lo que en una LAN compartida (dos negocios
            // en la misma red) hace que un cliente termine usando el
            // agente del otro negocio.
            if (hubBiz.isEmpty || hubBiz != businessIdFilter) {
              continue;
            }
          }

          String? ipv4;
          try {
            final ipList = await client
                .lookup<IPAddressResourceRecord>(
                  ResourceRecordQuery.addressIPv4(srv.target),
                )
                .toList();
            if (ipList.isNotEmpty) {
              ipv4 = ipList.first.address.address;
            }
          } catch (_) {/* sin IPv4, dejamos host .local */}

          final agent = DiscoveredAgent(
            name: ptr.domainName.split('.').first.replaceAll('\\032', ' '),
            host: srv.target,
            ip: ipv4,
            port: srv.port,
            agentUuid: txtMap['agent_uuid']?.isNotEmpty == true
                ? txtMap['agent_uuid']
                : null,
            businessId: txtMap['business_id']?.isNotEmpty == true
                ? txtMap['business_id']
                : null,
            version: txtMap['version'],
            cloudQueue: txtMap['cloud_queue']?.toLowerCase() == 'true',
          );

          // Dedup por baseUrl (mismo agent puede anunciarse en varias
          // interfaces de red).
          results[agent.baseUrl] = agent;
        } catch (e) {
          debugPrint('[AgentDiscovery] error procesando PTR: $e');
        }
      }
    } catch (e) {
      debugPrint('[AgentDiscovery] mDNS falló: $e');
    } finally {
      client.stop();
      await AndroidNetLock.releaseMulticastLock();
    }

    return results.values.toList(growable: false);
  }
}
