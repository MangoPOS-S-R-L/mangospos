-- ============================================================================
-- LA PENDA EXPRESS — Gastos del 29 de agosto de 2026
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
-- ============================================================================
-- OJO CON LA FECHA: created_at es timestamptz y el servidor guarda en UTC.
-- Filtrar por '2026-08-29' a secas corta el dia en UTC y se come los gastos
-- de la noche (a partir de las 8:00 PM de RD ya es dia 30 en UTC). Por eso
-- todo va con el huso de Republica Dominicana (-04, sin horario de verano).
--
-- Un GASTO no es lo mismo que un RETIRO: 'expense' es plata que se fue del
-- negocio (compra de hielo, gas, mandado); 'withdrawal' es efectivo que se
-- saco de la gaveta y sigue siendo del negocio. Van los dos, separados.
-- ============================================================================


-- 1) DETALLE — un renglon por movimiento ────────────────────────────────────
select ct.created_at at time zone 'America/Santo_Domingo' as fecha_hora,
       case ct.type
         when 'expense'    then 'GASTO'
         when 'withdrawal' then 'RETIRO'
         else upper(ct.type)
       end                                                as tipo,
       coalesce(r.label, ct.reason_code, '(sin razon)')    as concepto,
       abs(ct.amount)                                      as monto,
       ct.description                                      as descripcion,
       cr.name                                             as caja,
       coalesce(e.first_name || ' ' || e.last_name, '(sin identificar)') as registrado_por,
       ct.approval_pin_used                                as con_pin_supervisor
from public.cash_transactions ct
join public.cash_register_sessions s on s.id = ct.session_id
join public.cash_registers cr        on cr.id = s.cash_register_id
left join public.cash_transaction_reasons r on r.id = ct.reason_id
left join public.employees e on e.user_id = ct.created_by
                            and e.business_id = cr.business_id
where cr.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid
  and ct.type in ('expense', 'withdrawal')
  and ct.created_at >= timestamptz '2026-08-29 00:00:00-04'
  and ct.created_at <  timestamptz '2026-08-30 00:00:00-04'
order by ct.created_at;


-- 2) RESUMEN — cuanto se fue y en que ───────────────────────────────────────
select case ct.type when 'expense' then 'GASTO' else 'RETIRO' end as tipo,
       coalesce(r.label, ct.reason_code, '(sin razon)')            as concepto,
       count(*)                                                    as movimientos,
       sum(abs(ct.amount))                                         as total
from public.cash_transactions ct
join public.cash_register_sessions s on s.id = ct.session_id
join public.cash_registers cr        on cr.id = s.cash_register_id
left join public.cash_transaction_reasons r on r.id = ct.reason_id
where cr.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid
  and ct.type in ('expense', 'withdrawal')
  and ct.created_at >= timestamptz '2026-08-29 00:00:00-04'
  and ct.created_at <  timestamptz '2026-08-30 00:00:00-04'
group by rollup (1, 2)
order by 1 nulls last, 4 desc nulls last;


-- 3) POR SI "GASTOS" ERA OTRA COSA — compras registradas ese dia ────────────
-- En La Penda tambien se le dice gasto a la factura del suplidor. Esto no
-- toca la caja: son ordenes de compra creadas el 29.
select po.order_number,
       po.status,
       sup.name        as suplidor,
       po.subtotal,
       po.tax,
       po.total,
       po.received_date,
       po.created_at at time zone 'America/Santo_Domingo' as creada
from public.purchase_orders po
left join public.suppliers sup on sup.id = po.supplier_id
where po.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid
  and po.created_at >= timestamptz '2026-08-29 00:00:00-04'
  and po.created_at <  timestamptz '2026-08-30 00:00:00-04'
order by po.created_at;
