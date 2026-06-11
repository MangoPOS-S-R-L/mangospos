// azul-3ds-session — crea una sesión 3DS para registrar/verificar la tarjeta
// del comercio (CIT con autenticación 3D Secure 2.0).
//
// POST /functions/v1/azul-3ds-session
// Headers: Authorization: Bearer <user_jwt>  (owner/admin del business)
// Body: { business_id: uuid }
// → { session_id, url }   ← la app abre `url` en el navegador del sistema.
//
// La página (azul-3ds-page) y los callbacks del ACS son públicos, autorizados
// por el session_id (uuid v4) + expires_at. Ver PRD-Azul-3DSecure §7/§9.

import { corsPreflight, errorResponse, jsonResponse } from "../_shared/responses.ts";
import { getAzulEnv } from "../_shared/env.ts";
import { getServiceClient, getUserClient } from "../_shared/supabase.ts";
import { generateTokenizeOrderNumber } from "../_shared/azul.ts";

const ALLOWED_ROLES = new Set(["owner", "admin"]);
const VERIFICATION_AMOUNT_CENTS = 100; // RD$1.00 (Hold + Void)

function isUuid(s: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
}

Deno.serve(async (req) => {
  const pre = corsPreflight(req);
  if (pre) return pre;

  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Use POST");
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return errorResponse(401, "unauthorized", "Missing Bearer token");
  }

  let body: { business_id?: string };
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_request", "Body must be JSON");
  }

  const businessId = body.business_id?.trim();
  if (!businessId || !isUuid(businessId)) {
    return errorResponse(400, "invalid_request", "business_id must be a valid UUID");
  }

  // Validar rol (owner/admin) sobre el business, respetando RLS.
  const userClient = getUserClient(authHeader);
  const { data: { user }, error: userErr } = await userClient.auth.getUser();
  if (userErr || !user) {
    return errorResponse(401, "unauthorized", "Invalid JWT");
  }
  const { data: role, error: roleErr } = await userClient.rpc("user_business_role", {
    _user_id: user.id,
    _business_id: businessId,
  });
  if (roleErr) {
    return errorResponse(500, "rpc_error", "Could not resolve user role", roleErr.message);
  }
  if (!role || !ALLOWED_ROLES.has(role as string)) {
    return errorResponse(403, "forbidden", "User is not owner/admin of business");
  }

  const service = getServiceClient();
  const { data: session, error: insErr } = await service
    .from("azul_payment_sessions")
    .insert({
      business_id: businessId,
      intent_type: "tokenize_and_verify",
      order_number: generateTokenizeOrderNumber(),
      amount_cents: VERIFICATION_AMOUNT_CENTS,
      currency_code: "DOP",
      status: "pending",
      threeds_flow: "none",
    })
    .select("id")
    .single();

  if (insErr || !session) {
    return errorResponse(500, "db_error", "No se pudo crear la sesión 3DS", insErr?.message);
  }

  const env = getAzulEnv();
  const base = env.publicCallbackBaseUrl.replace(/\/+$/, "");
  const url = `${base}/azul-3ds-page?sid=${session.id}`;

  return jsonResponse({ session_id: session.id, url });
});
