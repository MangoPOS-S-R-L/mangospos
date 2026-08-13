-- ============================================================================
-- Ventas con pago MIXTO que quedaron a medio anular
-- Negocio 6e18428f-fdd6-4c58-af0e-dae2403fbf1d (LA COCINA MEXICANA AUTENTICA)
--
-- Síntoma: el historial marca la venta ANULADA (el NCF quedó cancelado) pero
-- la orden revivió como `partially_paid`, la mesa volvió a `occupied` y las
-- otras piernas del pago siguen en `completed` sin forma de anularlas desde
-- la UI.
--
-- Causa: `annulPayment` cancelaba solo el pago pivote (el que creó el NCF) y
-- caía al flujo de anulación parcial. Corregido en sales_repository.dart;
-- este script repara lo que quedó mal ANTES del fix.
--
-- El PASO 1 es SOLO LECTURA. Corre el PASO 2 solo sobre las órdenes que el
-- PASO 1 haya listado.
-- ============================================================================

-- ─── PASO 1) DETECTAR ───────────────────────────────────────────────────────
--   Ventas a medio anular, en TODOS los negocios. Dos formas de quedar así:
--     a) NCF cancelado con pagos todavía vivos.
--     b) Orden anulada (status_ext = 'void') con el NCF todavía activo — el
--        caso que producía la falta de policy de UPDATE en fiscal_documents.
--   Filtra PRIMERO con EXISTS y solo después agrega sobre las coincidencias.
--   Agrupar la tabla completa reventaba con 53100 ("could not resize shared
--   memory segment"): los workers paralelos no caben en /dev/shm del
--   contenedor. Si aun así falla, corre antes:
--       set max_parallel_workers_per_gather = 0;
--   y acota con el filtro de fecha de abajo.

set max_parallel_workers_per_gather = 0;

select
  b.business_name,
  fd.id                                   as fiscal_document_id,
  fd.ncf_number,
  fd.status                               as doc_fiscal,
  fd.order_id,
  o.status,
  o.status_ext,
  dt.code                                 as mesa,
  dt.state                                as estado_mesa,
  agg.pagos_vivos,
  agg.pagos_anulados,
  agg.monto_vivo,
  case
    when fd.status = 'cancelled' then 'NCF anulado con pagos vivos'
    else 'orden anulada con NCF activo'
  end                                     as sintoma,
  fd.created_at at time zone 'America/Santo_Domingo' as emitido
from public.fiscal_documents fd
join public.orders o     on o.id = fd.order_id
join public.businesses b on b.id = fd.business_id
left join public.table_sessions ts on ts.id = o.session_id
left join public.dining_tables dt  on dt.id = ts.table_id
cross join lateral (
  select
    count(*) filter (where p.status = 'completed')      as pagos_vivos,
    count(*) filter (where p.status = 'cancelled')      as pagos_anulados,
    sum(p.amount) filter (where p.status = 'completed') as monto_vivo
  from public.payments p
  where p.fiscal_document_id = fd.id
) agg
where
  -- ▼ acota si la instalación es grande
  fd.created_at >= current_date - 90
  and (
    (fd.status = 'cancelled' and agg.pagos_vivos > 0)
    or (o.status_ext = 'void' and fd.status <> 'cancelled')
  )
order by fd.created_at desc
limit 200;


-- ─── PASO 2) REPARAR una orden ──────────────────────────────────────────────
--   Pon el order_id del PASO 1 en v_order. Deja la venta como la habría
--   dejado `annulOrder`: pagos cancelados, ítems en void, orden cerrada como
--   void, mesa liberada y la caja revertida por cada pierna en efectivo.
--   Idempotente. Todo en una transacción.

begin;

do $$
declare
  -- ▼▼▼ order_id a reparar (columna order_id del PASO 1)
  v_order    uuid := '00000000-0000-0000-0000-000000000000';
  v_motivo   text := 'Anulación manual — venta quedó a medias';
  -- ▲▲▲
  v_pagos    int;
  v_items    int;
  v_caja     int := 0;
  r          record;
  fdr        record;
begin
  if v_order = '00000000-0000-0000-0000-000000000000' then
    raise exception 'Pon el order_id del PASO 1 en v_order.';
  end if;

  if not exists (select 1 from public.orders where id = v_order) then
    raise exception 'La orden % no existe.', v_order;
  end if;

  -- 0) Guardar los montos de los NCF de la orden. El trigger
  --    trg_fn_recompute_fd_on_payment_change (SECURITY DEFINER) recalcula
  --    fd.total cada vez que cambia el status de un payment, y al cancelar
  --    todas las piernas lo dejaría en 0 — borrando el rastro de qué se
  --    facturó. Se restauran en el paso 3.
  create temp table if not exists _fd_backup (
    id uuid primary key, total numeric, subtotal numeric,
    taxable_amount numeric, itbis_amount numeric, service_fee numeric
  ) on commit drop;

  insert into _fd_backup
  select id, total, subtotal, taxable_amount, itbis_amount, service_fee
  from public.fiscal_documents
  where order_id = v_order
  on conflict (id) do nothing;

  -- 1) Revertir caja por cada pierna en efectivo que siga viva, contra la
  --    sesión donde se cobró. Solo si no se revirtió antes.
  for r in
    select p.id, p.session_id,
           (p.amount - coalesce(p.change_amount, 0)) as neto
    from public.payments p
    join public.payment_methods pm on pm.id = p.payment_method_id
    where p.order_id = v_order
      and p.status = 'completed'
      and pm.code = 'cash'
      and p.session_id is not null
      and (p.amount - coalesce(p.change_amount, 0)) > 0
  loop
    if not exists (
      select 1 from public.cash_transactions ct
      where ct.session_id = r.session_id
        and ct.related_order_id = v_order
        and ct.amount = -r.neto
        and ct.description like 'Anulacion pago %'
    ) then
      insert into public.cash_transactions
        (session_id, amount, type, description, related_order_id)
      values
        (r.session_id, -r.neto, 'sale',
         'Anulacion pago ' || left(r.id::text, 8), v_order);
      v_caja := v_caja + 1;
    end if;
  end loop;

  -- 2) Cancelar los pagos que quedaron vivos.
  update public.payments
  set status = 'cancelled'
  where order_id = v_order and status = 'completed';
  get diagnostics v_pagos = row_count;

  -- 3) Cancelar los documentos fiscales de la orden, restaurando los montos
  --    que el trigger de recomputo haya pisado al cancelar los pagos.
  for fdr in select * from _fd_backup loop
    update public.fiscal_documents
    set status              = 'cancelled',
        cancelled_at        = coalesce(cancelled_at, now()),
        cancellation_reason = coalesce(cancellation_reason, v_motivo),
        total               = fdr.total,
        subtotal            = fdr.subtotal,
        taxable_amount      = fdr.taxable_amount,
        itbis_amount        = fdr.itbis_amount,
        service_fee         = fdr.service_fee
    where id = fdr.id;
  end loop;

  -- 4) Anular los ítems (los reportes filtran por status = 'void').
  update public.order_items
  set status = 'void'
  where order_id = v_order and status is distinct from 'void';
  get diagnostics v_items = row_count;

  -- 5) Cerrar la orden como void y liberar la mesa (misma RPC que usa la app).
  perform public.fn_close_order_and_table(v_order, 'void'::public.order_status);

  -- 6) CxC abiertas de la orden (si hubo pierna a crédito).
  update public.customer_credits
  set status = 'cancelled'
  where order_id = v_order
    and status in ('pending', 'partial', 'overdue');

  raise notice
    'OK — orden %: % pagos cancelados, % items anulados, % reversas de caja.',
    v_order, v_pagos, v_items, v_caja;
end $$;

commit;


-- ─── PASO 3) VERIFICAR ──────────────────────────────────────────────────────
--   `status` void, sin pagos vivos y la mesa libre.
select
  o.id,
  o.status,
  o.status_ext,
  o.closed_at,
  dt.code                                             as mesa,
  dt.state                                            as estado_mesa,
  count(*) filter (where p.status = 'completed')      as pagos_vivos,
  count(*) filter (where oi.status <> 'void')         as items_no_anulados
from public.orders o
left join public.payments p        on p.order_id = o.id
left join public.order_items oi    on oi.order_id = o.id
left join public.table_sessions ts on ts.id = o.session_id
left join public.dining_tables dt  on dt.id = ts.table_id
where o.id = '00000000-0000-0000-0000-000000000000'::uuid  -- ← mismo order_id
group by o.id, o.status, o.status_ext, o.closed_at, dt.code, dt.state;
