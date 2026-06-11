// Tests del armado de payload de los helpers 3D Secure 2.0 (Fase 3DS.0).
// No tocan la red: stubeamos globalThis.fetch para capturar lo que el sidecar
// recibiría y verificamos la forma del mensaje a Azul.
//
// Correr local:
//   deno test supabase/functions/_shared/azul-api_test.ts

import {
  assertEquals,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

// getAzulEnv() es lazy (lee Deno.env al primer uso, no al importar), así que
// basta con setear las vars antes de invocar cualquier builder en los tests.
Deno.env.set("AZUL_MERCHANT_ID", "39038540035");
Deno.env.set("AZUL_PROXY_URL", "http://azul-proxy:3000");
Deno.env.set("AZUL_PROXY_AUTH_TOKEN", "test-token");
Deno.env.set("PUBLIC_CALLBACK_BASE_URL", "https://cb.example.com");
Deno.env.set("PUBLIC_RETURN_BASE_URL", "https://ret.example.com");
Deno.env.set("SUPABASE_URL", "https://x.supabase.co");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "srv");

import {
  processPaymentWith3DS,
  processThreeDSChallenge,
  processThreeDSMethod,
} from "./azul-api.ts";

interface CapturedCall {
  url: string;
  method: string;
  // deno-lint-ignore no-explicit-any
  payload: any;
}

/** Reemplaza fetch por un stub que captura el body y devuelve una respuesta del sidecar. */
function stubFetch(responseBody: Record<string, unknown> = { IsoCode: "00" }) {
  const calls: CapturedCall[] = [];
  const original = globalThis.fetch;
  const stub = (_input: unknown, init?: RequestInit): Promise<Response> => {
    const body = init?.body ? JSON.parse(String(init.body)) : {};
    calls.push({ url: String(_input), method: body.method, payload: body.body });
    const proxyResp = { ok: true, httpStatus: 200, durationMs: 1, body: responseBody };
    return Promise.resolve(
      new Response(JSON.stringify(proxyResp), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
  };
  globalThis.fetch = stub as unknown as typeof fetch;
  return { calls, restore: () => (globalThis.fetch = original) };
}

const BROWSER = {
  acceptHeader: "text/html",
  ipAddress: "1.2.3.4",
  language: "es-DO",
  colorDepth: "24",
  screenWidth: "1920",
  screenHeight: "1080",
  timeZone: "240",
  userAgent: "Mozilla/5.0",
  javaScriptEnabled: "true",
};

const THREEDS_AUTH = {
  termUrl: "https://cb.example.com/azul-3ds-term?sid=abc",
  methodNotificationUrl: "https://cb.example.com/azul-3ds-method-notify?sid=abc",
};

Deno.test("processPaymentWith3DS (Hold + card): activa 3DS, tokeniza y arma los 3 nodos", async () => {
  const { calls, restore } = stubFetch();
  try {
    await processPaymentWith3DS({
      trxType: "Hold",
      amountCents: 100,
      itbisCents: 0,
      orderNumber: "MP3DSTEST00001",
      card: { cardNumber: "4005520000000129", expiration: "202812", cvc: "123" },
      saveToDataVault: true,
      threeDSAuth: THREEDS_AUTH,
      cardHolderInfo: { name: "Juan Perez", email: "juan@example.com" },
      browserInfo: BROWSER,
    });

    assertEquals(calls.length, 1);
    const { method, payload: p } = calls[0];
    assertEquals(method, "ProcessPayment");
    assertEquals(p.TrxType, "Hold");
    assertEquals(p.ForceNo3DS, "0"); // 0 = pasa por 3DS (no se salta)
    assertEquals(p.SaveToDataVault, "1");
    assertEquals(p.Itbis, "000"); // itbis 0 → "000"
    assertEquals(p.CardNumber, "4005520000000129");
    assertEquals(p.Expiration, "202812");
    assertEquals("DataVaultToken" in p, false); // con card no va token
    // ThreeDSAuth
    assertEquals(p.ThreeDSAuth.TermUrl, THREEDS_AUTH.termUrl);
    assertEquals(p.ThreeDSAuth.MethodNotificationUrl, THREEDS_AUTH.methodNotificationUrl);
    assertEquals(p.ThreeDSAuth.RequestorChallengeIndicator, "01"); // default
    // CardHolderInfo: Name+Email presentes, opcionales vacíos omitidos
    assertEquals(p.CardHolderInfo.Name, "Juan Perez");
    assertEquals(p.CardHolderInfo.Email, "juan@example.com");
    assertEquals("PhoneHome" in p.CardHolderInfo, false);
    assertEquals("BillingAddressCity" in p.CardHolderInfo, false);
    // BrowserInfo: los 9 obligatorios
    assertEquals(Object.keys(p.BrowserInfo).length, 9);
    assertEquals(p.BrowserInfo.JavaScriptEnabled, "true");
    assertEquals(p.BrowserInfo.IPAddress, "1.2.3.4");
  } finally {
    restore();
  }
});

Deno.test("processPaymentWith3DS: itbis>0 pasa los centavos; indicador de desafío configurable", async () => {
  const { calls, restore } = stubFetch();
  try {
    await processPaymentWith3DS({
      trxType: "Sale",
      amountCents: 1075,
      itbisCents: 121,
      orderNumber: "MP3DSTEST00002",
      card: { cardNumber: "4005520000000129", expiration: "202812", cvc: "123" },
      threeDSAuth: { ...THREEDS_AUTH, requestorChallengeIndicator: "03" },
      cardHolderInfo: { name: "Ana", email: "ana@example.com" },
      browserInfo: BROWSER,
    });
    const p = calls[0].payload;
    assertEquals(p.TrxType, "Sale");
    assertEquals(p.Itbis, "121");
    assertEquals(p.SaveToDataVault, "0"); // default sin tokenizar
    assertEquals(p.ThreeDSAuth.RequestorChallengeIndicator, "03");
  } finally {
    restore();
  }
});

Deno.test("processPaymentWith3DS (token): usa DataVaultToken y no manda CardNumber", async () => {
  const { calls, restore } = stubFetch();
  try {
    await processPaymentWith3DS({
      trxType: "Sale",
      amountCents: 100,
      itbisCents: 0,
      orderNumber: "MP3DSTOKEN0001",
      dataVaultToken: "FE1525FD-A59B-476A-9EFA-387D510689AB",
      threeDSAuth: THREEDS_AUTH,
      cardHolderInfo: { name: "Ana", email: "ana@example.com" },
      browserInfo: BROWSER,
    });
    const p = calls[0].payload;
    assertEquals(p.DataVaultToken, "FE1525FD-A59B-476A-9EFA-387D510689AB");
    assertEquals("CardNumber" in p, false);
  } finally {
    restore();
  }
});

Deno.test("processPaymentWith3DS: conserva opcionales de CardHolderInfo cuando vienen", async () => {
  const { calls, restore } = stubFetch();
  try {
    await processPaymentWith3DS({
      trxType: "Hold",
      amountCents: 100,
      itbisCents: 0,
      orderNumber: "MP3DSTEST00003",
      card: { cardNumber: "4005520000000129", expiration: "202812", cvc: "123" },
      threeDSAuth: THREEDS_AUTH,
      cardHolderInfo: {
        name: "Juan Perez",
        email: "juan@example.com",
        phoneMobile: "8095551234",
        billingAddressCity: "Santo Domingo",
        billingAddressCountry: "DO",
        billingAddressLine2: "", // vacío explícito → debe omitirse
      },
      browserInfo: BROWSER,
    });
    const chi = calls[0].payload.CardHolderInfo;
    assertEquals(chi.PhoneMobile, "8095551234");
    assertEquals(chi.BillingAddressCity, "Santo Domingo");
    assertEquals(chi.BillingAddressCountry, "DO");
    assertEquals("BillingAddressLine2" in chi, false);
    assertEquals("PhoneHome" in chi, false);
  } finally {
    restore();
  }
});

Deno.test("processPaymentWith3DS: lanza si no hay ni card ni token", () => {
  assertThrows(
    () =>
      processPaymentWith3DS({
        trxType: "Hold",
        amountCents: 100,
        itbisCents: 0,
        orderNumber: "MP3DSTEST00004",
        threeDSAuth: THREEDS_AUTH,
        cardHolderInfo: { name: "Ana", email: "ana@example.com" },
        browserInfo: BROWSER,
      }),
    Error,
    "requiere card o dataVaultToken",
  );
});

Deno.test("processThreeDSMethod: arma método y status", async () => {
  const { calls, restore } = stubFetch({ IsoCode: "00" });
  try {
    await processThreeDSMethod({
      azulOrderId: "39306",
      methodNotificationStatus: "RECEIVED",
    });
    const { method, payload: p } = calls[0];
    assertEquals(method, "ProcessThreeDSMethod");
    assertEquals(p.Channel, "EC");
    assertEquals(p.Store, "39038540035");
    assertEquals(p.AzulOrderId, "39306");
    assertEquals(p.MethodNotificationStatus, "RECEIVED");
  } finally {
    restore();
  }
});

Deno.test("processThreeDSChallenge: arma método y CRes", async () => {
  const { calls, restore } = stubFetch({ IsoCode: "00" });
  try {
    await processThreeDSChallenge({
      azulOrderId: "39306",
      cRes: "ewogICAiYWN...base64...Igo9",
    });
    const { method, payload: p } = calls[0];
    assertEquals(method, "ProcessThreeDSChallenge");
    assertEquals(p.AzulOrderId, "39306");
    assertEquals(p.CRes, "ewogICAiYWN...base64...Igo9");
  } finally {
    restore();
  }
});
