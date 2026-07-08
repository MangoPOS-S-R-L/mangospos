import '../../storage/storage_service.dart';
import 'hub_mode.dart';

/// Puertos donde puede vivir el servidor `/hub/*`:
///   - [kHubPortPrimary] (4000): el agente Dart en-proceso en Mac/tablet/móvil
///     (que ya corre para impresión) también sirve el Hub.
///   - [kHubPortAlt] (4100): en Windows/Linux el 4000 lo ocupa el agente Node
///     de impresión, así que el equipo Hub levanta un servidor Dart DEDICADO
///     en este puerto solo para `/hub/*` (ver HubServerController).
/// El cliente prueba AMBOS puertos al localizar el Hub, para que el usuario no
/// tenga que saber en qué plataforma corre.
const int kHubPortPrimary = 4000;
const int kHubPortAlt = 4100;

/// Política de RED del local (business-level, en `business_settings.network_mode`).
///
/// - [cloud]: cada caja habla directo con Supabase (comportamiento actual).
/// - [hub]: la caja principal es el servidor central de la LAN; todas las
///   cajas leen/escriben de ella y el Hub es la única subida a Supabase.
enum NetworkPolicy { cloud, hub }

/// Rol de ESTE dispositivo cuando la política del local es [NetworkPolicy.hub]
/// (device-level, en el almacenamiento local del equipo).
///
/// - [pos]: caja normal — habla al Hub por LAN.
/// - [hub]: este equipo ES el Hub (autoridad LAN + única subida).
/// - [hubBackup]: respaldo — opera como [pos] hasta que un failover lo
///   promueva (H7). Hoy se comporta como cliente.
enum HubDeviceRole { pos, hub, hubBackup }

/// Modo operativo resuelto de ESTE terminal en el mundo LAN-first. Evolución de
/// [HubMode] que distingue "soy el Hub" de "soy una caja hablando al Hub".
///
/// - [cloud]: nube directa (política cloud + internet, o feature apagada).
/// - [solo]: sin internet y sin Hub → cola local propia (F1/F2).
/// - [hubHost]: este dispositivo ES el Hub (sirve la LAN + único uplink).
/// - [hubClient]: este dispositivo es una caja que lee/escribe del Hub por LAN.
enum TerminalMode { cloud, solo, hubHost, hubClient }

NetworkPolicy networkPolicyFromString(String? raw) =>
    raw == 'hub' ? NetworkPolicy.hub : NetworkPolicy.cloud;

String networkPolicyToString(NetworkPolicy p) =>
    p == NetworkPolicy.hub ? 'hub' : 'cloud';

HubDeviceRole hubDeviceRoleFromString(String? raw) {
  switch (raw) {
    case 'hub':
      return HubDeviceRole.hub;
    case 'hub_backup':
      return HubDeviceRole.hubBackup;
    default:
      return HubDeviceRole.pos;
  }
}

String hubDeviceRoleToString(HubDeviceRole r) {
  switch (r) {
    case HubDeviceRole.hub:
      return 'hub';
    case HubDeviceRole.hubBackup:
      return 'hub_backup';
    case HubDeviceRole.pos:
      return 'pos';
  }
}

/// Resolución PURA del modo operativo del terminal (sin I/O, testeable). Es el
/// corazón del ruteo LAN-first (D2): con la política `hub` activa, una caja
/// habla al Hub AUNQUE tenga internet — el WAN de cada equipo sale del camino
/// crítico. El cableado real (consumir esto en los viewmodels) es H4.
///
/// Reglas:
/// - Feature apagada o política `cloud` → comportamiento actual: cloud con
///   internet, solo sin internet.
/// - Política `hub` + este equipo es el Hub → [TerminalMode.hubHost].
/// - Política `hub` + caja (pos/backup) + Hub alcanzable → [TerminalMode.hubClient]
///   (LAN-first, ignora `isConnected`).
/// - Política `hub` + caja + Hub caído → cae a nube si hay internet, si no solo.
///   (La promoción del backup a host es H7.)
TerminalMode resolveTerminalMode({
  required NetworkPolicy policy,
  required HubDeviceRole role,
  required bool isConnected,
  required bool hubReachable,
  bool hubEnabled = kHubModeEnabled,
}) {
  if (!hubEnabled || policy == NetworkPolicy.cloud) {
    return isConnected ? TerminalMode.cloud : TerminalMode.solo;
  }
  if (role == HubDeviceRole.hub) {
    return TerminalMode.hubHost;
  }
  // Cajas (pos) y backup: LAN-first mientras el Hub esté alcanzable.
  if (hubReachable) return TerminalMode.hubClient;
  return isConnected ? TerminalMode.cloud : TerminalMode.solo;
}

/// Config del Hub a nivel de DISPOSITIVO (rol + URL del Hub primario/backup).
/// Persistida en [StorageService] (SharedPreferences), namespaced por negocio,
/// porque "quién es el Hub" es una decisión por-instalación, no del negocio.
/// La URL primaria reusa la key `hub_primary_url_<businessId>` que ya lee
/// [HubModeController].
class HubConfigService {
  static String _roleKey(String businessId) => 'hub_device_role_$businessId';
  static String _primaryUrlKey(String businessId) =>
      'hub_primary_url_$businessId';
  static String _backupUrlKey(String businessId) => 'hub_backup_url_$businessId';

  Future<HubDeviceRole> getDeviceRole(String businessId) async {
    if (businessId.isEmpty) return HubDeviceRole.pos;
    final storage = await StorageService.getInstance();
    return hubDeviceRoleFromString(await storage.read(_roleKey(businessId)));
  }

  Future<void> setDeviceRole(String businessId, HubDeviceRole role) async {
    if (businessId.isEmpty) return;
    final storage = await StorageService.getInstance();
    await storage.write(_roleKey(businessId), hubDeviceRoleToString(role));
  }

  /// URL/IP del Hub primario que las cajas usan para conectarse (p.ej.
  /// `http://192.168.1.50:4000`). En el equipo Hub queda null (él es el host).
  Future<String?> getHubUrl(String businessId) async {
    if (businessId.isEmpty) return null;
    final storage = await StorageService.getInstance();
    final raw = await storage.read(_primaryUrlKey(businessId));
    return (raw == null || raw.trim().isEmpty) ? null : raw.trim();
  }

  Future<void> setHubUrl(String businessId, String? url) async {
    if (businessId.isEmpty) return;
    final storage = await StorageService.getInstance();
    final clean = url?.trim() ?? '';
    if (clean.isEmpty) {
      await storage.delete(_primaryUrlKey(businessId));
    } else {
      await storage.write(_primaryUrlKey(businessId), clean);
    }
  }

  Future<String?> getBackupUrl(String businessId) async {
    if (businessId.isEmpty) return null;
    final storage = await StorageService.getInstance();
    final raw = await storage.read(_backupUrlKey(businessId));
    return (raw == null || raw.trim().isEmpty) ? null : raw.trim();
  }

  Future<void> setBackupUrl(String businessId, String? url) async {
    if (businessId.isEmpty) return;
    final storage = await StorageService.getInstance();
    final clean = url?.trim() ?? '';
    if (clean.isEmpty) {
      await storage.delete(_backupUrlKey(businessId));
    } else {
      await storage.write(_backupUrlKey(businessId), clean);
    }
  }
}
