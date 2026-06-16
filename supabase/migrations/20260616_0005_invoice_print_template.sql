-- =============================================================================
-- 20260616_0003 — Modelo de factura impresa por negocio (estándar | compacta)
-- =============================================================================
--
-- Permite que cada negocio elija, desde Ajustes → Impresión → Recibos, cómo se
-- imprime la FACTURA:
--   - 'standard' (default): layout detallado actual (nombre y precio por ítem,
--     TOTAL grande). No cambia para nadie sin opt-in.
--   - 'compact': ítems en una sola línea ("2x Nombre …… 500.00"), fuente y
--     espaciado mínimos, TOTAL en tamaño normal. Mantiene TODOS los datos
--     fiscales (NCF/e-NCF, RNC, desglose de impuestos, QR). Pensado para
--     cuentas con muchos productos (menos papel).
--
-- ADITIVA y segura: Flutter cae al default 'standard' si la columna no existe
-- (pre-migración) o la query falla. Sin impacto fiscal: no toca emisión, NCF
-- ni fiscal_documents — solo el formato de impresión.
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists invoice_print_template text not null default 'standard';

comment on column public.business_settings.invoice_print_template is
  'Modelo de factura impresa: "standard" (detallada) o "compact" (ítems en una '
  'línea, fuente/espaciado mínimos). Ambos conservan los datos fiscales. '
  'Default "standard".';

commit;
