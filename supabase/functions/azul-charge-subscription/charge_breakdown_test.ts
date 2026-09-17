import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { ecfChargeColumns, isMissingFunction, parseChargeBreakdown } from "./charge_breakdown.ts";

const withQuota = {
  plan_cents: 299999,
  ecf_overage_cents: 6000,
  total_cents: 305999,
  ecf: {
    has_quota: true,
    included: 5,
    used: 9,
    extra: 4,
    unit_price_cents: 1500,
    price_source: "global",
    overage_cents: 6000,
    usage_from: "2026-09-16T04:00:00+00:00",
    usage_to: "2026-10-16T04:00:00+00:00",
  },
};

Deno.test("plan + extra de e-CF: cobra el total y guarda el desglose", () => {
  const parsed = parseChargeBreakdown(withQuota)!;
  assertEquals(parsed.amountCents, 305999);
  assertEquals(parsed.planCents, 299999);
  assertEquals(parsed.ecf?.overageCents, 6000);
  assertEquals(parsed.ecf?.usageTo, "2026-10-16T04:00:00+00:00");
  assertEquals(ecfChargeColumns(parsed.ecf, true), {
    ecf_overage_cents: 6000,
    ecf_detail: withQuota.ecf,
    ecf_usage_from: "2026-09-16T04:00:00+00:00",
    ecf_usage_to: "2026-10-16T04:00:00+00:00",
  });
});

Deno.test("sin cantidad configurada: solo el plan, sin ventana de uso", () => {
  const parsed = parseChargeBreakdown({
    plan_cents: 299999,
    ecf_overage_cents: 0,
    total_cents: 299999,
    ecf: { has_quota: false, overage_cents: 0 },
  })!;
  assertEquals(parsed.amountCents, 299999);
  assertEquals(parsed.ecf, null);
  assertEquals(ecfChargeColumns(parsed.ecf, true), {
    ecf_overage_cents: 0,
    ecf_detail: null,
    ecf_usage_from: null,
    ecf_usage_to: null,
  });
});

Deno.test("respuestas que no cierran no se cobran", () => {
  assertEquals(parseChargeBreakdown(null), null);
  assertEquals(parseChargeBreakdown(299999), null);
  // total distinto de plan + extra
  assertEquals(parseChargeBreakdown({ ...withQuota, total_cents: 310000 }), null);
  // montos no enteros o negativos
  assertEquals(parseChargeBreakdown({ ...withQuota, plan_cents: 2999.99, total_cents: 8999.99 }), null);
  assertEquals(parseChargeBreakdown({ plan_cents: -1, ecf_overage_cents: 0, total_cents: -1 }), null);
  assertEquals(parseChargeBreakdown({ plan_cents: "299999", total_cents: 299999 }), null);
});

Deno.test("sin la migración 0051 no se mandan las columnas nuevas", () => {
  assertEquals(ecfChargeColumns(null, false), {});
});

Deno.test("detecta la función inexistente (0051 sin aplicar)", () => {
  assertEquals(isMissingFunction({ code: "PGRST202" }), true);
  assertEquals(isMissingFunction({ code: "42883" }), true);
  assertEquals(isMissingFunction({ code: "P0001" }), false);
  assertEquals(isMissingFunction(null), false);
});
