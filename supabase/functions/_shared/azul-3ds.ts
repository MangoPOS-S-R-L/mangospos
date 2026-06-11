// Lógica pura del flujo 3D Secure 2.0 (PRD-Azul-3DSecure §6). Sin I/O ni red:
// clasifica respuestas de Azul y decide el siguiente paso de la máquina de
// estados. Aislado aquí para poder unit-testearlo (azul-3ds_test.ts).

import type { AzulResponse } from "./azul-api.ts";

/** Accept header estándar de navegador (doc Azul pág. 9). Lo fijamos server-side. */
export const STANDARD_ACCEPT_HEADER =
  "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp," +
  "image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9";

/** Siguiente acción según la respuesta de Azul a un Sale/Hold con 3DS. */
export type ThreeDSNext =
  | { kind: "approved"; azul: AzulResponse }
  | { kind: "declined"; iso?: string; message?: string; errorDescription?: string }
  | { kind: "method"; methodForm: string }
  | { kind: "challenge"; creq: string; redirectPostUrl: string };

/**
 * Clasifica una respuesta de ProcessPayment/ProcessThreeDSMethod con 3DS:
 *   IsoCode 00          → approved (autorización final)
 *   IsoCode 3D2METHOD   → method (renderizar MethodForm oculto)
 *   IsoCode 3D          → challenge (POST del creq al ACS)
 *   cualquier otro       → declined
 */
export function classify3DSResponse(httpStatus: number, azul: AzulResponse): ThreeDSNext {
  const iso = azul.IsoCode;

  if (httpStatus === 200 && iso === "00") {
    return { kind: "approved", azul };
  }

  if (iso === "3D2METHOD") {
    const methodForm = azul.ThreeDSMethod?.MethodForm;
    if (methodForm) return { kind: "method", methodForm };
    return { kind: "declined", iso, message: "3D2METHOD sin MethodForm" };
  }

  if (iso === "3D") {
    const c = azul.ThreeDSChallenge;
    if (c?.CReq && c?.RedirectPostUrl) {
      return { kind: "challenge", creq: c.CReq, redirectPostUrl: c.RedirectPostUrl };
    }
    return { kind: "declined", iso, message: "3D sin datos de desafío (CReq/RedirectPostUrl)" };
  }

  return {
    kind: "declined",
    iso,
    message: azul.ResponseMessage,
    errorDescription: azul.ErrorDescription,
  };
}

/**
 * MethodNotificationStatus para ProcessThreeDSMethod (doc Azul pág. 19):
 *   - No se envió MethodNotificationUrl            → NOT_EXPECTED
 *   - Se envió y el ACS notificó en ≤10s           → RECEIVED
 *   - Se envió pero no notificó en 10s             → EXPECTED_BUT_NOT_RECEIVED
 */
export function decideMethodNotificationStatus(p: {
  methodFormSent: boolean;
  notificationReceived: boolean;
}): "RECEIVED" | "EXPECTED_BUT_NOT_RECEIVED" | "NOT_EXPECTED" {
  if (!p.methodFormSent) return "NOT_EXPECTED";
  return p.notificationReceived ? "RECEIVED" : "EXPECTED_BUT_NOT_RECEIVED";
}

/**
 * Decodifica el `threeDSMethodData` (base64 de un JSON {threeDSServerTransID})
 * que el ACS postea a MethodNotificationUrl. Devuelve null si no se puede.
 */
export function decodeThreeDSServerTransID(threeDSMethodData: string | null): string | null {
  if (!threeDSMethodData) return null;
  try {
    const json = atob(threeDSMethodData);
    const parsed = JSON.parse(json) as { threeDSServerTransID?: string };
    return parsed.threeDSServerTransID ?? null;
  } catch {
    return null;
  }
}

/** Extrae la IP del cliente de los headers de proxy (x-forwarded-for primero). */
export function clientIpFromHeaders(headers: Headers): string {
  const xff = headers.get("x-forwarded-for");
  if (xff) return xff.split(",")[0].trim();
  return headers.get("x-real-ip") ?? headers.get("cf-connecting-ip") ?? "0.0.0.0";
}
