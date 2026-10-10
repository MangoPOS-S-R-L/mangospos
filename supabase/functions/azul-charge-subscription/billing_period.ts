// Qué período se cobra, y si ya está pagado.
//
// Por qué existe este archivo:
//
// Octubre 2026 (ECOBAR AND LOUNGE): una suscripción que nunca había pagado,
// con next_billing_date viejo (27/06/2026), se cobró CUATRO veces seguidas
// (03, 04, 05 y 06/10), una mensualidad atrasada por día. Cada cobro aprobado
// corría next_billing_date un solo mes (27/07, 27/08, 27/09), que seguía en el
// pasado, y el cron de las 03:00 lo volvía a encontrar vencido al día
// siguiente. Recién paró al llegar a 27/10.
//
// Pero un cliente que YA venía pagando y se atrasó (The Pizza Hot, agosto
// 2026) sí debe su mes atrasado, y ese cobro es correcto.
//
// Regla, cuando el período pedido ya terminó entero (vence hoy o antes):
//   - Ya venía pagando y no se le cobró nada en los últimos 15 días → se cobra
//     ESE mes atrasado. El siguiente (el actual) lo cobra el cron al otro día.
//   - Nunca pagó (venía de prueba), o ya se le cobró hace poco → se re-ancla:
//     el cobro cubre desde HOY un mes. Lo de en medio no se cobra solo.
//   El "hace poco" es el tope: de una racha de atrasos se cobra UN solo mes
//   atrasado, nunca uno por día.
//
// Y nunca se cobran dos veces los mismos días: si un cobro aprobado (y no
// reembolsado completo) ya cubre parte del período, no se cobra. Pasa si
// alguien mueve next_billing_date hacia atrás después de un pago.
//
// Fechas como "YYYY-MM-DD": compararlas como texto es compararlas como fecha.

/** Un cobro aprobado más nuevo que esto impide cobrar otro mes atrasado. Una
 *  racha de cobros atrasados va de a uno por día; un cliente al día se cobra
 *  cada ~30 días. */
export const RECENT_CHARGE_MS = 15 * 24 * 60 * 60 * 1000;

export function addMonthIso(baseIso: string): string {
  const d = new Date(`${baseIso}T00:00:00Z`);
  d.setUTCMonth(d.getUTCMonth() + 1);
  return d.toISOString().slice(0, 10);
}

/** Cobro aprobado de la suscripción, con lo que se le reembolsó. */
export interface PaidCharge {
  id: string;
  billing_period_start: string;
  billing_period_end: string;
  amount_cents: number;
  attempted_at: string | null;
  /** Suma de reembolsos aprobados de este cobro. */
  refunded_cents: number;
}

export interface BillingPeriod {
  periodStart: string;
  periodEnd: string;
  /** Fecha pedida que se descartó por vencida; null si no hubo re-anclaje. */
  reanchoredFrom: string | null;
}

function fullyRefunded(c: PaidCharge): boolean {
  return c.refunded_cents >= c.amount_cents;
}

export function resolveBillingPeriod(
  requestedStart: string,
  today: string,
  paid: PaidCharge[],
  nowMs: number,
): BillingPeriod {
  const requestedEnd = addMonthIso(requestedStart);
  if (requestedEnd > today) {
    return { periodStart: requestedStart, periodEnd: requestedEnd, reanchoredFrom: null };
  }

  // Un cobro reembolsado completo no cuenta como "venía pagando"...
  const paidBefore = paid.some((c) => !fullyRefunded(c));
  // ...pero sí como "se le cobró hace poco": si se reembolsó, menos razón para
  // volver a cobrarle un atraso al día siguiente. Sin fecha legible, se asume
  // reciente (ante la duda, no se cobra el atraso).
  const chargedRecently = paid.some((c) => {
    const ms = c.attempted_at ? Date.parse(c.attempted_at) : NaN;
    return !Number.isFinite(ms) || nowMs - ms < RECENT_CHARGE_MS;
  });
  if (paidBefore && !chargedRecently) {
    return { periodStart: requestedStart, periodEnd: requestedEnd, reanchoredFrom: null };
  }
  return { periodStart: today, periodEnd: addMonthIso(today), reanchoredFrom: requestedStart };
}

/**
 * Cobro aprobado que ya cubre días del período [periodStart, periodEnd), o null.
 *
 * Se ignora el cobro del MISMO billing_period_start: ese caso lo resuelve el
 * índice UNIQUE (respuesta idempotente), no esta barrera. Un cobro reembolsado
 * completo ya no cubre nada.
 */
export function findOverlappingPaidCharge(
  paid: PaidCharge[],
  periodStart: string,
  periodEnd: string,
): PaidCharge | null {
  for (const c of paid) {
    if (c.billing_period_start === periodStart) continue;
    if (fullyRefunded(c)) continue;
    if (c.billing_period_start < periodEnd && c.billing_period_end > periodStart) return c;
  }
  return null;
}
