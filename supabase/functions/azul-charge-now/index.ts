// azul-charge-now — cobro manual de la suscripción ("Pagar sistema"), iniciado
// por el dueño/admin desde la app.
//
// POST /functions/v1/azul-charge-now
// Auth: Bearer <user JWT>.   Body: { business_id }
//
// La función de cobro real (azul-charge-subscription) exige service_role, que el
// cliente no tiene. Esta capa fina: (1) autentica al usuario por su JWT y valida
// que sea owner/admin del business, (2) resuelve la membership anchor + verifica
// que haya tarjeta default verificada, (3) delega en azul-charge-subscription con
// service_role para el período vigente. Reusa toda su lógica/idempotencia.
//
// El intento se alinea con la política de reintentos (current_attempt_number+1,
// tope 3) para compartir la llave de idempotencia con el cron y NO duplicar cobro.

import { corsPreflight, errorResponse, jsonResponse } from "../_shared/responses.ts";
import { getAzulEnv } from "../_shared/env.ts";
import { getServiceClient, getUserClient } from "../_shared/supabase.ts";

const ALLOWED_ROLES = new Set(["owner", "admin"]);

function isUuid(s: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
}

Deno.serve(async (req) => {
  const pre = corsPreflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed", "Use POST");

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return errorResponse(401, "unauthorized", "Falta el token de sesión");
  }

  let body: { business_id?: string };
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_request", "El body debe ser JSON");
  }
  const businessId = body.business_id?.trim();
  if (!businessId || !isUuid(businessId)) {
    return errorResponse(400, "invalid_request", "business_id inválido");
  }

  // 1. Autorización: el usuario debe ser owner/admin del business.
  const userClient = getUserClient(authHeader);
  const { data: { user }, error: userErr } = await userClient.auth.getUser();
  if (userErr || !user) return errorResponse(401, "unauthorized", "Sesión inválida");

  const { data: role, error: roleErr } = await userClient.rpc("user_business_role", {
    _user_id: user.id,
    _business_id: businessId,
  });
  if (roleErr) {
    return errorResponse(500, "rpc_error", "No se pudo resolver el rol", roleErr.message);
  }
  if (!role || !ALLOWED_ROLES.has(role as string)) {
    return errorResponse(403, "forbidden", "No tienes permiso para cobrar este negocio");
  }

  const service = getServiceClient();

  // 2. Resolver la membership anchor + estado.
  const { data: membership, error: mErr } = await service
    .from("memberships")
    .select("id, billing_status, current_attempt_number, next_billing_date")
    .eq("business_id", businessId)
    .eq("is_billing_anchor", true)
    .maybeSingle();
  if (mErr) {
    return errorResponse(500, "db_error", "No se pudo cargar la suscripción", mErr.message);
  }
  if (!membership) {
    return errorResponse(404, "no_membership", "Este negocio no tiene una suscripción configurada");
  }
  if (membership.billing_status === "cancelled") {
    return errorResponse(409, "cancelled", "La suscripción está cancelada. Elige un plan para reactivarla.");
  }
  if (membership.billing_status === "suspended") {
    return errorResponse(409, "suspended", "La suscripción está suspendida. Elige un plan para reactivarla.");
  }

  // Gate de 48h: el cobro MANUAL solo se habilita dentro de las 48h previas a la
  // fecha de cobro (o si ya está vencida). El cobro AUTOMÁTICO (cron) llama
  // directo a azul-charge-subscription y NO pasa por acá, así que no le aplica.
  const nextStr = membership.next_billing_date as string | null;
  if (!nextStr) {
    return errorResponse(422, "no_billing_date", "Aún no hay una fecha de cobro programada.");
  }
  const nextMs = new Date(`${nextStr}T00:00:00Z`).getTime();
  const WINDOW_MS = 48 * 60 * 60 * 1000;
  if (Date.now() < nextMs - WINDOW_MS) {
    return errorResponse(
      409,
      "too_early",
      `El pago se habilita 48 horas antes de tu fecha de cobro (${nextStr}).`,
      { next_billing_date: nextStr },
    );
  }

  // 3. Verificar que haya tarjeta default verificada (mensaje claro antes de cobrar).
  const { data: pm } = await service
    .from("azul_payment_methods")
    .select("id, status")
    .eq("business_id", businessId)
    .eq("is_default", true)
    .maybeSingle();
  if (!pm) {
    return errorResponse(422, "no_payment_method", "No hay una tarjeta registrada para cobrar.");
  }
  if (pm.status !== "verified") {
    return errorResponse(422, "payment_method_not_verified", "La tarjeta aún no está verificada.");
  }

  // 4. Intento alineado con la política de reintentos (idempotencia compartida
  //    con el cron): siguiente intento del período vigente, tope 3.
  const attempt = Math.min((membership.current_attempt_number ?? 0) + 1, 3);

  // 5. Disparar el cobro real (service_role → azul-charge-subscription).
  const env = getAzulEnv();
  const fnUrl = `${env.supabaseUrl.replace(/\/$/, "")}/functions/v1/azul-charge-subscription`;
  let res: Response;
  try {
    res = await fetch(fnUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        // service_role como Bearer (lo exige azul-charge-subscription) y como
        // apikey (lo exige el gateway kong en self-hosted para enrutar la fn).
        Authorization: `Bearer ${env.supabaseServiceRoleKey}`,
        apikey: env.supabaseServiceRoleKey,
      },
      body: JSON.stringify({ membership_id: membership.id, attempt_number: attempt }),
    });
  } catch (e) {
    return errorResponse(
      502,
      "charge_unreachable",
      `No se pudo contactar el cobro: ${e instanceof Error ? e.message : String(e)}`,
    );
  }

  const text = await res.text();
  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch {
    data = { error: { code: "bad_response", message: text.slice(0, 300) } };
  }
  // Pass-through del status + body de azul-charge-subscription (approved 200 ok:true,
  // declined 200 ok:false, error 4xx/5xx con { error }).
  return jsonResponse(data, { status: res.status });
});
