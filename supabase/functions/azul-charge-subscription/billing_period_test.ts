import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  addMonthIso,
  findOverlappingPaidCharge,
  type PaidCharge,
  RECENT_CHARGE_MS,
  resolveBillingPeriod,
} from "./billing_period.ts";

const DAY_MS = 24 * 60 * 60 * 1000;
const at = (iso: string) => Date.parse(`${iso}T07:00:00Z`);

const paid = (
  start: string,
  end: string,
  opts: { refunded?: number; attemptedOn?: string | null } = {},
): PaidCharge => ({
  id: `c-${start}`,
  billing_period_start: start,
  billing_period_end: end,
  amount_cents: 299999,
  attempted_at: opts.attemptedOn === null
    ? null
    : `${opts.attemptedOn ?? start}T07:00:00Z`,
  refunded_cents: opts.refunded ?? 0,
});

// ---------------------------------------------------------------------------
// resolveBillingPeriod — período vigente
// ---------------------------------------------------------------------------

Deno.test("fecha de cobro de hoy: se cobra el período normal", () => {
  assertEquals(resolveBillingPeriod("2026-10-27", "2026-10-27", [], at("2026-10-27")), {
    periodStart: "2026-10-27",
    periodEnd: "2026-11-27",
    reanchoredFrom: null,
  });
});

Deno.test("reintento de un cobro atrasado unos días: se mantiene el período", () => {
  assertEquals(
    resolveBillingPeriod("2026-09-27", "2026-10-03", [], at("2026-10-03")).periodStart,
    "2026-09-27",
  );
});

Deno.test("pago adelantado (Pagar ahora 48h antes): se mantiene el período", () => {
  assertEquals(
    resolveBillingPeriod("2026-10-27", "2026-10-25", [], at("2026-10-25")).periodStart,
    "2026-10-27",
  );
});

// ---------------------------------------------------------------------------
// resolveBillingPeriod — nunca pagó (ECOBAR, octubre 2026)
// ---------------------------------------------------------------------------

Deno.test("ECOBAR: nunca pagó y la fecha es del 27/06 → un solo cobro desde hoy", () => {
  // Antes: 03/10 cobró 27/06→27/07, y el cron cobró 27/07, 27/08 y 27/09 los
  // días 04, 05 y 06/10.
  const p = resolveBillingPeriod("2026-06-27", "2026-10-03", [], at("2026-10-03"));
  assertEquals(p, {
    periodStart: "2026-10-03",
    periodEnd: "2026-11-03",
    reanchoredFrom: "2026-06-27",
  });
  // Al día siguiente next_billing_date ya está en el futuro: el cron no lo toma.
  assertEquals(p.periodEnd > "2026-10-04", true);
});

Deno.test("solo pagos reembolsados completos cuenta como 'nunca pagó'", () => {
  const refunded = paid("2026-03-01", "2026-04-01", { refunded: 299999 });
  assertEquals(
    resolveBillingPeriod("2026-06-27", "2026-10-03", [refunded], at("2026-10-03")).reanchoredFrom,
    "2026-06-27",
  );
});

Deno.test("período que termina justo hoy ya terminó", () => {
  assertEquals(
    resolveBillingPeriod("2026-09-09", "2026-10-09", [], at("2026-10-09")).periodStart,
    "2026-10-09",
  );
});

Deno.test("re-anclado y guardado, el reintento del día siguiente usa la misma llave", () => {
  // Día 1: 27/06 → re-ancla a 10/10 (index.ts guarda next_billing_date=10/10
  // antes de cobrar). Si la llamada a Azul se cae, al día siguiente el cron
  // manda 10/10: NO se re-ancla otra vez, cae en la misma fila y pasa por
  // VerifyPayment en vez de crear un cobro nuevo.
  const day1 = resolveBillingPeriod("2026-06-27", "2026-10-10", [], at("2026-10-10"));
  const day2 = resolveBillingPeriod(day1.periodStart, "2026-10-11", [], at("2026-10-11"));
  assertEquals(day2.periodStart, day1.periodStart);
  assertEquals(day2.reanchoredFrom, null);
});

// ---------------------------------------------------------------------------
// resolveBillingPeriod — venía pagando y se atrasó (The Pizza Hot)
// ---------------------------------------------------------------------------

const julyPaid = paid("2026-07-01", "2026-08-01");

Deno.test("Pizza Hot: pagó julio y se atrasó en agosto → se cobra agosto", () => {
  assertEquals(resolveBillingPeriod("2026-08-01", "2026-09-02", [julyPaid], at("2026-09-02")), {
    periodStart: "2026-08-01",
    periodEnd: "2026-09-01",
    reanchoredFrom: null,
  });
});

Deno.test("Pizza Hot: al día siguiente se cobra septiembre normal, sin re-anclar", () => {
  const augPaid = paid("2026-08-01", "2026-09-01", { attemptedOn: "2026-09-02" });
  assertEquals(
    resolveBillingPeriod("2026-09-01", "2026-09-03", [julyPaid, augPaid], at("2026-09-03")),
    { periodStart: "2026-09-01", periodEnd: "2026-10-01", reanchoredFrom: null },
  );
});

Deno.test("tope: un solo mes atrasado aunque deba varios", () => {
  // Pagó hasta el 01/07, debe julio, agosto y septiembre. Día 1: se cobra
  // julio. Día 2: agosto también está vencido, pero ya se le cobró ayer →
  // se re-ancla a hoy. Total: 2 cobros, no 4.
  const day1 = resolveBillingPeriod("2026-07-01", "2026-10-02", [paid("2026-06-01", "2026-07-01")], at("2026-10-02"));
  assertEquals(day1.periodStart, "2026-07-01");
  assertEquals(day1.reanchoredFrom, null);

  const history = [
    paid("2026-06-01", "2026-07-01"),
    paid("2026-07-01", "2026-08-01", { attemptedOn: "2026-10-02" }),
  ];
  const day2 = resolveBillingPeriod("2026-08-01", "2026-10-03", history, at("2026-10-03"));
  assertEquals(day2, {
    periodStart: "2026-10-03",
    periodEnd: "2026-11-03",
    reanchoredFrom: "2026-08-01",
  });
});

Deno.test("tope en el borde: el mes que vence justo al día siguiente no suma otro cobro", () => {
  // 31/08 se cobra julio (atrasado). El 01/09 vence agosto el mismo día, pero
  // ya se le cobró ayer → re-ancla en vez de cobrar agosto Y septiembre.
  const history = [
    paid("2026-06-01", "2026-07-01"),
    paid("2026-07-01", "2026-08-01", { attemptedOn: "2026-08-31" }),
  ];
  assertEquals(
    resolveBillingPeriod("2026-08-01", "2026-09-01", history, at("2026-09-01")).reanchoredFrom,
    "2026-08-01",
  );
});

Deno.test("cobro de hace más de 15 días ya no frena el cobro del atraso", () => {
  const old = paid("2026-07-01", "2026-08-01", {
    attemptedOn: new Date(at("2026-09-02") - RECENT_CHARGE_MS - DAY_MS).toISOString().slice(0, 10),
  });
  assertEquals(
    resolveBillingPeriod("2026-08-01", "2026-09-02", [old], at("2026-09-02")).reanchoredFrom,
    null,
  );
});

Deno.test("cobro sin fecha legible se toma como reciente: no se cobra el atraso", () => {
  const noDate = paid("2026-07-01", "2026-08-01", { attemptedOn: null });
  assertEquals(
    resolveBillingPeriod("2026-08-01", "2026-09-02", [noDate], at("2026-09-02")).reanchoredFrom,
    "2026-08-01",
  );
});

Deno.test("reintento de un atraso que dio error usa la misma llave", () => {
  // El intento de ayer quedó en `error` (no aprobado): no está en el
  // historial, así que hoy se pide el mismo período y cae en la misma fila.
  const day1 = resolveBillingPeriod("2026-08-01", "2026-09-02", [julyPaid], at("2026-09-02"));
  const day2 = resolveBillingPeriod("2026-08-01", "2026-09-03", [julyPaid], at("2026-09-03"));
  assertEquals(day2.periodStart, day1.periodStart);
});

Deno.test("addMonthIso conserva el día", () => {
  assertEquals(addMonthIso("2026-06-27"), "2026-07-27");
  assertEquals(addMonthIso("2026-12-15"), "2027-01-15");
});

// ---------------------------------------------------------------------------
// findOverlappingPaidCharge
// ---------------------------------------------------------------------------

Deno.test("el período siguiente no choca con el pagado (fin == inicio)", () => {
  assertEquals(
    findOverlappingPaidCharge([paid("2026-09-27", "2026-10-27")], "2026-10-27", "2026-11-27"),
    null,
  );
});

Deno.test("fecha movida hacia atrás después de pagar: no se cobra de nuevo", () => {
  const c = paid("2026-09-27", "2026-10-27");
  assertEquals(findOverlappingPaidCharge([c], "2026-10-15", "2026-11-15"), c);
});

Deno.test("mismo inicio de período lo resuelve el UNIQUE, no esta barrera", () => {
  assertEquals(
    findOverlappingPaidCharge([paid("2026-09-27", "2026-10-27")], "2026-09-27", "2026-10-27"),
    null,
  );
});

Deno.test("cobro reembolsado completo ya no cubre el período", () => {
  assertEquals(
    findOverlappingPaidCharge(
      [paid("2026-09-27", "2026-10-27", { refunded: 299999 })],
      "2026-10-15",
      "2026-11-15",
    ),
    null,
  );
});

Deno.test("reembolso parcial sigue cubriendo el período", () => {
  const c = paid("2026-09-27", "2026-10-27", { refunded: 100000 });
  assertEquals(findOverlappingPaidCharge([c], "2026-10-15", "2026-11-15"), c);
});
