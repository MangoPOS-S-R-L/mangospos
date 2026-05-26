// Smoke test end-to-end: Edge Function → azul-proxy (sidecar) → Azul real.
//
// Modes:
//   ?mode=health   → GET al /health del sidecar (sanidad de network + cert load)
//   ?mode=verify   → VerifyPayment con CustomOrderId inexistente (handshake real)
//   ?mode=raw      → POST { method, body } arbitrario (debug)
//
// Si todo OK en `verify`:
//   - HTTP 200, body.IsoCode === "00", body.Found === "0"
//   - Eso prueba: edge function ↔ sidecar ↔ Azul (mTLS + Auth1/Auth2 OK).
//
// SEGURIDAD: requiere header `x-mangopos-smoke-key` = MANGOPOS_SMOKE_KEY del env.
// Sin esa var configurada, responde 503. Borrar este endpoint en B4.

import {
  callAzul,
  verifyPayment,
  AzulCallError,
} from "../_shared/azul-api.ts";
import { getAzulEnv } from "../_shared/env.ts";
import { corsPreflight, errorResponse, jsonResponse } from "../_shared/responses.ts";

Deno.serve(async (req: Request) => {
  const pre = corsPreflight(req);
  if (pre) return pre;

  const expectedKey = Deno.env.get("MANGOPOS_SMOKE_KEY");
  if (!expectedKey) {
    return errorResponse(503, "smoke_disabled", "MANGOPOS_SMOKE_KEY not set");
  }
  if (req.headers.get("x-mangopos-smoke-key") !== expectedKey) {
    return errorResponse(401, "unauthorized", "Bad smoke key");
  }

  const url = new URL(req.url);
  const mode = url.searchParams.get("mode") ?? "health";

  try {
    if (mode === "health") {
      const env = getAzulEnv();
      const healthUrl = `${env.azulProxyUrl.replace(/\/$/, "")}/health`;
      let res: Response;
      try {
        res = await fetch(healthUrl, { method: "GET" });
      } catch (e) {
        return errorResponse(502, "sidecar_unreachable", String(e), { healthUrl });
      }
      const body = await res.text();
      let parsed: unknown;
      try {
        parsed = JSON.parse(body);
      } catch (_e) {
        parsed = body.slice(0, 500);
      }
      return jsonResponse({
        mode: "health",
        sidecarUrl: env.azulProxyUrl,
        httpStatus: res.status,
        sidecarBody: parsed,
      });
    }

    if (mode === "verify") {
      const fakeOrderId = `mp_smoketest_${crypto.randomUUID().slice(0, 12)}`;
      const result = await verifyPayment({ customOrderId: fakeOrderId });
      return jsonResponse({
        mode: "verify",
        customOrderId: fakeOrderId,
        httpStatus: result.httpStatus,
        durationMs: result.durationMs,
        ok: result.ok,
        isoCode: result.body.IsoCode,
        found: result.body.Found,
        responseMessage: result.body.ResponseMessage,
        errorDescription: result.body.ErrorDescription,
        bodyKeys: Object.keys(result.body),
      });
    }

    if (mode === "raw") {
      const payload = req.method === "POST"
        ? (await req.json()) as { method: string; body: Record<string, unknown> }
        : null;
      if (!payload) {
        return errorResponse(400, "bad_request", "POST { method, body } required");
      }
      // deno-lint-ignore no-explicit-any
      const result = await callAzul(payload.method as any, payload.body);
      return jsonResponse({
        mode: "raw",
        method: payload.method,
        httpStatus: result.httpStatus,
        durationMs: result.durationMs,
        ok: result.ok,
        body: result.body,
      });
    }

    return errorResponse(400, "bad_mode", `Unknown mode: ${mode}`);
  } catch (e) {
    if (e instanceof AzulCallError) {
      return errorResponse(502, "azul_call_failed", e.message, {
        code: e.code,
        httpStatus: e.httpStatus,
        detail: e.detail,
      });
    }
    const msg = e instanceof Error ? e.message : String(e);
    return errorResponse(500, "internal", msg);
  }
});
