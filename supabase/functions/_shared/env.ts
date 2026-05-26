// Carga y validación de variables de entorno requeridas por las Edge Functions Azul.
// PRD §D — variables documentadas.
//
// Falla rápido (throw en startup) si falta alguna requerida. Esto previene
// runtime errors en producción por config incompleta.
//
// PIVOT (2026-05-26): migramos de Payment Page (AuthHash HMAC) a Integración
// vía API directa (mTLS + Auth1/Auth2). Las variables nuevas son requeridas;
// las viejas (AZUL_AUTH_KEY, AZUL_PAYMENT_PAGE_URL) quedan como opcionales
// hasta que B4 limpie las edge functions del Payment Page.

export interface AzulEnv {
  azulEnv: "test" | "production";
  azulMerchantId: string;
  azulMerchantName: string;
  azulMerchantType: string;
  azulCurrencyCode: string;
  // ---- API directa vía sidecar mTLS (azul-proxy) ----
  // El cert/key/Auth1/Auth2 los maneja el sidecar; las edge functions solo
  // necesitan saber dónde está el sidecar y el token compartido.
  azulProxyUrl: string;
  azulProxyAuthToken: string;
  // ---- Legacy (mantener vacío si no los usás, validación los ignora) ----
  azulApiUrl?: string;
  azulAuth1?: string;
  azulAuth2?: string;
  azulCertPath?: string;
  azulKeyPath?: string;
  // ---- Payment Page (legacy, a eliminar en B4) ----
  azulAuthKey?: string;
  azulPaymentPageUrl?: string;
  // ---- Comunes ----
  publicCallbackBaseUrl: string;
  publicReturnBaseUrl: string;
  supabaseUrl: string;
  supabaseServiceRoleKey: string;
}

function required(name: string): string {
  const v = Deno.env.get(name);
  if (!v || v.trim() === "") {
    throw new Error(`Missing required env var: ${name}`);
  }
  return v;
}

function optional(name: string): string | undefined {
  const v = Deno.env.get(name);
  return v && v.trim() !== "" ? v : undefined;
}

let cached: AzulEnv | null = null;

export function getAzulEnv(): AzulEnv {
  if (cached) return cached;

  const azulEnv = (Deno.env.get("AZUL_ENV") ?? "test") as "test" | "production";
  if (azulEnv !== "test" && azulEnv !== "production") {
    throw new Error(`AZUL_ENV must be "test" or "production", got: ${azulEnv}`);
  }

  cached = {
    azulEnv,
    azulMerchantId: required("AZUL_MERCHANT_ID"),
    azulMerchantName: Deno.env.get("AZUL_MERCHANT_NAME") ?? "MangoPOS",
    azulMerchantType: Deno.env.get("AZUL_MERCHANT_TYPE") ?? "ECommerce",
    azulCurrencyCode: Deno.env.get("AZUL_CURRENCY_CODE") ?? "$",
    azulProxyUrl: required("AZUL_PROXY_URL"),
    azulProxyAuthToken: required("AZUL_PROXY_AUTH_TOKEN"),
    azulApiUrl: optional("AZUL_API_URL"),
    azulAuth1: optional("AZUL_AUTH1"),
    azulAuth2: optional("AZUL_AUTH2"),
    azulCertPath: optional("AZUL_CERT_PATH"),
    azulKeyPath: optional("AZUL_KEY_PATH"),
    azulAuthKey: optional("AZUL_AUTH_KEY"),
    azulPaymentPageUrl: optional("AZUL_PAYMENT_PAGE_URL"),
    publicCallbackBaseUrl: required("PUBLIC_CALLBACK_BASE_URL"),
    publicReturnBaseUrl: required("PUBLIC_RETURN_BASE_URL"),
    supabaseUrl: required("SUPABASE_URL"),
    supabaseServiceRoleKey: required("SUPABASE_SERVICE_ROLE_KEY"),
  };
  return cached;
}
