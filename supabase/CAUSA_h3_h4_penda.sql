-- =============================================================================
-- CAUSA de H-3 y H-4 — La Penda Express
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- HIPOTESIS (de la migracion 20260812_0001, escrita y NUNCA aplicada):
--   fiscal_documents tiene RLS con policies de INSERT y SELECT para
--   `authenticated`, pero NINGUNA de UPDATE. El UPDATE afecta 0 filas y
--   PostgREST responde 200: falla EN SILENCIO.
--   Al anular una venta el pago pasa a 'cancelled' pero el NCF queda 'active'.
--
-- COMO SE CONFIRMA: si los 9 de H-4 tienen pagos en estado 'cancelled',
-- entonces la anulacion SI se ejecuto y lo unico que no cuajo fue el
-- comprobante. Eso prueba la causa.
--
-- SOLO LECTURA.
-- =============================================================================

-- A ─── ¿EXISTE HOY la policy de UPDATE? ──────────────────────────────────────
--     RESULTADO 1-sep-2026: fd_update SI EXISTE. La migracion 20260812_0001
--     esta aplicada y anular ventas FUNCIONA hoy.
--
--     PERO los 9 comprobantes de H-4 son del 1 al 10 de agosto: TODOS
--     anteriores al 12. La hipotesis pasa a ser que el bug existio, hizo ese
--     dano, y se cerro al aplicar la policy. Lo confirma la consulta E: si no
--     hay NCF fantasma despues del 12-ago, la causa esta cerrada.
select polname as policy, polcmd as comando,
       pg_get_expr(polqual, polrelid)      as using_expr,
       pg_get_expr(polwithcheck, polrelid) as with_check
from pg_policy
where polrelid = 'public.fiscal_documents'::regclass
order by polcmd, polname;


-- B ─── LA PRUEBA: estado de los pagos de los 20 comprobantes problematicos ───
--     Si aparecen pagos 'cancelled' -> la anulacion CORRIO y el NCF se quedo
--     atras. Causa confirmada.
--     Si NO hay ningun pago -> es otra cosa (se anularon items a mano).
select
  d.ncf_number,
  d.issued_at::date                                   as fecha,
  d.status                                            as estado_del_ncf,
  d.total,
  count(p.*)                                          as pagos_totales,
  count(p.*) filter (where p.status = 'completed')    as completados,
  count(p.*) filter (where p.status = 'cancelled')    as cancelados,
  count(p.*) filter (where p.status not in ('completed','cancelled')) as otros,
  max(p.created_at)                                   as ultimo_pago,
  count(oi.*)                                         as items,
  count(oi.*) filter (where oi.status = 'void')       as items_anulados
from public.fiscal_documents d
left join public.payments p     on p.order_id = d.order_id
left join public.order_items oi on oi.order_id = d.order_id
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.ncf_number in (
    -- H-4 (9)
    'B0200154331','B0200155575','B0200153870','B0200154723','B0200155167',
    'B0200154457','B0100015497','B0200154020','B0100015499',
    -- H-3 (4, incluida la que el auditor no reporto)
    'B0200159100','B0200157123','B0200158089','B0200159130',
    -- lote del 13-ago (7)
    'B0200155952','B0200155953','B0200155954','B0200155956',
    'B0200155957','B0200155958','B0200155959'
  )
group by d.id, d.ncf_number, d.issued_at, d.status, d.total
order by d.issued_at, d.ncf_number;


-- C ─── Contraste: las 15 anulaciones que SI funcionaron ──────────────────────
--     El auditor verifico que 15 ventas anuladas tienen su devolucion. Si esas
--     tienen fd.status='cancelled', hay DOS caminos de anulacion distintos y
--     hay que ver cual usa cual.
select d.ncf_number, d.issued_at::date as fecha, d.cancelled_at::date as anulado,
       d.cancellation_reason, d.cancelled_by is not null as tiene_autor,
       count(p.*) filter (where p.status = 'cancelled') as pagos_cancelados
from public.fiscal_documents d
left join public.payments p on p.order_id = d.order_id
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.status = 'cancelled'
  and (d.issued_at at time zone 'America/Santo_Domingo')::date
      between date '2026-08-01' and date '2026-08-31'
group by d.id, d.ncf_number, d.issued_at, d.cancelled_at,
         d.cancellation_reason, d.cancelled_by
order by d.cancelled_at;


-- D ─── ¿Quedo rastro en audit_logs? ──────────────────────────────────────────
select a.created_at, a.action, a.reason, a.ref_table, a.ref_id,
       coalesce(e.first_name || ' ' || e.last_name, a.user_id::text) as quien
from public.audit_logs a
left join public.employees e on e.user_id = a.user_id
                            and e.business_id = a.business_id
where a.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and a.created_at >= date '2026-08-01'
  and a.created_at <  date '2026-09-02'
  and (a.action ilike '%anul%' or a.action ilike '%void%' or a.action ilike '%cancel%')
order by a.created_at desc
limit 50;


-- E ─── El alcance real: ¿cuantos NCF vivos hay hoy sin venta detras? ─────────
--     No solo agosto. Si el bug sigue vivo, septiembre ya esta acumulando.
select (d.issued_at at time zone 'America/Santo_Domingo')::date as fecha,
       count(*)                as ncf_activos_sin_venta,
       round(sum(d.total), 2)  as monto
from public.fiscal_documents d
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.status = 'active'
  and d.issued_at >= date '2026-07-01'
  and not exists (select 1 from public.payments p
                   where p.order_id = d.order_id and p.status = 'completed')
  and exists (select 1 from public.order_items oi where oi.order_id = d.order_id)
  and not exists (select 1 from public.order_items oi
                   where oi.order_id = d.order_id and oi.status <> 'void')
group by 1
order by 1 desc;
