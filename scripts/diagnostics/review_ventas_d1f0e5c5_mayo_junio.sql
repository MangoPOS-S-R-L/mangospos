-- =====================================================================
-- Auditoría de ventas e impuestos — MAYO y JUNIO 2026
-- Negocio: d1f0e5c5-f598-4bd6-a3d1-19543c133f99
--
-- Objetivo: ver las ventas totales y CÓMO se calcularon los impuestos
-- (ITBIS / LEY) en cada comprobante, para detectar:
--   - ITBIS guardado lumped/deflactado (28% junto) vs el real de los items.
--   - Productos vendidos sin ITBIS por config (ej. AGUA en 10%) o tax_rate=0.
--   - Comprobantes "fallback" (sin items con impuesto) que deflactan mal.
--
-- Correr en el SQL Editor de Supabase (rol service). Las horas son RD (-04).
-- Pega cada bloque (A..G) por separado; cada uno trae su propio prefijo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- (A) TOP-LINE por mes: lo facturado y lo registrado (base/itbis/ley/total)
-- ---------------------------------------------------------------------
with params as (
  select 'd1f0e5c5-f598-4bd6-a3d1-19543c133f99'::uuid as business_id,
         timestamptz '2026-05-01 00:00:00-04' as from_ts,
         timestamptz '2026-07-01 00:00:00-04' as to_ts
)
select
  'A_topline_mes' as bloque,
  to_char(fd.issued_at - interval '4 hours', 'YYYY-MM')                as mes,
  count(*) filter (where fd.status = 'active')                        as comprobantes,
  count(*) filter (where fd.status <> 'active')                       as anulados,
  round(sum(fd.subtotal)     filter (where fd.status = 'active'), 2)  as base,
  round(sum(fd.itbis_amount) filter (where fd.status = 'active'), 2)  as itbis_registrado,
  round(sum(fd.service_fee)  filter (where fd.status = 'active'), 2)  as ley_registrada,
  round(sum(fd.total)        filter (where fd.status = 'active'), 2)  as total_facturado,
  round((sum(fd.total) filter (where fd.status = 'active'))
        - sum(fd.subtotal + fd.itbis_amount + fd.service_fee)
              filter (where fd.status = 'active'), 2)                 as descuadre
from fiscal_documents fd, params p
where fd.business_id = p.business_id
  and fd.issued_at >= p.from_ts and fd.issued_at < p.to_ts
group by 2 order by 2;

-- ---------------------------------------------------------------------
-- (B) RECONCILIACIÓN por mes: ITBIS/LEY registrado vs el REAL de los items
--     (split 18/28 + 10/28). Si itbis_registrado != itbis_real_items, el
--     valor guardado para DGII está mal.
-- ---------------------------------------------------------------------
with params as (
  select 'd1f0e5c5-f598-4bd6-a3d1-19543c133f99'::uuid as business_id,
         timestamptz '2026-05-01 00:00:00-04' as from_ts,
         timestamptz '2026-07-01 00:00:00-04' as to_ts
),
docs as (
  select fd.id, fd.order_id,
         to_char(fd.issued_at - interval '4 hours', 'YYYY-MM') as mes,
         fd.subtotal, fd.itbis_amount, fd.service_fee, fd.total
  from fiscal_documents fd, params p
  where fd.business_id = p.business_id
    and fd.issued_at >= p.from_ts and fd.issued_at < p.to_ts
    and fd.status = 'active'
),
items as (
  select d.id as doc_id,
    coalesce(sum(oi.tax), 0) as tax_baked,
    coalesce(sum(case when oi.tax_rate = 28 then oi.tax * 18.0/28
                      when oi.tax_rate >= 18 and oi.tax_rate < 28 then oi.tax
                      else 0 end), 0) as itbis_items,
    coalesce(sum(case when oi.tax_rate = 28 then oi.tax * 10.0/28
                      when oi.tax_rate = 10 then oi.tax
                      else 0 end), 0) as ley_items
  from docs d
  join order_items oi on oi.order_id = d.order_id and oi.status <> 'void'
  group by d.id
)
select
  'B_reconciliacion_mes'                          as bloque,
  d.mes,
  count(*)                                        as comprobantes,
  count(*) filter (where d.itbis_amount = 0)      as docs_itbis_cero,
  count(*) filter (where d.service_fee = 0)       as docs_ley_cero,
  round(sum(d.subtotal), 2)                       as base,
  round(sum(d.total), 2)                          as total,
  round(sum(d.itbis_amount), 2)                   as itbis_registrado,
  round(sum(coalesce(i.itbis_items, 0)), 2)       as itbis_real_items,
  round(sum(d.service_fee), 2)                    as ley_registrada,
  round(sum(coalesce(i.ley_items, 0)), 2)         as ley_real_items
from docs d
left join items i on i.doc_id = d.id
group by d.mes order by d.mes;

-- ---------------------------------------------------------------------
-- (C) DISTRIBUCIÓN de tax_rate en los items (todo el período).
--     28 = combinado 18+10 | 18 = ITBIS solo | 10 = LEY sola (sin ITBIS!)
--     0 = exento/sin impuesto. Mucha base en 0 o en 10 => ITBIS bajo.
-- ---------------------------------------------------------------------
with params as (
  select 'd1f0e5c5-f598-4bd6-a3d1-19543c133f99'::uuid as business_id,
         timestamptz '2026-05-01 00:00:00-04' as from_ts,
         timestamptz '2026-07-01 00:00:00-04' as to_ts
)
select
  'C_tax_rates' as bloque,
  oi.tax_rate,
  count(*)                   as items,
  round(sum(oi.subtotal), 2) as base,
  round(sum(oi.tax), 2)      as tax_cobrado
from order_items oi
join orders o           on o.id = oi.order_id
join fiscal_documents fd on fd.order_id = o.id
cross join params p
where fd.business_id = p.business_id
  and fd.issued_at >= p.from_ts and fd.issued_at < p.to_ts
  and fd.status = 'active'
  and oi.status <> 'void'
group by oi.tax_rate order by oi.tax_rate;

-- ---------------------------------------------------------------------
-- (D) POR COMPROBANTE: itbis del doc vs ITBIS real de items + RUTA.
--     ruta 'fallback' = el comprobante no tiene items con impuesto
--     (manual / tax_rate=0) → ahí el ITBIS se deflacta mal.
-- ---------------------------------------------------------------------
with params as (
  select 'd1f0e5c5-f598-4bd6-a3d1-19543c133f99'::uuid as business_id,
         timestamptz '2026-05-01 00:00:00-04' as from_ts,
         timestamptz '2026-07-01 00:00:00-04' as to_ts
),
agg as (
  select fd.id, fd.ncf_number, fd.ncf_type, fd.order_id,
         to_char(fd.issued_at - interval '4 hours', 'YYYY-MM') as mes,
         fd.subtotal, fd.itbis_amount, fd.service_fee, fd.total,
    coalesce(sum(oi.tax), 0) as item_tax,
    coalesce(sum(case when oi.tax_rate = 28 then oi.tax * 18.0/28
                      when oi.tax_rate >= 18 and oi.tax_rate < 28 then oi.tax
                      else 0 end), 0) as itbis_items
  from fiscal_documents fd
  left join order_items oi on oi.order_id = fd.order_id and oi.status <> 'void'
  cross join params p
  where fd.business_id = p.business_id
    and fd.issued_at >= p.from_ts and fd.issued_at < p.to_ts
    and fd.status = 'active'
  group by fd.id, fd.ncf_number, fd.ncf_type, fd.order_id, mes,
           fd.subtotal, fd.itbis_amount, fd.service_fee, fd.total
)
select 'D_por_doc' as bloque,
       mes, ncf_number, ncf_type,
       case when order_id is null then 'manual'
            when item_tax > 0.005 then 'items' else 'fallback' end as ruta,
       round(subtotal, 2)     as base_col,
       round(itbis_amount, 2) as itbis_col,
       round(service_fee, 2)  as ley_col,
       round(total, 2)        as total,
       round(itbis_items, 2)  as itbis_real_items,
       round(itbis_amount - itbis_items, 2) as diferencia
from agg
order by abs(itbis_amount - itbis_items) desc
limit 40;

-- ---------------------------------------------------------------------
-- (E) CONFIG de impuestos del negocio (¿18+10 separados o 28 combinado?).
-- ---------------------------------------------------------------------
select 'E_taxes_config' as bloque, t.*
from taxes t
where t.business_id = 'd1f0e5c5-f598-4bd6-a3d1-19543c133f99'::uuid
order by t.rate desc;

-- ---------------------------------------------------------------------
-- (F) PRODUCTOS activos SIN impuesto vinculado (se venden en tax_rate=0).
--     Revisa cuáles DEBERÍAN llevar ITBIS y se les asigna en el menú.
-- ---------------------------------------------------------------------
select 'F_productos_sin_impuesto' as bloque,
       mi.name as producto,
       mi.price,
       c.name as categoria
from menu_items mi
left join categories c on c.id = mi.category_id
where mi.business_id = 'd1f0e5c5-f598-4bd6-a3d1-19543c133f99'::uuid
  and mi.is_active = true
  and not exists (
    select 1 from menu_item_taxes mit
    join taxes t on t.id = mit.tax_id and coalesce(t.is_active, true)
    where mit.item_id = mi.id
  )
order by c.name nulls last, mi.name;

-- ---------------------------------------------------------------------
-- (G) PRODUCTOS y su impuesto vinculado (para ver los mal configurados,
--     ej. AGUA con solo 10% / sin ITBIS).
-- ---------------------------------------------------------------------
select 'G_config_productos' as bloque,
       mi.name as producto,
       coalesce(string_agg(t.name || ' ' || t.rate || '%', ', '
                           order by t.rate desc), 'SIN IMPUESTO') as impuestos
from menu_items mi
left join menu_item_taxes mit on mit.item_id = mi.id
left join taxes t on t.id = mit.tax_id and coalesce(t.is_active, true)
where mi.business_id = 'd1f0e5c5-f598-4bd6-a3d1-19543c133f99'::uuid
  and mi.is_active = true
group by mi.id, mi.name
order by impuestos, mi.name;
