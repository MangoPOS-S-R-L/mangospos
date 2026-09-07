-- ============================================================================
-- Import de catálogo — BARRA PAYÁN
-- Business e0aef218-ab95-4ba4-b8ef-036fab1c07c7
-- ============================================================================
--
-- PASO 4 — Áreas de comanda.
--   SANDWICHERA 14  (los 10 sándwiches + tostadas + papas)
--   JUGUERA     40  (los 28 jugos + las 12 bebidas)
--
-- SE RESUELVE POR `name`, NO POR `code`: de la pantalla de la app solo se
--   conocen los nombres (JUGUERA / SANDWICHERA). El `code` real se lee de la
--   propia fila y se usa para el legacy, así no hay que adivinarlo.
--
-- SE ESCRIBEN LOS DOS MECANISMOS, A PROPÓSITO:
--   1. menu_item_print_areas (N:M) — fuente de verdad; el orchestrator la
--      prefiere cuando hay filas.
--   2. menu_items.print_area_code (legacy) — NO es redundante:
--      fn_add_item_from_menu lo COPIA al order_item al insertarlo, y ese valor
--      es el fallback. El lookup N:M tiene timeout online; sin el legacy
--      correcto, un bache de red manda los sándwiches a la juguera.
--
-- Un producto sin área NO IMPRIME COMANDA. En el seed de ECOBAR quedaron 326
--   de 711 sin área por saltarse este paso.
--
-- IDEMPOTENTE. Requiere el PASO 2.
-- ============================================================================

begin;

do $$
declare
  v_business uuid := 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7';
  v_missing  text;
  v_dup      text;
begin
  -- Guarda 1: las dos áreas existen y están activas.
  select string_agg(w.nombre, ', ') into v_missing
  from (values ('SANDWICHERA'), ('JUGUERA')) as w(nombre)
  where not exists (
    select 1 from public.print_areas a
    where a.business_id = v_business and a.name = w.nombre and a.is_active
  );

  if v_missing is not null then
    raise exception
      'Faltan áreas de comanda activas en este negocio: %. Créalas en '
      'Ajustes → Impresoras → Comandas por impresora, con ese nombre exacto.',
      v_missing;
  end if;

  -- Guarda 2: nombre único, si no el join multiplicaría filas.
  select string_agg(a.name, ', ') into v_dup
  from public.print_areas a
  where a.business_id = v_business and a.name in ('SANDWICHERA', 'JUGUERA')
    and a.is_active
  group by a.name having count(*) > 1;

  if v_dup is not null then
    raise exception 'Hay áreas activas con nombre repetido: %.', v_dup;
  end if;

  -- 1) Legacy print_area_code — saca a los productos del default 'kitchen_hot',
  --    un código que este negocio no tiene. Con un código inexistente,
  --    "Enviar a cocina" revienta y NO sale NINGUNA comanda de la orden.
  update public.menu_items mi
  set print_area_code = a.code
  from public._import_e0aef218 s
  join public.print_areas a
    on a.business_id = v_business and a.name = s.area and a.is_active
  where mi.business_id = v_business
    and lower(mi.name) = lower(s.name)
    and mi.print_area_code is distinct from a.code;

  -- 2a) N:M — borra asignaciones que NO son el área objetivo.
  --     Sin esto, un producto con área vieja se rutea a DOS impresoras.
  delete from public.menu_item_print_areas mipa
  using public.menu_items mi
  join public._import_e0aef218 s on lower(s.name) = lower(mi.name)
  join public.print_areas destino
    on destino.business_id = mi.business_id and destino.name = s.area
   and destino.is_active
  where mipa.menu_item_id = mi.id
    and mi.business_id = v_business
    and mipa.print_area_id <> destino.id;

  -- 2b) N:M — asigna la correcta.
  insert into public.menu_item_print_areas (menu_item_id, print_area_id)
  select mi.id, a.id
  from public.menu_items mi
  join public._import_e0aef218 s on lower(s.name) = lower(mi.name)
  join public.print_areas a
    on a.business_id = mi.business_id and a.name = s.area and a.is_active
  where mi.business_id = v_business
    and not exists (
      select 1 from public.menu_item_print_areas x
      where x.menu_item_id = mi.id and x.print_area_id = a.id
    );
end $$;

commit;

-- ============================================================================
-- VERIFICACIÓN — esperado: JUGUERA 40 · SANDWICHERA 14
-- ============================================================================

select a.name, a.code, count(mipa.menu_item_id) as productos
from public.print_areas a
left join public.menu_item_print_areas mipa on mipa.print_area_id = a.id
left join public.menu_items mi on mi.id = mipa.menu_item_id and mi.is_active
where a.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
group by a.name, a.code
order by a.name;

-- 🚩 RED FLAGS — las tres deben dar 0 filas.

-- r1: productos apuntando a un área que no existe (ej. el default 'kitchen_hot')
select mi.name, mi.print_area_code
from public.menu_items mi
where mi.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid and mi.is_active
  and (mi.print_area_code is null
       or not exists (
         select 1 from public.print_areas a
         where a.business_id = mi.business_id and a.code = mi.print_area_code
           and a.is_active
       ));

-- r2: productos sin asignación N:M (no imprimirían comanda)
select mi.name
from public.menu_items mi
where mi.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid and mi.is_active
  and not exists (
    select 1 from public.menu_item_print_areas x where x.menu_item_id = mi.id
  );

-- r3: legacy y N:M en desacuerdo (rutearían distinto si falla la red)
select mi.name, mi.print_area_code as legacy, a.code as nm
from public.menu_items mi
join public.menu_item_print_areas mipa on mipa.menu_item_id = mi.id
join public.print_areas a on a.id = mipa.print_area_id
where mi.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid and mi.is_active
  and a.code is distinct from mi.print_area_code;

-- ============================================================================
-- ⚠ SIGUIENTE PASO, FUERA DE SQL: en la foto que mandaste, JUGUERA y
--   SANDWICHERA dicen "Sin impresora". La comanda se va a generar pero no sale
--   por ningún lado. Hay que vincular la impresora de cada área en
--   Ajustes → Impresoras → Comandas por impresora → Agregar impresora.
--   Esta consulta lo confirma (esperado: 1+ impresoras en cada una):
--     select a.name, count(pap.printer_id) as impresoras
--     from public.print_areas a
--     left join public.print_area_printers pap on pap.area_id = a.id
--     where a.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'
--     group by a.name;
-- ============================================================================
