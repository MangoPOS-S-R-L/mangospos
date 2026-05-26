// PRD §7.1 — azul-create-tokenization-session
//
// POST /functions/v1/azul-create-tokenization-session
//
// Crea una sesión de Payment Page para tokenizar (y verificar vía Hold+Void)
// una tarjeta nueva. NO postea a Azul desde acá — devuelve una URL pública que
// el cliente abre en browser; esa URL sirve el form auto-submit (Edge Fn
// azul-payment-form), y es el browser quien hace el POST final a Azul (D4).
//
// Request:
//   { business_id: uuid, return_to?: string, client_surface?: "web"|"flutter_app",
//     intent_type?: "tokenize_and_verify"|"replace_card" }
//
// Response 200:
//   { session_id, order_number, payment_page_url, expires_at }
//
// Errores:
//   400 invalid_request — body inválido
//   401 unauthorized — sin JWT
//   403 forbidden — usuario no es admin/owner del business
//   409 conflict — ya hay una sesión pending no expirada para este business
//   500 internal — error técnico

import { corsPreflight, errorResponse, jsonResponse } from "../_shared/responses.ts";
import { getAzulEnv } from "../_shared/env.ts";
import { getServiceClient, getUserClient } from "../_shared/supabase.ts";
import {
  computeAuthHash,
  generateTokenizeOrderNumber,
  paymentPageFieldsToOrdered,
} from "../_shared/azul.ts";

// El RD$1.00 = 100 centavos. Azul espera el monto como entero sin punto.
const VERIFICATION_AMOUNT_CENTS = "100";
const VERIFICATION_ITBIS = "000";
const ALLOWED_ROLES = new Set(["owner", "admin"]);

interface RequestBody {
  business_id?: string;
  return_to?: string;
  client_surface?: "web" | "flutter_app";
  intent_type?: "tokenize_and_verify" | "replace_card";
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

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_request", "Body must be JSON");
  }

  const businessId = body.business_id?.trim();
  if (!businessId || !isUuid(businessId)) {
    return errorResponse(400, "invalid_request", "business_id must be a valid UUID");
  }

  const intentType = body.intent_type ?? "tokenize_and_verify";
  if (intentType !== "tokenize_and_verify" && intentType !== "replace_card") {
    return errorResponse(400, "invalid_request", "intent_type inválido");
  }

  // 1. Verificar que el usuario tiene rol owner/admin en el business.
  const userClient = getUserClient(authHeader);
  const { data: roleData, error: roleErr } = await userClient
    .rpc("user_business_role", {
      _user_id: await getUserId(userClient),
      _business_id: businessId,
    });
  if (roleErr) {
    return errorResponse(500, "rpc_error", "Could not resolve user role", roleErr.message);
  }
  if (!roleData || !ALLOWED_ROLES.has(roleData)) {
    return errorResponse(403, "forbidden", "User is not owner/admin of business");
  }

  const env = getAzulEnv();
  const service = getServiceClient();

  // 2. Idempotencia suave: si ya hay sesión pending no expirada, devolverla.
  const { data: existing, error: existingErr } = await service
    .from("azul_payment_sessions")
    .select("id, order_number, expires_at, status")
    .eq("business_id", businessId)
    .eq("intent_type", intentType)
    .in("status", ["pending", "redirected"])
    .gt("expires_at", new Date().toISOString())
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (existingErr) {
    return errorResponse(500, "db_error", "Could not check existing sessions", existingErr.message);
  }
  if (existing) {
    return jsonResponse({
      session_id: existing.id,
      order_number: existing.order_number,
      payment_page_url: buildPaymentFormUrl(env.publicCallbackBaseUrl, existing.id),
      expires_at: existing.expires_at,
      reused: true,
    });
  }

  // 3. Construir campos del Hold de RD$1 con SaveToDataVault=1.
  const orderNumber = generateTokenizeOrderNumber();
  const callbackBase = env.publicCallbackBaseUrl.replace(/\/+$/, "");
  const approvedUrl = `${callbackBase}/azul-callback?status=approved`;
  const declinedUrl = `${callbackBase}/azul-callback?status=declined`;
  const cancelUrl = `${callbackBase}/azul-callback?status=cancelled`;

  const fields = {
    merchantId: env.azulMerchantId,
    merchantName: env.azulMerchantName,
    merchantType: env.azulMerchantType,
    currencyCode: env.azulCurrencyCode,
    orderNumber,
    amount: VERIFICATION_AMOUNT_CENTS,
    itbis: VERIFICATION_ITBIS,
    approvedUrl,
    declinedUrl,
    cancelUrl,
    useCustomField1: "1",
    customField1Label: "Verificacion de tarjeta",
    customField1Value: "RD$1.00 sera reembolsado automaticamente",
    useCustomField2: "0",
    customField2Label: "",
    customField2Value: "",
  };

  const authHash = await computeAuthHash(
    paymentPageFieldsToOrdered(fields),
    env.azulAuthKey,
  );

  // 4. INSERT session con status=pending.
  const { data: session, error: insertErr } = await service
    .from("azul_payment_sessions")
    .insert({
      business_id: businessId,
      intent_type: intentType,
      order_number: orderNumber,
      amount_cents: Number(VERIFICATION_AMOUNT_CENTS),
      currency_code: "DOP",
      auth_hash_sent: authHash,
      status: "pending",
    })
    .select("id, order_number, expires_at")
    .single();
  if (insertErr || !session) {
    return errorResponse(500, "db_error", "Could not create session", insertErr?.message);
  }

  return jsonResponse({
    session_id: session.id,
    order_number: session.order_number,
    payment_page_url: buildPaymentFormUrl(env.publicCallbackBaseUrl, session.id),
    expires_at: session.expires_at,
  });
});

function isUuid(s: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
}

function buildPaymentFormUrl(base: string, sessionId: string): string {
  const root = base.replace(/\/+$/, "");
  return `${root}/azul-payment-form?session_id=${sessionId}`;
}

async function getUserId(client: ReturnType<typeof getUserClient>): Promise<string> {
  const { data: { user }, error } = await client.auth.getUser();
  if (error || !user) throw new Error("Could not resolve user from JWT");
  return user.id;
}
