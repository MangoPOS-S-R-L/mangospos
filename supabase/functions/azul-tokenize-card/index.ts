// azul-tokenize-card — tokenización in-app vía Web Services (ProcessDataVault CREATE)
//
// POST /functions/v1/azul-tokenize-card
// Headers: Authorization: Bearer <user_jwt>  (owner/admin del business)
// Body: { business_id: uuid, card_number: string, expiration: "YYYYMM", cvc: string,
//         make_default?: boolean }
//
// Reemplaza el flujo de Payment Page: la app captura los datos de tarjeta y los
// manda aquí; esta función los tokeniza en Azul (DataVault) y guarda SOLO el
// token en azul_payment_methods. El PAN/CVV NUNCA se loguean ni se persisten.
//
// PCI (MangoPOS en scope SAQ D para la captura): por eso, en esta función:
//   - El PAN y CVV solo viven en memoria el tiempo de la llamada a Azul.
//   - raw_request/raw_body en azul_webhook_events va REDACTADO (sin PAN/CVV/token).
//   - Nunca console.log de la tarjeta.

import { corsPreflight, errorResponse, jsonResponse } from "../_shared/responses.ts";
import { getServiceClient, getUserClient } from "../_shared/supabase.ts";
import {
  createDataVaultToken,
  deleteDataVaultToken,
  holdWithToken,
  voidTransaction,
} from "../_shared/azul-api.ts";
import { generateTokenizeOrderNumber } from "../_shared/azul.ts";

const ALLOWED_ROLES = new Set(["owner", "admin"]);

interface RequestBody {
  business_id?: string;
  card_number?: string;
  expiration?: string;
  cvc?: string;
  make_default?: boolean;
}

function isUuid(s: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
}

async function getUserId(client: ReturnType<typeof getUserClient>): Promise<string | null> {
  const { data: { user }, error } = await client.auth.getUser();
  if (error || !user) return null;
  return user.id;
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

  // Validar datos de tarjeta (sin loguearlos).
  const cardNumber = (body.card_number ?? "").replace(/\s+/g, "");
  const expiration = (body.expiration ?? "").trim();
  const cvc = (body.cvc ?? "").trim();
  if (!/^[0-9]{13,19}$/.test(cardNumber)) {
    return errorResponse(400, "invalid_card", "card_number inválido");
  }
  if (!/^[0-9]{6}$/.test(expiration)) {
    return errorResponse(400, "invalid_card", "expiration debe ser AAAAMM (6 dígitos)");
  }
  if (!/^[0-9]{3,4}$/.test(cvc)) {
    return errorResponse(400, "invalid_card", "cvc inválido");
  }

  // 1. Verificar que el usuario es owner/admin del business (RLS-aware).
  const userClient = getUserClient(authHeader);
  const userId = await getUserId(userClient);
  if (!userId) {
    return errorResponse(401, "unauthorized", "Invalid JWT");
  }
  const { data: roleData, error: roleErr } = await userClient.rpc("user_business_role", {
    _user_id: userId,
    _business_id: businessId,
  });
  if (roleErr) {
    return errorResponse(500, "rpc_error", "Could not resolve user role", roleErr.message);
  }
  if (!roleData || !ALLOWED_ROLES.has(roleData as string)) {
    return errorResponse(403, "forbidden", "User is not owner/admin of business");
  }

  const service = getServiceClient();

  // 2. Tokenizar en Azul (DataVault CREATE). customOrderId solo para trazabilidad.
  const customOrderId = generateTokenizeOrderNumber();
  let result;
  try {
    result = await createDataVaultToken({
      cardNumber,
      expiration,
      cvc,
      customOrderId,
    });
  } catch (e) {
    return errorResponse(502, "azul_unreachable", e instanceof Error ? e.message : String(e));
  }

  const azul = result.body;
  // Log de auditoría SIN datos sensibles (ni PAN, ni CVV, ni token).
  await service.from("azul_webhook_events").insert({
    event_type: "webservice_response",
    http_method: "POST",
    raw_url: "azul-proxy /call (ProcessDataVault CREATE)",
    raw_body: JSON.stringify({
      IsoCode: azul.IsoCode ?? null,
      ResponseMessage: azul.ResponseMessage ?? null,
      ErrorDescription: azul.ErrorDescription ?? null,
      DataVaultBrand: azul.DataVaultBrand ?? azul.Brand ?? null,
      CardNumber: azul.CardNumber ?? null, // ya viene enmascarado de Azul
    }).slice(0, 4000),
    processed: true,
    processing_error: result.httpStatus === 200 && azul.IsoCode === "00"
      ? null
      : (azul.ErrorDescription || azul.ResponseMessage || `iso_${azul.IsoCode}`),
  });

  if (!(result.httpStatus === 200 && azul.IsoCode === "00") || !azul.DataVaultToken) {
    return errorResponse(402, "tokenization_declined", "La tarjeta no pudo tokenizarse", {
      iso_code: azul.IsoCode ?? null,
      response_message: azul.ResponseMessage ?? null,
      error_description: azul.ErrorDescription ?? null,
    });
  }
  const dataVaultToken = azul.DataVaultToken;

  // 2b. Verificar la tarjeta con un Hold de RD$1 (autorización) que liberamos
  //     con un Void. Solo guardamos el método de pago si el Hold APRUEBA — así
  //     una tarjeta que tokeniza pero no puede cobrar (p.ej. BIN no ruteada) NO
  //     completa el registro. Este Hold es la transacción CIT que respalda los
  //     cobros recurrentes MIT futuros.
  let holdAzulOrderId: string | null = null;
  try {
    const hold = await holdWithToken({
      dataVaultToken,
      amountCents: 100, // RD$1.00
      itbisCents: 0,
      orderNumber: generateTokenizeOrderNumber(),
    });
    const hb = hold.body;
    const holdApproved = hold.httpStatus === 200 && hb.IsoCode === "00";
    holdAzulOrderId = hb.AzulOrderId ?? null;

    await service.from("azul_webhook_events").insert({
      event_type: "webservice_response",
      http_method: "POST",
      raw_url: "azul-proxy /call (ProcessPayment Hold RD$1 verificación)",
      raw_body: JSON.stringify({
        IsoCode: hb.IsoCode ?? null,
        ResponseCode: hb.ResponseCode ?? null,
        ResponseMessage: hb.ResponseMessage ?? null,
        ErrorDescription: hb.ErrorDescription ?? null,
        AzulOrderId: hb.AzulOrderId ?? null,
      }).slice(0, 4000),
      processed: true,
      processing_error: holdApproved
        ? null
        : (hb.ErrorDescription || hb.ResponseMessage || `iso_${hb.IsoCode}`),
    });

    if (!holdApproved) {
      // Tokeniza pero no cobra → no la guardamos. Limpieza best-effort del token.
      try {
        await deleteDataVaultToken({ dataVaultToken });
      } catch (_) { /* best-effort */ }
      return errorResponse(
        402,
        "card_not_chargeable",
        "La tarjeta no pudo verificarse con la autorización de RD$1",
        {
          iso_code: hb.IsoCode ?? null,
          response_message: hb.ResponseMessage ?? null,
          error_description: hb.ErrorDescription ?? null,
        },
      );
    }
  } catch (e) {
    // Error de red en el Hold → no podemos verificar; no guardamos.
    try {
      await deleteDataVaultToken({ dataVaultToken });
    } catch (_) { /* best-effort */ }
    return errorResponse(502, "azul_unreachable", e instanceof Error ? e.message : String(e));
  }

  // 2c. Liberar el Hold con un Void (best-effort: si falla, el Hold expira solo).
  if (holdAzulOrderId) {
    try {
      const v = await voidTransaction({ azulOrderId: holdAzulOrderId });
      await service.from("azul_webhook_events").insert({
        event_type: "webservice_response",
        http_method: "POST",
        raw_url: "azul-proxy /call (ProcessPayment Void del Hold de verificación)",
        raw_body: JSON.stringify({
          IsoCode: v.body.IsoCode ?? null,
          ResponseMessage: v.body.ResponseMessage ?? null,
        }).slice(0, 2000),
        processed: true,
        processing_error:
          v.httpStatus === 200 && v.body.IsoCode === "00" ? null : "void_no_aprobado",
      });
    } catch (_) { /* best-effort: el Hold de RD$1 expira por sí solo */ }
  }

  // 3. Guardar SOLO el token (+ datos enmascarados que devuelve Azul).
  const makeDefault = body.make_default !== false; // default true
  const nowIso = new Date().toISOString();
  if (makeDefault) {
    await service
      .from("azul_payment_methods")
      .update({ is_default: false, updated_at: nowIso })
      .eq("business_id", businessId)
      .eq("is_default", true);
  }

  const { data: pm, error: pmErr } = await service
    .from("azul_payment_methods")
    .insert({
      business_id: businessId,
      data_vault_token: dataVaultToken,
      data_vault_expiration: azul.DataVaultExpiration ?? expiration,
      data_vault_brand: azul.DataVaultBrand ?? azul.Brand ?? "UNKNOWN",
      card_number_masked: azul.CardNumber ?? "****",
      azul_order_id_at_creation: holdAzulOrderId,
      status: "verified",
      is_default: makeDefault,
    })
    .select("id, data_vault_brand, card_number_masked, data_vault_expiration, status, is_default")
    .single();

  if (pmErr || !pm) {
    // El token quedó creado en Azul pero no se pudo guardar: avisar para reconciliar.
    return errorResponse(500, "db_error", "No se pudo guardar el método de pago", pmErr?.message);
  }

  return jsonResponse({
    ok: true,
    payment_method_id: pm.id,
    brand: pm.data_vault_brand,
    card_number_masked: pm.card_number_masked,
    expiration: pm.data_vault_expiration,
    status: pm.status,
    is_default: pm.is_default,
  });
});
