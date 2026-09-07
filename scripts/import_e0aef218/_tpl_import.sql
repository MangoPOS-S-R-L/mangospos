-- ============================================================================
-- BARRA PAYÁN BEIBOLISTA — CARGA COMPLETA DEL CATÁLOGO
-- Business e0aef218-ab95-4ba4-b8ef-036fab1c07c7
--
-- Fuente: fotos del menú impreso (2026-09-07).
-- Generado por scripts/build_import_e0aef218.py — NO EDITAR A MANO.
-- (para cambiar precios o productos, edita el .py y regenera)
-- ============================================================================
--
-- QUÉ CARGA
--   {{N}} productos · {{N_CATS}} categorías · {{N_MODS}} modificadores
--   SANDWICHERA {{N_SANDWICHERA}}  ·  JUGUERA {{N_JUGUERA}}
--
-- CÓMO CORRERLO
--   Pégalo entero en el SQL Editor de Supabase y dale Run. Una sola vez.
--
-- TODO O NADA
--   Va en UNA transacción con verificación final adentro: si al terminar no
--   quedan exactamente {{N}} productos, todos con ITBIS y todos con área, el
--   script lanza excepción y REVIERTE ENTERO. Es imposible que deje el
--   catálogo a medias.
--
-- SE PUEDE RE-CORRER
--   Inserta por NOT EXISTS contra lower(name). Correrlo dos veces no duplica.
--   OJO: tampoco actualiza precios ya cargados — para eso está
--   07_ajuste_precios.sql.
--
-- IMPUESTOS: el menú dice "impuestos incluidos", así que los {{N}} entran con
--   tax_mode='inclusive' y vinculados al ITBIS 18%. El Club Sándwich de $450
--   se cobra $450 y el ITBIS se desglosa hacia adentro (base 381.36 +
--   ITBIS 68.64). Verificado contra fn_compute_item_totals:
--   subtotal = line_amount / (1 + rate/100).
--   Si entrara como 'exclusive' el POS cobraría $531 y el menú sería mentira.
--
--   El vínculo en menu_item_taxes NO es cosmético: esa tabla es la ÚNICA
--   fuente del impuesto por producto desde el PRD 2.5 (ya no hay fallback a
--   default_tax_rate). Un producto sin fila ahí factura ITBIS 0.00 ante la
--   DGII aunque el impuesto exista y esté activo.
--
-- LEY 10%: no se cobra en este negocio. No se vincula ningún impuesto de
--   servicio, y las guardas abortan si alguien encendió is_service_fee o
--   business_settings.service_fee_enabled.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0) El catálogo, en una tabla temporal que muere con la transacción.
-- ---------------------------------------------------------------------------

create temp table _payan (
  categoria text not null,
  name      text not null,
  price     numeric(12,2) not null,
  descr     text,
  is_bev    boolean not null,
  posicion  int not null,
  area      text not null
) on commit drop;

insert into _payan (categoria, name, price, descr, is_bev, posicion, area) values
  {{VALS}};

do $$
declare
  v_business uuid := 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7';
  v_tax_name text := 'ITBIS';
  v_tax_id   uuid;
  v_tax_rate numeric;
  v_matches  int;
  v_group    uuid;
  v_missing  text;
  v_n        int;
begin
  -- =========================================================================
  -- 1) GUARDAS — todo se comprueba ANTES de escribir una sola fila.
  -- =========================================================================

  -- 1a) El negocio existe.
  if not exists (select 1 from public.businesses where id = v_business) then
    raise exception 'El negocio % no existe.', v_business;
  end if;

  -- 1b) El ITBIS existe y es único por nombre.
  select count(*) into v_matches
  from public.taxes where business_id = v_business and name = v_tax_name;

  if v_matches = 0 then
    raise exception
      'No existe un impuesto llamado "%" en este negocio. Créalo en '
      'Ajustes → Impuestos (18 por ciento, activo).', v_tax_name;
  elsif v_matches > 1 then
    raise exception
      'Hay % impuestos llamados "%". Desambigua antes de continuar.',
      v_matches, v_tax_name;
  end if;

  select id, rate into v_tax_id, v_tax_rate
  from public.taxes where business_id = v_business and name = v_tax_name;

  -- 1c) Activo. Inactivo facturaría 0 y además bajaría la tasa efectiva de
  --     los productos inclusive sin avisar.
  if not exists (select 1 from public.taxes
                 where id = v_tax_id and coalesce(is_active, true)) then
    raise exception
      'El impuesto "%" está INACTIVO: facturaría 0. Actívalo primero.',
      v_tax_name;
  end if;

  -- 1d) La tasa es 18.
  if v_tax_rate <> 18 then
    raise exception
      'El impuesto "%" tiene tasa % y se esperaba 18. Corrígela antes de '
      'vincular {{N}} productos.', v_tax_name, v_tax_rate;
  end if;

  -- 1e) is_service_fee apagado. Encendido, el servidor lo mete dentro del
  --     oi.tax consolidado Y el cliente lo suma aparte: cobra dos veces.
  if exists (select 1 from public.taxes
             where id = v_tax_id and coalesce(is_service_fee, false)) then
    raise exception
      'El impuesto "%" tiene is_service_fee = true. Así la factura lo cobra '
      'DOS veces. Apágalo antes de cargar el catálogo.', v_tax_name;
  end if;

  -- 1f) La propina por orden apagada: Barra Payán no cobra Ley 10%.
  if exists (select 1 from public.business_settings
             where business_id = v_business
               and coalesce(service_fee_enabled, false)) then
    raise exception
      'business_settings.service_fee_enabled está en true: cobraría un 10%% '
      'por orden que el menú de Barra Payán no anuncia. Apágalo primero.';
  end if;

  -- 1g) Las dos áreas de comanda existen, activas y con nombre único.
  select string_agg(w.nombre, ', ') into v_missing
  from (values ('SANDWICHERA'), ('JUGUERA')) as w(nombre)
  where not exists (
    select 1 from public.print_areas a
    where a.business_id = v_business and a.name = w.nombre and a.is_active
  );

  if v_missing is not null then
    raise exception
      'Faltan áreas de comanda activas: %. Créalas en Ajustes → Impresoras → '
      'Comandas por impresora con ese nombre exacto.', v_missing;
  end if;

  select string_agg(a.name, ', ') into v_missing
  from public.print_areas a
  where a.business_id = v_business and a.is_active
    and a.name in ('SANDWICHERA', 'JUGUERA')
  group by a.name having count(*) > 1;

  if v_missing is not null then
    raise exception 'Áreas activas con nombre repetido: %.', v_missing;
  end if;

  -- =========================================================================
  -- 2) CATEGORÍAS
  -- =========================================================================

  insert into public.categories (id, business_id, name, position, is_active)
  select gen_random_uuid(), v_business, c.name, c.pos, true
  from (values
    {{CATS}}
  ) as c(name, pos)
  where not exists (
    select 1 from public.categories x
    where x.business_id = v_business and x.name = c.name
  );

  -- =========================================================================
  -- 3) PRODUCTOS
  --    is_beverage = true en jugos y bebidas: lo usan los reportes y el
  --    ruteo de comandas para separar barra de cocina.
  -- =========================================================================

  insert into public.menu_items (
    id, business_id, category_id, name, description, price,
    tax_mode, is_active, is_beverage, position
  )
  select gen_random_uuid(), v_business, cat.id, s.name, s.descr, s.price,
         'inclusive', true, s.is_bev, s.posicion
  from _payan s
  join public.categories cat
    on cat.business_id = v_business and cat.name = s.categoria
  where not exists (
    select 1 from public.menu_items m
    where m.business_id = v_business and lower(m.name) = lower(s.name)
  );

  -- =========================================================================
  -- 4) ITBIS — sin esto la factura sale con ITBIS 0.00 ante la DGII.
  -- =========================================================================

  insert into public.menu_item_taxes (item_id, tax_id)
  select mi.id, v_tax_id
  from public.menu_items mi
  where mi.business_id = v_business and mi.is_active
    and not exists (
      select 1 from public.menu_item_taxes x
      where x.item_id = mi.id and x.tax_id = v_tax_id
    );

  -- =========================================================================
  -- 5) ÁREAS DE COMANDA — se escriben LOS DOS mecanismos, a propósito:
  --      a) menu_item_print_areas (N:M) — fuente de verdad del orchestrator.
  --      b) menu_items.print_area_code (legacy) — fn_add_item_from_menu lo
  --         COPIA al order_item, y ese valor es el fallback. El lookup N:M
  --         tiene timeout online; sin el legacy correcto, un bache de red
  --         manda los sándwiches a la juguera.
  --    Un producto sin área NO IMPRIME COMANDA.
  -- =========================================================================

  update public.menu_items mi
  set print_area_code = a.code
  from _payan s
  join public.print_areas a
    on a.business_id = v_business and a.name = s.area and a.is_active
  where mi.business_id = v_business
    and lower(mi.name) = lower(s.name)
    and mi.print_area_code is distinct from a.code;

  -- Borra asignaciones que NO son el área objetivo: si no, un producto con
  -- área vieja se rutearía a DOS impresoras.
  delete from public.menu_item_print_areas mipa
  using public.menu_items mi
  join _payan s on lower(s.name) = lower(mi.name)
  join public.print_areas destino
    on destino.business_id = mi.business_id and destino.name = s.area
   and destino.is_active
  where mipa.menu_item_id = mi.id
    and mi.business_id = v_business
    and mipa.print_area_id <> destino.id;

  insert into public.menu_item_print_areas (menu_item_id, print_area_id)
  select mi.id, a.id
  from public.menu_items mi
  join _payan s on lower(s.name) = lower(mi.name)
  join public.print_areas a
    on a.business_id = mi.business_id and a.name = s.area and a.is_active
  where mi.business_id = v_business
    and not exists (
      select 1 from public.menu_item_print_areas x
      where x.menu_item_id = mi.id and x.print_area_id = a.id
    );

  -- =========================================================================
  -- 6) ADICIONALES, como grupo de modificadores de los sándwiches.
  --    Así el extra viaja pegado al sándwich —sale debajo de su ítem en la
  --    comanda de la SANDWICHERA— en vez de ser una línea suelta que el
  --    cocinero no sabe a cuál de los tres sándwiches de la mesa pertenece.
  --    El price_delta hereda el tratamiento del padre: fn_compute_item_totals
  --    suma mods_total ANTES de extraer el impuesto, así que los adicionales
  --    también quedan con el ITBIS dentro.
  -- =========================================================================

  select id into v_group from public.modifier_groups
  where business_id = v_business and name = 'Adicionales';

  if v_group is null then
    v_group := gen_random_uuid();
    insert into public.modifier_groups
      (id, business_id, name, min_select, max_select, is_active, sort_order)
    values (v_group, v_business, 'Adicionales', 0, {{N_MODS}}, true, 0);
  end if;

  insert into public.modifiers
    (id, business_id, group_id, name, price_delta, is_active, sort_order)
  select gen_random_uuid(), v_business, v_group, m.name, m.delta, true, m.orden
  from (values
    {{MODS}}
  ) as m(name, delta, orden)
  where not exists (
    select 1 from public.modifiers x
    where x.group_id = v_group and lower(x.name) = lower(m.name)
  );

  insert into public.menu_item_groups (menu_item_id, group_id)
  select mi.id, v_group
  from public.menu_items mi
  join (values
    {{SANDWICHES}}
  ) as w(nombre) on lower(w.nombre) = lower(mi.name)
  where mi.business_id = v_business and mi.is_active
    and not exists (
      select 1 from public.menu_item_groups x
      where x.menu_item_id = mi.id and x.group_id = v_group
    );

  -- =========================================================================
  -- 7) VERIFICACIÓN DENTRO DE LA TRANSACCIÓN.
  --    Cualquier fallo aquí revierte TODO lo de arriba.
  -- =========================================================================

  -- Todos los del menú entraron. Se comprueba contra la lista, no contra el
  -- total del negocio: así un producto añadido a mano después no rompe un
  -- re-run del script.
  select count(*) into v_n
  from _payan s
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and lower(mi.name) = lower(s.name)
  );
  if v_n > 0 then
    raise exception '% productos del menú no entraron. Revertido.', v_n;
  end if;

  -- Ninguno sin impuesto: si no, facturaría ITBIS 0 ante la DGII.
  select count(*) into v_n
  from public.menu_items mi
  where mi.business_id = v_business and mi.is_active
    and not exists (select 1 from public.menu_item_taxes x where x.item_id = mi.id);
  if v_n > 0 then
    raise exception '% productos quedaron SIN ITBIS. Revertido.', v_n;
  end if;

  -- Ninguno sin área: si no, no imprime comanda.
  select count(*) into v_n
  from public.menu_items mi
  where mi.business_id = v_business and mi.is_active
    and not exists (select 1 from public.menu_item_print_areas x
                    where x.menu_item_id = mi.id);
  if v_n > 0 then
    raise exception '% productos quedaron SIN ÁREA de comanda. Revertido.', v_n;
  end if;

  -- Ninguno apuntando a un código de área inexistente: con un código que el
  -- negocio no tiene, "Enviar a cocina" revienta y NO sale NINGUNA comanda
  -- de la orden entera.
  select count(*) into v_n
  from public.menu_items mi
  where mi.business_id = v_business and mi.is_active
    and (mi.print_area_code is null
         or not exists (select 1 from public.print_areas a
                        where a.business_id = mi.business_id
                          and a.code = mi.print_area_code and a.is_active));
  if v_n > 0 then
    raise exception
      '% productos apuntan a un área inexistente (legacy). Revertido.', v_n;
  end if;

  -- Legacy y N:M de acuerdo: si divergen, rutearían distinto según la red.
  select count(*) into v_n
  from public.menu_items mi
  join public.menu_item_print_areas mipa on mipa.menu_item_id = mi.id
  join public.print_areas a on a.id = mipa.print_area_id
  where mi.business_id = v_business and mi.is_active
    and a.code is distinct from mi.print_area_code;
  if v_n > 0 then
    raise exception
      '% productos con legacy y N:M en desacuerdo. Revertido.', v_n;
  end if;

  -- Ninguno en 'exclusive': cobraría 18 por ciento ENCIMA del precio del menú.
  select count(*) into v_n
  from public.menu_items
  where business_id = v_business and is_active and tax_mode <> 'inclusive';
  if v_n > 0 then
    raise exception
      '% productos quedaron en exclusive y cobrarían de más. Revertido.', v_n;
  end if;

  -- Nombres únicos: el cajero no sabría cuál teclear.
  select count(*) into v_n from (
    select 1 from public.menu_items
    where business_id = v_business and is_active
    group by lower(name) having count(*) > 1
  ) d;
  if v_n > 0 then
    raise exception '% nombres duplicados. Revertido.', v_n;
  end if;

  -- Los sándwiches con su grupo de adicionales.
  select count(*) into v_n
  from public.menu_item_groups mig
  join public.modifier_groups g on g.id = mig.group_id
  where g.business_id = v_business and g.name = 'Adicionales';
  if v_n <> {{N_SAND}} then
    raise exception
      'Se esperaban {{N_SAND}} sándwiches con adicionales y hay %. Revertido.', v_n;
  end if;

  raise notice 'OK — {{N}} productos, todos con ITBIS y área. Commit.';
end $$;

commit;

-- ============================================================================
-- REPORTE — así quedó el catálogo
-- ============================================================================

select 'productos'                 as concepto, count(*) as encontrado, {{N}} as esperado
  from public.menu_items where business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid and is_active
union all
select 'categorías', count(*), {{N_CATS}}
  from public.categories where business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
union all
select 'con ITBIS', count(distinct mit.item_id), {{N}}
  from public.menu_item_taxes mit
  join public.menu_items mi on mi.id = mit.item_id and mi.is_active
  where mi.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
union all
select 'con área', count(distinct mipa.menu_item_id), {{N}}
  from public.menu_item_print_areas mipa
  join public.menu_items mi on mi.id = mipa.menu_item_id and mi.is_active
  where mi.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
union all
select 'modificadores', count(*), {{N_MODS}}
  from public.modifiers m join public.modifier_groups g on g.id = m.group_id
  where g.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid and m.is_active
union all
select 'sándwiches con adicionales', count(*), {{N_SAND}}
  from public.menu_item_groups mig
  join public.modifier_groups g on g.id = mig.group_id
  where g.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid;

-- Reparto por área — esperado: JUGUERA {{N_JUGUERA}} · SANDWICHERA {{N_SANDWICHERA}}
select a.name as area, a.code, count(mipa.menu_item_id) as productos
from public.print_areas a
left join public.menu_item_print_areas mipa on mipa.print_area_id = a.id
left join public.menu_items mi on mi.id = mipa.menu_item_id and mi.is_active
where a.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
group by a.name, a.code order by a.name;

-- El catálogo completo, para cotejar contra el menú impreso.
-- La columna itbis muestra lo que se declara a la DGII de cada precio.
select c.position as orden, c.name as categoria, mi.name as producto,
       mi.price as paga_el_cliente,
       round(mi.price / 1.18, 2) as base_gravada,
       round(mi.price - (mi.price / 1.18), 2) as itbis,
       a.name as area
from public.menu_items mi
join public.categories c on c.id = mi.category_id
left join public.menu_item_print_areas mipa on mipa.menu_item_id = mi.id
left join public.print_areas a on a.id = mipa.print_area_id
where mi.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid and mi.is_active
order by c.position, mi.position;

-- ============================================================================
-- ⚠ FALTA FUERA DE SQL: JUGUERA y SANDWICHERA no tienen impresora vinculada.
--   Con auto_print_order = true, el POS va a intentar imprimir la comanda en
--   cada orden y no va a salir por ningún lado. Vincúlalas en
--   Ajustes → Impresoras → Comandas por impresora → Agregar impresora.
-- ============================================================================
