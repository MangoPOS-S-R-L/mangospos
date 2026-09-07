-- =============================================================================
-- Areas de produccion ECODOME VILLAGE — Business 528df61f-7136-4591-9e87-ee19f5882037
-- Correr DESPUES de scripts/IMPORT_ecodome_528df61f.sql
--
-- POR QUE HACE FALTA:
--   Un producto insertado por SQL queda con print_area_code = NULL. Sin
--   area, "Enviar a cocina" se bloquea y NO sale ninguna comanda — falla
--   callado hasta que alguien intenta imprimir.
--
-- CREA LAS DOS AREAS si no existen: `cocina` (Cocina) y `bar` (Barra),
-- y despues les asigna los 42 productos. Si ya existen, las reusa tal cual.
--
-- CANDADO: solo crea si el negocio NO tiene ninguna area activa. Si ya
--   tiene areas y no estan las dos mias, ABORTA y te las lista — incluso
--   si calza una sola: crear la que falta al lado de un `barra` que ya
--   hace ese papel deja 33 productos apuntando a un area nueva y vacia.
--   El code lo genera la app desde el nombre: Cocina -> cocina, Bar -> bar,
--   Barra -> barra, y `_2` si choca. Pon los reales en el bloque 1.
--
-- LO QUE NO HACE: pegarle una impresora a cada area. Un area sin impresora
--   acepta el producto pero la comanda NO sale. Eso se configura en
--   Ajustes -> Areas de impresion, o con el bloque comentado del final.
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
-- 1) LAS DOS AREAS — se CREAN si no existen. Cambia `name`/`code` aqui
--    si el negocio las llama de otra forma.
-- ---------------------------------------------------------------------------
create temp table _area_cfg (rol text primary key, code text, name text) on commit drop;
insert into _area_cfg (rol, code, name) values
  ('K', 'cocina', 'Cocina'),   -- area de COCINA
  ('B', 'bar',    'Barra');    -- area de BARRA

do $$
declare
  v_business  uuid := '528df61f-7136-4591-9e87-ee19f5882037';
  v_activas   int;
  v_nuestras  int;
  v_otras     text;
  v_faltan    text;
  v_creadas   text;
begin
  -- Reactiva primero: un area NUESTRA apagada cuenta como existente, si no
  -- rutearia a un area desactivada y el control daria sin_area_nm > 0.
  update public.print_areas a
     set is_active = true
    from _area_cfg cfg
   where a.business_id = v_business and a.code = cfg.code
     and not coalesce(a.is_active, true);

  select count(*) into v_activas
  from public.print_areas a
  where a.business_id = v_business and coalesce(a.is_active, true);

  select count(*) into v_nuestras
  from public.print_areas a
  join _area_cfg cfg on cfg.code = a.code
  where a.business_id = v_business and coalesce(a.is_active, true);

  -- CANDADO. Solo hay dos caminos limpios: el negocio no tiene NINGUNA
  -- area activa (las creamos), o ya tiene LAS DOS nuestras (las reusamos).
  -- Cualquier mezcla aborta: crear la que falta al lado de un area que ya
  -- hace ese papel con otro nombre (Barra -> code `barra`) deja el ruteo
  -- partido y 33 productos apuntando a un area nueva y vacia.
  if v_activas > 0 and v_nuestras < (select count(*) from _area_cfg) then
    select string_agg(a.code || ' (' || a.name || ')', ', ' order by a.code)
      into v_otras
    from public.print_areas a
    where a.business_id = v_business and coalesce(a.is_active, true);

    select string_agg(cfg.code, ', ' order by cfg.code)
      into v_faltan
    from _area_cfg cfg
    where not exists (
      select 1 from public.print_areas a
      where a.business_id = v_business and a.code = cfg.code
        and coalesce(a.is_active, true)
    );

    raise exception 'El negocio ya tiene estas areas activas: %. De las mias faltan: %. Pon los codes REALES en el bloque 1 y vuelve a correr (el code lo genera la app desde el nombre: Cocina -> cocina, Barra -> barra).', v_otras, v_faltan;
  end if;

  with ins as (
    insert into public.print_areas (business_id, name, code, is_active)
    select v_business, cfg.name, cfg.code, true
    from _area_cfg cfg
    where not exists (
      select 1 from public.print_areas a
      where a.business_id = v_business and a.code = cfg.code
    )
    returning code
  )
  select string_agg(code, ', ' order by code) into v_creadas from ins;
  raise notice 'Areas creadas: %', coalesce(v_creadas, '(ninguna: ya existian, se reusan)');
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

-- Las areas que quedaron. impr_comandas = 0 -> el area acepta el producto
-- pero la comanda NO sale: hay que pegarle una impresora.
select a.code, a.name, a.is_active,
       (select count(*) from public.print_area_printers pp
         where pp.area_id = a.id) as impresoras,
       (select count(*) from public.print_area_printers pp
         where pp.area_id = a.id and pp.enabled and pp.prints_orders) as impr_comandas
from public.print_areas a
where a.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
order by a.code;

commit;


-- ---------------------------------------------------------------------------
-- OPCIONAL — pegarle una impresora a un area, si no la configuras por la app.
-- Descomenta y pon el nombre exacto de la impresora y el code del area.
-- ---------------------------------------------------------------------------
-- insert into public.print_area_printers
--   (business_id, area_id, printer_id, priority, enabled, prints_orders, prints_prebills, prints_receipts)
-- select p.business_id, a.id, p.id, 1, true, true, false, false
-- from public.printers p
-- join public.print_areas a
--   on a.business_id = p.business_id and a.code = 'cocina'   -- << el area
-- where p.business_id = '528df61f-7136-4591-9e87-ee19f5882037'::uuid
--   and p.name = 'NOMBRE EXACTO DE LA IMPRESORA'             -- << la impresora
--   and not exists (select 1 from public.print_area_printers pp
--                    where pp.area_id = a.id and pp.printer_id = p.id);
