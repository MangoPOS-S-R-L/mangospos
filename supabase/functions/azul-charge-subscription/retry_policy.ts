// Qué hacer cuando el cobro de un período ya existe (choque con el índice
// UNIQUE (membership_id, billing_period_start, attempt_number)), y cómo leer la
// verificación con Azul antes de reintentarlo.
//
// Por qué existe este archivo:
//
// 1) Agosto 2026: varias suscripciones quedaron con DOS ventas aprobadas en
//    Azul en el mismo segundo. Llegaron dos pedidos concurrentes del mismo
//    cobro; el segundo encontró la fila en `pending` (la primera llamada seguía
//    en Azul) y volvió a mandar la venta.
// 2) Julio 2026 (Tropella): la llamada se cayó DESPUÉS de que Azul aprobó; la
//    fila quedó en `error` y el reintento volvió a cobrar. No había forma de
//    preguntarle a Azul si ese intento había pasado.
//
// Regla:
//   pending reciente         → EN VUELO: otro pedido lo está cobrando. No se
//                              toca Azul.
//   error muy reciente       → demasiado pronto para verificar: Azul puede no
//                              ver todavía la venta. No se toca Azul.
//   error, o pending viejo   → se VERIFICA con Azul (VerifyPayment por
//                              CustomOrderId) y solo si Azul no lo cobró se
//                              reintenta, reclamando la fila con un UPDATE
//                              condicional (un solo pedido gana).
//   todo lo demás            → terminal: approved/declined se devuelven tal
//                              cual; un estado inesperado no dispara un cobro.

/** Un `pending` más nuevo que esto se considera en vuelo. Una llamada real a
 *  Azul tarda segundos; 10 minutos cubren con holgura cualquier cobro vivo sin
 *  dejar trabado para siempre uno cuyo worker murió. */
export const IN_FLIGHT_WINDOW_MS = 10 * 60 * 1000;

/** VerifyPayment demasiado pronto puede no ver una venta que Azul todavía
 *  procesa (mismo criterio que admin-azul-refund). Un `error` más nuevo que
 *  esto no se verifica ni se reintenta todavía. */
export const VERIFY_MIN_AGE_MS = 2 * 60 * 1000;

export interface ExistingCharge {
  status: string;
  attempted_at: string | null;
}

export type RetryDecision = "terminal" | "in_progress" | "retry";

export function decideOnExistingCharge(
  existing: ExistingCharge,
  nowMs: number,
): RetryDecision {
  if (existing.status !== "error" && existing.status !== "pending") {
    return "terminal";
  }
  const attemptedMs = existing.attempted_at ? Date.parse(existing.attempted_at) : NaN;
  // Sin fecha legible no se puede saber si sigue vivo: ante la duda, NO se
  // cobra. Un cobro diferido se recupera; uno doble hay que reembolsarlo.
  if (!Number.isFinite(attemptedMs)) return "in_progress";

  const minAgeMs = existing.status === "pending" ? IN_FLIGHT_WINDOW_MS : VERIFY_MIN_AGE_MS;
  return nowMs - attemptedMs < minAgeMs ? "in_progress" : "retry";
}

/** Un `pending` con `attempted_at` anterior a esto ya no está en vuelo. */
export function inFlightCutoffIso(nowMs: number): string {
  return new Date(nowMs - IN_FLIGHT_WINDOW_MS).toISOString();
}

/** CustomOrderId de un cobro: único por fila y el mismo en sus reintentos,
 *  así VerifyPayment responde por CUALQUIER venta de ese cobro. Mismo formato
 *  que los reembolsos (`mprf-…`). */
export function chargeCustomOrderId(chargeId: string): string {
  return `mpch-${chargeId.replace(/-/g, "").toLowerCase()}`;
}

/**
 * `Found` de VerifyPayment. Azul lo documenta como booleano pero en la práctica
 * llega como string ('0'/'1'/'true'/'false'). `null` = no se puede saber.
 */
export function parseFound(value: unknown): boolean | null {
  if (value === true || value === 1) return true;
  if (value === false || value === 0) return false;
  const s = String(value ?? "").trim().toLowerCase();
  if (s === "1" || s === "true") return true;
  if (s === "0" || s === "false") return false;
  return null;
}

/** Qué dice Azul del intento anterior:
 *   approved     → la venta pasó: registrarla, NO volver a cobrar.
 *   not_charged  → Azul no la tiene, o la tiene rechazada/sin procesar: no se
 *                  movió dinero, se puede reintentar.
 *   unknown      → no se puede saber: NO se cobra. */
export type VerifyOutcome = "approved" | "not_charged" | "unknown";

export function classifyChargeVerify(
  httpStatus: number,
  body: { Found?: unknown; IsoCode?: string; ResponseCode?: string },
): VerifyOutcome {
  if (httpStatus !== 200) return "unknown";
  const found = parseFound(body.Found);
  if (found === null) return "unknown";
  // Ojo: con Found=0 Azul igual responde IsoCode "00" (la CONSULTA salió
  // bien). Por eso se mira Found primero y el IsoCode solo si la encontró.
  if (!found) return "not_charged";
  if (body.IsoCode === "00") return "approved";
  const responseCode = String(body.ResponseCode ?? "").trim().toUpperCase();
  // ISO8583 = el procesador la rechazó; Error = Azul no la procesó.
  if (responseCode === "ISO8583" || responseCode === "ERROR") return "not_charged";
  return "unknown";
}
