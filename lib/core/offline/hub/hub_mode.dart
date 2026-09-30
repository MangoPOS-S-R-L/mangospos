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
/// El controlador prepara y descubre el Hub automaticamente para cada negocio,
/// incluyendo negocios con network_mode legacy 'cloud'. La preparacion inicial
/// requiere autenticacion, token privado y concesion de Hub con internet.
/// Validar en hardware antes de un release general.
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
