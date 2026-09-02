-- =============================================================================
-- LA PENDA EXPRESS — costos de compra disparados contra la historia
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- REQUIERE: 20260902_0015 aplicada. Nada más.
--
-- Este guion NO espera al conteo ni al motor de capas: lee las compras que ya
-- están en la base desde el 05-07-2026. Corre hoy y devuelve los artículos del
-- hallazgo 1 del informe DH.
--
-- Solo lee. No cambia nada.
-- =============================================================================


-- ===========================================================================
-- 1. LOS ARTÍCULOS DEL HALLAZGO 1 — costo máximo al menos el doble del mínimo.
--    DH encontró 21 con este criterio. Esta consulta debe devolver los mismos.
--
--    Leer así: si `ratio_max_min` es grande y la unidad es una sola (todo en
--    "L" o todo en "unidad"), casi nunca es que el precio subió — es que una
--    vez se compró el saco y otra la libra bajo el mismo código.
-- ===========================================================================
select
  item_sku                  as codigo,
  item_name                 as articulo,
  item_unit                 as unidad,
  compras,
  costo_min,
  costo_max,
  costo_mediana,
  ratio_max_min             as veces_mas_caro,
  costo_maestro_actual      as costo_que_usa_el_sistema,
  existencia,
  valor_a_costo_maestro     as valor_hoy,
  valor_a_mediana           as valor_a_precio_tipico,
  round(valor_a_costo_maestro - valor_a_mediana, 2) as cuanto_infla,
  ultima_compra
from public.v_purchase_cost_dispersion
where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
order by abs(valor_a_costo_maestro - valor_a_mediana) desc;


-- ===========================================================================
-- 2. LAS COMPRAS CONCRETAS QUE DISPARARON LA ALARMA.
--    Con el documento y el proveedor, para que Compras vaya a la factura.
-- ===========================================================================
select
  item_sku                  as codigo,
  item_name                 as articulo,
  item_unit                 as unidad,
  created_at::date          as fecha,
  quantity                  as cantidad,
  costo_de_esta_compra,
  costo_mediana             as costo_tipico,
  veces_la_mediana,
  direccion,
  documento                 as ncf_o_factura,
  proveedor,
  magnitud_del_desvio
from public.v_purchase_cost_alarms
where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
order by magnitud_del_desvio desc;


-- ===========================================================================
-- 3. CUÁNTO PESA TODO ESTO EN LA VALUACIÓN ACTUAL.
--    Compara la cifra del sistema contra lo que daría a precio típico.
--    La diferencia debería acercarse a los RD$1,256,970 que DH atribuye a
--    AZUCAR BLANCA y SACO DE CEBOLLA.
-- ===========================================================================
select
  count(*)                                        as articulos_afectados,
  round(sum(valor_a_costo_maestro), 2)            as valor_hoy,
  round(sum(valor_a_mediana), 2)                  as valor_a_precio_tipico,
  round(sum(valor_a_costo_maestro - valor_a_mediana), 2) as cuanto_infla
from public.v_purchase_cost_dispersion
where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';


-- ===========================================================================
-- 4. QUÉ TAN SENSIBLE ES EL UMBRAL.
--    Cuántas alarmas saldrían con cada factor, para calibrarlo sin adivinar.
--    El default es 3. Si salen demasiadas, subirlo:
--      update public.business_settings set cost_alarm_factor = 5
--       where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
-- ===========================================================================
with base as (
  select m.item_id, m.cost_per_unit
    from public.inventory_movements m
   where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and m.movement_type = 'purchase'
     and coalesce(m.cost_per_unit, 0) > 0
     and m.quantity > 0
),
med as (
  select item_id,
         count(*) as compras,
         percentile_disc(0.5) within group (order by cost_per_unit) as mediana
    from base group by item_id
),
f as (select unnest(array[2, 3, 5, 10, 25]::numeric[]) as factor)
select f.factor,
       count(*) filter (
         where b.cost_per_unit > med.mediana * f.factor
            or b.cost_per_unit < med.mediana / f.factor
       ) as compras_con_alarma
  from f
  cross join base b
  join med on med.item_id = b.item_id
 where med.compras >= 2 and med.mediana > 0
 group by f.factor
 order by f.factor;
