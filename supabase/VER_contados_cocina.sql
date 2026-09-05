-- =============================================================================
-- PC-2026-000003 · Cocina — todo lo que tiene cantidad cargada
--
-- La columna `origen` dice de qué lote salió cada renglón:
--   «carga 21»  los que se cargaron con ID desde el papel
--   «nuevo 8»   los insumos creados para la cocina
--   «otro»      cualquier otro — tecleado a mano o de otro lote
-- =============================================================================

with s as (
  select id from public.physical_count_sessions
   where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and code = 'PC-2026-000003'
),
lote21(item_id) as (values
  ('e7dc40a8-5100-4b38-8e40-88f053ac8a80'::uuid),
  ('1777df41-1169-4614-a6c7-470bc0d75af9'),
  ('197d82fa-fe07-4552-93b4-849a8ce96eea'),
  ('cdee569a-f603-4818-a0cf-5675ddb1d6bd'),
  ('6ba4e779-fceb-4143-b71b-e231bcbc334d'),
  ('cc01f726-1955-47e4-8060-fa5afa9a9e65'),
  ('122a3d3f-2e0e-4adf-891b-44f7672abd7e'),
  ('56da1160-5ff8-4224-b05c-634f99329432'),
  ('8ec8627b-53fb-4a40-970e-6b081526469a'),
  ('e1890ea5-ef55-40da-9c5c-5cb00e281a1e'),
  ('d5b7e98b-cbd9-4e1f-9648-e14be92f805f'),
  ('eb3e5f70-a3be-43d5-9b1e-f99462e3f77b'),
  ('d39590f7-c7d7-4fea-9e9e-b2e592fb940e'),
  ('e0c7950e-f20e-44d6-8735-f4d02c0f36bd'),
  ('b357c6d9-9735-4f0b-8f2a-d62abb25aa55'),
  ('9e3008df-1f98-4b53-8729-03f58c7f2afb'),
  ('e27e130e-9506-452e-b837-dd145981fda0'),
  ('67f5a7bd-e091-4e12-8ebf-fd460ebd82a8'),
  ('17f6b501-628d-4a5e-ab39-a3e05310221f'),
  ('fb176a38-0946-4043-9f5a-991a133a0dbd'),
  ('e0d2e3fc-bcf4-43b9-ba2c-356e5bfdf799')
),
nuevos8(nombre) as (values
  ('salami genoa'),('pepperoni pedrollo'),('picante red hot'),
  ('aceite especial lata 30 libras'),('salmón penca'),
  ('chicharrón 10 oz'),('pollo mechado 4 oz'),('cativía de queso')
)
select
  case
    when l.item_id in (select item_id from lote21)              then 'carga 21'
    when lower(ii.name) in (select nombre from nuevos8)         then 'nuevo 8'
    else 'otro'
  end                                                     as origen,
  ii.name                                                 as articulo,
  coalesce(nullif(btrim(ii.sku),''), '—')                 as codigo,
  ii.unit                                                 as unidad,
  l.counted_quantity                                      as contado,
  l.snapshot_quantity                                     as sistema,
  round(l.counted_quantity - l.snapshot_quantity, 3)      as diferencia,
  round(coalesce(ii.cost,0), 2)                           as costo,
  round((l.counted_quantity - l.snapshot_quantity)
        * coalesce(ii.cost,0), 2)                         as valor_diferencia,
  case when coalesce(ii.cost,0) = 0 then 'SIN COSTO' end  as ojo,
  coalesce(l.counter_notes,'')                            as nota
from public.physical_count_lines l
join public.inventory_items ii on ii.id = l.item_id
where l.session_id = (select id from s)
  and l.counted_quantity is not null
order by origen, ii.name;


-- ── El resumen, para cuadrar de un vistazo ─────────────────────────────────
with s as (
  select id from public.physical_count_sessions
   where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and code = 'PC-2026-000003'
)
select
  count(*)                                                as contados,
  count(*) filter (where coalesce(ii.cost,0) = 0)         as sin_costo,
  round(sum(l.counted_quantity * coalesce(ii.cost,0)), 2) as valor_contado,
  round(sum((l.counted_quantity - l.snapshot_quantity)
            * coalesce(ii.cost,0)), 2)                    as valor_diferencia
from public.physical_count_lines l
join public.inventory_items ii on ii.id = l.item_id
where l.session_id = (select id from s)
  and l.counted_quantity is not null;
