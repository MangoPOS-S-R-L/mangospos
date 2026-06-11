// Helpers con I/O compartidos por azul-3ds-orchestrate y azul-3ds-callback:
// finalizar una sesión 3DS aprobada y loguear eventos. La lógica pura (sin I/O)
// vive en azul-3ds.ts.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { type AzulResponse, voidTransaction } from "./azul-api.ts";

export interface ThreeDSSessionRow {
  id: string;
  business_id: string;
  azul_order_id: string | null;
  resulting_payment_method_id?: string | null;
}

export interface FinalizeResult {
  ok: boolean;
  paymentMethodId?: string;
  reason?: string;
}

/**
 * La autenticación 3DS aprobó (IsoCode 00) sobre un Hold con SaveToDataVault=1.
 * Cierra el registro de tarjeta:
 *   1. Libera el Hold con un Void (best-effort).
 *   2. Guarda SOLO el DataVaultToken (+ datos enmascarados de Azul) como
 *      método de pago verificado y default.
 *   3. Marca la sesión approved.
 *
 * Idempotente: si la sesión ya tiene resulting_payment_method_id, no re-procesa.
 */
export async function finalizeApprovedSession(
  service: SupabaseClient,
  session: ThreeDSSessionRow,
  azul: AzulResponse,
): Promise<FinalizeResult> {
  // Idempotencia: un segundo callback no duplica la tarjeta.
  if (session.resulting_payment_method_id) {
    return { ok: true, paymentMethodId: session.resulting_payment_method_id };
  }

  const dataVaultToken = azul.DataVaultToken;
  const azulOrderId = azul.AzulOrderId ?? session.azul_order_id ?? null;

  if (!dataVaultToken) {
    // Autorizó pero no tokenizó (SaveToDataVault no devolvió token). No podemos
    // guardar un método de pago utilizable → marcar para reconciliación manual.
    await service
      .from("azul_payment_sessions")
      .update({
        status: "error",
        threeds_auth_status: "approved_no_token",
        completed_at: new Date().toISOString(),
      })
      .eq("id", session.id);
    return { ok: false, reason: "approved_no_token" };
  }

  // 1. Void del Hold de verificación (best-effort: el Hold de RD$1 expira solo).
  if (azulOrderId) {
    try {
      const v = await voidTransaction({ azulOrderId });
      await logWebhookEvent(service, {
        eventType: "webservice_response",
        sessionId: session.id,
        rawUrl: "azul-proxy /call (Void del Hold 3DS)",
        body: { IsoCode: v.body.IsoCode ?? null, ResponseMessage: v.body.ResponseMessage ?? null },
        processed: v.httpStatus === 200 && v.body.IsoCode === "00",
      });
    } catch (_) { /* best-effort */ }
  }

  // 2. Guardar el método de pago (default). Desmarca el default anterior.
  const nowIso = new Date().toISOString();
  await service
    .from("azul_payment_methods")
    .update({ is_default: false, updated_at: nowIso })
    .eq("business_id", session.business_id)
    .eq("is_default", true);

  const { data: pm, error: pmErr } = await service
    .from("azul_payment_methods")
    .insert({
      business_id: session.business_id,
      data_vault_token: dataVaultToken,
      data_vault_expiration: azul.DataVaultExpiration ?? "000000",
      data_vault_brand: azul.DataVaultBrand ?? "UNKNOWN",
      card_number_masked: azul.CardNumber ?? "****",
      azul_order_id_at_creation: azulOrderId,
      status: "verified",
      is_default: true,
      verification_session_id: session.id,
    })
    .select("id")
    .single();

  if (pmErr || !pm) {
    await service
      .from("azul_payment_sessions")
      .update({ status: "error", threeds_auth_status: "save_failed", completed_at: nowIso })
      .eq("id", session.id);
    return { ok: false, reason: pmErr?.message ?? "save_failed" };
  }

  // 3. Marcar la sesión aprobada.
  await service
    .from("azul_payment_sessions")
    .update({
      status: "approved",
      resulting_payment_method_id: pm.id,
      threeds_auth_status: "approved",
      azul_order_id: azulOrderId,
      completed_at: nowIso,
    })
    .eq("id", session.id);

  return { ok: true, paymentMethodId: pm.id };
}

/** Inserta un evento en la bitácora forense azul_webhook_events. */
export async function logWebhookEvent(
  service: SupabaseClient,
  p: {
    eventType:
      | "webservice_response"
      | "threeds_method_notification"
      | "threeds_term_callback";
    sessionId?: string;
    rawUrl?: string;
    rawQuery?: Record<string, unknown>;
    body?: Record<string, unknown>;
    processed?: boolean;
    processingError?: string | null;
  },
): Promise<void> {
  await service.from("azul_webhook_events").insert({
    event_type: p.eventType,
    http_method: "POST",
    raw_url: p.rawUrl ?? null,
    raw_query: p.rawQuery ?? null,
    raw_body: p.body ? JSON.stringify(p.body).slice(0, 4000) : null,
    related_session_id: p.sessionId ?? null,
    processed: p.processed ?? true,
    processing_error: p.processingError ?? null,
  });
}
