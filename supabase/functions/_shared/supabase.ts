// Factory para clientes Supabase usados por las Edge Functions.
// Diferencia clave (PRD §10.6):
//   - serviceClient: rol service_role. Bypassa RLS. Solo backend, nunca cliente.
//   - userClient(jwt): rol del usuario autenticado. RLS se aplica.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { getAzulEnv } from "./env.ts";

let cachedService: SupabaseClient | null = null;

export function getServiceClient(): SupabaseClient {
  if (cachedService) return cachedService;
  const env = getAzulEnv();
  cachedService = createClient(env.supabaseUrl, env.supabaseServiceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return cachedService;
}

/**
 * Cliente firmado como el usuario que envió el JWT. Útil para validaciones
 * que respetan RLS (ej. confirmar que el usuario tiene acceso al business).
 */
export function getUserClient(authHeader: string | null): SupabaseClient {
  const env = getAzulEnv();
  return createClient(env.supabaseUrl, env.supabaseServiceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: authHeader ? { headers: { Authorization: authHeader } } : undefined,
  });
}
