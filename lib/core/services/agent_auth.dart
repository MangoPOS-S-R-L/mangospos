// PRD 7 Fase 1.2 — Resolución del Bearer token al llamar al agente LAN.
//
// Orden de preferencia:
//   1. JWT actual de Supabase (`auth.currentSession?.accessToken`).
//      Es lo que el agente con `JWT_SECRET` configurado va a validar.
//   2. Token explícito pasado por el caller (apiToken inyectado).
//   3. Override de build via `--dart-define=MANGOPOS_AGENT_TOKEN=...`.
//   4. Fallback legacy hardcoded — solo útil contra agentes en modo
//      legacy (sin JWT_SECRET). Se mantiene para no romper rollout.
//
// Nota: el agente en modo legacy ignora el header, así que mandar el
// JWT real no rompe nada — solo activa la validación cuando el agente
// se configura con JWT_SECRET.

import 'package:supabase_flutter/supabase_flutter.dart';

const String _kBuildOverrideToken = String.fromEnvironment(
    'MANGOPOS_AGENT_TOKEN',
    defaultValue: '');

const String _kLegacyFallbackToken = 'MANGOPOS_SECURE_TOKEN_123';

/// Returns the Bearer token to send in `Authorization` when calling the
/// MangoPOS LAN agent. Prefer the live Supabase JWT so the agent can
/// validate `restaurant_id` per request.
String resolveAgentBearerToken({String? explicitToken}) {
  final supaToken = _currentSupabaseAccessToken();
  if (supaToken != null && supaToken.isNotEmpty) return supaToken;
  if (explicitToken != null && explicitToken.isNotEmpty) return explicitToken;
  if (_kBuildOverrideToken.isNotEmpty) return _kBuildOverrideToken;
  return _kLegacyFallbackToken;
}

String? _currentSupabaseAccessToken() {
  try {
    return Supabase.instance.client.auth.currentSession?.accessToken;
  } catch (_) {
    // Supabase puede no estar inicializado en arranque temprano o tests.
    return null;
  }
}
