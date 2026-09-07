-- ============================================================================
-- Import de catálogo — BARRA PAYÁN BEIBOLISTA
-- Business e0aef218-ab95-4ba4-b8ef-036fab1c07c7
-- ============================================================================
--
-- PASO 7 (OPCIONAL) — Corregir precios después de cargados.
--
-- POR QUÉ EXISTE: el paso 2 inserta con NOT EXISTS, así que re-correrlo NO
--   actualiza precios de productos que ya están. Este script sí los pisa.
--
-- ÚSALO para los 6 precios de OTRAS BEBIDAS que la foto trae tachados, o para
--   cualquier ajuste posterior. Es seguro correrlo las veces que haga falta.
--
-- ⚠ SOLO CAMBIA EL PRECIO DE VENTA. Como los productos son 'inclusive', el
--   ITBIS se recalcula solo hacia adentro: pones 75 y el cliente paga 75.
--   No toca ventas ya hechas — esas guardan su propio unit_price.
-- ============================================================================

begin;

do $$
declare
  v_business uuid := 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7';
  v_faltan   text;
  v_tocados  int;
begin
  -- ▼▼▼ EDITA AQUÍ: nombre exacto y precio nuevo. Borra los que no cambien.
  create temp table _precios(name text, price numeric(12,2)) on commit drop;
  insert into _precios values
    ('Agua',             175.00),
    ('Leche',            145.00),
    ('Chocolate',        175.00),
    ('Café Dominicano',  225.00),
    ('Cortadito',        225.00),
    ('Expreso',          225.00);
  -- ▲▲▲

  -- Guarda: un nombre mal escrito no cambiaría nada y no te enterarías.
  select string_agg(p.name, ', ') into v_faltan
  from _precios p
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and lower(mi.name) = lower(p.name)
  );

  if v_faltan is not null then
    raise exception
      'Estos productos no existen con ese nombre exacto: %. Revisa la '
      'ortografía (acentos incluidos) contra 06_verificacion.sql.', v_faltan;
  end if;

  update public.menu_items mi
  set price = p.price, updated_at = now()
  from _precios p
  where mi.business_id = v_business
    and lower(mi.name) = lower(p.name)
    and mi.price is distinct from p.price;

  get diagnostics v_tocados = row_count;
  raise notice 'Precios cambiados: %', v_tocados;
end $$;

commit;

-- ============================================================================
-- VERIFICACIÓN — cómo queda el desglose de las bebidas
-- ============================================================================

select mi.name, mi.price as paga_el_cliente,
       round(mi.price / 1.18, 2) as base_gravada,
       round(mi.price - (mi.price / 1.18), 2) as itbis
from public.menu_items mi
join public.categories c on c.id = mi.category_id
where mi.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
  and c.name = 'Bebidas' and mi.is_active
order by mi.position;
