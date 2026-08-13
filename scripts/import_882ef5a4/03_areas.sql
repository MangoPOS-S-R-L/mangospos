-- ============================================================================
-- Import de catálogo Square → MangoPOS
-- Business 882ef5a4-93eb-4e58-92c3-bf532e179d45 (licorería MONCION)
-- Fuente: MLYH9X2TGPA28_catalog-2026-08-11-0140.csv (export de Square)
-- ============================================================================
--
-- PASO 3 — Áreas de producción (comandas).
--
-- Barra 1500 · Cocina 16  (total 1516)
--   Cocina = la categoría Comida. Todo lo demás va a barra, incluido el retail
--   (chicles, vapes, papitas): no necesitan comanda, pero `print_area_code` es
--   NOT NULL y su default es 'kitchen_hot' — un código que este negocio no
--   tiene. Con un código inexistente, "Enviar a cocina" revienta con
--   UnknownPrintAreaCodeException y NO sale NINGUNA comanda de la orden.
--
-- SE ESCRIBEN LOS DOS MECANISMOS, A PROPÓSITO:
--   1. menu_item_print_areas (N:M) — fuente de verdad; el orchestrator la
--      prefiere cuando hay filas.
--   2. menu_items.print_area_code (legacy) — NO es redundante:
--      fn_add_item_from_menu lo COPIA al order_item al insertarlo, y ese valor
--      es el fallback. El lookup N:M se salta entero sin red y tiene timeout de
--      8s online; sin el legacy correcto, un bache de red manda la comida a la
--      impresora de la barra.
--
-- ▼▼▼ ÚNICO LUGAR A EDITAR: los `code` reales de este negocio.
--     Sácalos del diagnóstico (scripts/diag_business_882ef5a4.sql, consulta 3).
-- ============================================================================

begin;

do $$
declare
  v_business uuid := '882ef5a4-93eb-4e58-92c3-bf532e179d45';

  -- ▼▼▼ EDITA ESTOS DOS ▼▼▼
  v_code_bar    text := 'bar';
  v_code_cocina text := 'cocina';
  -- ▲▲▲

  v_missing text;
begin
  -- Guarda: las áreas deben existir y estar activas, si no aborta sin tocar nada.
  select string_agg(w.code, ', ') into v_missing
  from (values (v_code_bar), (v_code_cocina)) as w(code)
  where not exists (
    select 1 from public.print_areas a
    where a.business_id = v_business and a.code = w.code and a.is_active
  );

  if v_missing is not null then
    raise exception
      'Faltan áreas de producción activas en este negocio: %. Créalas en '
      'Ajustes → Impresoras → Áreas, o corrige los códigos arriba.', v_missing;
  end if;

  -- 1) Legacy print_area_code — saca a los productos de 'kitchen_hot'
  update public.menu_items mi
  set print_area_code = case s.area when 'cocina' then v_code_cocina
                                    else v_code_bar end
  from public._import_882ef5a4 s
  where mi.business_id = v_business
    and lower(mi.name) = lower(s.name)
    and mi.print_area_code is distinct from
        (case s.area when 'cocina' then v_code_cocina else v_code_bar end);

  -- 2a) N:M — borra asignaciones que NO son el área objetivo.
  --     Sin esto, un producto con un área vieja se rutea a DOS impresoras.
  delete from public.menu_item_print_areas mipa
  using public.menu_items mi
  join public._import_882ef5a4 s on lower(s.name) = lower(mi.name)
  where mipa.menu_item_id = mi.id
    and mi.business_id = v_business
    and mipa.print_area_id <> (
      select a.id from public.print_areas a
      where a.business_id = v_business
        and a.code = case s.area when 'cocina' then v_code_cocina
                                 else v_code_bar end
    );

  -- 2b) N:M — asigna la correcta
  insert into public.menu_item_print_areas (menu_item_id, print_area_id)
  select mi.id, a.id
  from public.menu_items mi
  join public._import_882ef5a4 s on lower(s.name) = lower(mi.name)
  join public.print_areas a
    on a.business_id = mi.business_id
   and a.code = case s.area when 'cocina' then v_code_cocina else v_code_bar end
  where mi.business_id = v_business
    and not exists (
      select 1 from public.menu_item_print_areas x
      where x.menu_item_id = mi.id and x.print_area_id = a.id
    );
end $$;

commit;

-- ============================================================================
-- VERIFICACIÓN — esperado: barra 1500 · cocina 16
-- ============================================================================

select a.code, a.name, count(mipa.menu_item_id) as productos
from public.print_areas a
left join public.menu_item_print_areas mipa on mipa.print_area_id = a.id
left join public.menu_items mi on mi.id = mipa.menu_item_id and mi.is_active
where a.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid
group by a.code, a.name
order by a.code;

-- RED FLAGS — las tres deben dar 0 filas.
-- r1: productos apuntando a un área que no existe (ej. 'kitchen_hot')
select mi.name, mi.print_area_code
from public.menu_items mi
where mi.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid and mi.is_active
  and not exists (
    select 1 from public.print_areas a
    where a.business_id = mi.business_id and a.code = mi.print_area_code
      and a.is_active
  );

-- r2: productos sin asignación N:M
select mi.name
from public.menu_items mi
where mi.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid and mi.is_active
  and not exists (
    select 1 from public.menu_item_print_areas x where x.menu_item_id = mi.id
  );

-- r3: legacy y N:M en desacuerdo (rutearían distinto si falla la red)
select mi.name, mi.print_area_code as legacy, a.code as nm
from public.menu_items mi
join public.menu_item_print_areas mipa on mipa.menu_item_id = mi.id
join public.print_areas a on a.id = mipa.print_area_id
where mi.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid and mi.is_active
  and a.code is distinct from mi.print_area_code;

-- ============================================================================
-- SIGUIENTE PASO: cada área necesita impresora asignada, si no la comanda se
-- genera pero no sale por ningún lado. Se configura en Ajustes → Impresoras.
--   select a.code, count(pap.printer_id) as impresoras
--   from public.print_areas a
--   left join public.print_area_printers pap on pap.area_id = a.id
--   where a.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45' group by a.code;
-- ============================================================================
