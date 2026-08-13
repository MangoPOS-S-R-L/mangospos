-- ============================================================================
-- Import de catálogo Square → MangoPOS
-- Business 882ef5a4-93eb-4e58-92c3-bf532e179d45 (licorería MONCION)
-- Fuente: MLYH9X2TGPA28_catalog-2026-08-11-0140.csv (export de Square)
-- ============================================================================
--
-- PASO 6 — Vincular la Propina de Ley (10%).
--
-- DECISIÓN DEL DUEÑO (2026-08-10): se vincula SOLO la Propina de Ley.
--   El ITBIS 18% queda SIN vincular a propósito, aunque el impuesto exista
--   y esté activo en el negocio. El precio del CSV se cobra tal cual y encima
--   solo se suma el 10%.
--
--   ⚠ Consecuencia fiscal: mientras el ITBIS no se vincule, las facturas de
--     este negocio salen con ITBIS 0.00 ante la DGII. `menu_item_taxes` es la
--     ÚNICA fuente del impuesto por producto — no hay fallback a
--     business_settings.default_tax_rate (PRD 2.5 lo quitó). Si más adelante
--     se quiere el ITBIS, es este mismo script cambiando v_tax_name.
--
-- DÓNDE SE COBRA — lo gobiernan los apply_on del impuesto, ya configurados:
--     zona ✓   manual ✓   delivery ✓   |   quick ✗   takeout ✗
--   O sea: el trago en mesa cobra el 10%; la botella en venta rápida o para
--   llevar, no. No hay que mantener listas de productos.
--
-- ┌────────────────────────────────────────────────────────────────────────┐
-- │ 🚫 `taxes.is_service_fee` se queda en FALSE. Si se enciende, el servidor │
-- │    lo mete dentro del oi.tax consolidado Y el cliente lo vuelve a sumar │
-- │    aparte: la factura cobra 10% + 10%. Regla fija, no se toca.          │
-- ├────────────────────────────────────────────────────────────────────────┤
-- │ ⚠ Tampoco enciendas business_settings.service_fee_enabled. Con el 10%   │
-- │   vinculado por producto Y ese switch en true, se cobra dos veces: una  │
-- │   por ítem (menu_item_taxes) y otra por orden (calculate_order_totals).  │
-- │   Hoy está en false; el PASO 1 de abajo aborta si cambió.               │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- ALCANCE: todos los productos activos del negocio, no solo los del import.
--   Así no depende de la tabla de staging (que se borra en el paso 5).
--
-- IDEMPOTENTE: re-ejecutar no duplica vínculos.
-- ============================================================================

begin;

do $$
declare
  -- ▼▼▼ Impuesto a vincular. Confirmado en el diagnóstico del 2026-08-10:
  --     "Propina de Ley" · 10.0% · activo · is_service_fee=false
  v_tax_name text := 'Propina de Ley';
  -- ▲▲▲

  v_business uuid := '882ef5a4-93eb-4e58-92c3-bf532e179d45';
  v_tax_id   uuid;
  v_tax_rate numeric;
  v_sf_on    boolean;
  v_matches  int;
  v_linked   int;
begin
  -- Guarda 1: el impuesto existe, es único por nombre y está activo.
  select count(*) into v_matches
  from public.taxes where business_id = v_business and name = v_tax_name;

  if v_matches = 0 then
    raise exception
      'No existe un impuesto llamado "%" en este negocio. Revisa el nombre '
      'exacto en Ajustes → Impuestos (distingue mayúsculas y espacios).',
      v_tax_name;
  elsif v_matches > 1 then
    raise exception
      'Hay % impuestos llamados "%". Desambigua por id antes de continuar.',
      v_matches, v_tax_name;
  end if;

  select id, rate into v_tax_id, v_tax_rate
  from public.taxes where business_id = v_business and name = v_tax_name;

  if not exists (select 1 from public.taxes
                 where id = v_tax_id and coalesce(is_active, true)) then
    raise exception
      'El impuesto "%" existe pero está INACTIVO: no cobraría nada. Actívalo '
      'en Ajustes → Impuestos y vuelve a correr.', v_tax_name;
  end if;

  -- Guarda 2: cobro doble.
  select coalesce(service_fee_enabled, false) into v_sf_on
  from public.business_settings where business_id = v_business;

  if coalesce(v_sf_on, false) then
    raise exception
      'ABORTADO: business_settings.service_fee_enabled está en TRUE. Vincular '
      '"%" (% %%) por producto con ese switch encendido cobra la propina DOS '
      'veces. Apágalo en Ajustes y vuelve a correr.', v_tax_name, v_tax_rate;
  end if;

  -- 1) Garantizar modo exclusivo (el impuesto se suma encima del precio).
  update public.menu_items
  set tax_mode = 'exclusive'
  where business_id = v_business and tax_mode is distinct from 'exclusive';

  -- 2) Vincular.
  insert into public.menu_item_taxes (item_id, tax_id)
  select mi.id, v_tax_id
  from public.menu_items mi
  where mi.business_id = v_business
    and mi.is_active
    and not exists (
      select 1 from public.menu_item_taxes x
      where x.item_id = mi.id and x.tax_id = v_tax_id
    );
  get diagnostics v_linked = row_count;

  raise notice 'OK — "%" (% %%) vinculado a % productos nuevos.',
    v_tax_name, v_tax_rate, v_linked;
end $$;

commit;

-- ============================================================================
-- VERIFICACIÓN
-- ============================================================================

-- A) Cobertura por categoría — `con_propina` debe igualar `productos`,
--    y `tasas` mostrar solo 10.0 (si aparece un 18, se coló el ITBIS).
select
  c.position, c.name as categoria,
  count(*)                                              as productos,
  count(mit.tax_id)                                     as con_propina,
  coalesce(string_agg(distinct t.rate::text, '+'), '—') as tasas
from public.menu_items mi
join public.categories c             on c.id = mi.category_id
left join public.menu_item_taxes mit on mit.item_id = mi.id
left join public.taxes t             on t.id = mit.tax_id
where mi.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid and mi.is_active
group by c.position, c.name
order by c.position;

-- B) RED FLAGS — las dos deben dar 0 filas.
-- b1: productos activos sin la propina vinculada
select mi.name
from public.menu_items mi
where mi.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid and mi.is_active
  and not exists (
    select 1 from public.menu_item_taxes x
    join public.taxes t on t.id = x.tax_id
    where x.item_id = mi.id and t.name = 'Propina de Ley'
  );

-- b2: algún producto quedó inclusivo
select mi.name, mi.tax_mode
from public.menu_items mi
where mi.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid and mi.is_active
  and mi.tax_mode <> 'exclusive';

-- C) Simulación de cobro EN MESA. Una Presidente 12oz de 150 debe dar 165;
--    una botella de 1500, 1650. En venta rápida y para llevar se cobra el
--    precio pelado, porque apply_on_quick y apply_on_takeout están en false.
select
  mi.name, mi.price as precio, mi.tax_mode,
  sum(t.rate)                                    as tasa_total,
  round(mi.price * sum(t.rate) / 100.0, 2)       as impuesto,
  round(mi.price * (1 + sum(t.rate) / 100.0), 2) as total_en_mesa
from public.menu_items mi
join public.menu_item_taxes mit on mit.item_id = mi.id
join public.taxes t             on t.id = mit.tax_id and t.is_active
where mi.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid
  and mi.name in ('Presidente 12oz', 'Corona Extra 12oz', 'Hookah', 'Hamburger')
group by mi.name, mi.price, mi.tax_mode
order by mi.price;

-- ============================================================================
-- OPCIONAL — quitar el 10% de las entregas a domicilio.
-- Hoy `apply_on_delivery` está en TRUE: una botella despachada a domicilio
-- cobra el 10% de servicio. Si en BAMBOLEO el delivery es solo venta de
-- botella, descoméntalo:
--
-- update public.taxes set apply_on_delivery = false
-- where business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid and name = 'Propina de Ley';
-- ============================================================================

-- ============================================================================
-- ROLLBACK — desvincula SOLO la propina, no toca los productos.
-- delete from public.menu_item_taxes mit
-- using public.taxes t, public.menu_items mi
-- where mit.tax_id = t.id and mit.item_id = mi.id
--   and t.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid
--   and mi.business_id = t.business_id
--   and t.name = 'Propina de Ley';
-- ============================================================================
