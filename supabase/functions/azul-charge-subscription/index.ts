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
//     attempt_number) de azul_charges es el candado. Si choca, decide
//     retry_policy.ts: terminal → se devuelve sin recobrar; `pending` reciente →
//     409 "en curso" SIN llamar a Azul; `error` o `pending` viejo → se reintenta
//     reclamando la fila con un UPDATE condicional (un solo pedido gana).
//   - Resultado desconocido: cada cobro manda un CustomOrderId único (columna
//     custom_order_id, migración 20260917_0004). Antes de reintentar un `error`
//     o un `pending` viejo se consulta VerifyPayment: si Azul ya lo cobró, se
//     registra como aprobado SIN volver a cobrar; si no lo tiene, se reintenta;
//     si no se puede saber, no se cobra.
//   - Política de reintentos D11: intentos 1/2/3; tras el 3º declinado → suspended.
//   - Monto: subscription_charge_breakdown (migración 0051 de mangopos_administrador)
//     = precio efectivo del plan (precio especial vigente o lista, 20260915_0006)
//     + facturas electrónicas aceptadas por encima de lo incluido. El desglose
//     queda en la fila del cobro (ecf_overage_cents, ecf_detail, ecf_usage_*).

import { corsPreflight, errorResponse, jsonResponse } from "../_shared/responses.ts";
import { getAzulEnv } from "../_shared/env.ts";
import { getServiceClient } from "../_shared/supabase.ts";
import { generateChargeOrderNumber } from "../_shared/azul.ts";
import { AzulCallError, chargeWithToken, verifyPayment } from "../_shared/azul-api.ts";
import {
  ecfChargeColumns,
  type EcfOverage,
  isMissingFunction,
  parseChargeBreakdown,
} from "./charge_breakdown.ts";
import {
  chargeCustomOrderId,
  classifyChargeVerify,
  decideOnExistingCharge,
  inFlightCutoffIso,
} from "./retry_policy.ts";

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

type ServiceClient = ReturnType<typeof getServiceClient>;

/** Suscripción al día tras un cobro aprobado (venta nueva o recuperada con
 *  VerifyPayment). */
async function markMembershipCharged(
  service: ServiceClient,
  membershipId: string,
  chargeId: string,
  periodStart: string,
  periodEnd: string,
): Promise<void> {
  await service
    .from("memberships")
    .update({
      billing_status: "active",
      current_attempt_number: 0,
      last_successful_charge_id: chargeId,
      current_period_start: periodStart,
      current_period_end: periodEnd,
      next_billing_date: periodEnd,
    })
    .eq("id", membershipId);
}

/** Bitácora forense de llamadas a Azul. El método va en raw_url: las
 *  consultas VerifyPayment se distinguen así de las ventas (una verificación
 *  repite el IsoCode 00 y no debe contarse como otra venta). */
async function logWebservice(
  service: ServiceClient,
  chargeId: string,
  method: string,
  rawBody: string,
  processingError: string | null,
): Promise<void> {
  const env = getAzulEnv();
  await service.from("azul_webhook_events").insert({
    event_type: "webservice_response",
    http_method: "POST",
    raw_url: `${env.azulProxyUrl}/call (${method})`,
    raw_body: rawBody.slice(0, 10000),
    related_charge_id: chargeId,
    processed: true,
    processing_error: processingError?.slice(0, 500) ?? null,
  });
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
    .select("currency_code")
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

  // 2. Período de facturación. Va ANTES del monto: el precio especial puede
  //    tener vencimiento y se evalúa contra el período que se cobra, no contra
  //    "hoy" — un reintento de un pago atrasado no debe perder el descuento del
  //    mes al que corresponde.
  const today = todayUtcIso();
  const periodStart = (body.billing_period_start ?? membership.next_billing_date ??
    membership.current_period_end ?? today) as string;
  const periodEnd = addMonthIso(periodStart);

  // 3. Monto = plan + facturas electrónicas extra. v1 sin prorrateo.
  //    El plan lo decide subscription_effective_price_cents (la misma función
  //    que usan las facturas y el MRR, para que lo cobrado y lo facturado no
  //    diverjan); subscription_charge_breakdown le suma el extra de e-CF.
  //
  //    Falla CERRADA: si no se puede resolver el monto, NO se cobra. Caer al
  //    precio de lista le cobraría de más a un cliente con descuento; no
  //    cobrar hoy solo lo difiere al próximo ciclo del cron. Única excepción:
  //    si 0051 todavía no está aplicada (la función no existe), se cobra solo
  //    el plan como antes, en vez de frenar todos los cobros.
  let amountCents: number;
  let ecf: EcfOverage | null = null;
  let breakdownApplied = true;
  const { data: breakdown, error: breakdownErr } = await service.rpc(
    "subscription_charge_breakdown",
    { p_membership_id: membershipId, p_period_start: periodStart },
  );
  if (breakdownErr && isMissingFunction(breakdownErr)) {
    breakdownApplied = false;
    const { data: effectivePrice, error: priceErr } = await service.rpc(
      "subscription_effective_price_cents",
      { p_membership_id: membershipId, p_on: periodStart },
    );
    if (priceErr || typeof effectivePrice !== "number") {
      return errorResponse(
        500,
        "price_unresolved",
        "Could not resolve the effective price for this membership",
        priceErr?.message ?? `unexpected value: ${JSON.stringify(effectivePrice)}`,
      );
    }
    amountCents = effectivePrice;
  } else {
    const parsed = breakdownErr ? null : parseChargeBreakdown(breakdown);
    if (!parsed) {
      return errorResponse(
        500,
        "price_unresolved",
        "Could not resolve the charge amount for this membership",
        breakdownErr?.message ?? `unexpected value: ${JSON.stringify(breakdown)}`,
      );
    }
    amountCents = parsed.amountCents;
    ecf = parsed.ecf;
  }

  // Precio 0 (plan gratis o precio especial en 0): no hay nada que cobrar.
  // Azul rechaza una venta de RD$0; antes la fila quedaba en `error` y el cron
  // la repetía todos los días ("cristian", desde el 24/06/2026). El cron ya no
  // las encola (20260915_0007); esta es la segunda barrera, por si llega un
  // pedido manual o el cron viejo sigue activo. Va ANTES del INSERT: ni fila
  // ni llamada a Azul.
  if (amountCents <= 0) {
    return errorResponse(
      422,
      "zero_amount",
      "El precio de este período es RD$0: no hay nada que cobrar.",
      { membership_id: membershipId, billing_period_start: periodStart },
    );
  }
  const itbisCents = 0;
  const currencyCode = (plan.currency_code as string) ?? "DOP";

  // 4. OrderNumber determinístico (≤15 alfanumérico).
  const orderNumber = generateChargeOrderNumber(
    membershipId,
    new Date(`${periodStart}T00:00:00Z`),
    attempt,
  );

  // 5. INSERT charge en estado pending. El UNIQUE (membership, período, intento) es
  //    el candado de idempotencia.
  const nowMs = Date.now();
  const nowIso = new Date(nowMs).toISOString();
  let chargeId: string;
  let customOrderId: string;
  // Id y CustomOrderId se generan acá para ir juntos en el INSERT: el
  // CustomOrderId tiene que quedar guardado ANTES de hablar con Azul.
  const newChargeId = crypto.randomUUID();
  const { data: inserted, error: insErr } = await service
    .from("azul_charges")
    .insert({
      id: newChargeId,
      custom_order_id: chargeCustomOrderId(newChargeId),
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
      ...ecfChargeColumns(ecf, breakdownApplied),
    })
    .select("id")
    .single();

  if (insErr) {
    // 23505 = unique_violation → ya existe una charge para (membership, período, intento).
    if (insErr.code !== "23505") {
      return errorResponse(500, "db_error", "Could not create charge", insErr.message);
    }
    const { data: existing } = await service
      .from("azul_charges")
      .select("id, status, iso_code, azul_order_id, response_message, attempted_at, custom_order_id")
      .eq("membership_id", membershipId)
      .eq("billing_period_start", periodStart)
      .eq("attempt_number", attempt)
      .maybeSingle();
    if (!existing) {
      return errorResponse(500, "db_error", "Could not create charge", insErr.message);
    }
    const decision = decideOnExistingCharge(existing, nowMs);

    // Terminal (approved/declined) → idempotente: devolver sin recobrar.
    if (decision === "terminal") {
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
    // En vuelo: otro pedido está cobrando este mismo período AHORA. Volver a
    // llamar a Azul acá es exactamente lo que duplicó cobros en agosto 2026.
    if (decision === "in_progress") {
      return errorResponse(
        409,
        "charge_in_progress",
        "Ya hay un cobro en curso para este período. No se volvió a enviar a Azul.",
        { charge_id: existing.id },
      );
    }

    // Reintentable, pero el intento anterior pudo haber cobrado sin que nos
    // enteráramos (la llamada se cayó después de que Azul aprobó). Antes de
    // volver a cobrar se le pregunta a Azul.
    if (!existing.custom_order_id) {
      // Cobro anterior a la migración 20260917_0004: no hay con qué
      // verificarlo. No se reintenta solo — ver
      // supabase/VERIFICAR_20260917_0004_custom_order_id.sql.
      return errorResponse(
        409,
        "unverifiable_previous_attempt",
        "El intento anterior de este cobro no se puede verificar con Azul. " +
          `Revisar en el portal de Azul el OrderNumber ${orderNumber} antes de reintentar.`,
        { charge_id: existing.id, order_number: orderNumber },
      );
    }

    let verify;
    try {
      verify = await verifyPayment({ customOrderId: existing.custom_order_id });
    } catch (e) {
      const msg = e instanceof AzulCallError ? `${e.code}: ${e.message}` : String(e);
      await logWebservice(service, existing.id, "VerifyPayment", `EXCEPTION: ${msg}`, msg);
      return errorResponse(
        502,
        "verify_failed",
        "No se pudo confirmar con Azul si el intento anterior se cobró. No se reintentó.",
        { charge_id: existing.id },
      );
    }
    await logWebservice(service, existing.id, "VerifyPayment", JSON.stringify(verify.body), null);

    const verifyOutcome = classifyChargeVerify(verify.httpStatus, verify.body);
    if (verifyOutcome === "unknown") {
      return errorResponse(
        502,
        "verify_inconclusive",
        "Azul no dio una respuesta clara sobre el intento anterior. No se reintentó; " +
          "revisarlo en el portal de Azul.",
        { charge_id: existing.id, order_number: orderNumber },
      );
    }
    if (verifyOutcome === "approved") {
      // Azul SÍ lo había cobrado: se registra la venta como si la respuesta
      // hubiera llegado. Volver a cobrar acá era el cobro doble de julio.
      const v = verify.body;
      await service
        .from("azul_charges")
        .update({
          status: "approved",
          authorization_code: v.AuthorizationCode ?? null,
          response_code: v.ResponseCode ?? null,
          iso_code: v.IsoCode ?? null,
          response_message: v.ResponseMessage ?? null,
          error_description: null,
          rrn: v.RRN ?? null,
          azul_order_id: v.AzulOrderId ?? null,
          raw_response: v,
          completed_at: new Date().toISOString(),
        })
        .eq("id", existing.id);
      await markMembershipCharged(service, membershipId, existing.id, periodStart, periodEnd);
      return jsonResponse({
        ok: true,
        recovered: true,
        charge_id: existing.id,
        status: "approved",
        iso_code: v.IsoCode ?? null,
        azul_order_id: v.AzulOrderId ?? null,
        response_message: v.ResponseMessage ?? null,
      });
    }
    // not_charged: Azul no tiene la venta (o la rechazó): no se movió dinero.

    // Reintentable (error, o pending viejo cuyo worker murió). Se RECLAMA la
    // fila con un UPDATE condicional: solo pasa a pending si sigue en el mismo
    // estado reintentable. Si dos pedidos reintentan a la vez, uno solo
    // actualiza la fila; el otro recibe 0 filas y se trata como en vuelo.
    //
    // El monto se reescribe: si el precio cambió entre intentos (se cargó o
    // quitó un precio especial), la fila tiene que reflejar lo que se cobra
    // AHORA, no lo que se intentó la primera vez.
    let claim = service
      .from("azul_charges")
      .update({
        status: "pending",
        attempted_at: nowIso,
        amount_cents: amountCents,
        ...ecfChargeColumns(ecf, breakdownApplied),
      })
      .eq("id", existing.id)
      .eq("status", existing.status);
    if (existing.status === "pending") {
      claim = claim.lt("attempted_at", inFlightCutoffIso(nowMs));
    }
    const { data: claimed, error: claimErr } = await claim.select("id");
    if (claimErr) {
      return errorResponse(500, "db_error", "Could not claim charge for retry", claimErr.message);
    }
    if (!claimed || claimed.length === 0) {
      return errorResponse(
        409,
        "charge_in_progress",
        "Ya hay un cobro en curso para este período. No se volvió a enviar a Azul.",
        { charge_id: existing.id },
      );
    }
    chargeId = existing.id;
    customOrderId = existing.custom_order_id;
  } else {
    chargeId = inserted!.id;
    customOrderId = chargeCustomOrderId(chargeId);
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
    CustomOrderId: customOrderId,
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
      customOrderId,
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
      .eq("id", chargeId);
    await service.from("azul_webhook_events").insert({
      event_type: "webservice_response",
      http_method: "POST",
      raw_url: `${env.azulProxyUrl}/call (ProcessPayment Sale)`,
      raw_body: `EXCEPTION: ${msg}`.slice(0, 10000),
      related_charge_id: chargeId,
      processed: true,
      processing_error: msg.slice(0, 500),
    });
    return errorResponse(502, "azul_unreachable", msg, { charge_id: chargeId });
  }

  // 7. Clasificar resultado.
  //   - approved: IsoCode "00".
  //   - declined: el procesador (ISO8583) lo rechazó con IsoCode != "00"
  //     (p.ej. 05/51/63). Cuenta como intento fallido (política D11).
  //   - error: validación/técnico (ResponseCode "Error", IsoCode vacío) o no-200.
  //     NO cuenta como intento — es nuestro/transitorio y se reintenta.
  const azul = result.body;
  const approved = result.httpStatus === 200 && azul.IsoCode === "00";
  const declined = result.httpStatus === 200 && azul.IsoCode !== "00" &&
    azul.ResponseCode === "ISO8583";
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
    .eq("id", chargeId);

  await service.from("azul_webhook_events").insert({
    event_type: "webservice_response",
    http_method: "POST",
    raw_url: `${env.azulProxyUrl}/call (ProcessPayment Sale)`,
    raw_body: JSON.stringify(azul).slice(0, 10000),
    related_charge_id: chargeId,
    processed: true,
    processing_error: approved ? null : (azul.ErrorDescription || azul.ResponseMessage || `iso_${azul.IsoCode}`),
  });

  // 9. Actualizar el estado de la suscripción (memberships).
  if (approved) {
    await markMembershipCharged(service, membershipId, chargeId, periodStart, periodEnd);
  } else if (declined) {
    if (attempt < 3) {
      // D11: reintentos en día 3 (attempt 1 → +2) y día 7 (attempt 2 → +4).
      const retryDays = attempt === 1 ? 2 : 4;
      await service
        .from("memberships")
        .update({
          billing_status: "past_due",
          current_attempt_number: attempt,
          last_failed_charge_id: chargeId,
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
          last_failed_charge_id: chargeId,
        })
        .eq("id", membershipId);
    }
  }
  // finalStatus === "error" (no-200 sin excepción): la charge queda 'error' y NO se
  // toca la membership (defensivo; en la práctica el proxy devuelve 200).

  return jsonResponse({
    ok: approved,
    charge_id: chargeId,
    status: finalStatus,
    iso_code: azul.IsoCode ?? null,
    azul_order_id: azul.AzulOrderId ?? null,
    response_message: azul.ResponseMessage ?? null,
    ecf_overage_cents: ecf?.overageCents ?? 0,
  });
});
