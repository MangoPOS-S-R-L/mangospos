// Tests de la lógica pura del flujo 3DS (azul-3ds.ts). Sin red.
//   deno test supabase/functions/_shared/azul-3ds_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  classify3DSResponse,
  clientIpFromHeaders,
  decideMethodNotificationStatus,
  decodeThreeDSServerTransID,
} from "./azul-3ds.ts";

Deno.test("classify: IsoCode 00 + http 200 → approved", () => {
  const r = classify3DSResponse(200, { IsoCode: "00", AzulOrderId: "39597" });
  assertEquals(r.kind, "approved");
});

Deno.test("classify: 3D2METHOD con MethodForm → method", () => {
  const r = classify3DSResponse(200, {
    IsoCode: "3D2METHOD",
    ResponseMessage: "3D_SECURE_2_METHOD",
    ThreeDSMethod: { MethodForm: "<iframe>...</iframe>" },
  });
  assertEquals(r.kind, "method");
  if (r.kind === "method") assertEquals(r.methodForm, "<iframe>...</iframe>");
});

Deno.test("classify: 3D2METHOD sin MethodForm → declined", () => {
  const r = classify3DSResponse(200, { IsoCode: "3D2METHOD" });
  assertEquals(r.kind, "declined");
});

Deno.test("classify: 3D con CReq+RedirectPostUrl → challenge", () => {
  const r = classify3DSResponse(200, {
    IsoCode: "3D",
    ResponseMessage: "3D_SECURE_CHALLENGE",
    ThreeDSChallenge: {
      CReq: "ewogICA...",
      RedirectPostUrl: "https://3ds-acs.test.modirum.com/mdpayacs/creq",
    },
  });
  assertEquals(r.kind, "challenge");
  if (r.kind === "challenge") {
    assertEquals(r.creq, "ewogICA...");
    assertEquals(r.redirectPostUrl, "https://3ds-acs.test.modirum.com/mdpayacs/creq");
  }
});

Deno.test("classify: 3D sin datos de desafío → declined", () => {
  const r = classify3DSResponse(200, { IsoCode: "3D", ThreeDSChallenge: {} });
  assertEquals(r.kind, "declined");
});

Deno.test("classify: IsoCode distinto → declined con mensaje", () => {
  const r = classify3DSResponse(200, {
    IsoCode: "63",
    ResponseMessage: "BIN NOT FOUND",
    ErrorDescription: "",
  });
  assertEquals(r.kind, "declined");
  if (r.kind === "declined") {
    assertEquals(r.iso, "63");
    assertEquals(r.message, "BIN NOT FOUND");
  }
});

Deno.test("classify: http != 200 con IsoCode 00 → declined (no se cuela)", () => {
  const r = classify3DSResponse(502, { IsoCode: "00" });
  assertEquals(r.kind, "declined");
});

Deno.test("methodNotificationStatus: sin method → NOT_EXPECTED", () => {
  assertEquals(
    decideMethodNotificationStatus({ methodFormSent: false, notificationReceived: false }),
    "NOT_EXPECTED",
  );
});

Deno.test("methodNotificationStatus: method enviado y notificado → RECEIVED", () => {
  assertEquals(
    decideMethodNotificationStatus({ methodFormSent: true, notificationReceived: true }),
    "RECEIVED",
  );
});

Deno.test("methodNotificationStatus: method enviado sin notificación → EXPECTED_BUT_NOT_RECEIVED", () => {
  assertEquals(
    decideMethodNotificationStatus({ methodFormSent: true, notificationReceived: false }),
    "EXPECTED_BUT_NOT_RECEIVED",
  );
});

Deno.test("decodeThreeDSServerTransID: base64 de JSON válido", () => {
  const data = btoa(JSON.stringify({ threeDSServerTransID: "3ac7caa7-aa42-2663-791b-2ac05a542c4a" }));
  assertEquals(decodeThreeDSServerTransID(data), "3ac7caa7-aa42-2663-791b-2ac05a542c4a");
});

Deno.test("decodeThreeDSServerTransID: basura o null → null", () => {
  assertEquals(decodeThreeDSServerTransID(null), null);
  assertEquals(decodeThreeDSServerTransID("no-es-base64-json"), null);
});

Deno.test("clientIpFromHeaders: primer IP de x-forwarded-for", () => {
  const h = new Headers({ "x-forwarded-for": "152.167.90.2, 10.0.0.1" });
  assertEquals(clientIpFromHeaders(h), "152.167.90.2");
});

Deno.test("clientIpFromHeaders: fallback cuando no hay headers", () => {
  assertEquals(clientIpFromHeaders(new Headers()), "0.0.0.0");
});
