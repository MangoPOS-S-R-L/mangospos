-- =============================================================================
-- ECO BAR & LOUNGE — quién tiene impuestos y quién no.
-- Negocio: fc3065c8-cb40-45ad-bec1-aecb388001c1
--
-- SOLO LEE. Nada de esto cambia un dato.
--
-- Por qué importa: `menu_item_taxes` es la ÚNICA fuente del impuesto de un
-- producto. Un producto sin vínculo no factura "por defecto": factura CERO,
-- y ese cero es lo que se declara en el 607.
--
-- Con la configuración de este negocio, un producto correcto suma 28%
-- (ITBIS 18 + LEY 10). Cualquier otra cifra es un hueco.
--
-- Pega TODO de una vez en el SQL Editor de Supabase.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. LOS IMPUESTOS DEL NEGOCIO Y SUS BANDERAS.
--    is_service_fee TIENE que estar en false: en true la factura cobra el
--    cargo dos veces (el servidor lo mete en oi.tax y el cliente lo repite).
-- ---------------------------------------------------------------------------
select t.name,
       t.rate,
       t.is_active,
       t.is_service_fee,
       t.apply_on_takeout,
       t.include_in_ecf,
       (select count(*) from public.menu_item_taxes mit
          join public.menu_items mi on mi.id = mit.item_id
         where mit.tax_id = t.id and mi.is_active)      as productos_vinculados
  from public.taxes t
 where t.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
 order by t.is_active desc, t.rate desc;


-- ---------------------------------------------------------------------------
-- 2. EL RESUMEN. Lo ideal: todo en "con_ambos", el resto en 0.
-- ---------------------------------------------------------------------------
with x as (
  select mi.id,
         exists (select 1 from public.menu_item_taxes t
                   join public.taxes tx on tx.id = t.tax_id
                                       and tx.is_active
                                       and tx.name ilike '%itbis%'
                  where t.item_id = mi.id)              as tiene_itbis,
         exists (select 1 from public.menu_item_taxes t
                   join public.taxes tx on tx.id = t.tax_id
                                       and tx.is_active
                                       and tx.name ilike '%ley%'
                  where t.item_id = mi.id)              as tiene_ley
    from public.menu_items mi
   where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
     and mi.is_active
)
select count(*)                                                    as productos,
       count(*) filter (where tiene_itbis and tiene_ley)            as con_ambos,
       count(*) filter (where tiene_itbis and not tiene_ley)        as solo_itbis,
       count(*) filter (where tiene_ley and not tiene_itbis)        as solo_ley,
       count(*) filter (where not tiene_itbis and not tiene_ley)    as SIN_NINGUNO
  from x;


-- ---------------------------------------------------------------------------
-- 3. LA TASA EFECTIVA, agrupada. Todo debería caer en la fila del 28%.
--    Ojo a la fila de 0.00: esos productos facturan sin impuesto.
-- ---------------------------------------------------------------------------
select coalesce(sum_rate, 0)                as tasa_efectiva_pct,
       count(*)                             as productos,
       -- El grupo bueno son cientos de productos: no tiene sentido listarlos.
       -- Los grupos chicos son las anomalías, y esos sí van por nombre.
       case when count(*) > 20 then '(' || count(*) || ' productos)'
            else string_agg(name, ', ' order by name) end as cuales
  from (
    select mi.name,
           (select sum(tx.rate) from public.menu_item_taxes t
              join public.taxes tx on tx.id = t.tax_id and tx.is_active
             where t.item_id = mi.id) as sum_rate
      from public.menu_items mi
     where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
       and mi.is_active
  ) q
 group by coalesce(sum_rate, 0)
 order by coalesce(sum_rate, 0);


-- ---------------------------------------------------------------------------
-- 4. LOS QUE LE FALTA ALGO, uno por uno. Si esto sale vacío, está todo bien.
-- ---------------------------------------------------------------------------
select c.position                                       as orden,
       c.name                                           as categoria,
       mi.name                                          as producto,
       mi.price,
       mi.tax_mode,
       case when not exists (select 1 from public.menu_item_taxes t
                               join public.taxes tx on tx.id = t.tax_id
                                                   and tx.is_active
                                                   and tx.name ilike '%itbis%'
                              where t.item_id = mi.id)
            then 'FALTA' else 'ok' end                   as itbis,
       case when not exists (select 1 from public.menu_item_taxes t
                               join public.taxes tx on tx.id = t.tax_id
                                                   and tx.is_active
                                                   and tx.name ilike '%ley%'
                              where t.item_id = mi.id)
            then 'FALTA' else 'ok' end                   as ley
  from public.menu_items mi
  left join public.categories c on c.id = mi.category_id
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and mi.is_active
   and (
     not exists (select 1 from public.menu_item_taxes t
                   join public.taxes tx on tx.id = t.tax_id
                                       and tx.is_active
                                       and tx.name ilike '%itbis%'
                  where t.item_id = mi.id)
     or
     not exists (select 1 from public.menu_item_taxes t
                   join public.taxes tx on tx.id = t.tax_id
                                       and tx.is_active
                                       and tx.name ilike '%ley%'
                  where t.item_id = mi.id)
   )
 order by c.position, mi.position, mi.name;


-- ---------------------------------------------------------------------------
-- 5. CATEGORÍA POR CATEGORÍA, para ver de un tirón si algún bloque quedó
--    fuera. "con_ambos" tiene que igualar a "productos" en cada fila.
-- ---------------------------------------------------------------------------
select c.position                                        as orden,
       c.name                                            as categoria,
       count(mi.id)                                      as productos,
       count(mi.id) filter (where exists (
         select 1 from public.menu_item_taxes t
           join public.taxes tx on tx.id = t.tax_id and tx.is_active
                               and tx.name ilike '%itbis%'
          where t.item_id = mi.id))                       as con_itbis,
       count(mi.id) filter (where exists (
         select 1 from public.menu_item_taxes t
           join public.taxes tx on tx.id = t.tax_id and tx.is_active
                               and tx.name ilike '%ley%'
          where t.item_id = mi.id))                       as con_ley
  from public.categories c
  left join public.menu_items mi on mi.category_id = c.id and mi.is_active
 where c.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and c.is_active
 group by c.position, c.name
 order by c.position;


-- ---------------------------------------------------------------------------
-- 6. VÍNCULOS HUÉRFANOS: productos apuntando a un impuesto INACTIVO. Cuenta
--    como vínculo en la tabla pero no cobra nada, así que engaña la vista.
-- ---------------------------------------------------------------------------
select tx.name as impuesto_inactivo, tx.rate, count(*) as productos_apuntando
  from public.menu_item_taxes mit
  join public.taxes tx on tx.id = mit.tax_id
  join public.menu_items mi on mi.id = mit.item_id
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and mi.is_active
   and not tx.is_active
 group by tx.name, tx.rate;
