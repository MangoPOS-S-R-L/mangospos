-- =============================================================================
-- LA PENDA EXPRESS — corregir el desglose ITBIS/LEY de comprobantes YA emitidos
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Repara el daño de H-1 (auditoría DH del 31-ago-2026). La migración
-- 20260902_0007 arregla la función para los comprobantes NUEVOS; esto arregla
-- los viejos, que la función no vuelve a tocar.
--
-- ORDEN OBLIGATORIO:
--   1. Aplicar 20260902_0007_fd_split_by_tax_name.sql
--   2. Correr los pasos 1 y 2 de AQUÍ (dry run) y comparar con DH
--   3. Solo si el paso 2 cuadra, correr el paso 3
--
-- LOS PASOS 1 Y 2 NO ESCRIBEN NADA. El paso 3 sí. No lo corras de corrido.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- PASO 1 · DRY RUN — qué cambiaría, comprobante por comprobante.
--
-- Calcula el desglose por DOS caminos distintos a propósito, para poder
-- elegir con criterio:
--
--   A) ANCLADO EN EL DOCUMENTO: el monto del impuesto es total - subtotal +
--      descuento (lo que el comprobante realmente facturó) y los ítems solo
--      dicen la PROPORCIÓN ITBIS/LEY. Garantiza que subtotal + ITBIS + LEY
--      cierre contra el total. Es lo que aprendimos a la mala en el feed
--      contable (20260830_0008).
--
--   B) DERIVADO DE LOS ÍTEMS: suma el impuesto de las líneas, igual que hace
--      la función v6. Si el comprobante y sus ítems están sanos, A y B dan lo
--      mismo. Donde difieran, hay algo más que mirar (ítems anulados después
--      de facturar, cuentas divididas, H-3/H-4).
--
-- CAMBIA ESTAS DOS FECHAS PARA OTRO MES.
-- ---------------------------------------------------------------------------
with params as (
  select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as biz,
         date '2026-08-01' as desde,
         date '2026-08-31' as hasta
),
tasas as (
  -- Manda el interruptor de Ajustes > Impuestos (include_in_ecf) SI el negocio
  -- ya lo configuro; si no, respaldo por el nombre. Igual que la v6 de
  -- fn_recompute_fd_for_scope: no exige tocar la config de un negocio vivo.
  select case when x.usa_flag then x.r_ecf else x.r_name_ecf end as r_itbis,
         case when x.usa_flag then x.r_non else x.r_name_non end as r_ley
  from (
    select
      coalesce(bool_or(coalesce(t.include_in_ecf, true) = false), false)          as usa_flag,
      coalesce(sum(t.rate) filter (where     coalesce(t.include_in_ecf, true)),0) as r_ecf,
      coalesce(sum(t.rate) filter (where not coalesce(t.include_in_ecf, true)),0) as r_non,
      coalesce(sum(t.rate) filter (where upper(t.name) like     '%ITBIS%'), 0)    as r_name_ecf,
      coalesce(sum(t.rate) filter (where upper(t.name) not like '%ITBIS%'), 0)    as r_name_non
    from public.taxes t, params p
  where t.business_id = p.biz and coalesce(t.is_active, true)
  ) x
),
fd as (
  select d.id, d.ncf_number, d.order_id, d.check_id, d.issued_at,
         coalesce(d.subtotal,0)     as subtotal,
         coalesce(d.discount,0)     as descuento,
         coalesce(d.total,0)        as total,
         coalesce(d.itbis_amount,0) as itbis_hoy,
         coalesce(d.service_fee,0)  as ley_hoy
  from public.fiscal_documents d, params p
  where d.business_id = p.biz
    and d.status = 'active'
    and (d.issued_at at time zone 'America/Santo_Domingo')::date between p.desde and p.hasta
),
-- Split por ítem, misma regla que la función v6. NO usa order_item_tax_lines:
-- esa tabla se reescribe desde menu_item_taxes y no es historia de lo cobrado.
per_item as (
  select oi.order_id, oi.check_id,
         coalesce(oi.tax, 0) as impuesto,
         case
           when t.r_itbis > 0 and t.r_ley > 0
                and abs(oi.tax_rate - (t.r_itbis + t.r_ley)) < 0.5
             then round(coalesce(oi.tax,0) * t.r_itbis / (t.r_itbis + t.r_ley), 2)
           when t.r_itbis > 0 and abs(oi.tax_rate - t.r_itbis) < 0.5
             then coalesce(oi.tax, 0)
           else 0
         end as itbis_item
  from public.order_items oi
  cross join tasas t
  where oi.status <> 'void'
    and oi.order_id in (select f.order_id from fd f where f.order_id is not null)
),
der_check as (
  select order_id, check_id, sum(itbis_item) as itbis, sum(impuesto) as impuesto
  from per_item group by order_id, check_id
),
der_order as (
  select order_id, sum(itbis_item) as itbis, sum(impuesto) as impuesto
  from per_item group by order_id
),
calc as (
  select f.*,
         greatest(f.total - f.subtotal + f.descuento, 0)   as impuesto_del_documento,
         coalesce(dc.itbis,    do_.itbis,    0)            as itbis_items,
         coalesce(dc.impuesto, do_.impuesto, 0)            as impuesto_items
  from fd f
  left join der_check dc on dc.order_id = f.order_id and dc.check_id = f.check_id
  left join der_order do_ on do_.order_id = f.order_id
),
final as (
  select c.*,
         case when c.impuesto_items > 0
              then c.itbis_items / c.impuesto_items else null end as ratio,
         -- A) anclado en el documento
         round(c.impuesto_del_documento
               * coalesce(case when c.impuesto_items > 0
                          then c.itbis_items / c.impuesto_items end, 1), 2) as itbis_A,
         -- B) derivado de los ítems
         round(c.itbis_items, 2)                                            as itbis_B
  from calc c
)
select
  ncf_number,
  (issued_at at time zone 'America/Santo_Domingo')::date as fecha,
  subtotal, total,
  itbis_hoy,
  itbis_A                                   as itbis_anclado_en_documento,
  itbis_B                                   as itbis_derivado_de_items,
  round(impuesto_del_documento - itbis_A, 2) as ley_anclada,
  round(itbis_A - itbis_hoy, 2)             as diferencia,
  case when abs(itbis_A - itbis_B) > 0.05 then 'REVISAR' else 'ok' end as concuerdan,
  check_id is not null                      as es_subcuenta,
  order_id
from final
where abs(itbis_A - itbis_hoy) > 0.005
order by abs(itbis_A - itbis_hoy) desc
limit 100;


-- ---------------------------------------------------------------------------
-- PASO 2 · EL TOTAL. Este es el número que hay que cotejar con DH antes de
-- escribir nada.
--
-- ESPERADO SEGÚN LA AUDITORÍA:
--   itbis_hoy      ~ RD$ 305,016.63   (yo medí 305,377.56; el criterio de corte
--                                      de fecha explica la diferencia)
--   itbis_corregido~ RD$ 779,169.11
--   diferencia     ~ RD$ 474,152.48
--
-- Es la MISMA consulta del paso 1, agregada. Si cambias fechas arriba,
-- cámbialas aquí también.
-- ---------------------------------------------------------------------------
with params as (
  select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as biz,
         date '2026-08-01' as desde,
         date '2026-08-31' as hasta
),
tasas as (
  -- Manda el interruptor de Ajustes > Impuestos (include_in_ecf) SI el negocio
  -- ya lo configuro; si no, respaldo por el nombre. Igual que la v6 de
  -- fn_recompute_fd_for_scope: no exige tocar la config de un negocio vivo.
  select case when x.usa_flag then x.r_ecf else x.r_name_ecf end as r_itbis,
         case when x.usa_flag then x.r_non else x.r_name_non end as r_ley
  from (
    select
      coalesce(bool_or(coalesce(t.include_in_ecf, true) = false), false)          as usa_flag,
      coalesce(sum(t.rate) filter (where     coalesce(t.include_in_ecf, true)),0) as r_ecf,
      coalesce(sum(t.rate) filter (where not coalesce(t.include_in_ecf, true)),0) as r_non,
      coalesce(sum(t.rate) filter (where upper(t.name) like     '%ITBIS%'), 0)    as r_name_ecf,
      coalesce(sum(t.rate) filter (where upper(t.name) not like '%ITBIS%'), 0)    as r_name_non
    from public.taxes t, params p
  where t.business_id = p.biz and coalesce(t.is_active, true)
  ) x
),
fd as (
  select d.id, d.order_id, d.check_id,
         coalesce(d.subtotal,0) as subtotal, coalesce(d.discount,0) as descuento,
         coalesce(d.total,0) as total, coalesce(d.itbis_amount,0) as itbis_hoy
  from public.fiscal_documents d, params p
  where d.business_id = p.biz and d.status = 'active'
    and (d.issued_at at time zone 'America/Santo_Domingo')::date between p.desde and p.hasta
),
per_item as (
  select oi.order_id, oi.check_id, coalesce(oi.tax,0) as impuesto,
         case
           when t.r_itbis > 0 and t.r_ley > 0
                and abs(oi.tax_rate - (t.r_itbis + t.r_ley)) < 0.5
             then round(coalesce(oi.tax,0) * t.r_itbis / (t.r_itbis + t.r_ley), 2)
           when t.r_itbis > 0 and abs(oi.tax_rate - t.r_itbis) < 0.5
             then coalesce(oi.tax,0)
           else 0
         end as itbis_item
  from public.order_items oi
  cross join tasas t
  where oi.status <> 'void'
    and oi.order_id in (select f.order_id from fd f where f.order_id is not null)
),
der_check as (select order_id, check_id, sum(itbis_item) i, sum(impuesto) x
              from per_item group by order_id, check_id),
der_order as (select order_id, sum(itbis_item) i, sum(impuesto) x
              from per_item group by order_id),
calc as (
  select f.*,
         greatest(f.total - f.subtotal + f.descuento, 0) as imp_doc,
         coalesce(dc.i, do_.i, 0) as i_items,
         coalesce(dc.x, do_.x, 0) as x_items
  from fd f
  left join der_check dc on dc.order_id = f.order_id and dc.check_id = f.check_id
  left join der_order do_ on do_.order_id = f.order_id
)
select
  count(*)                                                    as comprobantes,
  count(*) filter (where itbis_hoy = 0 and imp_doc > 0)       as con_itbis_en_cero,
  round(sum(itbis_hoy), 2)                                    as itbis_hoy,
  round(sum(round(imp_doc * coalesce(case when x_items > 0
        then i_items / x_items end, 1), 2)), 2)               as itbis_corregido,
  round(sum(round(imp_doc * coalesce(case when x_items > 0
        then i_items / x_items end, 1), 2)) - sum(itbis_hoy), 2) as diferencia,
  count(*) filter (where x_items = 0 and imp_doc > 0)
    as sin_senal_de_items_REVISAR
from calc;


-- ---------------------------------------------------------------------------
-- PASO 2b · ¿CUÁNTAS FILAS TOCARÍA EXACTAMENTE?
--
-- OJO: no son sólo las ~1.977 que están en cero. Un comprobante de 18% puro con
-- el ITBIS bien guardado también se actualiza si el recálculo difiere en más de
-- medio centavo. Este es el número real de filas que va a escribir el paso 4.
-- ---------------------------------------------------------------------------
with params as (
  select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as biz,
         date '2026-08-01' as desde, date '2026-08-31' as hasta
),
tasas as (
  -- Manda el interruptor de Ajustes > Impuestos (include_in_ecf) SI el negocio
  -- ya lo configuro; si no, respaldo por el nombre. Igual que la v6 de
  -- fn_recompute_fd_for_scope: no exige tocar la config de un negocio vivo.
  select case when x.usa_flag then x.r_ecf else x.r_name_ecf end as r_itbis,
         case when x.usa_flag then x.r_non else x.r_name_non end as r_ley
  from (
    select
      coalesce(bool_or(coalesce(t.include_in_ecf, true) = false), false)          as usa_flag,
      coalesce(sum(t.rate) filter (where     coalesce(t.include_in_ecf, true)),0) as r_ecf,
      coalesce(sum(t.rate) filter (where not coalesce(t.include_in_ecf, true)),0) as r_non,
      coalesce(sum(t.rate) filter (where upper(t.name) like     '%ITBIS%'), 0)    as r_name_ecf,
      coalesce(sum(t.rate) filter (where upper(t.name) not like '%ITBIS%'), 0)    as r_name_non
    from public.taxes t, params p
  where t.business_id = p.biz and coalesce(t.is_active, true)
  ) x
),
fd as (
  select d.id, d.order_id, d.check_id, coalesce(d.subtotal,0) as subtotal,
         coalesce(d.discount,0) as descuento, coalesce(d.total,0) as total,
         coalesce(d.itbis_amount,0) as itbis_hoy
  from public.fiscal_documents d, params p
  where d.business_id = p.biz and d.status = 'active'
    and (d.issued_at at time zone 'America/Santo_Domingo')::date between p.desde and p.hasta
),
per_item as (
  select oi.order_id, oi.check_id, coalesce(oi.tax,0) as impuesto,
         case when t.r_itbis > 0 and t.r_ley > 0
                   and abs(oi.tax_rate - (t.r_itbis + t.r_ley)) < 0.5
                then round(coalesce(oi.tax,0) * t.r_itbis / (t.r_itbis + t.r_ley), 2)
              when t.r_itbis > 0 and abs(oi.tax_rate - t.r_itbis) < 0.5
                then coalesce(oi.tax,0)
              else 0 end as itbis_item
  from public.order_items oi cross join tasas t
  where oi.status <> 'void'
    and oi.order_id in (select f.order_id from fd f where f.order_id is not null)
),
der_check as (select order_id, check_id, sum(itbis_item) i, sum(impuesto) x
              from per_item group by order_id, check_id),
der_order as (select order_id, sum(itbis_item) i, sum(impuesto) x
              from per_item group by order_id),
n as (
  select f.id, f.itbis_hoy,
         greatest(f.total - f.subtotal + f.descuento, 0) as imp_doc,
         coalesce(dc.i, do_.i, 0) as i, coalesce(dc.x, do_.x, 0) as x
  from fd f
  left join der_check dc on dc.order_id = f.order_id and dc.check_id = f.check_id
  left join der_order do_ on do_.order_id = f.order_id
)
select
  count(*)                                              as comprobantes_en_el_rango,
  count(*) filter (where x = 0)                         as excluidos_sin_senal_de_items,
  count(*) filter (where x > 0
                     and abs(itbis_hoy - round(imp_doc * (i/x), 2)) > 0.005)
                                                        as FILAS_QUE_SE_VAN_A_ESCRIBIR,
  count(*) filter (where x > 0 and itbis_hoy > 0
                     and abs(itbis_hoy - round(imp_doc * (i/x), 2)) > 0.005)
                                                        as de_esas_ya_tenian_itbis_distinto_de_cero
from n;


-- ---------------------------------------------------------------------------
-- PASO 3 · ANTES DE ESCRIBIR — qué se dispara al hacer UPDATE.
--
-- Un UPDATE sobre fiscal_documents puede tener efectos colaterales. Hay que
-- mirarlos ANTES, no después.
--
-- LO QUE HAY QUE VER:
--   * Si aparece un trigger de e-CF / Alanube en UPDATE  -> NO CORRER EL PASO 4.
--     (en jun-2026 se documentó que el hook es AFTER INSERT, pero la BD viva
--      diverge del repo: hay que confirmarlo aquí, no asumirlo)
--   * Cualquier otro trigger en UPDATE hay que leerlo antes.
-- ---------------------------------------------------------------------------
select t.tgname, p.proname as ejecuta, t.tgenabled, pg_get_triggerdef(t.oid) as definicion
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_proc  p on p.oid = t.tgfoid
where c.relname = 'fiscal_documents' and not t.tgisinternal;

-- ¿Alguno de estos comprobantes es e-CF ya transmitido a la DGII? Un e-CF
-- enviado NO se puede reescribir: se corrige con nota de crédito, no con UPDATE.
select ncf_type, count(*), min(issued_at), max(issued_at)
from public.fiscal_documents
where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and status = 'active'
  and (issued_at at time zone 'America/Santo_Domingo')::date
      between date '2026-08-01' and date '2026-08-31'
group by ncf_type order by 2 desc;


-- ---------------------------------------------------------------------------
-- PASO 4 · EL BACKFILL. ESCRIBE EN fiscal_documents.
--
-- NO LO CORRAS hasta que: (a) DH confirme el número del paso 2, (b) el paso 3
-- no muestre triggers de e-CF en UPDATE.
--
-- QUÉ TOCA:  únicamente itbis_amount y service_fee.
-- QUÉ NO TOCA: subtotal, total, NCF, status, issued_at, cliente, pagos, ítems.
--              El monto cobrado al cliente NO cambia. Sólo el desglose.
--
-- Toma respaldo en public._backup_fd_607_penda_agosto ANTES de escribir, así
-- que es reversible (el UNDO está al final, comentado).
--
-- Descarta los comprobantes sin señal de ítems (x = 0): ahí el reparto sería
-- adivinanza. Son los de H-3/H-4 y van a mano.
--
-- Va en una transacción explícita. Revisa el conteo ANTES del COMMIT.
-- ---------------------------------------------------------------------------
/*
BEGIN;

-- 4.1 RESPALDO. Si la tabla ya existe, esto falla a propósito: quiere decir que
--     el backfill ya se corrió y no hay que pisar el respaldo original.
create table public._backup_fd_607_penda_agosto as
select id, subtotal, discount, taxable_amount, itbis_amount, service_fee, total,
       now() as respaldado_en
from public.fiscal_documents
where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and status = 'active'
  and (issued_at at time zone 'America/Santo_Domingo')::date
      between date '2026-08-01' and date '2026-08-31';

-- 4.2 EL UPDATE.
with params as (
  select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as biz,
         date '2026-08-01' as desde, date '2026-08-31' as hasta
),
tasas as (
  -- Manda el interruptor de Ajustes > Impuestos (include_in_ecf) SI el negocio
  -- ya lo configuro; si no, respaldo por el nombre. Igual que la v6 de
  -- fn_recompute_fd_for_scope: no exige tocar la config de un negocio vivo.
  select case when x.usa_flag then x.r_ecf else x.r_name_ecf end as r_itbis,
         case when x.usa_flag then x.r_non else x.r_name_non end as r_ley
  from (
    select
      coalesce(bool_or(coalesce(t.include_in_ecf, true) = false), false)          as usa_flag,
      coalesce(sum(t.rate) filter (where     coalesce(t.include_in_ecf, true)),0) as r_ecf,
      coalesce(sum(t.rate) filter (where not coalesce(t.include_in_ecf, true)),0) as r_non,
      coalesce(sum(t.rate) filter (where upper(t.name) like     '%ITBIS%'), 0)    as r_name_ecf,
      coalesce(sum(t.rate) filter (where upper(t.name) not like '%ITBIS%'), 0)    as r_name_non
    from public.taxes t, params p
  where t.business_id = p.biz and coalesce(t.is_active, true)
  ) x
),
fd as (
  select d.id, d.order_id, d.check_id, coalesce(d.subtotal,0) as subtotal,
         coalesce(d.discount,0) as descuento, coalesce(d.total,0) as total
  from public.fiscal_documents d, params p
  where d.business_id = p.biz and d.status = 'active'
    and (d.issued_at at time zone 'America/Santo_Domingo')::date between p.desde and p.hasta
),
per_item as (
  select oi.order_id, oi.check_id, coalesce(oi.tax,0) as impuesto,
         case when t.r_itbis > 0 and t.r_ley > 0
                   and abs(oi.tax_rate - (t.r_itbis + t.r_ley)) < 0.5
                then round(coalesce(oi.tax,0) * t.r_itbis / (t.r_itbis + t.r_ley), 2)
              when t.r_itbis > 0 and abs(oi.tax_rate - t.r_itbis) < 0.5
                then coalesce(oi.tax,0)
              else 0 end as itbis_item
  from public.order_items oi cross join tasas t
  where oi.status <> 'void'
    and oi.order_id in (select f.order_id from fd f where f.order_id is not null)
),
der_check as (select order_id, check_id, sum(itbis_item) i, sum(impuesto) x
              from per_item group by order_id, check_id),
der_order as (select order_id, sum(itbis_item) i, sum(impuesto) x
              from per_item group by order_id),
nuevo as (
  select f.id,
         greatest(f.total - f.subtotal + f.descuento, 0) as imp_doc,
         round(greatest(f.total - f.subtotal + f.descuento, 0)
               * (coalesce(dc.i, do_.i, 0) / coalesce(dc.x, do_.x, 0)), 2) as itbis_nuevo
  from fd f
  left join der_check dc on dc.order_id = f.order_id and dc.check_id = f.check_id
  left join der_order do_ on do_.order_id = f.order_id
  where coalesce(dc.x, do_.x, 0) > 0
)
update public.fiscal_documents d
   set itbis_amount = n.itbis_nuevo,
       service_fee  = round(n.imp_doc - n.itbis_nuevo, 2)
  from nuevo n
 where d.id = n.id
   and abs(coalesce(d.itbis_amount,0) - n.itbis_nuevo) > 0.005;

-- 4.3 VERIFICAR ANTES DEL COMMIT. Tiene que dar el número del paso 2.
select count(*)                        as comprobantes,
       round(sum(itbis_amount), 2)     as itbis_ahora,
       round(sum(service_fee), 2)      as ley_ahora,
       round(sum(subtotal + itbis_amount + service_fee - total), 2) as descuadre_total
from public.fiscal_documents
where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and status = 'active'
  and (issued_at at time zone 'America/Santo_Domingo')::date
      between date '2026-08-01' and date '2026-08-31';

-- Si NO se parece al paso 2:  ROLLBACK;
-- Si cuadra:                  COMMIT;
*/


-- ---------------------------------------------------------------------------
-- DESHACER — sólo si ya se hizo COMMIT y hay que volver atrás.
-- ---------------------------------------------------------------------------
/*
BEGIN;
update public.fiscal_documents d
   set subtotal       = b.subtotal,
       discount       = b.discount,
       taxable_amount = b.taxable_amount,
       itbis_amount   = b.itbis_amount,
       service_fee    = b.service_fee,
       total          = b.total
  from public._backup_fd_607_penda_agosto b
 where d.id = b.id;
-- COMMIT;
-- drop table public._backup_fd_607_penda_agosto;   -- sólo cuando ya no haga falta
*/
