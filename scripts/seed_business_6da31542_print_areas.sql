-- ============================================================================
-- Áreas de producción — Business 6da31542-72e1-4f55-bc28-9837da98a119
-- Complemento de scripts/seed_business_6da31542_menu.sql (correr DESPUÉS)
-- ============================================================================
--
-- POR QUÉ HACE FALTA ESTE SCRIPT:
--   `menu_items.print_area_code` tiene NOT NULL DEFAULT 'kitchen_hot'. Los 49
--   productos del seed quedaron con ese código heredado, pero este negocio
--   NO tiene un área 'kitchen_hot' — solo 'bar' y 'pizzeria'.
--   Con un código que no existe, "Enviar a cocina" revienta con
--   UnknownPrintAreaCodeException y NO sale ninguna comanda.
--
-- ASIGNACIÓN (2 áreas ya existentes en el negocio):
--   pizzeria (PIZZERIA) → Entrada, Pizzas Clásicas, Pizzas Especiales,
--                         Ensalada, Sandwich                      = 19
--   bar      (BAR)      → Cocktails, Tragos, Cervezas, Bebidas    = 30
--                                                          Total  = 49
--   Coincide 1:1 con el flag is_beverage del seed (30 en true).
--
-- SE ESCRIBEN LOS DOS MECANISMOS, A PROPÓSITO:
--   1. `menu_item_print_areas` (N:M) — es la fuente de verdad; el
--      orchestrator la prefiere sobre el legacy cuando hay filas.
--   2. `menu_items.print_area_code` (legacy 1-a-1) — NO es redundante:
--      · `fn_add_item_from_menu` lo COPIA al order_item al insertarlo, y ese
--        es el valor que usa el fallback si el lookup N:M falla.
--      · El lookup N:M se salta entero cuando no hay red (y tiene timeout de
--        8s online). Sin legacy correcto, un bache de red mandaría las 30
--        bebidas a la impresora de pizzería.
--      Dejar solo uno de los dos deja un agujero de ruteo. Van los dos.
--
-- MODIFICADORES: no llevan área propia; se imprimen con el producto padre
--   (burrata / borde relleno salen en la comanda de pizzería; los sabores
--   de mojito/frozen en la de barra). No hay nada que asignar.
--
-- CONVERGENTE: borra asignaciones N:M que no correspondan y luego inserta
--   las correctas. Re-ejecutar deja el mismo estado (0 filas afectadas).
--   `updated_at` lo bumpea el trigger set_menu_items_updated_at, así que
--   los dispositivos re-sincronizan el catálogo solos.
--
-- Ejecutar en Supabase Studio → SQL Editor. Un solo commit.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 0) Guarda: las áreas DEBEN existir y estar activas.
--    Si falta alguna, aborta la transacción sin tocar nada.
-- ----------------------------------------------------------------------------

do $$
declare
  v_business uuid := '6da31542-72e1-4f55-bc28-9837da98a119';
  v_missing  text;
begin
  select string_agg(w.code, ', ')
    into v_missing
  from (values ('pizzeria'), ('bar')) as w(code)
  where not exists (
    select 1
    from public.print_areas a
    where a.business_id = v_business
      and a.code = w.code
      and a.is_active
  );

  if v_missing is not null then
    raise exception
      'Faltan áreas de producción activas para este negocio: %. '
      'Créalas en Ajustes → Impresoras → Áreas antes de correr este script.',
      v_missing;
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 1) Legacy `print_area_code` — saca a los 49 productos de 'kitchen_hot'
-- ----------------------------------------------------------------------------

-- 1a) Comida → pizzeria
update public.menu_items mi
set print_area_code = 'pizzeria'
from public.categories c
where c.id = mi.category_id
  and mi.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
  and c.business_id = mi.business_id
  and c.name in ('Entrada', 'Pizzas Clásicas', 'Pizzas Especiales',
                 'Ensalada', 'Sandwich')
  and mi.print_area_code is distinct from 'pizzeria';

-- 1b) Bebidas → bar
update public.menu_items mi
set print_area_code = 'bar'
from public.categories c
where c.id = mi.category_id
  and mi.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
  and c.business_id = mi.business_id
  and c.name in ('Cocktails', 'Tragos', 'Cervezas', 'Bebidas')
  and mi.print_area_code is distinct from 'bar';

-- ----------------------------------------------------------------------------
-- 2) N:M `menu_item_print_areas` — limpia lo que sobre y asigna lo correcto
-- ----------------------------------------------------------------------------

-- 2a) Borra asignaciones que NO corresponden al área objetivo del producto.
--     Sin esto, un producto con un área vieja se rutearía a DOS impresoras.
--     Estrictamente acotado a los productos de este negocio.
delete from public.menu_item_print_areas mipa
using public.menu_items mi
join public.categories c on c.id = mi.category_id
where mipa.menu_item_id = mi.id
  and mi.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
  and mipa.print_area_id <> (
    select a.id
    from public.print_areas a
    where a.business_id = mi.business_id
      and a.code = case
        when c.name in ('Cocktails', 'Tragos', 'Cervezas', 'Bebidas')
          then 'bar'
        else 'pizzeria'
      end
  );

-- 2b) Comida → pizzeria
insert into public.menu_item_print_areas (menu_item_id, print_area_id)
select mi.id, a.id
from public.menu_items mi
join public.categories c
  on c.id = mi.category_id
join public.print_areas a
  on a.business_id = mi.business_id
 and a.code = 'pizzeria'
where mi.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
  and c.name in ('Entrada', 'Pizzas Clásicas', 'Pizzas Especiales',
                 'Ensalada', 'Sandwich')
  and not exists (
    select 1
    from public.menu_item_print_areas x
    where x.menu_item_id = mi.id
      and x.print_area_id = a.id
  );

-- 2c) Bebidas → bar
insert into public.menu_item_print_areas (menu_item_id, print_area_id)
select mi.id, a.id
from public.menu_items mi
join public.categories c
  on c.id = mi.category_id
join public.print_areas a
  on a.business_id = mi.business_id
 and a.code = 'bar'
where mi.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
  and c.name in ('Cocktails', 'Tragos', 'Cervezas', 'Bebidas')
  and not exists (
    select 1
    from public.menu_item_print_areas x
    where x.menu_item_id = mi.id
      and x.print_area_id = a.id
  );

commit;

-- ============================================================================
-- VERIFICACIÓN (correr después del commit)
-- ============================================================================

-- A) Ruteo por categoría — esperado: pizzeria 19 / bar 30, y las dos
--    columnas (legacy y N:M) SIEMPRE iguales.
select
  c.position,
  c.name                                as categoria,
  mi.print_area_code                    as legacy,
  string_agg(distinct a.code, ',')      as nm,
  count(*)                              as productos
from public.menu_items mi
join public.categories c        on c.id = mi.category_id
left join public.menu_item_print_areas mipa on mipa.menu_item_id = mi.id
left join public.print_areas a  on a.id = mipa.print_area_id
where mi.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
  and mi.is_active
group by c.position, c.name, mi.print_area_code
order by c.position;

-- B) Totales por área — esperado: bar 30 | pizzeria 19
select a.code, a.name, count(mipa.menu_item_id) as productos
from public.print_areas a
left join public.menu_item_print_areas mipa on mipa.print_area_id = a.id
left join public.menu_items mi
       on mi.id = mipa.menu_item_id and mi.is_active
where a.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
group by a.code, a.name
order by a.code;

-- C) RED FLAGS — las tres deben dar 0 filas.
--    c1: ningún producto quedó en un área inexistente (ej. 'kitchen_hot')
select mi.name, mi.print_area_code
from public.menu_items mi
where mi.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
  and mi.is_active
  and not exists (
    select 1 from public.print_areas a
    where a.business_id = mi.business_id
      and a.code = mi.print_area_code
      and a.is_active
  );

--    c2: ningún producto sin asignación N:M
select mi.name
from public.menu_items mi
where mi.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
  and mi.is_active
  and not exists (
    select 1 from public.menu_item_print_areas x where x.menu_item_id = mi.id
  );

--    c3: legacy y N:M no coinciden (rutearían distinto si falla la red)
select mi.name, mi.print_area_code as legacy, a.code as nm
from public.menu_items mi
join public.menu_item_print_areas mipa on mipa.menu_item_id = mi.id
join public.print_areas a on a.id = mipa.print_area_id
where mi.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
  and mi.is_active
  and a.code is distinct from mi.print_area_code;

--    c4: control cruzado contra is_beverage — esperado 0 filas
--        (toda bebida en bar, toda comida en pizzeria)
select mi.name, mi.is_beverage, mi.print_area_code
from public.menu_items mi
where mi.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
  and mi.is_active
  and mi.print_area_code <> case when mi.is_beverage then 'bar' else 'pizzeria' end;

-- ============================================================================
-- SIGUIENTE PASO
-- ============================================================================
-- Falta que cada área tenga impresora asignada (tabla print_area_printers),
-- si no, la comanda se genera pero no sale por ningún lado:
--   select a.code, a.name, count(pap.printer_id) as impresoras
--   from public.print_areas a
--   left join public.print_area_printers pap on pap.area_id = a.id
--   where a.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'
--   group by a.code, a.name;
-- Se configura en Ajustes → Impresoras → Áreas.
-- ============================================================================
