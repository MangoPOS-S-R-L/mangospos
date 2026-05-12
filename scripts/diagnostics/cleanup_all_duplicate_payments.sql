-- ============================================================================
-- Limpieza generalizada: payments duplicados pre-migración 20260510_0003
-- ============================================================================
--
-- Contexto:
--   La migración 20260509_0005 puso un unique index para evitar duplicados,
--   pero ya había rows existentes con duplicados (causados por doble-tap +
--   race conditions en concurrent RPC calls). El index `CREATE UNIQUE INDEX`
--   se aplicó con `IF NOT EXISTS` y probablemente NO se creó originalmente
--   por estos duplicados, dejando la DB sin defensa hasta hoy.
--
--   El diagnóstico identificó 11 grupos de duplicados al 11-mayo:
--     - 6cadb1f4 (5 cash en orden VOID — bug retry)
--     - 9e53bd8c (3 cash idénticos 160 ms apart — bug retry obvio)
--     - 2ae69f34, 93ac0ca9 (x2), 9636a0d6, cacacc7d, 0f3b3828 (ms apart)
--     - a0bb5c4f, 0d5ce7c8, a6daf8ce (legítimos splits del bug 09-may o
--       partial payments que entraron como duplicado)
--
-- Estrategia automatizada (esta consulta):
--   Por cada grupo (order_id, check_id, method_id) con duplicados completed:
--     - Quedarse con UNA fila. Prioridad:
--         (a) la que tiene fiscal_document_id NOT NULL (vinculada a NCF real),
--         (b) si ninguna o varias tienen NCF, la más antigua.
--     - Las demás pasan a status 'cancelled' con marca de timestamp.
--
--   NO se borran rows — quedan en cancelled con auditoría preservada.
--   NO se revierten cash_transactions automáticamente. Si la integridad del
--   cierre de caja importa históricamente, hacer cleanup manual de
--   cash_transactions duplicadas DESPUÉS de revisar reportes.
--
-- USO:
--   1) Correr BLOQUE 1 para preview (sin escribir nada).
--   2) Si el listado se ve razonable, correr BLOQUE 2 dentro de begin/commit.
--   3) Re-aplicar 20260510_0003_split_full_order_payments.sql.
--
-- IMPORTANTE: hacer un dump de payments antes:
--   pg_dump --table=public.payments -d <db> > payments_backup_pre_cleanup.sql
-- ============================================================================

-- ----------------------------------------------------------------------------
-- BLOQUE 1: Preview (read-only, qué se cancelaría)
-- ----------------------------------------------------------------------------

with grouped as (
  select
    order_id,
    coalesce(check_id, '00000000-0000-0000-0000-000000000000'::uuid) as ck,
    payment_method_id,
    -- Ranking: fiscal_document_id NOT NULL primero, después oldest.
    -- El "ganador" (a quedarse) tiene rn = 1.
    row_number() over (
      partition by
        order_id,
        coalesce(check_id, '00000000-0000-0000-0000-000000000000'::uuid),
        payment_method_id
      order by
        (fiscal_document_id is not null) desc,
        created_at asc
    ) as rn,
    id,
    amount,
    fiscal_document_id,
    created_at
  from public.payments
  where status = 'completed'
)
select
  g.order_id,
  g.payment_method_id,
  g.id as payment_id,
  g.amount,
  g.fiscal_document_id,
  g.created_at,
  case when g.rn = 1 then 'KEEP (completed)' else 'CANCEL' end as action
from grouped g
where exists (
  select 1 from grouped g2
  where g2.order_id = g.order_id
    and g2.ck = g.ck
    and g2.payment_method_id = g.payment_method_id
  group by 1
  having count(*) > 1
)
order by g.order_id, g.payment_method_id, g.created_at asc;

-- ----------------------------------------------------------------------------
-- BLOQUE 2: Cleanup (write — descomentar para correr)
-- ----------------------------------------------------------------------------


begin;

-- Órdenes excluidas del cleanup automático (revisar manualmente):
--   a0bb5c4f-8e57-4347-b088-4080a04e8e1e
--     → partial legítimo: cliente añadió un segundo item 2h después,
--       pagó 550 adicional pero el sistema NO emitió NCF para ese pago.
--       Decisión fiscal pendiente (re-facturar, fusionar, o aceptar gap).

-- 2.1) Marcar como cancelled todos los duplicados excepto el "ganador".
with grouped as (
  select
    id,
    row_number() over (
      partition by
        order_id,
        coalesce(check_id, '00000000-0000-0000-0000-000000000000'::uuid),
        payment_method_id
      order by
        (fiscal_document_id is not null) desc,
        created_at asc
    ) as rn
  from public.payments
  where status = 'completed'
    and order_id <> 'a0bb5c4f-8e57-4347-b088-4080a04e8e1e'
)
update public.payments p
set status = 'cancelled'
from grouped g
where p.id = g.id
  and g.rn > 1;

-- 2.2) Verificar: no debe quedar ningún grupo con > 1 completed.
select
  order_id,
  coalesce(check_id, '00000000-0000-0000-0000-000000000000'::uuid) as ck,
  payment_method_id,
  count(*) as still_dup
from public.payments
where status = 'completed'
group by 1, 2, 3
having count(*) > 1;
-- Esperado: 0 rows.

commit;
-- O `rollback;` si el preview se vio mal.
*/

-- ----------------------------------------------------------------------------
-- BLOQUE 3: (opcional) Revertir cash_transactions duplicadas
-- ----------------------------------------------------------------------------
-- Después del cleanup de payments, las cash_transactions vinculadas a
-- payments cancelled siguen sumando al cierre de caja. Para limpiarlas:
--
-- - Identificar cash_transactions con related_order_id donde el payment
--   asociado ahora está cancelled.
-- - Borrarlas o marcarlas como type='void'.
--
-- Esto puede afectar reportes históricos. Hacer SOLO si la integridad
-- contable de los cierres de caja pasados es crítica. Si no, dejar como
-- está (los duplicados sumaron al efectivo, pero ese efectivo ya se contó
-- físicamente o no en cierres pasados — el cleanup actual no cambia eso).
-- ----------------------------------------------------------------------------

/*
select
  ct.id,
  ct.related_order_id,
  ct.amount,
  ct.created_at,
  p.status as related_payment_status
from public.cash_transactions ct
join public.payments p on p.related_order_id = ct.related_order_id::uuid
  -- Nota: no hay FK directo cash_transactions → payments, hay que joinar
  -- via related_order_id + amount + created_at proximity.
where ct.type = 'sale'
  and p.status = 'cancelled'
  and ct.amount = p.amount
  and abs(extract(epoch from (ct.created_at - p.created_at))) < 5
order by ct.created_at desc;
*/
