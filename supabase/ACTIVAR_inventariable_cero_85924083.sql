-- =============================================================================
-- TODOS los productos INVENTARIABLES y con stock en CERO
-- business_id = 85924083-2e8e-4e64-8192-808ee24674ed          (2026-10-01)
--
-- QUÉ HACE (paso 2), producto por producto, lo mismo que el switch
-- "Inventariable" de la app (fn_menu_item_set_inventory_tracked, 20260613_0002):
--   · CON receta real → solo prende el flag; descuenta por sus ingredientes.
--     Los ingredientes NO se ponen en cero (pueden ser materia prima
--     compartida: el pollo de 12 platos).
--   · SIN receta → busca su insumo (mismo nombre; si no, mismo SKU) o lo
--     crea, y lo enlaza DIRECTO en menu_items.inventory_item_id.
--   · A todos: "Vender aunque esté agotado" (allow_negative_sale = true).
--     Sin esto el POS bloquea el producto ("está agotado") con stock 0.
--     Decisión del dueño: seguir vendiendo; el stock baja a negativo hasta
--     que entren compras o un conteo.
--   · Reactiva los que el auto-86 había ocultado por falta de stock.
--   · Stock en CERO: un movimiento 'adjustment' (motivo Corrección) por cada
--     bodega donde el insumo propio del producto tenga existencia ≠ 0. Queda
--     en el Kardex y es reversible. No toca la bodega __IN_TRANSIT__.
--
-- NO TOCA: combos (sus componentes ya descuentan; inventariar el combo
--   descontaría DOS veces), productos inactivos, ni el modo de inventario
--   del negocio. OJO: si el modo es 'none' NO se descuenta NADA al vender
--   aunque todo quede inventariable → activarlo en Configuración.
--
-- POR QUÉ NO SE LLAMA AL RPC: exige auth.uid() con rol owner/admin/manager;
--   desde el SQL Editor no hay uid y revienta con INSUFFICIENT_ROLE.
--
-- CÓMO CORRER: cada paso por separado (el SQL Editor solo muestra el
--   resultado de la última consulta). 1 → mirar → 2. El 3 solo si hay que
--   deshacer.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- PASO 1 — DIAGNÓSTICO (solo lectura). Una sola tabla.
-- ---------------------------------------------------------------------------
with prod as (
  select m.*,
         exists (
           select 1
           from public.recipes r
           join public.recipe_ingredients ri on ri.recipe_id = r.id
           where r.menu_item_id = m.id
             and ri.inventory_item_id is not null
             and coalesce(ri.quantity, 0) > 0
         ) as tiene_receta,
         exists (
           select 1 from public.recipes r where r.menu_item_id = m.id
         ) as tiene_fila_receta
  from public.menu_items m
  where m.business_id = '85924083-2e8e-4e64-8192-808ee24674ed'
),
alcance as (
  select * from prod
  where coalesce(item_type, 'standard') <> 'combo'
    and (is_active or auto_disabled)
),
sin_receta as (
  select a.*,
         (select ii.id
            from public.inventory_items ii
           where ii.business_id = a.business_id
             and coalesce(ii.is_active, true)
             and (lower(btrim(ii.name)) = lower(btrim(a.name))
                  or (nullif(btrim(a.sku), '') is not null
                      and nullif(btrim(ii.sku), '') = btrim(a.sku)))
           order by (lower(btrim(ii.name)) = lower(btrim(a.name))) desc,
                    ii.created_at asc, ii.id
           limit 1) as insumo_existente
  from alcance a
  where not a.tiene_receta
),
-- Self-recipe viejo: 1 ingrediente × 1 con el mismo nombre del producto.
self_recipe as (
  select ri.inventory_item_id as item_id
  from alcance a
  join public.recipes rc on rc.menu_item_id = a.id
  join public.recipe_ingredients ri on ri.recipe_id = rc.id
  join public.inventory_items ii on ii.id = ri.inventory_item_id
  where ri.quantity = 1
    and lower(btrim(ii.name)) = lower(btrim(a.name))
    and (select count(*)
           from public.recipes rc2
           join public.recipe_ingredients ri2 on ri2.recipe_id = rc2.id
          where rc2.menu_item_id = a.id
            and ri2.inventory_item_id is not null
            and coalesce(ri2.quantity, 0) > 0) = 1
),
stock_propio as (
  select st.item_id, st.quantity
  from public.inventory_stock st
  join public.warehouses w on w.id = st.warehouse_id
  where w.business_id = '85924083-2e8e-4e64-8192-808ee24674ed'
    and w.name is distinct from '__IN_TRANSIT__'
    and coalesce(st.quantity, 0) <> 0
    and st.item_id in (select coalesce(inventory_item_id, insumo_existente)
                         from sin_receta
                        where not tiene_fila_receta
                       union
                       select item_id from self_recipe)
)
select orden, dato, valor from (
  select 1 as orden, 'Negocio' as dato,
         coalesce((select business_name || coalesce(' — ' || branch_name, '')
                     from public.businesses
                    where id = '85924083-2e8e-4e64-8192-808ee24674ed'),
                  '¡NO EXISTE!') as valor
  union all
  select 2, 'Modo de inventario (none = al vender NO se descuenta nada)',
         coalesce((select inventory_mode from public.business_settings
                    where business_id = '85924083-2e8e-4e64-8192-808ee24674ed'),
                  'none (sin fila en business_settings)')
  union all
  select 3, 'Bodegas activas',
         (select count(*)::text from public.warehouses w
           where w.business_id = '85924083-2e8e-4e64-8192-808ee24674ed'
             and coalesce(w.is_active, true)
             and w.name is distinct from '__IN_TRANSIT__')
  union all
  select 4, 'Productos EN ALCANCE (activos u ocultos por auto-86, sin combos)',
         count(*)::text from alcance
  union all
  select 5, '  … ya inventariables', count(*)::text from alcance where is_inventory_tracked
  union all
  select 6, '  … con receta (solo se prende el flag)', count(*)::text from alcance where tiene_receta
  union all
  select 7, '  … sin receta, ya enlazados a su insumo',
         count(*)::text from sin_receta where inventory_item_id is not null
  union all
  select 8, '  … sin receta, reusarán un insumo existente (nombre/SKU)',
         count(*)::text from sin_receta where inventory_item_id is null and insumo_existente is not null
  union all
  select 9, '  … sin receta y sin insumo (productos / insumos a CREAR, uno por nombre)',
         count(*)::text || ' / ' || count(distinct lower(btrim(name)))::text
    from sin_receta where inventory_item_id is null and insumo_existente is null
  union all
  select 10, '  … con receta VACÍA (sin ingredientes: no descontarán)',
         count(*)::text from alcance where tiene_fila_receta and not tiene_receta
  union all
  select 11, '  … ocultos hoy por auto-86 (se reactivan)',
         count(*)::text from alcance where not is_active and auto_disabled
  union all
  select 12, '  … ya con "Vender aunque esté agotado"',
         count(*)::text from alcance where allow_negative_sale
  union all
  select 13, 'Fuera: combos', count(*)::text from prod where item_type = 'combo'
  union all
  select 14, 'Fuera: inactivos (apagados a mano)',
         count(*)::text from prod
          where coalesce(item_type, 'standard') <> 'combo'
            and not is_active and not auto_disabled
  union all
  select 15, 'Filas de stock ≠ 0 que se pondrán en cero',
         count(*)::text from stock_propio
  union all
  select 16, '  … unidades netas que hoy suman',
         coalesce(sum(quantity), 0)::text from stock_propio
  union all
  select 17, 'Conteos físicos en curso (los insumos nuevos entran solos)',
         (select count(*)::text from public.physical_count_sessions s
           where s.business_id = '85924083-2e8e-4e64-8192-808ee24674ed'
             and s.status = 'in_progress')
) x
order by orden;


-- ---------------------------------------------------------------------------
-- PASO 2 — APLICAR. Seleccionar desde aquí hasta el final del PASO 2.
-- Atómico: si algo falla no queda nada a medias. Re-ejecutable: el respaldo
-- guarda el estado de la PRIMERA corrida (on conflict do nothing).
-- ---------------------------------------------------------------------------
create table if not exists public.zz_backup_inventariable_85924083 (
  menu_item_id              uuid primary key,
  was_tracked               boolean,
  was_inventory_item_id     uuid,
  was_allow_negative_sale   boolean,
  was_is_active             boolean,
  was_auto_disabled         boolean,
  enlace                    text,  -- receta | ya_enlazado | reusa_nombre | reusa_sku | creado
  created_inventory_item_id uuid,
  registrado_en             timestamptz default now()
);

do $$
declare
  c_biz constant uuid := '85924083-2e8e-4e64-8192-808ee24674ed';
  r      record;
  v_ins  uuid;
  v_enl  text;
begin
  for r in
    select m.id, m.name, m.sku, coalesce(m.cost, 0) as cost,
           m.is_inventory_tracked, m.inventory_item_id,
           m.allow_negative_sale, m.is_active, m.auto_disabled,
           exists (
             select 1
             from public.recipes rc
             join public.recipe_ingredients ri on ri.recipe_id = rc.id
             where rc.menu_item_id = m.id
               and ri.inventory_item_id is not null
               and coalesce(ri.quantity, 0) > 0
           ) as tiene_receta
    from public.menu_items m
    where m.business_id = c_biz
      and coalesce(m.item_type, 'standard') <> 'combo'
      and (m.is_active or m.auto_disabled)
    order by m.created_at, m.id
  loop
    v_ins := null;
    v_enl := null;

    if r.tiene_receta then
      v_enl := 'receta';
    elsif r.inventory_item_id is not null then
      v_ins := r.inventory_item_id;
      v_enl := 'ya_enlazado';
    else
      -- Mismo criterio que el RPC (nombre exacto normalizado o SKU exacto),
      -- prefiriendo el NOMBRE: un SKU interno repetido ("001") podría
      -- apuntar a otro artículo, y vender uno descontaría el otro.
      select ii.id,
             case when lower(btrim(ii.name)) = lower(btrim(r.name))
                  then 'reusa_nombre' else 'reusa_sku' end
        into v_ins, v_enl
      from public.inventory_items ii
      where ii.business_id = c_biz
        and coalesce(ii.is_active, true)
        and (lower(btrim(ii.name)) = lower(btrim(r.name))
             or (nullif(btrim(r.sku), '') is not null
                 and nullif(btrim(ii.sku), '') = btrim(r.sku)))
      order by (lower(btrim(ii.name)) = lower(btrim(r.name))) desc,
               ii.created_at asc, ii.id
      limit 1;

      if v_ins is null then
        -- En el bucle (no un INSERT masivo) para que dos productos con el
        -- mismo nombre compartan UNA ficha: el segundo ya encuentra la que
        -- creó el primero.
        insert into public.inventory_items (business_id, sku, name, unit, cost, is_active)
        values (c_biz, nullif(btrim(coalesce(r.sku, '')), ''), r.name, 'unidad', r.cost, true)
        returning id into v_ins;
        v_enl := 'creado';
      end if;
    end if;

    insert into public.zz_backup_inventariable_85924083 (
      menu_item_id, was_tracked, was_inventory_item_id, was_allow_negative_sale,
      was_is_active, was_auto_disabled, enlace, created_inventory_item_id
    )
    values (
      r.id, r.is_inventory_tracked, r.inventory_item_id, r.allow_negative_sale,
      r.is_active, r.auto_disabled, v_enl,
      case when v_enl = 'creado' then v_ins end
    )
    on conflict (menu_item_id) do nothing;

    -- allow_negative_sale ANTES de los ajustes a cero: el auto-86 corre en
    -- cada movimiento y, sin el flag, ocultaría los productos con receta.
    update public.menu_items
       set is_inventory_tracked = true,
           inventory_item_id    = coalesce(v_ins, inventory_item_id),
           allow_negative_sale  = true,
           is_active            = true,
           auto_disabled        = false
     where id = r.id;
  end loop;

  -- Stock en CERO del insumo PROPIO de cada producto: el enlace directo, o
  -- el self-recipe viejo (1 ingrediente × 1 con el mismo nombre del
  -- producto). Las recetas reales no entran.
  with propios as (
    select m.inventory_item_id as item_id
    from public.menu_items m
    join public.zz_backup_inventariable_85924083 b on b.menu_item_id = m.id
    where m.business_id = c_biz
      and m.inventory_item_id is not null
      and not exists (select 1 from public.recipes rc where rc.menu_item_id = m.id)
    union
    select ri.inventory_item_id
    from public.menu_items m
    join public.zz_backup_inventariable_85924083 b on b.menu_item_id = m.id
    join public.recipes rc on rc.menu_item_id = m.id
    join public.recipe_ingredients ri on ri.recipe_id = rc.id
    join public.inventory_items ii on ii.id = ri.inventory_item_id
    where m.business_id = c_biz
      and ri.quantity = 1
      and lower(btrim(ii.name)) = lower(btrim(m.name))
      and (select count(*)
             from public.recipes rc2
             join public.recipe_ingredients ri2 on ri2.recipe_id = rc2.id
            where rc2.menu_item_id = m.id
              and ri2.inventory_item_id is not null
              and coalesce(ri2.quantity, 0) > 0) = 1
  )
  insert into public.inventory_movements (
    business_id, warehouse_id, item_id, movement_type, quantity,
    cost_per_unit, reference_type, reason_code, notes
  )
  select c_biz, st.warehouse_id, st.item_id, 'adjustment', -st.quantity,
         ii.cost, 'reset_cero_20261001', 'correction',
         'Stock puesto en cero: todos los productos inventariables desde cero'
  from public.inventory_stock st
  join public.warehouses w      on w.id = st.warehouse_id
  join public.inventory_items ii on ii.id = st.item_id
  where w.business_id = c_biz
    and w.name is distinct from '__IN_TRANSIT__'
    and coalesce(st.quantity, 0) <> 0
    and st.item_id in (select item_id from propios);
end $$;

-- Reporte (esta es la tabla que muestra el SQL Editor).
select orden, dato, valor from (
  select 1 as orden, 'Productos procesados' as dato, count(*)::text as valor
  from public.zz_backup_inventariable_85924083
  union all
  select 2, '  … ' || enlace, count(*)::text
  from public.zz_backup_inventariable_85924083 group by enlace
  union all
  select 3, 'Insumos creados', count(created_inventory_item_id)::text
  from public.zz_backup_inventariable_85924083
  union all
  select 4, 'Filas de stock puestas en cero',
         count(*)::text from public.inventory_movements
   where business_id = '85924083-2e8e-4e64-8192-808ee24674ed'
     and reference_type = 'reset_cero_20261001'
  union all
  select 5, 'Productos del alcance aún SIN inventariable (debe ser 0)',
         count(*)::text from public.menu_items m
   where m.business_id = '85924083-2e8e-4e64-8192-808ee24674ed'
     and coalesce(m.item_type, 'standard') <> 'combo'
     and m.is_active and not m.is_inventory_tracked
  union all
  select 6, 'Modo de inventario (si es none, activarlo en Configuración)',
         coalesce((select inventory_mode from public.business_settings
                    where business_id = '85924083-2e8e-4e64-8192-808ee24674ed'),
                  'none')
  union all
  -- Enlazados por SKU con OTRO nombre: revisar que sea el mismo artículo.
  select 7, 'REVISAR enlace por SKU: ' || m.name || '  →  ' || ii.name,
         coalesce(m.sku, '')
  from public.zz_backup_inventariable_85924083 b
  join public.menu_items m       on m.id = b.menu_item_id
  join public.inventory_items ii on ii.id = m.inventory_item_id
  where b.enlace = 'reusa_sku'
) x
order by orden, dato;


-- ---------------------------------------------------------------------------
-- PASO 3 — REVERTIR (todo). Quitar los comentarios y correr UNA sola vez.
-- 1) devuelve el stock que se puso en cero (movimiento inverso, Kardex limpio)
-- 2) restaura cada producto como estaba
-- 3) borra los insumos creados que nadie usó (sin movimientos, sin conteo,
--    sin receta). Los que ya se vendieron se quedan: borrarlos falsearía el
--    Kardex.
-- ---------------------------------------------------------------------------
-- do $$
-- begin
--   if exists (select 1 from public.inventory_movements
--               where business_id = '85924083-2e8e-4e64-8192-808ee24674ed'
--                 and reference_type = 'reset_cero_20261001_reverso') then
--     raise exception 'Ya se revirtió una vez';
--   end if;
--
--   insert into public.inventory_movements (
--     business_id, warehouse_id, item_id, movement_type, quantity,
--     cost_per_unit, reference_type, reason_code, notes)
--   select business_id, warehouse_id, item_id, 'adjustment', -quantity,
--          cost_per_unit, 'reset_cero_20261001_reverso', 'correction',
--          'Reverso del stock puesto en cero el 2026-10-01'
--   from public.inventory_movements
--   where business_id = '85924083-2e8e-4e64-8192-808ee24674ed'
--     and reference_type = 'reset_cero_20261001';
--
--   update public.menu_items m
--      set is_inventory_tracked = coalesce(b.was_tracked, false),
--          inventory_item_id    = b.was_inventory_item_id,
--          allow_negative_sale  = coalesce(b.was_allow_negative_sale, false),
--          is_active            = b.was_is_active,
--          auto_disabled        = coalesce(b.was_auto_disabled, false)
--     from public.zz_backup_inventariable_85924083 b
--    where m.id = b.menu_item_id;
--
--   delete from public.inventory_items ii
--    using public.zz_backup_inventariable_85924083 b
--    where ii.id = b.created_inventory_item_id
--      and not exists (select 1 from public.inventory_movements mv where mv.item_id = ii.id)
--      and not exists (select 1 from public.physical_count_lines l where l.item_id = ii.id)
--      and not exists (select 1 from public.recipe_ingredients ri where ri.inventory_item_id = ii.id)
--      and not exists (select 1 from public.menu_items mi where mi.inventory_item_id = ii.id);
-- end $$;
