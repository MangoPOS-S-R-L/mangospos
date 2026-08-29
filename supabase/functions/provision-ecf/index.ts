// provision-ecf: activa la facturacion electronica de un negocio YA certificado,
// sin tener que meter SQL a mano.
//
// POST /functions/v1/provision-ecf
//
// Request:
//   { business_id: uuid,
//     alanube_company_id: string,      // ULID de la company en Alanube
//     mode?: "electronic" | "hybrid",  // default hybrid
//     certification_status?: "pending"|"in_progress"|"certified"|"rejected",
//     dry_run?: boolean }              // true = solo preflight, no escribe
//
// Response 200: { ok, wrote, environment, company, settings, checks[] }
//   `checks` es el semaforo que pinta la pantalla de Ajustes -> Fiscal.
//
// Errores:
//   400 invalid_request         — body invalido
//   401 unauthorized            — sin JWT
//   403 forbidden               — el usuario no es owner/admin del negocio
//   404 company_not_found       — el ULID no existe en Alanube
//   409 company_already_assigned— ese ULID ya es de otro negocio
//   409 preflight_failed        — hay chequeos en `fail`; NO se escribio nada
//   500 config_error / db_error / rpc_error, 502 alanube_error
//
// El chequeo que justifica esta funcion: comparar el RNC que Alanube tiene
// registrado contra `fiscal_settings.rnc`. Activar un negocio con el ULID de
// OTRO contribuyente hace que sus comprobantes se firmen con el certificado
// ajeno — un error que por SQL manual no lo detiene nadie.
//
// La escritura va con service_role a proposito: `business_alanube_settings`
// tiene RLS con policy de SELECT unicamente, asi que la app (authenticated)
// puede leer esa config pero nunca escribirla. Toda activacion pasa por aqui.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { createAlanubeClient, AlanubeError } from "../_shared/alanube-client.ts";
import { corsPreflight, errorResponse, jsonResponse } from "../_shared/responses.ts";
import {
  AlanubeCompany,
  buildChecks,
  environmentFromBaseUrl,
  ItemTaxCounts,
  SequenceRow,
  worstLevel,
} from "../_shared/ecf-preflight.ts";
import { EcfTaxRef, isExcludedFromEcf, unwrapTax } from "../_shared/ecf-tax-lines.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

const ALLOWED_ROLES = new Set(["owner", "admin"]);
const WEBHOOK_PATH = "/functions/v1/alanube-webhook";
const CERTIFICATION_STATUSES = ["pending", "in_progress", "certified", "rejected"];

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface RequestBody {
  business_id?: string;
  alanube_company_id?: string;
  mode?: string;
  certification_status?: string;
  dry_run?: boolean;
}

Deno.serve(async (req: Request) => {
  const pre = corsPreflight(req);
  if (pre) return pre;

  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Use POST");
  }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return errorResponse(
      500,
      "config_error",
      "Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.",
    );
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return errorResponse(401, "unauthorized", "Falta el Bearer token");
  }

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_request", "El body debe ser JSON");
  }

  const businessId = body.business_id?.trim() ?? "";
  if (!UUID_RE.test(businessId)) {
    return errorResponse(400, "invalid_request", "business_id debe ser un UUID");
  }

  const companyId = body.alanube_company_id?.trim() ?? "";
  if (companyId.length === 0) {
    return errorResponse(
      400,
      "invalid_request",
      "alanube_company_id es obligatorio (el ULID de la empresa en Alanube)",
    );
  }

  // 'physical' se excluye a proposito: aprovisionar asi deja al negocio
  // emitiendo serie E que el trigger nunca encola — el limbo silencioso que
  // esta funcion existe para evitar.
  const mode = body.mode ?? "hybrid";
  if (mode !== "electronic" && mode !== "hybrid") {
    return errorResponse(400, "invalid_request", "mode debe ser 'electronic' o 'hybrid'");
  }

  const certificationStatus = body.certification_status ?? "certified";
  if (!CERTIFICATION_STATUSES.includes(certificationStatus)) {
    return errorResponse(400, "invalid_request", "certification_status invalido");
  }

  const dryRun = body.dry_run === true;

  // ── 1. Autorizacion: owner/admin del negocio ────────────────────────────
  const userClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: authHeader } },
  });

  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) {
    return errorResponse(401, "unauthorized", "No se pudo resolver el usuario del JWT");
  }

  const { data: role, error: roleErr } = await userClient.rpc("user_business_role", {
    _user_id: userData.user.id,
    _business_id: businessId,
  });
  if (roleErr) {
    return errorResponse(500, "rpc_error", "No se pudo resolver el rol", roleErr.message);
  }
  if (!role || !ALLOWED_ROLES.has(role as string)) {
    return errorResponse(
      403,
      "forbidden",
      "Solo el owner o un admin del negocio puede activar la facturacion electronica",
    );
  }

  // ── 2. Cliente Alanube ──────────────────────────────────────────────────
  let alanube;
  try {
    alanube = createAlanubeClient();
  } catch (e) {
    return errorResponse(
      500,
      "config_error",
      "El servidor no tiene configurado Alanube (ALANUBE_BASE_URL / ALANUBE_JWT).",
      e instanceof Error ? e.message : String(e),
    );
  }
  const environment = environmentFromBaseUrl(Deno.env.get("ALANUBE_BASE_URL") ?? "");

  const service = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // ── 3. Estado actual del negocio ────────────────────────────────────────
  const [fsRes, bizRes, seqRes, existingRes, takenRes] = await Promise.all([
    service
      .from("fiscal_settings")
      .select("rnc, business_legal_name, ecf_enabled, default_ncf_type")
      .eq("business_id", businessId)
      .maybeSingle(),
    service
      .from("businesses")
      .select("business_name, branch_name, address")
      .eq("id", businessId)
      .maybeSingle(),
    service
      .from("ncf_sequences")
      .select("ncf_type, range_start, range_end, current_number, expiration_date, is_active")
      .eq("business_id", businessId),
    service
      .from("business_alanube_settings")
      .select("id")
      .eq("business_id", businessId)
      .maybeSingle(),
    service
      .from("business_alanube_settings")
      .select("business_id")
      .eq("alanube_company_id", companyId)
      .maybeSingle(),
  ]);

  if (bizRes.error || !bizRes.data) {
    return errorResponse(404, "business_not_found", "El negocio no existe", bizRes.error?.message);
  }

  const fs = fsRes.data as
    | { rnc: string | null; business_legal_name: string | null; ecf_enabled: boolean | null }
    | null;
  const biz = bizRes.data as { address: string | null };

  // ULID ya asignado a OTRO negocio. La tabla tiene UNIQUE en
  // alanube_company_id, asi que el insert reventaria igual — pero con un 23505
  // criptico en vez de decir de quien es.
  const taken = takenRes.data as { business_id: string } | null;
  if (taken && taken.business_id !== businessId) {
    return errorResponse(
      409,
      "company_already_assigned",
      "Ese ULID de Alanube ya esta asignado a otro negocio de esta instalacion.",
      { assigned_to_business_id: taken.business_id },
    );
  }

  // ── 4. La empresa en Alanube ────────────────────────────────────────────
  // OJO: tiene que ser /companies/{id}. `GET /companies` a secas devuelve
  // SIEMPRE la empresa principal de la cuenta e ignora X-Company-Id, asi que
  // filtrar por ahi da falsos negativos.
  let company: AlanubeCompany;
  try {
    company = await alanube.request<AlanubeCompany>({
      method: "GET",
      path: `/companies/${encodeURIComponent(companyId)}`,
    });
  } catch (e) {
    const err = e as AlanubeError;
    if (err.status === 404) {
      return errorResponse(
        404,
        "company_not_found",
        "Alanube no reconoce ese ULID. Verificalo en el portal (Network -> X-Company-Id).",
      );
    }
    return errorResponse(
      502,
      "alanube_error",
      `Alanube respondio ${err.status} al consultar la empresa`,
      err.body,
    );
  }

  // ── 5. Productos sin impuesto vinculado ─────────────────────────────────
  let itemTaxes: ItemTaxCounts | null = null;
  try {
    // Se traen los impuestos de cada producto para poder separar dos casos que
    // no son lo mismo: el producto sin ningun impuesto (error de config) y el
    // que solo lleva impuestos excluidos del e-CF, como la Ley 10% (se declara
    // exento, y puede ser correcto).
    const { data: itemRows, error: itemsErr } = await service
      .from("menu_items")
      .select("id, menu_item_taxes(taxes(include_in_ecf, name, rate))")
      .eq("business_id", businessId)
      .eq("is_active", true)
      .limit(5000);
    if (itemsErr) throw new Error(itemsErr.message);

    const rows = (itemRows ?? []) as Array<{
      id: string;
      menu_item_taxes: Array<{ taxes: EcfTaxRef | EcfTaxRef[] | null }> | null;
    }>;

    let sinImpuesto = 0;
    let soloExcluidos = 0;
    for (const r of rows) {
      const links = r.menu_item_taxes ?? [];
      if (links.length === 0) {
        sinImpuesto++;
        continue;
      }
      const entraAlEcf = links.some((l) => !isExcludedFromEcf(unwrapTax(l.taxes)));
      if (!entraAlEcf) soloExcluidos++;
    }
    itemTaxes = { total: rows.length, sinImpuesto, soloExcluidos };
  } catch (e) {
    console.error("preflight item_taxes falló:", e);
    itemTaxes = null;
  }

  // ── 6. Preflight ────────────────────────────────────────────────────────
  const checks = buildChecks({
    fiscal: fs ? { rnc: fs.rnc, business_legal_name: fs.business_legal_name } : null,
    business: { address: biz.address },
    company,
    sequences: (seqRes.data ?? []) as SequenceRow[],
    itemTaxes,
    webhookPath: WEBHOOK_PATH,
  });

  const companySummary = {
    id: company.id,
    name: company.name,
    tradeName: company.tradeName,
    identification: company.identification,
    address: company.address,
    type: company.type,
    certificationStep: company.certificationStep,
  };

  if (worstLevel(checks) === "fail") {
    return jsonResponse(
      { ok: false, wrote: false, reason: "preflight_failed", environment, company: companySummary, checks },
      { status: 409 },
    );
  }

  if (dryRun) {
    return jsonResponse({
      ok: true,
      wrote: false,
      dry_run: true,
      environment,
      company: companySummary,
      checks,
    });
  }

  // ── 7. Escribir la configuracion ────────────────────────────────────────
  const existing = existingRes.data as { id: string } | null;
  const payload = {
    business_id: businessId,
    alanube_company_id: companyId,
    environment,
    certification_status: certificationStatus,
    mode,
    webhooks_configured: JSON.stringify(company.webhooks ?? {}).includes(WEBHOOK_PATH),
  };
  const returning =
    "id, business_id, alanube_company_id, environment, mode, certification_status, webhooks_configured";

  const { data: saved, error: saveErr } = existing
    ? await service
        .from("business_alanube_settings")
        .update(payload)
        .eq("business_id", businessId)
        .select(returning)
        .single()
    : await service
        .from("business_alanube_settings")
        .insert(payload)
        .select(returning)
        .single();

  if (saveErr) {
    return errorResponse(500, "db_error", "No se pudo guardar la configuracion de Alanube", saveErr.message);
  }

  return jsonResponse({
    ok: true,
    wrote: true,
    updated: existing !== null,
    environment,
    company: companySummary,
    settings: saved,
    checks,
    next_step: fs?.ecf_enabled === true
      ? "El negocio ya tiene la modalidad e-CF encendida: el proximo cobro emite."
      : "Falta encender 'Modalidad e-CF' en Ajustes -> Fiscal para que el POS emita serie E.",
  });
});
