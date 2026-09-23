-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 4: el mapeo del recetario
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. UNA sola consulta. REQUIERE haber corrido PENDA_PASO6 antes
-- (deja la tabla `_recetario_penda` con las 143 fichas y la función `_norm`).
--
-- Contesta lo único que falta para crear los insumos y cargar las recetas:
--   E1  el resumen de todo
--   E2  LOS INGREDIENTES QUE NO EXISTEN  ← de aquí sale el script de creación
--   E3  los que existen pero con la unidad cambiada (no se pueden convertir)
--   E4  las fichas cuyo producto no está en el menú
--   E5  RIESGO: fichas que casan con un producto que ya tiene vínculo directo.
--       Ponerle receta a uno de esos lo saca de la rama del vínculo directo
--       (`consume_inventory_from_order` hace `not exists recipes`) y pasa a
--       descontar ingredientes en vez de la botella. Esos NO llevan receta.
--   E6  la guarnición: las 22 fichas que la meten dentro del plato
-- =============================================================================

with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),

-- ingrediente del papel -> insumo del sistema (por nombre normalizado)
ing as (
  -- Se agrupa por el nombre NORMALIZADO, no por el texto crudo: el papel
  -- escribe «Jamon» y «Jamón» y son el mismo ingrediente.
  select min(r.ingrediente)                  as ingrediente,
         min(r.unidad)                       as u_receta,
         count(distinct r.codigo)            as fichas,
         (array_agg(i.id     order by i.name))[1] as insumo_id,
         (array_agg(i.name   order by i.name))[1] as insumo,
         (array_agg(i.unit   order by i.name))[1] as u_insumo,
         count(distinct i.id)                as cuantos_insumos
    from public._recetario_penda r
    cross join biz
    left join public.inventory_items i
           on i.business_id = biz.id and coalesce(i.is_active,true)
          and public._norm(i.name) = public._norm(r.ingrediente)
   group by public._norm(r.ingrediente)
),
-- ficha -> producto del menú
prod as (
  select r.codigo, r.producto,
         (array_agg(m.id   order by m.name))[1]                     as menu_id,
         (array_agg(m.name order by m.name))[1]                     as menu,
         bool_or(coalesce(m.is_inventory_tracked,false))            as tracked,
         bool_or(m.inventory_item_id is not null)                   as vinculo_directo
    from (select distinct codigo, producto from public._recetario_penda) r
    cross join biz
    left join public.menu_items m
           on m.business_id = biz.id and coalesce(m.is_active,true)
          and public._norm(m.name) = public._norm(r.producto)
   group by r.codigo, r.producto
),

e1 as (
  select 1 as orden, 'E1 resumen' as seccion, dato, valor from (
    select 'fichas / líneas / ingredientes distintos' as dato,
           (select count(distinct codigo)::text from public._recetario_penda) || ' / ' ||
           (select count(*)::text from public._recetario_penda) || ' / ' ||
           (select count(*)::text from ing) as valor
    union all select 'ingredientes que SÍ existen',
           (select count(*)::text from ing where insumo_id is not null)
    union all select 'ingredientes que NO existen  → hay que crearlos',
           (select count(*)::text from ing where insumo_id is null)
    union all select 'existen pero con unidad que NO convierte',
           (select count(*)::text from ing
             where insumo_id is not null
               and public._penda_a_base(1, u_receta, insumo_id) is null
               and u_receta <> 'c/n')
    union all select 'nombre ambiguo (empareja con 2+ insumos)',
           (select count(*)::text from ing where cuantos_insumos > 1)
    union all select 'fichas con producto en el menú',
           (select count(*)::text from prod where menu_id is not null) || ' de ' ||
           (select count(*)::text from prod)
    union all select 'de esas, con VÍNCULO DIRECTO (no llevan receta)',
           (select count(*)::text from prod where menu_id is not null and vinculo_directo)
    union all select 'fichas que llevan Guarnición dentro del plato',
           (select count(distinct codigo)::text from public._recetario_penda
             where ingrediente ilike '%guarnic%')
  ) x
),

-- ── E2 · LA LISTA PARA CREAR ────────────────────────────────────────────────
e2 as (
  select 2, 'E2 NO EXISTE → crear', ing.ingrediente,
         'pide ' || ing.u_receta || ' · en ' || ing.fichas || ' ficha(s)'
    from ing where insumo_id is null
   order by fichas desc, ingrediente
   limit 130
),

-- ── E3 · unidad que no convierte ────────────────────────────────────────────
e3 as (
  select 3, 'E3 unidad no convierte', ing.ingrediente,
         'receta pide ' || ing.u_receta || ' · insumo está en ' ||
         coalesce(ing.u_insumo,'?') || ' · ' || ing.insumo ||
         ' · en ' || ing.fichas || ' ficha(s)'
    from ing
   where insumo_id is not null and u_receta <> 'c/n'
     and public._penda_a_base(1, u_receta, insumo_id) is null
   order by fichas desc, ingrediente
   limit 90
),

-- ── E4 · fichas sin producto ────────────────────────────────────────────────
e4 as (
  select 4, 'E4 ficha sin producto', p.codigo, p.producto
    from prod p where p.menu_id is null
   order by p.codigo
   limit 70
),

-- ── E5 · el riesgo del vínculo directo ──────────────────────────────────────
e5 as (
  select 5, 'E5 RIESGO vínculo directo', p.codigo,
         p.producto || '  →  ' || p.menu ||
         '  (ya descuenta la botella; ponerle receta lo cambia)'
    from prod p where p.menu_id is not null and p.vinculo_directo
   order by p.codigo
   limit 60
),

-- ── E6 · la guarnición ──────────────────────────────────────────────────────
e6 as (
  select 6, 'E6 Guarnición dentro del plato', z.codigo,
         z.producto || '  ·  «' || z.ingrediente || '» ' ||
         coalesce(trim(to_char(z.cantidad,'FM999990.00')),'') || ' ' || z.unidad
    from public._recetario_penda z
   where z.ingrediente ilike '%guarnic%'
   order by z.codigo
)

select seccion, dato, valor from (
  select * from e1 union all select * from e2 union all select * from e3
  union all select * from e4 union all select * from e5 union all select * from e6
) todo
order by orden, dato;
