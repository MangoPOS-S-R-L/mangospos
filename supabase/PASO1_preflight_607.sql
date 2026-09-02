-- =============================================================================
-- PASO 1 · PREFLIGHT del arreglo del 607 — La Penda Express
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. No escribe absolutamente nada.
-- Correr las 4 secciones y pasar los resultados.
-- =============================================================================


-- A ─── Los impuestos del negocio ─────────────────────────────────────────────
--     Confirma tasas, cuáles están activos y el estado del interruptor.
select
  t.name,
  t.rate,
  t.is_active,
  t.include_in_ecf,
  t.is_service_fee
from public.taxes t
where t.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
order by t.rate desc;


-- B ─── Simulación: qué va a hacer la v6 con esa config ───────────────────────
--     Reproduce EXACTAMENTE la decisión de la migración 20260902_0007.
--     ESPERADO:  declarable = 18   /   no_declarable = 10   /   fuente = 'nombre'
with cfg as (
  select
    coalesce(bool_or(coalesce(t.include_in_ecf, true) = false), false)           as usa_flag,
    coalesce(sum(t.rate) filter (where     coalesce(t.include_in_ecf, true)), 0) as ecf_si,
    coalesce(sum(t.rate) filter (where not coalesce(t.include_in_ecf, true)), 0) as ecf_no,
    coalesce(sum(t.rate) filter (where upper(t.name) like     '%ITBIS%'), 0)     as nom_si,
    coalesce(sum(t.rate) filter (where upper(t.name) not like '%ITBIS%'), 0)     as nom_no
  from public.taxes t
  where t.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(t.is_active, true)
)
select
  case when usa_flag then 'configuracion (include_in_ecf)' else 'nombre (respaldo)' end as fuente,
  case when usa_flag then ecf_si else nom_si end as declarable,
  case when usa_flag then ecf_no else nom_no end as no_declarable,
  case
    when (case when usa_flag then ecf_no else nom_no end) = 0
      then 'PARAR: no separa la Ley, todo se declararia como ITBIS'
    else 'OK: un item al 28% se reparte '
         || (case when usa_flag then ecf_si else nom_si end) || '/'
         || ((case when usa_flag then ecf_si else nom_si end)
           + (case when usa_flag then ecf_no else nom_no end))
  end as veredicto
from cfg;


-- C ─── ¿La función viva sigue siendo la v5? ──────────────────────────────────
--     Confirma que nadie la cambió desde que la leímos. Si el comentario dice
--     v6, ya está aplicada y no hay que volver a aplicarla.
select obj_description(
  'public.fn_recompute_fd_for_scope(uuid,uuid,uuid)'::regprocedure, 'pg_proc'
) as version_viva;


-- D ─── Triggers: el enganche que falta y el riesgo de e-CF ───────────────────
--     payments          -> si NO aparece trg_recompute_fd_on_payment_change,
--                          ese es el hueco que cierra la migración 0009.
--     fiscal_documents  -> si aparece algo de e-CF/Alanube en UPDATE,
--                          PARAR antes del backfill.
select c.relname as tabla, t.tgname as trigger, p.proname as ejecuta,
       case t.tgenabled when 'O' then 'habilitado' else t.tgenabled::text end as estado
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_proc  p on p.oid = t.tgfoid
where c.relname in ('payments', 'fiscal_documents')
  and not t.tgisinternal
order by c.relname, t.tgname;
