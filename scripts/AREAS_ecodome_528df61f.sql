-- =============================================================================
-- Areas de produccion ECODOME VILLAGE — Business 528df61f-7136-4591-9e87-ee19f5882037
-- Correr DESPUES de scripts/IMPORT_ecodome_528df61f.sql
--
-- POR QUE HACE FALTA:
--   Un producto insertado por SQL queda con print_area_code = NULL. Sin
--   area, "Enviar a cocina" se bloquea y NO sale ninguna comanda — falla
--   callado hasta que alguien intenta imprimir.
--
-- >> ANTES DE CORRER: pon abajo los CODES reales de las areas del negocio.
--    Miralos con scripts/AREAS_diagnostico_528df61f.sql, o con:
--      select code, name, is_active from public.print_areas
--       where business_id = '528df61f-7136-4591-9e87-ee19f5882037';
--    Si un code no existe, el script aborta y te dice cuales hay.
--
-- REPARTO: cocina 9 (todo lo de `Comida`) | barra 33 (todo lo demas).
--   No hay combos de dos areas en este catalogo.
--
-- ESCRIBE LOS DOS MECANISMOS, A PROPOSITO:
--   1. menu_item_print_areas (N:M) — fuente de verdad.
--   2. menu_items.print_area_code (legacy) — NO es redundante:
--      fn_add_item_from_menu lo copia al order_item y se salta el lookup
--      N:M entero. Solo con N:M, un bache de red rutea mal.
--
-- CONVERGENTE: re-ejecutarlo deja el mismo estado.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- >> 1) CODES DE LAS AREAS — AJUSTA ESTOS DOS VALORES
-- ---------------------------------------------------------------------------
create temp table _area_cfg (rol text primary key, code text) on commit drop;
insert into _area_cfg (rol, code) values
  ('K', 'cocina'),   -- area de COCINA
  ('B', 'bar');      -- area de BARRA

do $$
declare
  v_business uuid := '528df61f-7136-4591-9e87-ee19f5882037';
  v_missing  text;
  v_have     text;
begin
  select string_agg(cfg.code, ', ')
    into v_missing
  from _area_cfg cfg
  where not exists (
    select 1 from public.print_areas a
    where a.business_id = v_business and a.code = cfg.code
      and coalesce(a.is_active, true)
  );
  if v_missing is not null then
    select string_agg(a.code || ' (' || a.name || ')', ', ' order by a.code)
      into v_have
    from public.print_areas a
    where a.business_id = v_business and coalesce(a.is_active, true);
    raise exception 'No existen estas areas: %. El negocio tiene: %', v_missing, coalesce(v_have, '(ninguna)');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2) Ruteo sku -> area
-- ---------------------------------------------------------------------------
create temp table _route (sku text primary key, areas text) on commit drop;
insert into _route (sku, areas) values
  ('10020', 'B'),
  ('10030', 'B'),
  ('10033', 'B'),
  ('10014', 'B'),
  ('10005', 'B'),
  ('10013', 'B'),
  ('10023', 'B'),
  ('10029', 'B'),
  ('10025', 'K'),
  ('10024', 'K'),
  ('10018', 'B'),
  ('10009', 'B'),
  ('10036', 'B'),
  ('10016', 'B'),
  ('10041', 'B'),
  ('10011', 'B'),
  ('10015', 'B'),
  ('10002', 'B'),
  ('10022', 'B'),
  ('10021', 'B'),
  ('10003', 'B'),
  ('10004', 'B'),
  ('10017', 'B'),
  ('10032', 'K'),
  ('10031', 'K'),
  ('10035', 'K'),
  ('10034', 'K'),
  ('10001', 'B'),
  ('10027', 'K'),
  ('10026', 'K'),
  ('10028', 'K'),
  ('10000', 'B'),
  ('10037', 'B'),
  ('10012', 'B'),
  ('10039', 'B'),
  ('10040', 'B'),
  ('10010', 'B'),
  ('10019', 'B'),
  ('10038', 'B'),
  ('10007', 'B'),
  ('10006', 'B'),
  ('10008', 'B');

create temp table _target on commit drop as
select mi.id as menu_item_id, a.id as print_area_id
from public.menu_items mi
join _route r on r.sku = mi.sku
join _area_cfg cfg on r.areas like '%' || cfg.rol || '%'
join lateral (
  select a2.id from public.print_areas a2
  where a2.business_id = mi.business_id and a2.code = cfg.code
    and coalesce(a2.is_active, true)
  order by a2.created_at asc limit 1
) a on true
where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid;

-- ---------------------------------------------------------------------------
-- 3) N:M — borra lo que sobra, inserta lo que falta
-- ---------------------------------------------------------------------------
delete from public.menu_item_print_areas mipa
using public.menu_items mi
join _route r on r.sku = mi.sku
where mipa.menu_item_id = mi.id
  and mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
  and not exists (
    select 1 from _target t
    where t.menu_item_id = mipa.menu_item_id
      and t.print_area_id = mipa.print_area_id
  );

insert into public.menu_item_print_areas (menu_item_id, print_area_id)
select t.menu_item_id, t.print_area_id from _target t
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 4) Legacy print_area_code + is_beverage (bebida = todo lo que va a barra)
-- ---------------------------------------------------------------------------
update public.menu_items mi
set print_area_code = cfg.code,
    is_beverage     = (r.areas = 'B'),
    updated_at      = now()
from _route r
join _area_cfg cfg
  on cfg.rol = case when r.areas like '%K%' then 'K' else 'B' end
where mi.sku = r.sku
  and mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
  and (mi.print_area_code is distinct from cfg.code
       or mi.is_beverage is distinct from (r.areas = 'B'));

-- ---------------------------------------------------------------------------
-- 5) Control. Esperado: sin_area_nm = 0, code_inexistente = 0,
--    catalogo_entero_sin_area = 0 (cuenta TODO el negocio, no solo el
--    archivo: si sale > 0 hay productos que no imprimen comanda).
-- ---------------------------------------------------------------------------
select
  (select count(*) from _route) as en_archivo,
  (select count(*) from public.menu_items mi join _route r on r.sku = mi.sku
    where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
      and not exists (select 1 from public.menu_item_print_areas p where p.menu_item_id = mi.id)
   ) as sin_area_nm,
  (select count(*) from public.menu_items mi
    where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
      and mi.print_area_code is not null
      and not exists (select 1 from public.print_areas a
                       where a.business_id = mi.business_id and a.code = mi.print_area_code)
   ) as code_inexistente,
  (select count(*) from public.menu_items mi
    where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
      and coalesce(mi.print_area_code, '') = ''
      and not exists (select 1 from public.menu_item_print_areas p where p.menu_item_id = mi.id)
   ) as catalogo_entero_sin_area;

-- Reparto final, para leerlo de un vistazo.
select a.code as area, count(*) as productos
from public.menu_item_print_areas x
join public.print_areas a on a.id = x.print_area_id
join public.menu_items mi on mi.id = x.menu_item_id
where mi.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
group by a.code order by a.code;

commit;
