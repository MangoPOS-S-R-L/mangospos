-- =============================================================================
-- PASO 3.1 · SIMULACRO del backfill — La Penda Express
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Calcula lo que fn_recompute_fd_for_scope v6 escribiria en cada comprobante de
-- agosto, SIN ejecutarla sobre los comprobantes. Deja el resultado en una tabla
-- de trabajo propia (_sim_607_penda) que se borra al final. NO toca
-- fiscal_documents.
--
-- CORRER LOS TRES BLOQUES POR SEPARADO, uno a la vez.
--
-- La version anterior moria por timeout: usaba subconsultas correlacionadas
-- (una por comprobante) y un join con OR que no puede usar indices. Aqui todo
-- son joins planos y agregados unicos.
-- =============================================================================


-- ═══ BLOQUE 1 · construir la tabla de trabajo (el unico pesado) ══════════════
drop table if exists public._sim_607_penda;

create table public._sim_607_penda as
with tasas as (
  select case when x.usa_flag then x.r_ecf else x.r_name_ecf end as r_ecf,
         case when x.usa_flag then x.r_non else x.r_name_non end as r_non
  from (
    select
      coalesce(bool_or(coalesce(t.include_in_ecf, true) = false), false)          as usa_flag,
      coalesce(sum(t.rate) filter (where     coalesce(t.include_in_ecf, true)),0) as r_ecf,
      coalesce(sum(t.rate) filter (where not coalesce(t.include_in_ecf, true)),0) as r_non,
      coalesce(sum(t.rate) filter (where upper(t.name) like     '%ITBIS%'), 0)    as r_name_ecf,
      coalesce(sum(t.rate) filter (where upper(t.name) not like '%ITBIS%'), 0)    as r_name_non
    from public.taxes t
    where t.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and coalesce(t.is_active, true)
  ) x
),
fd as (
  select d.id, d.ncf_number, d.order_id, d.check_id, d.issued_at,
         coalesce(d.subtotal,0)     as subtotal_hoy,
         coalesce(d.itbis_amount,0) as itbis_hoy,
         coalesce(d.service_fee,0)  as ley_hoy,
         coalesce(d.total,0)        as total_hoy
  from public.fiscal_documents d
  where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and d.status = 'active'
    and (d.issued_at at time zone 'America/Santo_Domingo')::date
        between date '2026-08-01' and date '2026-08-31'
),
-- Pagos: un solo agregado por cada criterio, no una subconsulta por fila.
pg_fd as (
  select p.fiscal_document_id as fd_id,
         sum(p.amount - coalesce(p.change_amount,0)) as monto
  from public.payments p
  join fd f on f.id = p.fiscal_document_id
  where p.status = 'completed'
  group by p.fiscal_document_id
),
pg_scope as (
  select p.order_id, p.check_id,
         sum(p.amount - coalesce(p.change_amount,0)) as monto
  from public.payments p
  where p.status = 'completed'
    and p.order_id in (select order_id from fd where order_id is not null)
  group by p.order_id, p.check_id
),
-- Items: dos ramas separadas (por check / por orden) para que use indices.
-- El join con OR de la version anterior forzaba nested loop sobre todo.
oi as (
  select oi.id, oi.order_id, oi.check_id, oi.subtotal, oi.total, oi.tax, oi.tax_rate,
    case
      when t.r_ecf + t.r_non > 0 and abs(oi.tax_rate - (t.r_ecf + t.r_non)) < 0.5
        then round(coalesce(oi.tax,0) * t.r_ecf / (t.r_ecf + t.r_non), 2)
      when t.r_ecf > 0 and abs(oi.tax_rate - t.r_ecf) < 0.5 then coalesce(oi.tax,0)
      when t.r_non > 0 and abs(oi.tax_rate - t.r_non) < 0.5 then 0
      when t.r_ecf + t.r_non > 0
        then round(coalesce(oi.tax,0) * t.r_ecf / (t.r_ecf + t.r_non), 2)
      else coalesce(oi.tax,0)
    end as itbis_item
  from public.order_items oi
  cross join tasas t
  where oi.status <> 'void'
    and oi.order_id in (select order_id from fd where order_id is not null)
),
por_check as (
  select order_id, check_id, count(*) n, sum(subtotal) base, sum(total) tot,
         sum(itbis_item) itbis, sum(coalesce(tax,0)) imp
  from oi where check_id is not null group by order_id, check_id
),
por_orden as (
  select order_id, count(*) n, sum(subtotal) base, sum(total) tot,
         sum(itbis_item) itbis, sum(coalesce(tax,0)) imp
  from oi group by order_id
),
calc as (
  select f.*,
    coalesce(case when f.check_id is not null then pc.n     else po.n     end, 0) as n_items,
    coalesce(case when f.check_id is not null then pc.base  else po.base  end, 0) as base,
    coalesce(case when f.check_id is not null then pc.tot   else po.tot   end, 0) as items_total,
    coalesce(case when f.check_id is not null then pc.itbis else po.itbis end, 0) as itbis,
    coalesce(case when f.check_id is not null then pc.imp   else po.imp   end, 0) as impuesto,
    case when coalesce(pf.monto, 0) <> 0 then pf.monto else coalesce(ps.monto, 0) end as scope_total
  from fd f
  left join pg_fd    pf on pf.fd_id = f.id
  left join pg_scope ps on ps.order_id = f.order_id
                       and ps.check_id is not distinct from f.check_id
  left join por_check pc on pc.order_id = f.order_id and pc.check_id = f.check_id
  left join por_orden po on po.order_id = f.order_id
)
select c.*,
  case when scope_total <= 0 or n_items = 0 then null
       when items_total <= 0           then scope_total
       when scope_total < items_total  then round(base * (scope_total/items_total), 2)
       else base end                                              as subtotal_nuevo,
  case when scope_total <= 0 or n_items = 0 then null
       when items_total <= 0           then 0
       when scope_total < items_total  then round(itbis * (scope_total/items_total), 2)
       else itbis end                                             as itbis_nuevo,
  case when scope_total <= 0 or n_items = 0 then null
       when items_total <= 0           then 0
       when scope_total < items_total  then round((impuesto-itbis) * (scope_total/items_total), 2)
       else impuesto - itbis end                                  as ley_nuevo,
  case when scope_total <= 0 or n_items = 0 then null
       else scope_total end                                       as total_nuevo
from calc c;


-- ═══ BLOQUE 2 · el resumen ═══════════════════════════════════════════════════
--   ESPERADO:  itbis_despues ~ 779,169   ·   CUANTOS_CAMBIAN_DE_TOTAL = 0
select
  count(*)                                                       as comprobantes,
  count(*) filter (where subtotal_nuevo is null)                 as no_los_toca,
  round(sum(itbis_hoy), 2)                                       as itbis_antes,
  round(sum(coalesce(itbis_nuevo, itbis_hoy)), 2)                as itbis_despues,
  round(sum(coalesce(ley_nuevo, ley_hoy)), 2)                    as ley_despues,
  count(*) filter (where total_nuevo is not null
                     and abs(total_nuevo - total_hoy) > 0.005)   as cuantos_cambian_de_total,
  round(coalesce(sum(total_nuevo - total_hoy)
        filter (where total_nuevo is not null), 0), 2)           as cambio_neto_en_ventas
from public._sim_607_penda;


-- ═══ BLOQUE 3 · detalle de los que cambiarian de TOTAL ═══════════════════════
select ncf_number, issued_at::date as fecha,
       total_hoy, total_nuevo, round(total_nuevo - total_hoy, 2) as diferencia,
       subtotal_hoy, subtotal_nuevo, n_items
from public._sim_607_penda
where total_nuevo is not null and abs(total_nuevo - total_hoy) > 0.005
order by abs(total_nuevo - total_hoy) desc
limit 30;


-- Al terminar:  drop table public._sim_607_penda;
