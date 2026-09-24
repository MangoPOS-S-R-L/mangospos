// channel-link — el canal canjea su código de vinculación por credenciales.
//
//   POST /channel-link/redeem   { "code": "ABCD-2345" }
//
// Ver docs/PRD_INTEGRACION_PINCER.md §11.
//
// POR QUÉ EXISTE
//   Para que la API key y el secreto NO viajen por WhatsApp. El dueño del
//   restaurante genera un código corto en su POS, se lo dicta al canal, y el
//   canal lo canjea acá: las llaves van servidor a servidor y nadie más las ve.
//
// EL CÓDIGO ES LA AUTENTICACIÓN
//   No hay API key todavía —justamente se está pidiendo—, así que este endpoint
//   es público. Lo que lo protege:
//     - vive 15 minutos y sirve UNA vez;
//     - son 8 caracteres de un alfabeto de 32 (10^12 combinaciones), imposible
//       de adivinar en esa ventana;
//     - cada intento contra un código existente queda contado en la fila.
//
//   Aun así hay un freno por IP: sin él, alguien podría barrer el espacio con
//   fuerza bruta a mil intentos por segundo y eso, además de inútil, nos tumba
//   la base a preguntas.

import {
  corsPreflight,
  errorResponse,
  jsonResponse,
} from "../_shared/responses.ts";
import { serviceClient } from "../_shared/external-channel-auth.ts";

// Intentos fallidos por IP en la ventana. Un canal legítimo canjea UNA vez.
const MAX_FALLOS = 10;
const VENTANA_MS = 10 * 60 * 1000;
const fallosPorIp = new Map<string, { n: number; desde: number }>();

function demasiadosFallos(ip: string): boolean {
  const ahora = Date.now();
  const reg = fallosPorIp.get(ip);
  if (!reg || ahora - reg.desde > VENTANA_MS) return false;
  return reg.n >= MAX_FALLOS;
}

function anotarFallo(ip: string): void {
  const ahora = Date.now();
  const reg = fallosPorIp.get(ip);
  if (!reg || ahora - reg.desde > VENTANA_MS) {
    fallosPorIp.set(ip, { n: 1, desde: ahora });
    return;
  }
  reg.n += 1;
  // El contador vive en memoria del isolate: se pierde en cada reinicio y no se
  // comparte entre instancias. Es un freno, no un candado — el candado real es
  // que el código vence en 15 minutos.
  if (fallosPorIp.size > 5000) fallosPorIp.clear();
}

Deno.serve(async (req) => {
  const preflight = corsPreflight(req);
  if (preflight) return preflight;

  const path = new URL(req.url).pathname
    .replace(/^\/functions\/v1/, "")
    .replace(/^\/channel-link\/?/, "")
    .replace(/\/+$/, "");

  if (req.method !== "POST" || (path !== "" && path !== "redeem")) {
    return errorResponse(405, "method_not_allowed", "Solo POST /channel-link/redeem");
  }

  const ip = req.headers.get("x-forwarded-for")?.split(",")[0].trim() ??
    req.headers.get("cf-connecting-ip") ?? "desconocida";

  if (demasiadosFallos(ip)) {
    return errorResponse(
      429,
      "too_many_attempts",
      "Demasiados intentos fallidos. Espera unos minutos.",
    );
  }

  let code: string;
  try {
    const body = await req.json();
    code = String(body?.code ?? "").trim().toUpperCase();
  } catch {
    return errorResponse(422, "invalid_payload", "Se espera { \"code\": \"ABCD-2345\" }");
  }

  if (!/^[A-Z0-9]{4}-?[A-Z0-9]{4}$/.test(code)) {
    anotarFallo(ip);
    return errorResponse(422, "invalid_code_format", "El código tiene 8 caracteres, tipo ABCD-2345");
  }
  // Se acepta con o sin guion: quien lo teclea no tiene por qué acordarse.
  const normalizado = code.includes("-") ? code : `${code.slice(0, 4)}-${code.slice(4)}`;

  const db = serviceClient();
  const { data, error } = await db.rpc("fn_redeem_channel_link_code", {
    p_code: normalizado,
  });

  if (error) {
    console.error("canje falló:", error.message);
    return errorResponse(500, "internal_error", "No se pudo canjear el código");
  }

  const res = data as Record<string, unknown>;
  if (res?.ok !== true) {
    anotarFallo(ip);
    const motivo = String(res?.error ?? "code_not_found");
    const mensajes: Record<string, string> = {
      code_not_found: "Ese código no existe",
      code_expired: "El código venció. Pídele al restaurante que genere otro.",
      code_already_used: "Ese código ya se usó",
    };
    return errorResponse(422, motivo, mensajes[motivo] ?? "Código inválido");
  }

  // Las credenciales salen UNA vez, acá. No hay forma de volver a consultarlas:
  // si se pierden, el restaurante genera otro código y esto rota la clave.
  return jsonResponse({
    business_id: res.business_id,
    business_name: res.business_name,
    channel: res.channel,
    environment: res.environment,
    api_key: res.api_key,
    hmac_secret: res.hmac_secret,
    endpoints: {
      catalog: "/functions/v1/pincer-catalog",
      orders: "/functions/v1/pincer-orders",
    },
  }, { status: 200 });
});
