-- =====================================================================
-- Revisión de ventas de AYER (2026-05-31, hora local RD = UTC-4)
-- Negocio: 33207ebd-985d-455c-bdbb-1b38af8b36ea
--
-- Objetivo doble:
--   1) Top-line de ventas del día (lo que se facturó).
--   2) Confirmar si el ITBIS se está deflactando por la resta legacy
--      (pureItbis = itbis_amount - derivedServiceFee) cuando hay items
--      con tax_rate combinado (28% = 18% ITBIS + 10% LEY).
--
-- Correr en el SQL Editor de Supabase (rol service) o `supabase db`.
-- Para otro día/negocio, cambia las constantes del CTE `params`.
-- =====================================================================

with params as (
  select
    '33207ebd-985d-455c-bdbb-1b38af8b36ea'::uuid as business_id,
    timestamptz '2026-05-31 00:00:00-04'         as from_ts,
    timestamptz '2026-06-01 00:00:00-04'         as to_ts
)

-- ---------------------------------------------------------------------
-- (A) TOP-LINE: comprobantes fiscales emitidos ayer
-- ---------------------------------------------------------------------
select
  'A_topline'                              as bloque,
  count(*) filter (where fd.status = 'active')                        as comprobantes_activos,
  count(*) filter (where fd.status <> 'active')                       as anulados,
  round(sum(fd.subtotal)    filter (where fd.status = 'active'), 2)   as base_gravable,
  round(sum(fd.itbis_amount)filter (where fd.status = 'active'), 2)   as itbis,
  round(sum(fd.service_fee) filter (where fd.status = 'active'), 2)   as ley_service_fee,
  round(sum(fd.total)       filter (where fd.status = 'active'), 2)   as total_facturado,
  -- chequeo de reconciliación: subtotal + itbis + service_fee vs total
  round(sum(fd.subtotal + fd.itbis_amount + fd.service_fee)
        filter (where fd.status = 'active') , 2)                      as suma_componentes,
  round((sum(fd.total) filter (where fd.status = 'active'))
        - (sum(fd.subtotal + fd.itbis_amount + fd.service_fee)
           filter (where fd.status = 'active')), 2)                   as descuadre
from fiscal_documents fd, params p
where fd.business_id = p.business_id
  and fd.issued_at >= p.from_ts
  and fd.issued_at <  p.to_ts;

-- ---------------------------------------------------------------------
-- (B) DISTRIBUCIÓN DE tax_rate EN LOS ITEMS DE AYER
--     Si aparece una fila con tax_rate ~28 (o cualquier combinado
--     18+10), ESE es el que dispara la resta y deflacta el ITBIS.
--     tax_rate 18 = ITBIS puro | 10 = LEY pura | 28 = combinado legacy.
-- ---------------------------------------------------------------------
with params as (
  select
    '33207ebd-985d-455c-bdbb-1b38af8b36ea'::uuid as business_id,
    timestamptz '2026-05-31 00:00:00-04'         as from_ts,
    timestamptz '2026-06-01 00:00:00-04'         as to_ts
)
select
  'B_tax_rates'              as bloque,
  oi.tax_rate,
  count(*)                   as items,
  round(sum(oi.subtotal), 2) as base,
  round(sum(oi.tax), 2)      as tax_cobrado
from order_items oi
join orders o          on o.id = oi.order_id
join fiscal_documents fd on fd.order_id = o.id
cross join params p
where fd.business_id = p.business_id
  and fd.issued_at >= p.from_ts
  and fd.issued_at <  p.to_ts
  and fd.status = 'active'
  and oi.status <> 'void'
group by oi.tax_rate
order by oi.tax_rate;

-- ---------------------------------------------------------------------
-- (C) POR COMPROBANTE: itbis del doc vs ITBIS "real" implícito en items
--     Compara fiscal_documents.itbis_amount contra la suma del tax de
--     items con tax_rate >= 18. Si itbis_doc << itbis_items, confirma
--     que la porción de ITBIS quedó baked/derivada hacia LEY.
-- ---------------------------------------------------------------------
with params as (
  select
    '33207ebd-985d-455c-bdbb-1b38af8b36ea'::uuid as business_id,
    timestamptz '2026-05-31 00:00:00-04'         as from_ts,
    timestamptz '2026-06-01 00:00:00-04'         as to_ts
)
select
  'C_por_doc'                as bloque,
  fd.ncf_number,
  fd.ncf_type,
  round(fd.subtotal, 2)      as base,
  round(fd.itbis_amount, 2)  as itbis_doc,
  round(fd.service_fee, 2)   as ley_doc,
  round(fd.total, 2)         as total_doc,
  round(coalesce(sum(oi.tax) filter (where oi.tax_rate >= 18), 0), 2) as itbis_items_estimado,
  string_agg(distinct oi.tax_rate::text, ',' order by oi.tax_rate::text) as tax_rates_en_items
from fiscal_documents fd
left join orders o      on o.id = fd.order_id
left join order_items oi on oi.order_id = o.id and oi.status <> 'void'
cross join params p
where fd.business_id = p.business_id
  and fd.issued_at >= p.from_ts
  and fd.issued_at <  p.to_ts
  and fd.status = 'active'
group by fd.ncf_number, fd.ncf_type, fd.subtotal, fd.itbis_amount, fd.service_fee, fd.total, fd.issued_at
order by fd.issued_at;

-- ---------------------------------------------------------------------
-- (D) RECONCILIACIÓN HEADLINE (una sola fila)
--     Cuantifica el hueco fiscal de ayer: cuánto ITBIS/LEY se cobró
--     realmente (baked en items) vs cuánto quedó registrado en los
--     comprobantes. itbis_esperado/ley_esperado = split 18/10 del 28%.
-- ---------------------------------------------------------------------
with params as (
  select
    '33207ebd-985d-455c-bdbb-1b38af8b36ea'::uuid as business_id,
    timestamptz '2026-05-31 00:00:00-04'         as from_ts,
    timestamptz '2026-06-01 00:00:00-04'         as to_ts
),
docs as (
  select fd.id, fd.order_id, fd.subtotal, fd.itbis_amount, fd.service_fee, fd.total
  from fiscal_documents fd, params p
  where fd.business_id = p.business_id
    and fd.issued_at >= p.from_ts and fd.issued_at < p.to_ts
    and fd.status = 'active'
),
items as (
  select d.id as doc_id, coalesce(sum(oi.tax), 0) as tax_baked
  from docs d
  join order_items oi on oi.order_id = d.order_id and oi.status <> 'void'
  group by d.id
)
select
  'D_reconciliacion'                                   as bloque,
  count(*)                                             as comprobantes,
  count(*) filter (where d.itbis_amount = 0)           as docs_itbis_cero,
  count(*) filter (where d.service_fee = 0)            as docs_ley_cero,
  round(sum(d.subtotal), 2)                            as base_total,
  round(sum(d.total), 2)                               as total_facturado,
  round(sum(d.itbis_amount), 2)                        as itbis_registrado,
  round(sum(d.service_fee), 2)                         as ley_registrada,
  round(sum(coalesce(i.tax_baked, 0)), 2)              as impuesto_baked_en_items,
  round(sum(coalesce(i.tax_baked, 0)) * 18.0/28.0, 2)  as itbis_esperado_18,
  round(sum(coalesce(i.tax_baked, 0)) * 10.0/28.0, 2)  as ley_esperada_10
from docs d
left join items i on i.doc_id = d.id;

-- ---------------------------------------------------------------------
-- (E) CONFIG DE IMPUESTOS DEL NEGOCIO
--     Define el fix correcto: ¿un solo impuesto 28% combinado, o
--     18% ITBIS + 10% LEY separados (is_service_fee)? select * para
--     ver todas las columnas (is_service_fee, apply_on_takeout, etc.)
-- ---------------------------------------------------------------------
select 'E_taxes_config' as bloque, t.*
from taxes t
where t.business_id = '33207ebd-985d-455c-bdbb-1b38af8b36ea'::uuid
order by t.rate desc;

-- ---------------------------------------------------------------------
-- (F) RECONCILIACIÓN RANGO AMPLIO (todo mayo 2026)
--     Igual que (D) pero del 01/05 al 01/06 para ver si el hueco es
--     de ayer o sistémico. Mira la relación itbis_registrado vs
--     itbis_esperado_18 y ley_registrada vs ley_esperada_10.
-- ---------------------------------------------------------------------
with params as (
  select
    '33207ebd-985d-455c-bdbb-1b38af8b36ea'::uuid as business_id,
    timestamptz '2026-05-01 00:00:00-04'         as from_ts,
    timestamptz '2026-06-01 00:00:00-04'         as to_ts
),
docs as (
  select fd.id, fd.order_id, fd.subtotal, fd.itbis_amount, fd.service_fee, fd.total
  from fiscal_documents fd, params p
  where fd.business_id = p.business_id
    and fd.issued_at >= p.from_ts and fd.issued_at < p.to_ts
    and fd.status = 'active'
),
items as (
  select d.id as doc_id, coalesce(sum(oi.tax), 0) as tax_baked
  from docs d
  join order_items oi on oi.order_id = d.order_id and oi.status <> 'void'
  group by d.id
)
select
  'F_reconciliacion_mayo'                              as bloque,
  count(*)                                             as comprobantes,
  count(*) filter (where d.itbis_amount = 0)           as docs_itbis_cero,
  count(*) filter (where d.service_fee = 0)            as docs_ley_cero,
  round(sum(d.subtotal), 2)                            as base_total,
  round(sum(d.total), 2)                               as total_facturado,
  round(sum(d.itbis_amount), 2)                        as itbis_registrado,
  round(sum(d.service_fee), 2)                         as ley_registrada,
  round(sum(coalesce(i.tax_baked, 0)), 2)              as impuesto_baked_en_items,
  round(sum(coalesce(i.tax_baked, 0)) * 18.0/28.0, 2)  as itbis_esperado_18,
  round(sum(coalesce(i.tax_baked, 0)) * 10.0/28.0, 2)  as ley_esperada_10
from docs d
left join items i on i.doc_id = d.id;

-- ---------------------------------------------------------------------
-- (G) ¿Por qué el ITBIS efectivo da ~18.7% y no 18%?
--     Distribución de la tasa efectiva de impuesto por comprobante de mayo.
--     Si hay un grupo ~18% (base sola) y otro ~19.8% (ITBIS sobre base+LEY)
--     o ~28% (combinado lumped), confirma que es data de config vieja.
-- ---------------------------------------------------------------------
with params as (
  select '33207ebd-985d-455c-bdbb-1b38af8b36ea'::uuid as business_id,
         timestamptz '2026-05-01 00:00:00-04' as from_ts,
         timestamptz '2026-06-01 00:00:00-04' as to_ts
),
docs as (
  select fd.id, fd.order_id, fd.subtotal, fd.itbis_amount, fd.total
  from fiscal_documents fd, params p
  where fd.business_id = p.business_id
    and fd.issued_at >= p.from_ts and fd.issued_at < p.to_ts
    and fd.status = 'active'
),
rates as (
  select d.id,
         case when d.subtotal > 0 then round((d.itbis_amount / d.subtotal) * 100, 1) end as rate_vs_subtotal,
         coalesce((select round((sum(oi.tax) * 18.0/28.0) / nullif(d.total - sum(oi.tax),0) * 100, 1)
                   from order_items oi where oi.order_id = d.order_id and oi.status <> 'void'), null) as rate_items
  from docs d
)
select 'G_rate_dist' as bloque,
       rate_vs_subtotal as itbis_efectivo_pct,
       count(*) as comprobantes
from rates
group by rate_vs_subtotal
order by rate_vs_subtotal;

-- ---------------------------------------------------------------------
-- (H) ¿Qué se vendió EXENTO ayer? (por qué el ITBIS efectivo < 18%)
--     Lista los items con tax_rate = 0 de ayer, agrupados por producto.
--     Sirve para confirmar que esos productos DEBEN ser exentos y no es
--     uno mal configurado. Compara base_exenta vs base_gravada.
-- ---------------------------------------------------------------------
with params as (
  select '33207ebd-985d-455c-bdbb-1b38af8b36ea'::uuid as business_id,
         timestamptz '2026-05-31 00:00:00-04' as from_ts,
         timestamptz '2026-06-01 00:00:00-04' as to_ts
),
yitems as (
  select oi.product_name, oi.tax_rate, oi.subtotal, oi.tax
  from order_items oi
  join fiscal_documents fd on fd.order_id = oi.order_id
  cross join params p
  where fd.business_id = p.business_id
    and fd.issued_at >= p.from_ts and fd.issued_at < p.to_ts
    and fd.status = 'active'
    and oi.status <> 'void'
)
-- detalle: productos exentos
select 'H_exentos' as bloque,
       coalesce(product_name, '(sin nombre)') as producto,
       count(*) as veces,
       round(sum(subtotal), 2) as base_exenta
from yitems
where tax_rate = 0
group by product_name
order by base_exenta desc;

-- resumen: base exenta vs gravada (descomenta para correr aparte)
-- select 'H_resumen' as bloque,
--        round(sum(subtotal) filter (where tax_rate = 0), 2)  as base_exenta,
--        round(sum(subtotal) filter (where tax_rate > 0), 2)  as base_gravada
-- from yitems;

-- ---------------------------------------------------------------------
-- (I) AUDITORÍA: productos activos SIN impuesto vinculado
--     Estos se venden sin ITBIS/LEY. Revisa cuáles DEBEN llevar impuesto
--     (bebidas, comida) y asígnaselo en el menú. Los que sí son exentos
--     legítimos (si hubiera) se dejan.
-- ---------------------------------------------------------------------
select 'I_productos_sin_impuesto' as bloque,
       mi.name as producto,
       mi.is_beverage,
       mi.price,
       c.name as categoria
from menu_items mi
left join categories c on c.id = mi.category_id
where mi.business_id = '33207ebd-985d-455c-bdbb-1b38af8b36ea'::uuid
  and mi.is_active = true
  and not exists (
    select 1
    from menu_item_taxes mit
    join taxes t on t.id = mit.tax_id and coalesce(t.is_active, true)
    where mit.item_id = mi.id
  )
order by mi.is_beverage desc, c.name nulls last, mi.name;

-- ---------------------------------------------------------------------
-- (J) ¿Por qué esas bebidas salen en 0? Vínculos + default del negocio.
--     J1: default_tax_rate del negocio (si es 0, productos sin vínculo
--         caen a cero).
--     J2: las bebidas exentas de ayer con sus impuestos vinculados.
--         Si linked_taxes sale NULL → no están vinculadas (fix = vincular).
-- ---------------------------------------------------------------------
select 'J1_default' as bloque, bs.default_tax_rate
from business_settings bs
where bs.business_id = '33207ebd-985d-455c-bdbb-1b38af8b36ea'::uuid;

select 'J2_vinculos' as bloque,
       mi.name as producto,
       mi.is_active,
       string_agg(t.name || ' (' || t.rate || '%)', ', ') as impuestos_vinculados
from menu_items mi
left join menu_item_taxes mit on mit.item_id = mi.id
left join taxes t on t.id = mit.tax_id and coalesce(t.is_active, true)
where mi.business_id = '33207ebd-985d-455c-bdbb-1b38af8b36ea'::uuid
  and mi.name in ('Mojito Chinola','Frozen de Limon con menta','Mojito Limon',
                  'Modelo Especial','Stella Artois')
group by mi.name, mi.is_active
order by mi.name;

-- ---------------------------------------------------------------------
-- (K) LÍNEA DE TIEMPO: los 4 productos VINCULADOS que vendieron en 0.
--     ¿Timing (vinculados tarde) o bug de captura (siempre en 0)?
--     Si hay filas con tax_rate=28 y otras con 0, mira las fechas:
--       0 antes de fecha X y 28 después → se vincularon en X (timing).
--       solo 0 en todo mayo → el resolver no aplicó el vínculo (bug).
-- ---------------------------------------------------------------------
select 'K_timeline' as bloque,
       oi.product_name as producto,
       oi.tax_rate,
       count(*) as veces,
       min(fd.issued_at) as primera_venta,
       max(fd.issued_at) as ultima_venta
from order_items oi
join fiscal_documents fd on fd.order_id = oi.order_id
where fd.business_id = '33207ebd-985d-455c-bdbb-1b38af8b36ea'::uuid
  and fd.issued_at >= timestamptz '2026-05-01 00:00:00-04'
  and fd.issued_at <  timestamptz '2026-06-01 00:00:00-04'
  and fd.status = 'active'
  and oi.status <> 'void'
  and oi.product_name in ('Mojito Chinola','Mojito Limon',
                          'Modelo Especial','Stella Artois')
group by oi.product_name, oi.tax_rate
order by oi.product_name, oi.tax_rate;

-- ---------------------------------------------------------------------
-- (L) CARACTERIZAR las líneas en 0 de ayer: ¿qué tienen en común?
--     Origen de la sesión, orden, hora de creación del ítem. Busca patrón:
--     mismo origin (quick/delivery/dine_in), misma orden, mismo mesero,
--     o ítems creados fuera de fn_add_item_from_menu (captura offline).
-- ---------------------------------------------------------------------
with params as (
  select '33207ebd-985d-455c-bdbb-1b38af8b36ea'::uuid as business_id,
         timestamptz '2026-05-31 00:00:00-04' as from_ts,
         timestamptz '2026-06-01 00:00:00-04' as to_ts
)
select 'L_zero_detail' as bloque,
       fd.ncf_number,
       ts.origin,
       oi.order_id,
       oi.product_name,
       oi.subtotal,
       oi.is_takeout,
       oi.created_at as item_creado,
       o.created_at  as orden_creada,
       ts.waiter_user_id,
       -- cuántas líneas de ESA orden están gravadas vs en 0
       (select count(*) from order_items x where x.order_id = oi.order_id and x.status <> 'void' and x.tax_rate > 0)  as lineas_gravadas_en_orden,
       (select count(*) from order_items x where x.order_id = oi.order_id and x.status <> 'void' and x.tax_rate = 0)  as lineas_cero_en_orden
from order_items oi
join orders o            on o.id = oi.order_id
join table_sessions ts   on ts.id = o.session_id
join fiscal_documents fd on fd.order_id = o.id
cross join params p
where fd.business_id = p.business_id
  and fd.issued_at >= p.from_ts and fd.issued_at < p.to_ts
  and fd.status = 'active'
  and oi.status <> 'void'
  and oi.tax_rate = 0
order by oi.created_at;

-- ---------------------------------------------------------------------
-- (M) ¿Por qué HOY (01/06) da 18.46%? Distribución de la tasa efectiva
--     de ITBIS por comprobante, replicando la lógica del reporte
--     (split 18/28 + 10/28 derivado de los items). La última fila
--     M_TOTAL reproduce el % global del card.
-- ---------------------------------------------------------------------
with params as (
  select '33207ebd-985d-455c-bdbb-1b38af8b36ea'::uuid as business_id,
         timestamptz '2026-06-01 00:00:00-04' as from_ts,
         timestamptz '2026-06-02 00:00:00-04' as to_ts
),
docitems as (
  select fd.id as doc_id, fd.subtotal, fd.itbis_amount, fd.service_fee, fd.total,
    coalesce(sum(oi.tax), 0) as item_tax,
    coalesce(sum(case when oi.tax_rate = 28 then oi.tax * 18.0/28
                      when oi.tax_rate >= 18 and oi.tax_rate < 28 then oi.tax
                      else 0 end), 0) as item_itbis,
    coalesce(sum(case when oi.tax_rate = 28 then oi.tax * 10.0/28
                      when oi.tax_rate = 10 then oi.tax
                      else 0 end), 0) as item_ley,
    coalesce(sum(case when oi.tax_rate = 0 then oi.subtotal else 0 end), 0) as base_exenta
  from fiscal_documents fd
  left join order_items oi on oi.order_id = fd.order_id and oi.status <> 'void'
  cross join params p
  where fd.business_id = p.business_id
    and fd.issued_at >= p.from_ts and fd.issued_at < p.to_ts
    and fd.status = 'active'
  group by fd.id, fd.subtotal, fd.itbis_amount, fd.service_fee, fd.total
),
resolved as (
  select doc_id, total, base_exenta,
    case when item_tax > 0.005 then item_itbis
         when subtotal > 0 and abs(itbis_amount/subtotal*100 - 28) < 0.5 then itbis_amount*18.0/28
         else greatest(itbis_amount, 0) end as itbis,
    case when item_tax > 0.005 then item_ley
         when subtotal > 0 and abs(itbis_amount/subtotal*100 - 28) < 0.5 then itbis_amount*10.0/28
         else service_fee end as ley
  from docitems
),
final as (
  select doc_id, base_exenta,
         itbis,
         greatest(total - itbis - ley, 0) as base
  from resolved
)
select * from (
  select 'M_dist' as bloque,
         case when base > 0 then round(itbis/base*100, 1) else null end as itbis_efectivo_pct,
         count(*) as comprobantes,
         round(sum(itbis), 2) as itbis,
         round(sum(base), 2) as base,
         round(sum(base_exenta), 2) as base_exenta
  from final
  group by 1, 2
  union all
  select 'M_TOTAL', round(sum(itbis)/nullif(sum(base),0)*100, 2),
         count(*), round(sum(itbis),2), round(sum(base),2), round(sum(base_exenta),2)
  from final
) q
order by (bloque = 'M_TOTAL'), itbis_efectivo_pct nulls last;

-- ---------------------------------------------------------------------
-- (N) ¿Qué comprobante de HOY mete el desbalance ITBIS/LEY (~RD$58)?
--     Compara, por comprobante, el split LIMPIO derivado de items
--     (28→18/10) contra las columnas del documento. Los de ruta
--     'fallback' (sin líneas de impuesto) son los sospechosos: ahí el
--     ITBIS no se parte y se infla vs la LEY.
-- ---------------------------------------------------------------------
with params as (
  select '33207ebd-985d-455c-bdbb-1b38af8b36ea'::uuid as business_id,
         timestamptz '2026-06-01 00:00:00-04' as from_ts,
         timestamptz '2026-06-02 00:00:00-04' as to_ts
),
agg as (
  select fd.id, fd.ncf_number, fd.subtotal, fd.itbis_amount, fd.service_fee, fd.total,
    coalesce(sum(oi.tax), 0) as item_tax,
    coalesce(sum(case when oi.tax_rate = 28 then oi.tax*18.0/28
                      when oi.tax_rate >= 18 and oi.tax_rate < 28 then oi.tax
                      else 0 end), 0) as itbis_items,
    coalesce(sum(case when oi.tax_rate = 28 then oi.tax*10.0/28
                      when oi.tax_rate = 10 then oi.tax
                      else 0 end), 0) as ley_items
  from fiscal_documents fd
  left join order_items oi on oi.order_id = fd.order_id and oi.status <> 'void'
  cross join params p
  where fd.business_id = p.business_id
    and fd.issued_at >= p.from_ts and fd.issued_at < p.to_ts
    and fd.status = 'active'
  group by fd.id, fd.ncf_number, fd.subtotal, fd.itbis_amount, fd.service_fee, fd.total
)
select 'N_desbalance' as bloque,
       ncf_number,
       case when item_tax > 0.005 then 'items' else 'fallback' end as ruta,
       round(total, 2)        as total,
       round(subtotal, 2)     as subtotal_col,
       round(itbis_amount, 2) as itbis_col,
       round(service_fee, 2)  as ley_col,
       round(itbis_items, 2)  as itbis_limpio,
       round(ley_items, 2)    as ley_limpio,
       case when subtotal > 0 then round(itbis_amount/subtotal*100, 1) end as itbis_col_pct
from agg
order by (case when item_tax > 0.005 then 1 else 0 end), itbis_col desc;

-- ---------------------------------------------------------------------
-- (O) ¿Qué es B0200066291? Comprobante total=0 con tax negativo.
--     Ver sus líneas (qty/subtotal/tax/status) y el estado de la orden.
--     Define si es comp/anulado/devolución y si debería contar como
--     activo en el reporte.
-- ---------------------------------------------------------------------
select 'O_doc' as bloque,
       fd.ncf_number, fd.status as doc_status, fd.subtotal, fd.itbis_amount,
       fd.service_fee, fd.total, fd.order_id, o.status_ext as orden_status
from fiscal_documents fd
left join orders o on o.id = fd.order_id
where fd.ncf_number = 'B0200066291'
  and fd.business_id = '33207ebd-985d-455c-bdbb-1b38af8b36ea'::uuid;

select 'O_items' as bloque,
       oi.product_name, oi.status, oi.qty, oi.quantity,
       oi.unit_price, oi.subtotal, oi.discounts, oi.tax, oi.tax_rate
from order_items oi
join fiscal_documents fd on fd.order_id = oi.order_id
where fd.ncf_number = 'B0200066291'
  and fd.business_id = '33207ebd-985d-455c-bdbb-1b38af8b36ea'::uuid
order by oi.created_at;
