// Monto de un cobro de suscripción: plan + facturas electrónicas extra.
//
// Lo calcula la base (subscription_charge_breakdown, migración 0051 de
// mangopos_administrador): precio efectivo del plan (con precio especial) más
// las e-CF aceptadas por la DGII por encima de lo incluido para el negocio.
// Acá solo se valida la respuesta y se arma lo que se guarda en azul_charges.

export interface EcfOverage {
  overageCents: number;
  /** Desglose tal como lo devolvió la base (incluidas, usadas, extra, precio…). */
  detail: Record<string, unknown>;
  usageFrom: string | null;
  usageTo: string | null;
}

export interface ChargeAmount {
  amountCents: number;
  planCents: number;
  /** null = el negocio no tiene cantidad de e-CF configurada. */
  ecf: EcfOverage | null;
}

function isNonNegativeInt(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0;
}

function asString(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

/** Lee la respuesta de subscription_charge_breakdown. `null` = respuesta que no
 *  cierra (no se cobra: falla cerrada, igual que un precio no resuelto). */
export function parseChargeBreakdown(data: unknown): ChargeAmount | null {
  if (!data || typeof data !== "object") return null;
  const d = data as Record<string, unknown>;
  const total = d.total_cents;
  const plan = d.plan_cents;
  const overage = d.ecf_overage_cents ?? 0;
  if (!isNonNegativeInt(total) || !isNonNegativeInt(plan) || !isNonNegativeInt(overage)) {
    return null;
  }
  // El total tiene que ser la suma: si no, algo cambió en la base y no se cobra
  // un monto que no se puede explicar.
  if (total !== plan + overage) return null;

  const ecfRaw = d.ecf;
  const hasQuota = !!ecfRaw && typeof ecfRaw === "object" &&
    (ecfRaw as Record<string, unknown>).has_quota === true;

  return {
    amountCents: total,
    planCents: plan,
    ecf: hasQuota
      ? {
        overageCents: overage,
        detail: ecfRaw as Record<string, unknown>,
        usageFrom: asString((ecfRaw as Record<string, unknown>).usage_from),
        usageTo: asString((ecfRaw as Record<string, unknown>).usage_to),
      }
      : null,
  };
}

/** La función no existe en la base: la migración 0051 todavía no se aplicó. */
export function isMissingFunction(err: { code?: string } | null | undefined): boolean {
  return err?.code === "PGRST202" || err?.code === "42883";
}

/** Columnas del desglose para azul_charges. Sin 0051 las columnas no existen:
 *  no se mandan. */
export function ecfChargeColumns(
  ecf: EcfOverage | null,
  migrationApplied: boolean,
): Record<string, unknown> {
  if (!migrationApplied) return {};
  return {
    ecf_overage_cents: ecf?.overageCents ?? 0,
    ecf_detail: ecf?.detail ?? null,
    ecf_usage_from: ecf?.usageFrom ?? null,
    ecf_usage_to: ecf?.usageTo ?? null,
  };
}
