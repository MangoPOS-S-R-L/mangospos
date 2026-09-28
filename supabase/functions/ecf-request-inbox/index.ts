// ecf-request-inbox: recibe las solicitudes de facturacion electronica que
// hacen los clientes de OTRAS apps que comparten esta cuenta de Alanube (hoy
// Busi Pos Web / flutter_shop+), para que se atiendan en un solo panel.
//
// POST /functions/v1/ecf-request-inbox
//   Header: X-Ecf-Panel-Secret: <ECF_PANEL_NOTIFY_SECRET>
//   Body:   { source, company_id, company_name, rnc, legal_name, trade_name,
//             email, contact_name, contact_phone, already_authorized,
//             alanube_company_id, company_registered, requested_at }
//
// Servidor a servidor: NO lleva JWT de usuario. Esas apps corren en otro
// proyecto de Supabase, con sus propios usuarios y sus propias empresas, asi
// que no hay identidad que validar acá — solo el secreto compartido.
//
// Idempotente: un reenvio del mismo (source, company_id) actualiza la fila en
// vez de crear otra. El cliente reintenta cuando el alta con Alanube falla.
//
// NO recibe ni guarda el certificado digital: ese viaja directo de esa app a
// Alanube.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsPreflight, errorResponse, jsonResponse } from "../_shared/responses.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const PANEL_SECRET = Deno.env.get("ECF_PANEL_NOTIFY_SECRET") ?? "";

/** Comparacion en tiempo constante: no filtrar el secreto por el tiempo. */
function secretMatches(provided: string): boolean {
  if (PANEL_SECRET.length === 0) return false;
  const a = new TextEncoder().encode(provided);
  const b = new TextEncoder().encode(PANEL_SECRET);
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

function clean(v: unknown): string | null {
  const t = (v ?? "").toString().trim();
  return t.length > 0 ? t : null;
}

Deno.serve(async (req: Request) => {
  const pre = corsPreflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed", "Use POST");
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return errorResponse(500, "config_error", "Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY.");
  }
  if (!PANEL_SECRET) {
    return errorResponse(500, "config_error", "El servidor no tiene ECF_PANEL_NOTIFY_SECRET.");
  }

  if (!secretMatches(req.headers.get("x-ecf-panel-secret") ?? "")) {
    return errorResponse(401, "unauthorized", "Secreto invalido");
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_request", "El body debe ser JSON");
  }

  const source = clean(body.source);
  const externalId = clean(body.company_id);
  if (!source || !externalId) {
    return errorResponse(400, "invalid_request", "Faltan source y company_id");
  }

  const service = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // `received_at` y `status` NO se tocan en el reenvio: si alguien ya la tomo,
  // un reintento del cliente no la devuelve a la bandeja como nueva.
  const { error } = await service
    .from("external_ecf_requests")
    .upsert(
      {
        source,
        external_id: externalId,
        company_name: clean(body.company_name),
        rnc: clean(body.rnc),
        legal_name: clean(body.legal_name),
        trade_name: clean(body.trade_name),
        email: clean(body.email),
        contact_name: clean(body.contact_name),
        contact_phone: clean(body.contact_phone),
        already_authorized: body.already_authorized === true,
        alanube_company_id: clean(body.alanube_company_id),
        company_registered: body.company_registered === true,
        requested_at: clean(body.requested_at),
        updated_at: new Date().toISOString(),
      },
      { onConflict: "source,external_id" },
    );

  if (error) {
    console.error("ecf-request-inbox: no se pudo guardar", error.message);
    return errorResponse(500, "db_error", "No se pudo guardar la solicitud", error.message);
  }

  return jsonResponse({ ok: true });
});
