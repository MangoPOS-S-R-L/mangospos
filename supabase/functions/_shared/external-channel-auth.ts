// Autenticacion de canales de pedidos externos (Pincer, y despues Uber Eats).
//
// Dos candados, distintos a proposito:
//   1. X-Api-Key      → QUIEN llama (identifica el restaurante, revocable).
//   2. X-Pincer-Signature → que el CUERPO no fue alterado y no es un replay.
//
// El allowlist por IP NO se usa: no hay filtro de red delante del endpoint y
// Pincer corre serverless con IPs dinamicas. El control es criptografico.
// Ver docs/PRD_INTEGRACION_PINCER.md §5.1 y §5.2.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

export interface ChannelCredential {
  businessId: string;
  channel: string;
  environment: "sandbox" | "production";
  hmacSecret: string;
  rateLimitRpm: number;
  scopes: string[];
}

export type AuthFailure =
  | { code: "invalid_api_key"; status: 401 }
  | { code: "invalid_signature"; status: 401 }
  | { code: "stale_timestamp"; status: 401 }
  | { code: "missing_scope"; status: 403 }
  | { code: "rate_limited"; status: 429; retryAfter: number };

export type AuthResult =
  | { ok: true; credential: ChannelCredential }
  | { ok: false; failure: AuthFailure; message: string };

let cached: SupabaseClient | null = null;

export function serviceClient(): SupabaseClient {
  if (cached) return cached;
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) {
    throw new Error("SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY son requeridas");
  }
  cached = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return cached;
}

/** Tolerancia del reloj entre Pincer y nosotros. Acordada en 5 minutos. */
const SIGNATURE_WINDOW_SECONDS = 300;

/** Comparacion en tiempo constante: no filtra por cuanto tarda en fallar. */
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function toHex(buf: ArrayBuffer): string {
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export async function hmacHex(secret: string, payload: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return toHex(await crypto.subtle.sign("HMAC", key, enc.encode(payload)));
}

/** Parsea `t=<unix>,v1=<hex>`. Tolera espacios y orden invertido. */
function parseSignature(header: string): { t: number; v1: string } | null {
  let t: number | null = null;
  let v1: string | null = null;
  for (const part of header.split(",")) {
    const [k, v] = part.split("=", 2).map((s) => s?.trim());
    if (k === "t" && v) t = Number(v);
    if (k === "v1" && v) v1 = v.toLowerCase();
  }
  if (t === null || !Number.isFinite(t) || !v1) return null;
  return { t, v1 };
}

/**
 * Resuelve la credencial y verifica la firma sobre el cuerpo CRUDO.
 *
 * `rawBody` tiene que ser el texto exacto que llego, byte por byte. Si se
 * parsea y re-serializa antes de firmar, la firma no cuadra nunca (un espacio
 * o un orden de claves distinto ya cambia el hash).
 *
 * En GET no hay cuerpo: se firma la cadena vacia.
 */
export async function authenticateChannel(
  req: Request,
  rawBody: string,
  requiredScope: string,
): Promise<AuthResult> {
  const apiKey = req.headers.get("x-api-key")?.trim();
  if (!apiKey) {
    return {
      ok: false,
      failure: { code: "invalid_api_key", status: 401 },
      message: "Falta el header X-Api-Key",
    };
  }

  const db = serviceClient();
  const { data, error } = await db.rpc("fn_resolve_external_api_key", {
    p_api_key: apiKey,
  });

  if (error) {
    console.error("fn_resolve_external_api_key fallo:", error.message);
    return {
      ok: false,
      failure: { code: "invalid_api_key", status: 401 },
      message: "No se pudo validar la credencial",
    };
  }

  const row = Array.isArray(data) ? data[0] : data;
  if (!row) {
    return {
      ok: false,
      failure: { code: "invalid_api_key", status: 401 },
      message: "Credencial invalida o revocada",
    };
  }

  const credential: ChannelCredential = {
    businessId: row.business_id,
    channel: row.channel,
    environment: row.environment,
    hmacSecret: row.hmac_secret,
    rateLimitRpm: row.rate_limit_rpm ?? 60,
    scopes: row.scopes ?? [],
  };

  if (credential.scopes.length > 0 && !credential.scopes.includes(requiredScope)) {
    return {
      ok: false,
      failure: { code: "missing_scope", status: 403 },
      message: `La credencial no tiene el permiso ${requiredScope}`,
    };
  }

  // ── Firma ───────────────────────────────────────────────────────────────
  const sigHeader = req.headers.get("x-pincer-signature") ??
    req.headers.get("x-signature");
  if (!sigHeader) {
    return {
      ok: false,
      failure: { code: "invalid_signature", status: 401 },
      message: "Falta el header X-Pincer-Signature",
    };
  }

  const parsed = parseSignature(sigHeader);
  if (!parsed) {
    return {
      ok: false,
      failure: { code: "invalid_signature", status: 401 },
      message: "Formato de firma invalido; se espera t=<unix>,v1=<hex>",
    };
  }

  const skew = Math.abs(Math.floor(Date.now() / 1000) - parsed.t);
  if (skew > SIGNATURE_WINDOW_SECONDS) {
    return {
      ok: false,
      failure: { code: "stale_timestamp", status: 401 },
      message:
        `El timestamp esta a ${skew}s del nuestro (maximo ${SIGNATURE_WINDOW_SECONDS}s). ` +
        "Revisa el reloj del servidor que firma.",
    };
  }

  const expected = await hmacHex(credential.hmacSecret, `${parsed.t}.${rawBody}`);
  if (!safeEqual(expected, parsed.v1)) {
    return {
      ok: false,
      failure: { code: "invalid_signature", status: 401 },
      message: "La firma no corresponde al cuerpo recibido",
    };
  }

  return { ok: true, credential };
}

/**
 * Rate limit por credencial, contando lo que ya entro al inbox en el ultimo
 * minuto. Sin Redis ni estado nuevo: con 5 pedidos/min por restaurante la
 * consulta es trivial, y de paso el limite se aplica sobre lo que de verdad
 * proceso el POS.
 */
export async function checkRateLimit(
  credential: ChannelCredential,
): Promise<{ allowed: boolean; retryAfter: number }> {
  const db = serviceClient();
  const since = new Date(Date.now() - 60_000).toISOString();

  const { count, error } = await db
    .from("external_order_inbox")
    .select("id", { count: "exact", head: true })
    .eq("business_id", credential.businessId)
    .eq("channel", credential.channel)
    .gte("received_at", since);

  // Si el conteo falla, NO bloqueamos: un pedido perdido es peor que uno de mas.
  if (error) {
    console.error("rate limit: conteo fallo, dejando pasar:", error.message);
    return { allowed: true, retryAfter: 0 };
  }

  const used = count ?? 0;
  return used >= credential.rateLimitRpm
    ? { allowed: false, retryAfter: 60 }
    : { allowed: true, retryAfter: 0 };
}
