-- =============================================================================
-- 20260616_0006 — Backfill JUNIO: ITBIS sub-declarado en fiscal_documents
-- =============================================================================
--
-- CONTEXTO
--   El trigger 20260530_0007 corre calculate_order_totals con ítems
--   transitorios durante el split/check, dejando order.tax = 0. Las
--   versiones viejas de fn_recompute_fd_for_scope copiaban order.tax a
--   fiscal_documents.itbis_amount → ITBIS = 0 declarado a DGII, aunque el
--   comprobante en papel sí cobró el ITBIS (la impresión deriva de los
--   ítems, no de order.tax).
--
--   La v5 (20260610_0001) ya corrige esto HACIA ADELANTE: deriva
--   itbis_amount/service_fee de los ÍTEMS del scope, partido por las tasas
--   de `taxes` (config-driven). Pero los NCFs de junio emitidos ANTES de la
--   v5 quedaron con el dato malo.
--
-- DIAGNÓSTICO (2026-06-16)
--   ~2,167 NCFs de junio en 19 negocios con ITBIS sub-declarado por
--   ~RD$ 303,846 en total. Junio aún no se declara (se hace en julio), así
--   que corregir el dato ahora alinea la declaración con lo realmente
--   cobrado.
--
-- QUÉ HACE
--   Re-corre fn_recompute_fd_for_scope (v5, ya aplicada) SOLO sobre los NCFs
--   activos de junio cuyo itbis_amount guardado quedó por debajo del que
--   implican sus ítems. v5 es idempotente y determinista (deriva de
--   ítems + payments), así que re-correr es seguro.
--
-- SEGURIDAD
--   - Solo UPDATE a fiscal_documents. NO toca órdenes, ítems, pagos ni la
--     app. NO dispara e-CF: el hook Alanube es AFTER INSERT (no UPDATE) y
--     estos son B0x en papel.
--   - GUARD: aborta si fn_recompute_fd_for_scope NO es la v5.
--   - RESPALDO: guarda el estado ANTERIOR de cada NCF afectado en
--     public._backup_fd_itbis_june_20260616 (IF NOT EXISTS → conserva el
--     primer respaldo si se re-ejecuta). El _ROLLBACK restaura desde ahí.
--   - Idempotente: re-ejecutar no vuelve a afectar NCFs ya corregidos.
-- =============================================================================

begin;

-- ── GUARD: exigir v5 ─────────────────────────────────────────────────────────
do $$
begin
  if coalesce(
       obj_description(
         'public.fn_recompute_fd_for_scope(uuid,uuid,uuid)'::regprocedure
       ) like 'v5:%', false) is not true then
    raise exception
      'fn_recompute_fd_for_scope NO es v5 — aplica 20260610_0001 antes del backfill';
  end if;
end$$;

-- ── 1. Set objetivo: NCFs de junio sub-declarados ────────────────────────────
--    (mismo criterio del diagnóstico: itbis esperado por ítems > guardado).
create temp table _june_underreported on commit drop as
with rates as (
  select t.business_id,
         coalesce(max(t.rate) filter (where not coalesce(t.is_service_fee,false)),0) as itbis_rate,
         coalesce(max(t.rate) filter (where coalesce(t.is_service_fee,false)),0)     as ley_rate
  from public.taxes t
  where coalesce(t.is_active,true)
  group by t.business_id
),
fd_items as (
  select fd.id as fd_id, fd.order_id, fd.check_id, fd.business_id,
         fd.itbis_amount as itbis_guardado, oi.tax, oi.tax_rate
  from public.fiscal_documents fd
  join public.order_items oi
    on ( (fd.check_id is not null and oi.check_id = fd.check_id)
      or (fd.check_id is null     and oi.order_id = fd.order_id) )
   and oi.status <> 'void'
  where fd.status = 'active'
    and fd.issued_at >= '2026-06-01' and fd.issued_at < '2026-07-01'
),
expected as (
  select fi.fd_id, fi.order_id, fi.check_id, fi.business_id, fi.itbis_guardado,
         sum(case
           when r.itbis_rate>0 and r.ley_rate>0
                and abs(fi.tax_rate-(r.itbis_rate+r.ley_rate))<0.5
             then round(fi.tax * r.itbis_rate/(r.itbis_rate+r.ley_rate),2)
           when r.itbis_rate>0 and abs(fi.tax_rate-r.itbis_rate)<0.5
             then fi.tax
           else 0 end) as itbis_esperado
  from fd_items fi
  join rates r on r.business_id = fi.business_id
  group by fi.fd_id, fi.order_id, fi.check_id, fi.business_id, fi.itbis_guardado
)
select fd_id, order_id, check_id, business_id
from expected
where itbis_esperado - itbis_guardado > 1;

-- ── 2. Respaldo del estado ANTERIOR (auditable / reversible) ─────────────────
create table if not exists public._backup_fd_itbis_june_20260616 as
select fd.id, fd.business_id, fd.ncf_number,
       fd.subtotal, fd.taxable_amount, fd.itbis_amount, fd.service_fee, fd.total
from public.fiscal_documents fd
join _june_underreported u on u.fd_id = fd.id;

comment on table public._backup_fd_itbis_june_20260616 is
  'Respaldo pre-backfill (20260616_0006) de fiscal_documents de junio con ITBIS sub-declarado. Usado por el _ROLLBACK.';

-- ── 3. Re-procesar con v5 ────────────────────────────────────────────────────
do $$
declare
  v_fd    record;
  v_count int := 0;
begin
  for v_fd in select fd_id, order_id, check_id from _june_underreported loop
    perform public.fn_recompute_fd_for_scope(
      v_fd.fd_id, v_fd.order_id, v_fd.check_id);
    v_count := v_count + 1;
  end loop;
  raise notice '✓ Backfill junio: % NCFs re-procesados con v5', v_count;
end$$;

commit;
