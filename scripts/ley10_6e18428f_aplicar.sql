-- ============================================================================
-- Aplicar la Ley 10% a TODOS los productos
-- Negocio 6e18428f-fdd6-4c58-af0e-dae2403fbf1d (LA COCINA MEXICANA AUTENTICA)
-- Impuesto: "Ley" 10% (id 170612a0-ee9b-4ee7-8e73-9dc8683637ab), ya creado.
--
-- Idempotente (NOT EXISTS) y scopeado al negocio. Solo escribe en
-- menu_item_taxes: no toca el ITBIS, ni precios, ni tax_mode, ni la config
-- del impuesto.
-- ============================================================================

-- ─── 1) PREVIEW: cuántos vínculos se van a insertar (debe dar 39) ───────────
select count(*) as filas_a_insertar
from public.menu_items mi
join public.taxes t
  on t.business_id = mi.business_id and t.rate = 10 and t.is_active
where mi.business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
  and mi.is_active
  and not exists (
    select 1 from public.menu_item_taxes m
    where m.item_id = mi.id and m.tax_id = t.id
  );


-- ─── 2) INSERT ──────────────────────────────────────────────────────────────
insert into public.menu_item_taxes (item_id, tax_id)
select mi.id, t.id
from public.menu_items mi
join public.taxes t
  on t.business_id = mi.business_id and t.rate = 10 and t.is_active
where mi.business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
  and mi.is_active
  and not exists (
    select 1 from public.menu_item_taxes m
    where m.item_id = mi.id and m.tax_id = t.id
  );


-- ─── 3) VERIFICAR: con_ley debe dar 46 = productos ──────────────────────────
select
  count(*)                                     as productos,
  count(*) filter (where exists (
    select 1 from public.menu_item_taxes m
    join public.taxes t on t.id = m.tax_id
    where m.item_id = mi.id
      and t.business_id = mi.business_id
      and t.rate = 10 and t.is_active))        as con_ley
from public.menu_items mi
where mi.business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
  and mi.is_active;


-- ─── 4) CÓMO QUEDA EL COBRO ─────────────────────────────────────────────────
--   Misma fórmula del trigger fn_compute_item_totals:
--     inclusive → base = precio/(1+tasa),  total = precio
--     exclusive → base = precio,           total = precio*(1+tasa)
--   `tasa_total` debe dar 28 (18 + 10) en todos menos AGUA, que da 10.
select
  mi.name                                     as producto,
  mi.price                                    as precio,
  mi.tax_mode,
  string_agg(t.name || ' ' || t.rate || '%', ' + ' order by t.rate desc) as impuestos,
  sum(t.rate)                                 as tasa_total,
  case when mi.tax_mode = 'inclusive'
       then round(mi.price / (1 + sum(t.rate) / 100.0), 2)
       else round(mi.price, 2) end            as base,
  case when mi.tax_mode = 'inclusive'
       then round(mi.price - mi.price / (1 + sum(t.rate) / 100.0), 2)
       else round(mi.price * sum(t.rate) / 100.0, 2) end as impuestos_rd,
  case when mi.tax_mode = 'inclusive'
       then round(mi.price, 2)
       else round(mi.price * (1 + sum(t.rate) / 100.0), 2) end as total_a_cobrar
from public.menu_items mi
join public.menu_item_taxes mit on mit.item_id = mi.id
join public.taxes t             on t.id = mit.tax_id and t.is_active
where mi.business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
  and mi.is_active
  and mi.price > 0
group by mi.id, mi.name, mi.price, mi.tax_mode
order by mi.price desc
limit 15;


-- ============================================================================
-- ROLLBACK — quita la Ley de TODOS los productos (también de los 7 Shots que
-- ya la tenían antes; no distingue).
-- ============================================================================
-- delete from public.menu_item_taxes m
-- using public.taxes t
-- where m.tax_id = t.id
--   and t.business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
--   and t.rate = 10;
