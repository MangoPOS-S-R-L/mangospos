// Carga y validación de variables de entorno requeridas por las Edge Functions Azul.
// PRD §D — variables documentadas.
//
// Falla rápido (throw en startup) si falta alguna requerida. Esto previene
// runtime errors en producción por config incompleta.

export interface AzulEnv {
  azulEnv: "test" | "production";
  azulMerchantId: string;
  azulMerchantName: string;
  azulMerchantType: string;
  azulCurrencyCode: string;
  azulAuthKey: string;
  azulPaymentPageUrl: string;
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
    azulAuthKey: required("AZUL_AUTH_KEY"),
    azulPaymentPageUrl: required("AZUL_PAYMENT_PAGE_URL"),
    publicCallbackBaseUrl: required("PUBLIC_CALLBACK_BASE_URL"),
    publicReturnBaseUrl: required("PUBLIC_RETURN_BASE_URL"),
    supabaseUrl: required("SUPABASE_URL"),
    supabaseServiceRoleKey: required("SUPABASE_SERVICE_ROLE_KEY"),
  };
  return cached;
}
