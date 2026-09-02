-- =============================================================================
-- Alarma de costo de compra contra el histórico del artículo.
-- Causa raíz del hallazgo 1 del informe DH del 02-09-2026.
--
-- QUÉ PROBLEMA RESUELVE:
--   Una compra de 1 saco de AZUCAR BLANCA a RD$4,500 revaluó 251 libras que
--   se habían comprado a RD$36, inflando el inventario en RD$1.1MM. El
--   umbral que ya existe (cost_variance_threshold_pct, 20260811_0003) NO lo
--   detecta: compara el costo de la ORDEN contra el costo FACTURADO al
--   recibir. Si la orden ya venía tecleada a 4,500 y se recibió a 4,500, la
--   varianza es 0% y no salta nada. Nadie compara contra la historia.
--
-- QUÉ HACE:
--   Dos vistas de LECTURA. No bloquean nada, no tocan
--   fn_receive_purchase_order ni la recepción con conduce. La mercancía entra
--   igual que siempre; lo que cambia es que Compras puede VER la anomalía y
--   corregirla. Bloquear la recepción es una decisión aparte, con su propio
--   despliegue y fuera de horario — no se mezcla con esto.
--
--   1. v_purchase_cost_alarms — una fila por compra cuyo costo unitario se
--      dispara contra la MEDIANA histórica de ese artículo. Se usa la mediana
--      y no el último costo porque el último costo ya está contaminado por el
--      propio disparate: en el azúcar, el "último" ERA los 4,500.
--   2. v_purchase_cost_dispersion — una fila por artículo cuyo costo máximo
--      es al menos el doble del mínimo. Es literalmente el criterio con el
--      que DH encontró los 21 artículos del hallazgo 1, para poder cotejar
--      cifra contra cifra.
--
-- POR QUÉ LA MEDIANA Y NO EL PROMEDIO:
--   El promedio se lo lleva el outlier. Con 36, 36 y 4,500 el promedio da
--   1,524 y el disparate parece apenas 3x; la mediana da 36 y lo muestra
--   como lo que es, 125x.
--
-- IDEMPOTENTE: sí. REVERSIBLE: sí (ver _ROLLBACK).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Umbral configurable por negocio
-- ---------------------------------------------------------------------------

alter table public.business_settings
  add column if not exists cost_alarm_factor numeric(8,2) not null default 3;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'business_settings_cost_alarm_factor_check'
  ) then
    alter table public.business_settings
      add constraint business_settings_cost_alarm_factor_check
      check (cost_alarm_factor > 1);
  end if;
end $$;

comment on column public.business_settings.cost_alarm_factor is
  'Cuántas veces puede separarse el costo de una compra de la mediana '
  'histórica del artículo antes de encender la alarma. Default 3 = el triple '
  'o la tercera parte. Es alarma de lectura, no bloquea la recepción.';

-- ---------------------------------------------------------------------------
-- 2. Compras fuera de rango contra la historia del artículo
-- ---------------------------------------------------------------------------

create or replace view public.v_purchase_cost_alarms
with (security_invoker = on) as
with base as (
  select m.id            as movement_id,
         m.business_id,
         m.item_id,
         m.warehouse_id,
         m.created_at,
         m.quantity,
         m.cost_per_unit,
         m.reference_id,
         m.reference_type
    from public.inventory_movements m
   where m.movement_type = 'purchase'
     and coalesce(m.cost_per_unit, 0) > 0
     and m.quantity > 0
),
stats as (
  select business_id,
         item_id,
         count(*)                                              as compras,
         min(cost_per_unit)                                    as costo_min,
         max(cost_per_unit)                                    as costo_max,
         percentile_disc(0.5) within group (order by cost_per_unit)
                                                               as costo_mediana
    from base
   group by business_id, item_id
)
select
  b.business_id,
  b.movement_id,
  b.item_id,
  ii.sku                                             as item_sku,
  ii.name                                            as item_name,
  ii.unit                                            as item_unit,
  b.warehouse_id,
  b.created_at,
  b.quantity,
  b.cost_per_unit                                    as costo_de_esta_compra,
  st.costo_mediana,
  st.costo_min,
  st.costo_max,
  st.compras                                         as compras_del_articulo,
  round(b.cost_per_unit / nullif(st.costo_mediana, 0), 2)
                                                     as veces_la_mediana,
  -- Tamaño de la anomalía, NO una pérdida: cuando la alarma es "muy por
  -- debajo" lo barato suele ser el precio correcto y lo caro el error de
  -- unidad. Sirve para ordenar por gravedad, no para contabilizar.
  round(abs(b.cost_per_unit - st.costo_mediana) * b.quantity, 2)
                                                     as magnitud_del_desvio,
  case
    when b.cost_per_unit > st.costo_mediana then 'muy por encima'
    else 'muy por debajo'
  end                                                as direccion,
  coalesce(
    nullif(pr.ncf, ''),
    nullif(po.ncf, ''),
    nullif(po.invoice_number, ''),
    nullif(dr.receipt_number, '')
  )                                                  as documento,
  coalesce(pr.supplier_id, po.supplier_id, dr.supplier_id)
                                                     as supplier_id,
  s.name                                             as proveedor,
  b.reference_type,
  b.reference_id
from base b
join stats st
  on st.business_id = b.business_id and st.item_id = b.item_id
join public.inventory_items ii on ii.id = b.item_id
left join public.business_settings bs on bs.business_id = b.business_id
left join public.purchase_reception_lines prl
  on prl.id = b.reference_id and b.reference_type = 'purchase_reception_line'
left join public.purchase_receptions pr on pr.id = prl.reception_id
left join public.purchase_orders po
  on po.id = b.reference_id
 and b.reference_type in ('purchase_order', 'purchase_order_item')
left join public.direct_receipts dr
  on dr.id = b.reference_id and b.reference_type = 'direct_receipt'
left join public.suppliers s
  on s.id = coalesce(pr.supplier_id, po.supplier_id, dr.supplier_id)
where st.compras >= 2
  and st.costo_mediana > 0
  and (
        b.cost_per_unit > st.costo_mediana * coalesce(bs.cost_alarm_factor, 3)
     or b.cost_per_unit < st.costo_mediana / coalesce(bs.cost_alarm_factor, 3)
      );

comment on view public.v_purchase_cost_alarms is
  'Compras cuyo costo unitario se separa de la mediana histórica del artículo '
  'más allá de business_settings.cost_alarm_factor. Es alarma de lectura: no '
  'bloquea la recepción. veces_la_mediana = 125 fue el saco de azúcar.';

-- ---------------------------------------------------------------------------
-- 3. Dispersión por artículo — el criterio exacto del hallazgo 1 de DH
-- ---------------------------------------------------------------------------

create or replace view public.v_purchase_cost_dispersion
with (security_invoker = on) as
select
  m.business_id,
  m.item_id,
  ii.sku                                             as item_sku,
  ii.name                                            as item_name,
  ii.unit                                            as item_unit,
  count(*)                                           as compras,
  min(m.cost_per_unit)                               as costo_min,
  max(m.cost_per_unit)                               as costo_max,
  percentile_disc(0.5) within group (order by m.cost_per_unit)
                                                     as costo_mediana,
  round(max(m.cost_per_unit) / nullif(min(m.cost_per_unit), 0), 2)
                                                     as ratio_max_min,
  ii.cost                                            as costo_maestro_actual,
  coalesce(st.quantity, 0)                           as existencia,
  round(coalesce(st.quantity, 0) * coalesce(ii.cost, 0), 2)
                                                     as valor_a_costo_maestro,
  round(coalesce(st.quantity, 0)
        * percentile_disc(0.5) within group (order by m.cost_per_unit), 2)
                                                     as valor_a_mediana,
  max(m.created_at)                                  as ultima_compra
from public.inventory_movements m
join public.inventory_items ii on ii.id = m.item_id
left join public.inventory_stock st
  on st.item_id = m.item_id
 and st.warehouse_id = m.warehouse_id
where m.movement_type = 'purchase'
  and coalesce(m.cost_per_unit, 0) > 0
  and m.quantity > 0
group by m.business_id, m.item_id, ii.sku, ii.name, ii.unit, ii.cost,
         st.quantity
having count(*) >= 2
   and max(m.cost_per_unit) >= 2 * min(m.cost_per_unit);

comment on view public.v_purchase_cost_dispersion is
  'Artículos cuyo costo de compra máximo es al menos el DOBLE del mínimo. Es '
  'el criterio con el que DH levantó los 21 artículos del hallazgo 1: casi '
  'siempre no es que el precio subió, es que una vez se compró el saco y otra '
  'la libra bajo el mismo código. valor_a_costo_maestro vs valor_a_mediana '
  'mide cuánto infla eso la valuación.';

grant select on public.v_purchase_cost_alarms to authenticated;
grant select on public.v_purchase_cost_dispersion to authenticated;

commit;
