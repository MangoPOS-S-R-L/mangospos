-- ============================================================================
-- Import de catálogo — BARRA PAYÁN
-- Business e0aef218-ab95-4ba4-b8ef-036fab1c07c7
-- ============================================================================
--
-- PASO 5 — Los ADICIONALES del menú, como grupo de modificadores.
--
--   Queso cheddar o danés  +95
--   Pollo o Pierna         +100
--   Jamón                  +75
--   Salami                 +55
--   Huevo                  +30
--
-- POR QUÉ MODIFICADORES Y NO PRODUCTOS: así el extra viaja pegado al sándwich
--   —sale debajo de su ítem en la comanda de la SANDWICHERA y en la factura—
--   en vez de aparecer como una línea suelta que el cocinero no sabe a cuál
--   de los tres sándwiches de la mesa pertenece.
--
-- SE ENGANCHA A LOS 10 SÁNDWICHES. Las tostadas y las papas quedan fuera; si
--   también les ponen adicionales, agrega sus nombres a la lista de abajo.
--
-- min_select 0 / max_select 5: todos opcionales, se pueden elegir varios.
-- max_qty_per_option se queda en su default (1): no se puede pedir "2 huevos"
--   en el mismo sándwich, hay que añadir el modificador dos veces. Dime si lo
--   quieres distinto.
--
-- IMPUESTO: el price_delta hereda el tratamiento del producto padre, así que
--   los adicionales también salen con el ITBIS incluido. Coherente con el menú.
--
-- IDEMPOTENTE. Requiere el PASO 2.
-- ============================================================================

begin;

do $$
declare
  v_business uuid := 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7';
  v_group    uuid;
  v_faltan   text;
  v_ligados  int;
begin
  -- Guarda: los 10 sándwiches tienen que existir ya (paso 2).
  select string_agg(w.nombre, ', ') into v_faltan
  from (values
    ('Club Sándwich'), ('Payán Especial'), ('Sándwich Completo'),
    ('Sándwich de Pierna'), ('Sándwich de Pollo'), ('Juancito Caminador'),
    ('Sándwich de Jamón y Queso'), ('Sándwich de Huevo y Queso'),
    ('Sándwich de Salami y Queso'), ('Derretido de Queso')
  ) as w(nombre)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and lower(mi.name) = lower(w.nombre)
  );

  if v_faltan is not null then
    raise exception
      'Estos sándwiches no existen todavía: %. Corre el PASO 2 primero.',
      v_faltan;
  end if;

  -- 1) El grupo
  select id into v_group
  from public.modifier_groups
  where business_id = v_business and name = 'Adicionales';

  if v_group is null then
    v_group := gen_random_uuid();
    insert into public.modifier_groups
      (id, business_id, name, min_select, max_select, is_active, sort_order)
    values
      (v_group, v_business, 'Adicionales', 0, 5, true, 0);
  end if;

  -- 2) Las 5 opciones
  insert into public.modifiers
    (id, business_id, group_id, name, price_delta, is_active, sort_order)
  select gen_random_uuid(), v_business, v_group, m.name, m.delta, true, m.orden
  from (values
    ('Queso cheddar o danés', 95.00, 0),
    ('Pollo o Pierna',       100.00, 1),
    ('Jamón',                 75.00, 2),
    ('Salami',                55.00, 3),
    ('Huevo',                 30.00, 4)
  ) as m(name, delta, orden)
  where not exists (
    select 1 from public.modifiers x
    where x.group_id = v_group and lower(x.name) = lower(m.name)
  );

  -- 3) Enganchar el grupo a los 10 sándwiches
  insert into public.menu_item_groups (menu_item_id, group_id)
  select mi.id, v_group
  from public.menu_items mi
  join (values
    ('Club Sándwich'), ('Payán Especial'), ('Sándwich Completo'),
    ('Sándwich de Pierna'), ('Sándwich de Pollo'), ('Juancito Caminador'),
    ('Sándwich de Jamón y Queso'), ('Sándwich de Huevo y Queso'),
    ('Sándwich de Salami y Queso'), ('Derretido de Queso')
  ) as w(nombre) on lower(w.nombre) = lower(mi.name)
  where mi.business_id = v_business
    and mi.is_active
    and not exists (
      select 1 from public.menu_item_groups x
      where x.menu_item_id = mi.id and x.group_id = v_group
    );

  get diagnostics v_ligados = row_count;
  raise notice 'Grupo Adicionales enganchado a % sándwiches nuevos', v_ligados;
end $$;

commit;

-- ============================================================================
-- VERIFICACIÓN — esperado: 5 opciones, enganchado a 10 sándwiches
-- ============================================================================

select g.name as grupo, g.min_select, g.max_select,
       count(distinct m.id)   as opciones,
       count(distinct mig.menu_item_id) as productos
from public.modifier_groups g
left join public.modifiers m on m.group_id = g.id and m.is_active
left join public.menu_item_groups mig on mig.group_id = g.id
where g.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
group by g.name, g.min_select, g.max_select;

select m.name, m.price_delta
from public.modifiers m
join public.modifier_groups g on g.id = m.group_id
where g.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
  and g.name = 'Adicionales'
order by m.sort_order;

-- Los 10 sándwiches que quedaron con el grupo.
select mi.name
from public.menu_items mi
join public.menu_item_groups mig on mig.menu_item_id = mi.id
join public.modifier_groups g on g.id = mig.group_id and g.name = 'Adicionales'
where mi.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
order by mi.name;
