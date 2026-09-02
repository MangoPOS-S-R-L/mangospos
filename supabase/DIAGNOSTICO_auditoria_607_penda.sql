-- =============================================================================
-- LA PENDA EXPRESS — confirmar los 4 hallazgos de la auditoría del 607 (agosto 2026)
-- DH Delgado Hernández & Asociados, informe del 31-ago-2026
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- CORRER UNA SENTENCIA A LA VEZ. Todo es SOLO LECTURA.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 0. LA CAUSA RAÍZ DE H-1, EN UNA CONSULTA.
--
--    fn_recompute_fd_for_scope separa ITBIS de LEY con `taxes.is_service_fee`:
--        v_itbis_rate = MAX(rate) WHERE NOT is_service_fee
--        v_ley_rate   = MAX(rate) WHERE     is_service_fee
--
--    Si la LEY 10% tiene is_service_fee = false, entonces v_ley_rate = 0 y un
--    ítem al 28% no encaja en NINGUNA rama del CASE => ITBIS 0 y LEY 0.
--
--    LO QUE HAY QUE VER: ley_rate_que_calcula = 0.00  => hallazgo confirmado.
-- ---------------------------------------------------------------------------
select
  t.name,
  t.rate,
  t.is_active,
  t.is_service_fee
from public.taxes t
where t.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
order by t.rate desc;

select
  coalesce(max(t.rate) filter (where not coalesce(t.is_service_fee, false)), 0)
    as itbis_rate_que_calcula,
  coalesce(max(t.rate) filter (where     coalesce(t.is_service_fee, false)), 0)
    as ley_rate_que_calcula   -- <=== si sale 0.00, H-1 queda confirmado
from public.taxes t
where t.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(t.is_active, true);


-- ---------------------------------------------------------------------------
-- 1. VERIFICAR QUE LA FUNCIÓN VIVA ES LA QUE CREO QUE ES.
--    La BD de prod diverge del repo. Antes de tocar nada, leer la definición
--    REAL. Buscar en el texto la línea `FILTER (WHERE COALESCE(t.is_service_fee`.
-- ---------------------------------------------------------------------------
select pg_get_functiondef('public.fn_recompute_fd_for_scope(uuid,uuid,uuid)'::regprocedure);


-- ---------------------------------------------------------------------------
-- 2. H-1 — MEDIR EL HUECO. Facturas de agosto con ITBIS 0 que SÍ llevan
--    impuesto cobrado, y cuánto ITBIS falta declarar.
--
--    ESPERADO SEGÚN EL AUDITOR: 2,011 facturas, RD$ 474,152.48
-- ---------------------------------------------------------------------------
with fd as (
  select d.id, d.ncf_number, d.order_id, d.check_id,
         coalesce(d.subtotal,0) as subtotal,
         coalesce(d.discount,0) as descuento,
         coalesce(d.total,0)    as total,
         coalesce(d.itbis_amount,0) as itbis_guardado,
         coalesce(d.service_fee,0)  as ley_guardada
  from public.fiscal_documents d
  where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and d.status = 'active'
    and (d.issued_at at time zone 'America/Santo_Domingo')::date
        between date '2026-08-01' and date '2026-08-31'
),
-- Impuesto que el documento REALMENTE facturó: total - base.
-- El documento ya sabe cuánto; los ítems solo dicen CÓMO se reparte.
calc as (
  select f.*,
         greatest(f.total - f.subtotal + f.descuento, 0) as impuesto_facturado
  from fd f
)
select
  count(*) filter (where itbis_guardado = 0 and impuesto_facturado > 0)
    as facturas_con_itbis_en_cero,
  count(*) as facturas_activas_agosto,
  round(sum(itbis_guardado), 2)     as itbis_que_dice_el_registro,
  round(sum(impuesto_facturado), 2) as impuesto_total_facturado,
  round(sum(impuesto_facturado) filter (where itbis_guardado = 0), 2)
    as impuesto_no_desglosado
from calc;


-- ---------------------------------------------------------------------------
-- 3. H-1 — EL CASO TESTIGO DEL INFORME, ítem por ítem.
--    Factura B0200154176 del 2026-08-02 (PGS SOLUTIONS).
--    ESPERADO: base 12,923.39 / ITBIS correcto 2,326.22 / LEY 1,292.34 /
--              total 16,541.95, con itbis_amount guardado en 0.00
-- ---------------------------------------------------------------------------
select
  d.ncf_number, d.status, d.issued_at,
  d.subtotal, d.discount, d.itbis_amount, d.service_fee, d.total,
  d.order_id, d.check_id
from public.fiscal_documents d
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.ncf_number = 'B0200154176';

select
  oi.tax_rate,
  count(*)                        as lineas,
  round(sum(oi.subtotal), 2)      as base,
  round(sum(oi.tax), 2)           as impuesto_cobrado,
  round(sum(oi.total), 2)         as total,
  round(sum(oi.subtotal) * 0.18, 2) as itbis_que_corresponde
from public.order_items oi
join public.fiscal_documents d
  on d.order_id = oi.order_id
 and (d.check_id is null or d.check_id = oi.check_id)
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.ncf_number = 'B0200154176'
  and oi.status <> 'void'
group by oi.tax_rate
order by oi.tax_rate;


-- ---------------------------------------------------------------------------
-- 4. H-2 — POR QUÉ EL FEED INVENTA LEY 10%.
--    La rama de respaldo de analytics.documentos usa la proporción de las
--    TASAS CONFIGURADAS (18/28 = 0.642857) cuando los ítems no aportan
--    ninguna señal de impuesto. Comprobación aritmética del caso del informe:
--        778.53 x 18/28 = 500.48   <- exactamente lo que reportó el feed
--
--    Esto muestra QUÉ ítems dejaron al feed sin señal en esa factura.
--    Factura B0200157713 del 2026-08-23, 11 ítems, todos al 18%.
-- ---------------------------------------------------------------------------
select
  d.ncf_number, d.order_id, d.check_id,
  d.subtotal, d.discount, d.itbis_amount, d.service_fee, d.total
from public.fiscal_documents d
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.ncf_number = 'B0200157713';

select
  oi.id, oi.product_name, oi.quantity, oi.check_id, oi.status,
  oi.tax_rate, oi.subtotal, oi.tax, oi.total,
  (select count(*) from public.order_item_tax_lines tl
    where tl.order_item_id = oi.id)                   as tiene_tax_lines,
  (select round(sum(tl.amount), 2) from public.order_item_tax_lines tl
    where tl.order_item_id = oi.id)                   as suma_tax_lines
from public.order_items oi
join public.fiscal_documents d on d.order_id = oi.order_id
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.ncf_number = 'B0200157713'
order by oi.created_at;

-- Y el alcance del defecto en todo agosto: documentos donde el feed NO pudo
-- sacar la proporción de los ítems y cayó al 18/28 fijo.
with fd as (
  select d.id, d.ncf_number, d.order_id, d.check_id,
         coalesce(d.subtotal,0) as subtotal, coalesce(d.discount,0) as descuento,
         coalesce(d.total,0) as total
  from public.fiscal_documents d
  where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and d.status = 'active'
    and (d.issued_at at time zone 'America/Santo_Domingo')::date
        between date '2026-08-01' and date '2026-08-31'
),
senal as (
  select f.id,
         greatest(f.total - f.subtotal + f.descuento, 0) as impuesto_facturado,
         coalesce(sum(oi.tax), 0)                        as senal_de_items,
         count(*) filter (where oi.tax_rate >= 27.5)     as items_con_ley
  from fd f
  left join public.order_items oi
    on oi.order_id = f.order_id
   and oi.status <> 'void'
   and (f.check_id is null or oi.check_id = f.check_id)
  group by f.id, f.total, f.subtotal, f.descuento
)
select
  count(*) filter (where senal_de_items = 0 and impuesto_facturado > 0)
    as docs_sin_senal_reparten_18_10_fijo,
  count(*) filter (where items_con_ley = 0 and senal_de_items = 0
                     and impuesto_facturado > 0)
    as de_esos_sin_un_solo_producto_con_ley,   -- <=== esperado ~104
  round(sum(impuesto_facturado * 10.0/28.0)
        filter (where items_con_ley = 0 and senal_de_items = 0), 2)
    as ley_inventada                            -- <=== esperado ~3,405.37
from senal;


-- ---------------------------------------------------------------------------
-- 5. H-4 — LAS 9 FACTURAS ACTIVAS SIN VENTA NI COBRO.
--    NCF vigente, TODOS los ítems anulados, cero pagos.
--    ESPERADO: 9 facturas, RD$ 8,848.56
-- ---------------------------------------------------------------------------
select
  d.ncf_number,
  (d.issued_at at time zone 'America/Santo_Domingo')::date as fecha,
  d.total                                                  as monto_facturado,
  d.status,
  count(oi.*)                                     as items_totales,
  count(oi.*) filter (where oi.status = 'void')    as items_anulados,
  (select count(*) from public.payments p
    where p.fiscal_document_id = d.id and p.status = 'completed') as pagos_al_documento,
  (select count(*) from public.payments p
    where p.order_id = d.order_id and p.status = 'completed')     as pagos_a_la_orden,
  d.order_id
from public.fiscal_documents d
left join public.order_items oi on oi.order_id = d.order_id
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.status = 'active'
  and (d.issued_at at time zone 'America/Santo_Domingo')::date
      between date '2026-08-01' and date '2026-08-31'
group by d.id, d.ncf_number, d.issued_at, d.total, d.status, d.order_id
having count(oi.*) > 0
   and count(oi.*) = count(oi.*) filter (where oi.status = 'void')
   and (select count(*) from public.payments p
         where p.order_id = d.order_id and p.status = 'completed') = 0
order by d.total desc;


-- ---------------------------------------------------------------------------
-- 6. H-3 — LAS 3 FACTURAS QUE COBRAN MÁS DE LO REGISTRADO.
--    Ojo: puede ser el problema conocido de ítems que quedan escondidos en un
--    check ya cerrado, no necesariamente un faltante de caja.
-- ---------------------------------------------------------------------------
with fd as (
  select d.id, d.ncf_number, d.order_id, d.check_id,
         coalesce(d.subtotal,0) as base_facturada, coalesce(d.total,0) as total
  from public.fiscal_documents d
  where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and d.status = 'active'
    and (d.issued_at at time zone 'America/Santo_Domingo')::date
        between date '2026-08-01' and date '2026-08-31'
),
items as (
  select f.id, coalesce(sum(oi.subtotal), 0) as base_en_items
  from fd f
  left join public.order_items oi
    on oi.order_id = f.order_id
   and oi.status <> 'void'
   and (f.check_id is null or oi.check_id = f.check_id)
  group by f.id
)
select f.ncf_number, f.base_facturada, i.base_en_items,
       round(f.base_facturada - i.base_en_items, 2) as diferencia_sin_respaldo,
       f.total, f.order_id
from fd f
join items i on i.id = f.id
where f.base_facturada - i.base_en_items > 1.00
order by (f.base_facturada - i.base_en_items) desc;


-- ---------------------------------------------------------------------------
-- 7. H-2 — LA DIRECCIÓN DEL DESFASE.
--
--    Los ítems de B0200157713 cobraron 18% pero sus tax_lines dicen 28%.
--    fn_populate_item_tax_lines hace DELETE+INSERT desde menu_item_taxes cada
--    vez que se la llama: las líneas NO son historia de lo cobrado, son una
--    foto de la config del momento en que corrió.
--
--    LO QUE HAY QUE VER: si created_at de las líneas es POSTERIOR al issued_at
--    del comprobante, las líneas se regrabaron después de facturar y no sirven
--    para reconstruir el 607.
-- ---------------------------------------------------------------------------
select
  oi.product_name,
  oi.tax_rate                        as tasa_del_item,
  oi.tax                             as impuesto_cobrado,
  tl.tax_name,
  tl.tax_rate                        as tasa_de_la_linea,
  tl.amount,
  oi.created_at                      as item_creado,
  tl.created_at                      as linea_creada,
  d.issued_at                        as comprobante_emitido,
  (tl.created_at > d.issued_at)      as linea_regrabada_despues
from public.fiscal_documents d
join public.order_items oi on oi.order_id = d.order_id and oi.status <> 'void'
join public.order_item_tax_lines tl on tl.order_item_id = oi.id
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.ncf_number = 'B0200157713'
order by oi.created_at, tl.tax_rate;

-- ¿A cuántos impuestos está vinculado HOY uno de esos productos?
select
  p.name                as producto,
  t.name                as impuesto,
  t.rate,
  t.is_active,
  t.apply_on_zone, t.apply_on_takeout, t.apply_on_quick, t.apply_on_manual
from public.order_items oi
join public.menu_items p       on p.id = oi.product_id
join public.menu_item_taxes mit on mit.item_id = oi.product_id
join public.taxes t             on t.id = mit.tax_id
where oi.id = '078d3046-2864-4dab-8440-758bd5612a45'   -- CAPUCCINO ITALIANO
order by t.rate;

-- ALCANCE: ítems de agosto donde la tasa de las líneas NO coincide con la del
-- ítem. Es la medida real de cuán poco confiable es order_item_tax_lines.
with x as (
  select
    oi.id,
    oi.tax_rate                        as tasa_item,
    round(sum(tl.tax_rate), 2)         as tasa_lineas,
    round(coalesce(oi.tax,0), 2)       as cobrado,
    round(sum(tl.amount), 2)           as segun_lineas
  from public.fiscal_documents d
  join public.order_items oi on oi.order_id = d.order_id and oi.status <> 'void'
  join public.order_item_tax_lines tl on tl.order_item_id = oi.id
  where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and d.status = 'active'
    and (d.issued_at at time zone 'America/Santo_Domingo')::date
        between date '2026-08-01' and date '2026-08-31'
  group by oi.id, oi.tax_rate, oi.tax
)
select
  count(*)                                                as items_con_lineas,
  count(*) filter (where abs(tasa_item - tasa_lineas) > 0.5) as items_que_no_cuadran,
  round(100.0 * count(*) filter (where abs(tasa_item - tasa_lineas) > 0.5)
        / nullif(count(*),0), 1)                          as pct_que_no_cuadra,
  round(sum(segun_lineas - cobrado) filter
        (where abs(tasa_item - tasa_lineas) > 0.5), 2)    as impuesto_inventado_por_las_lineas
from x;


-- ---------------------------------------------------------------------------
-- 8. CRÍTICO — ¿ALGUIEN LLAMA AL RECOMPUTE AL EMITIR?
--
--    Arreglar fn_recompute_fd_for_scope NO SIRVE DE NADA si nada la invoca.
--    En jun-2026 se documentó que `issue_fiscal_document` inserta
--    itbis_amount = coalesce(o.tax, 0) directo y NO llama al recompute; el
--    encargado de corregirlo era el trigger trg_recompute_fd_on_payment_change
--    (migración 20260530_0002, AFTER UPDATE OF fiscal_document_id ON payments),
--    y se sospechó que ese trigger NO estaba aplicado en vivo.
--
--    SI ESTE SELECT NO DEVUELVE FILAS, la migración 20260902_0007 sólo sirve
--    para el backfill y los comprobantes NUEVOS seguirán naciendo en cero.
-- ---------------------------------------------------------------------------
select
  t.tgname                      as trigger_vivo,
  c.relname                     as sobre_la_tabla,
  p.proname                     as ejecuta,
  t.tgenabled                   as habilitado,
  pg_get_triggerdef(t.oid)      as definicion
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_proc  p on p.oid = t.tgfoid
where not t.tgisinternal
  and (p.proname ilike '%recompute_fd%' or t.tgname ilike '%recompute_fd%');

-- Y la ruta de emisión: ¿escribe itbis desde order.tax sin recomputar?
-- Buscar en el texto: `itbis_amount` y si aparece `fn_recompute_fd_for_scope`.
select p.proname,
       (pg_get_functiondef(p.oid) like '%fn_recompute_fd_for_scope%') as llama_al_recompute,
       (pg_get_functiondef(p.oid) like '%itbis_amount%')              as escribe_itbis
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('issue_fiscal_document', 'fn_issue_fiscal_document')
order by p.proname;


-- ---------------------------------------------------------------------------
-- 9. H-2 — CUÁL DE LAS DOS HIPÓTESIS.
--
--    CORRECCIÓN: las líneas NO se regrabaron después de facturar. linea_creada
--    == comprobante_emitido AL MICROSEGUNDO, mientras el ítem se creó ~45 min
--    antes. O sea:
--        oi.tax        se congela cuando se AGREGA el ítem  (fn_resolve_order_item_tax_profile)
--        las tax_lines se escriben cuando se FACTURA        (fn_populate_item_tax_lines)
--    Los filtros de ambas funciones son idénticos (20260813_0002), así que la
--    divergencia sólo puede venir de que cambió algo ENTRE los dos momentos.
--
--    HIPÓTESIS A · is_takeout. resolve() lo recibe COMO PARÁMETRO del llamador;
--      populate() lo lee de la fila oi.is_takeout. Si el llamador pasó true
--      pero la columna quedó en false, resolve excluye la LEY (apply_on_takeout
--      = false) y populate la incluye. Da exactamente lo observado.
--
--    HIPÓTESIS B · se vinculó la LEY al producto entre las 12:45 y las 13:29.
--      menu_item_taxes no tiene created_at, así que se prueba por la forma:
--      si es config, los ítems que no cuadran se AGRUPAN en pocos días/horas.
--      Si es is_takeout, salen repartidos por todo el mes.
-- ---------------------------------------------------------------------------
select
  oi.product_name,
  oi.is_takeout,                       -- <=== HIPÓTESIS A
  oi.tax_rate,
  oi.tax,
  ts.origin                            as origen_de_la_sesion,
  oi.created_at                        as item_agregado,
  d.issued_at                          as facturado
from public.fiscal_documents d
join public.order_items oi on oi.order_id = d.order_id and oi.status <> 'void'
join public.orders o          on o.id = oi.order_id
join public.table_sessions ts on ts.id = o.session_id
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.ncf_number = 'B0200157713'
order by oi.created_at;

-- HIPÓTESIS B: ¿se agrupan en el tiempo los 451 ítems que no cuadran?
with x as (
  select
    oi.id,
    (oi.created_at at time zone 'America/Santo_Domingo')::date as dia,
    oi.tax_rate                as tasa_item,
    sum(tl.tax_rate)           as tasa_lineas
  from public.fiscal_documents d
  join public.order_items oi on oi.order_id = d.order_id and oi.status <> 'void'
  join public.order_item_tax_lines tl on tl.order_item_id = oi.id
  where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and d.status = 'active'
    and (d.issued_at at time zone 'America/Santo_Domingo')::date
        between date '2026-08-01' and date '2026-08-31'
  group by oi.id, oi.created_at, oi.tax_rate
)
select dia,
       count(*)                                                   as items,
       count(*) filter (where abs(tasa_item - tasa_lineas) > 0.5)  as no_cuadran,
       round(100.0 * count(*) filter (where abs(tasa_item - tasa_lineas) > 0.5)
             / nullif(count(*),0), 1)                             as pct
from x
group by dia
having count(*) filter (where abs(tasa_item - tasa_lineas) > 0.5) > 0
order by no_cuadran desc;


-- ---------------------------------------------------------------------------
-- 10. LA BANDERA QUE DECIDE TODO: taxes.include_in_ecf
--
--     Existe desde 20260506_0004, tiene interruptor en Ajustes > Impuestos y
--     significa "este impuesto se declara a la DGII". La app YA la usa; la
--     unica pieza que seguia en is_service_fee era fn_recompute_fd_for_scope.
--
--     LO QUE HAY QUE VER:
--        ITBIS 18%  -> include_in_ecf = true
--        LEY   10%  -> include_in_ecf = FALSE
--
--     El backfill de 20260506_0004 puso include_in_ecf = NOT is_service_fee.
--     Como la LEY de La Penda tiene is_service_fee = false, lo mas probable es
--     que este en TRUE, o sea marcada como declarable. Si es asi, hay que
--     apagarla ANTES de aplicar la migracion 20260902_0007 o el ITBIS saldra
--     inflado con la porcion de la Ley.
-- ---------------------------------------------------------------------------
select
  t.name,
  t.rate,
  t.is_active,
  t.include_in_ecf,          -- <=== la LEY tiene que estar en FALSE
  t.is_service_fee,          -- (informativo: NO se toca)
  case
    when upper(t.name) like '%ITBIS%' and not t.include_in_ecf then 'REVISAR: ITBIS sin declarar'
    when upper(t.name) like '%LEY%'   and     t.include_in_ecf then 'APAGAR: la Ley no se declara'
    else 'ok'
  end as veredicto
from public.taxes t
where t.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
order by t.rate desc;

-- Como quedaria el reparto con la config ACTUAL (esto es lo que hara la v6):
select
  coalesce(sum(t.rate) filter (where     coalesce(t.include_in_ecf, true)), 0) as tasa_declarable,
  coalesce(sum(t.rate) filter (where not coalesce(t.include_in_ecf, true)), 0) as tasa_no_declarable
from public.taxes t
where t.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(t.is_active, true);
-- ESPERADO PARA QUE EL 607 SALGA BIEN:  declarable 18  /  no declarable 10
-- Si sale  declarable 28 / no declarable 0  -> falta apagar el toggle de la LEY.
