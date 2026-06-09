// PRD §7.5 — azul-charge-subscription (Fase 4)
//
// POST /functions/v1/azul-charge-subscription
// Body: { membership_id: uuid, attempt_number?: 1..3, billing_period_start?: "YYYY-MM-DD" }
//
// Cobra UNA mensualidad de UNA suscripción (membership con is_billing_anchor) usando
// el DataVaultToken de su tarjeta default, vía el Web Service de Azul (ProcessPayment
// Sale) a través del sidecar mTLS. Invocada server-to-server por el cron (Fase 6) o
// manualmente con el service_role bearer.
//
// Notas de diseño (validadas en pruebas 2026-06-09 contra pruebas.azul.com.do):
//   - El cobro por WS NO usa AuthHash — la autenticación es el mTLS + Auth1/Auth2 del
//     sidecar. chargeWithToken ya manda los campos correctos.
//   - OrderNumber debe ser alfanumérico ≤15 (ver generateChargeOrderNumber).
//   - Idempotencia: el índice UNIQUE (membership_id, billing_period_start,
//     attempt_number) de azul_charges es el candado; si choca, devolvemos la charge
//     existente sin recobrar.
//   - Política de reintentos D11: intentos 1/2/3; tras el 3º declinado → suspended.

import { corsPreflight, errorResponse, jsonResponse } from "../_shared/responses.ts";
import { getAzulEnv } from "../_shared/env.ts";
import { getServiceClient } from "../_shared/supabase.ts";
import { generateChargeOrderNumber } from "../_shared/azul.ts";
import { AzulCallError, chargeWithToken } from "../_shared/azul-api.ts";

interface RequestBody {
  membership_id?: string;
  attempt_number?: number;
  billing_period_start?: string;
}

function isUuid(s: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
}

function todayUtcIso(): string {
  return new Date().toISOString().slice(0, 10);
}

function addDaysIso(baseIso: string, days: number): string {
  const d = new Date(`${baseIso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

function addMonthIso(baseIso: string): string {
  const d = new Date(`${baseIso}T00:00:00Z`);
  d.setUTCMonth(d.getUTCMonth() + 1);
  return d.toISOString().slice(0, 10);
}

Deno.serve(async (req) => {
  const pre = corsPreflight(req);
  if (pre) return pre;

  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Use POST");
  }

  // Auth server-to-server: Bearer <service_role>.
  const env = getAzulEnv();
  const authHeader = req.headers.get("Authorization") ?? "";
  if (authHeader !== `Bearer ${env.supabaseServiceRoleKey}`) {
    return errorResponse(401, "unauthorized", "Service role required");
  }

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_request", "Body must be JSON");
  }

  const membershipId = body.membership_id?.trim();
  if (!membershipId || !isUuid(membershipId)) {
    return errorResponse(400, "invalid_request", "membership_id must be a valid UUID");
  }

  const attempt = body.attempt_number ?? 1;
  if (!Number.isInteger(attempt) || attempt < 1 || attempt > 3) {
    return errorResponse(400, "invalid_request", "attempt_number must be 1, 2 or 3");
  }

  const service = getServiceClient();

  // 1. Cargar membership (anchor) + plan + tarjeta default verificada.
  const { data: membership, error: mErr } = await service
    .from("memberships")
    .select(
      "id, business_id, plan_id, is_billing_anchor, billing_status, current_period_start, current_period_end, next_billing_date, current_attempt_number",
    )
    .eq("id", membershipId)
    .maybeSingle();

  if (mErr) {
    return errorResponse(500, "db_error", "Could not load membership", mErr.message);
  }
  if (!membership) {
    return errorResponse(404, "not_found", "Membership not found");
  }
  if (!membership.is_billing_anchor) {
    return errorResponse(422, "not_billing_anchor", "Membership is not the billing anchor");
  }
  if (!membership.plan_id) {
    return errorResponse(422, "no_plan", "Membership has no plan_id");
  }

  const { data: plan, error: pErr } = await service
    .from("plans")
    .select("price_cents_monthly, currency_code")
    .eq("id", membership.plan_id)
    .maybeSingle();
  if (pErr || !plan) {
    return errorResponse(422, "plan_not_found", "Plan not found for membership");
  }

  const { data: pm, error: pmErr } = await service
    .from("azul_payment_methods")
    .select("id, data_vault_token, status")
    .eq("business_id", membership.business_id)
    .eq("is_default", true)
    .maybeSingle();
  if (pmErr) {
    return errorResponse(500, "db_error", "Could not load payment method", pmErr.message);
  }
  if (!pm) {
    return errorResponse(422, "no_payment_method", "No default payment method for business");
  }
  if (pm.status !== "verified") {
    return errorResponse(422, "payment_method_not_verified", `Payment method status is '${pm.status}'`);
  }

  // 2. Monto. v1 sin prorrateo (azul_plan_adjustments no existe todavía).
  const amountCents = plan.price_cents_monthly as number;
  const itbisCents = 0;
  const currencyCode = (plan.currency_code as string) ?? "DOP";

  // 3. Período de facturación.
  const today = todayUtcIso();
  const periodStart = (body.billing_period_start ?? membership.next_billing_date ??
    membership.current_period_end ?? today) as string;
  const periodEnd = addMonthIso(periodStart);

  // 4. OrderNumber determinístico (≤15 alfanumérico).
  const orderNumber = generateChargeOrderNumber(
    membershipId,
    new Date(`${periodStart}T00:00:00Z`),
    attempt,
  );

  // 5. INSERT charge en estado pending. El UNIQUE (membership, período, intento) es
  //    el candado de idempotencia.
  const nowIso = new Date().toISOString();
  const { data: charge, error: insErr } = await service
    .from("azul_charges")
    .insert({
      business_id: membership.business_id,
      membership_id: membershipId,
      payment_method_id: pm.id,
      order_number: orderNumber,
      billing_period_start: periodStart,
      billing_period_end: periodEnd,
      attempt_number: attempt,
      amount_cents: amountCents,
      itbis_cents: itbisCents,
      currency_code: currencyCode,
      status: "pending",
      attempted_at: nowIso,
    })
    .select("id")
    .single();

  if (insErr) {
    // 23505 = unique_violation → ya existe una charge para (membership, período, intento).
    if (insErr.code === "23505") {
      const { data: existing } = await service
        .from("azul_charges")
        .select("id, status, iso_code, azul_order_id, response_message")
        .eq("membership_id", membershipId)
        .eq("billing_period_start", periodStart)
        .eq("attempt_number", attempt)
        .maybeSingle();
      if (existing) {
        return jsonResponse({
          ok: existing.status === "approved",
          idempotent: true,
          charge_id: existing.id,
          status: existing.status,
          iso_code: existing.iso_code,
          azul_order_id: existing.azul_order_id,
          response_message: existing.response_message,
        });
      }
    }
    return errorResponse(500, "db_error", "Could not create charge", insErr.message);
  }

  // raw_request para auditoría — el token se redacta (vive en azul_payment_methods,
  // ambos protegidos por RLS; no lo duplicamos en claro).
  const sanitizedRequest = {
    method: "ProcessPayment",
    TrxType: "Sale",
    Store: env.azulMerchantId,
    Amount: String(amountCents),
    Itbis: String(itbisCents),
    OrderNumber: orderNumber,
    DataVaultToken: "***redacted***",
    CurrencyPosCode: "$",
  };

  // 6. Cobrar en Azul (vía sidecar mTLS).
  let result;
  try {
    result = await chargeWithToken({
      dataVaultToken: pm.data_vault_token as string,
      amountCents,
      itbisCents,
      orderNumber,
    });
  } catch (e) {
    // Error de red/sidecar/parsing → status='error'. NO cuenta como intento fallido
    // (no tocamos billing_status ni current_attempt_number); el cron reintenta luego.
    const msg = e instanceof AzulCallError ? `${e.code}: ${e.message}` : String(e);
    await service
      .from("azul_charges")
      .update({
        status: "error",
        error_description: msg.slice(0, 500),
        raw_request: sanitizedRequest,
        completed_at: new Date().toISOString(),
      })
      .eq("id", charge.id);
    await service.from("azul_webhook_events").insert({
      event_type: "webservice_response",
      http_method: "POST",
      raw_url: `${env.azulProxyUrl}/call (ProcessPayment Sale)`,
      raw_body: `EXCEPTION: ${msg}`.slice(0, 10000),
      related_charge_id: charge.id,
      processed: true,
      processing_error: msg.slice(0, 500),
    });
    return errorResponse(502, "azul_unreachable", msg, { charge_id: charge.id });
  }

  // 7. Clasificar resultado.
  const azul = result.body;
  const approved = result.httpStatus === 200 && azul.IsoCode === "00";
  const declined = result.httpStatus === 200 && azul.IsoCode !== "00";
  const finalStatus = approved ? "approved" : declined ? "declined" : "error";

  // 8. Actualizar la charge con el resultado + log de auditoría.
  await service
    .from("azul_charges")
    .update({
      status: finalStatus,
      authorization_code: azul.AuthorizationCode ?? null,
      response_code: azul.ResponseCode ?? null,
      iso_code: azul.IsoCode ?? null,
      response_message: azul.ResponseMessage ?? null,
      error_description: azul.ErrorDescription ?? null,
      rrn: azul.RRN ?? null,
      azul_order_id: azul.AzulOrderId ?? null,
      raw_request: sanitizedRequest,
      raw_response: azul,
      completed_at: new Date().toISOString(),
    })
    .eq("id", charge.id);

  await service.from("azul_webhook_events").insert({
    event_type: "webservice_response",
    http_method: "POST",
    raw_url: `${env.azulProxyUrl}/call (ProcessPayment Sale)`,
    raw_body: JSON.stringify(azul).slice(0, 10000),
    related_charge_id: charge.id,
    processed: true,
    processing_error: approved ? null : (azul.ErrorDescription || azul.ResponseMessage || `iso_${azul.IsoCode}`),
  });

  // 9. Actualizar el estado de la suscripción (memberships).
  if (approved) {
    await service
      .from("memberships")
      .update({
        billing_status: "active",
        current_attempt_number: 0,
        last_successful_charge_id: charge.id,
        current_period_start: periodStart,
        current_period_end: periodEnd,
        next_billing_date: periodEnd,
      })
      .eq("id", membershipId);
  } else if (declined) {
    if (attempt < 3) {
      // D11: reintentos en día 3 (attempt 1 → +2) y día 7 (attempt 2 → +4).
      const retryDays = attempt === 1 ? 2 : 4;
      await service
        .from("memberships")
        .update({
          billing_status: "past_due",
          current_attempt_number: attempt,
          last_failed_charge_id: charge.id,
          next_billing_date: addDaysIso(today, retryDays),
        })
        .eq("id", membershipId);
    } else {
      // 3º intento declinado → suspender.
      await service
        .from("memberships")
        .update({
          billing_status: "suspended",
          suspended_at: new Date().toISOString(),
          current_attempt_number: 3,
          last_failed_charge_id: charge.id,
        })
        .eq("id", membershipId);
    }
  }
  // finalStatus === "error" (no-200 sin excepción): la charge queda 'error' y NO se
  // toca la membership (defensivo; en la práctica el proxy devuelve 200).

  return jsonResponse({
    ok: approved,
    charge_id: charge.id,
    status: finalStatus,
    iso_code: azul.IsoCode ?? null,
    azul_order_id: azul.AzulOrderId ?? null,
    response_message: azul.ResponseMessage ?? null,
  });
});
