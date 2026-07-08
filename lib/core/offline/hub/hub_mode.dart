/// Modo de operación de un terminal respecto al backend (F3).
///
/// - [cloud]: hay internet → habla directo con Supabase (comportamiento de
///   siempre, intacto).
/// - [hub]: sin internet pero hay un Hub Local alcanzable en la LAN → las
///   mutaciones van al Hub y se lee/escucha de él.
/// - [solo]: sin internet y sin Hub → cola local propia (F1/F2).
enum HubMode { cloud, hub, solo }

/// Flag maestro del modo híbrido Hub LAN-first. Mientras esté en `false`, la
/// detección de Hub queda desactivada y el terminal solo alterna entre
/// `cloud` (con red) y `solo` (sin red) — exactamente el comportamiento actual.
///
/// ENCENDIDO (2026-07-08) para pruebas multi-dispositivo. IMPORTANTE: encender
/// esto NO cambia nada para los negocios con `business_settings.network_mode =
/// 'cloud'` (el default) — `resolveTerminalMode` devuelve cloud/solo y no se
/// sondea la LAN. Solo los negocios que pongan la política en `hub` (Ajustes →
/// Red local) entran al ruteo LAN-first. Validar en hardware antes de un
/// release general. Ver docs/PRD_HUB_HIBRIDO_LAN_FIRST.md.
const bool kHubModeEnabled = true;

/// Resolución PURA del modo a partir de las señales. Sin I/O, para poder
/// testearla sin red. El orden importa: internet manda (cloud); sin internet,
/// solo entramos a `hub` si la feature está activa Y hay Hub alcanzable.
HubMode resolveHubMode({
  required bool isConnected,
  required bool hubReachable,
  bool hubEnabled = kHubModeEnabled,
}) {
  if (isConnected) return HubMode.cloud;
  if (hubEnabled && hubReachable) return HubMode.hub;
  return HubMode.solo;
}
