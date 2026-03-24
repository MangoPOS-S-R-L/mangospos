-- Fix conservador para emisión fiscal duplicada
-- Objetivo:
-- 1) Corregir trigger para usar create_fiscal_document() (idempotente)
-- 2) Desactivar documentos fiscales duplicados dejando solo el más reciente por orden
--
-- IMPORTANTE:
-- - Revisar primero los SELECTs
-- - Ejecutar en ventana controlada
-- - Cambiar ROLLBACK por COMMIT cuando confirmes

-- ============================================================
-- 1. Preview: órdenes con múltiples documentos fiscales
-- ============================================================
select
  fd.order_id,
  count(*) as fiscal_docs,
  array_agg(fd.id order by fd.created_at desc) as doc_ids,
  array_agg(fd.ncf_number order by fd.created_at desc) as ncfs,
  array_agg(fd.status order by fd.created_at desc) as statuses
from public.fiscal_documents fd
where fd.order_id is not null
group by fd.order_id
having count(*) > 1
order by fiscal_docs desc, fd.order_id;

-- ============================================================
-- 2. Preview: qué quedaría activo y qué se desactivaría
-- Conservador = se conserva el más reciente por orden
-- ============================================================
with ranked as (
  select
    fd.id,
    fd.order_id,
    fd.payment_id,
    fd.ncf_number,
    fd.status,
    fd.created_at,
    row_number() over (
      partition by fd.order_id
      order by fd.created_at desc, fd.id desc
    ) as rn
  from public.fiscal_documents fd
  where fd.order_id is not null
)
select
  case when rn = 1 then 'KEEP' else 'DEACTIVATE' end as action,
  id,
  order_id,
  payment_id,
  ncf_number,
  status,
  created_at
from ranked
where order_id in (
  select order_id
  from public.fiscal_documents
  where order_id is not null
  group by order_id
  having count(*) > 1
)
order by order_id, rn, created_at desc;

-- ============================================================
-- 3. Fix del trigger: usar create_fiscal_document() en vez de issue_fiscal_document()
-- ============================================================
BEGIN;

create or replace function public.trigger_issue_fiscal_on_payment()
returns trigger
language plpgsql
as $function$
begin
  if NEW.status = 'completed' then
    perform public.create_fiscal_document(
      NEW.order_id,
      NEW.id,
      null,
      null
    );
  end if;
  return NEW;
end;
$function$;

-- ============================================================
-- 4. Desactivar duplicados dejando solo el más reciente por orden
-- Nota: se asume que la columna status acepta un valor distinto de 'active'.
-- Si tu esquema usa otro estado, ajusta 'cancelled'.
-- ============================================================
with ranked as (
  select
    fd.id,
    fd.order_id,
    row_number() over (
      partition by fd.order_id
      order by fd.created_at desc, fd.id desc
    ) as rn
  from public.fiscal_documents fd
  where fd.order_id is not null
), to_deactivate as (
  select id
  from ranked
  where rn > 1
)
update public.fiscal_documents fd
set status = 'cancelled'
where fd.id in (select id from to_deactivate)
  and coalesce(fd.status, 'active') = 'active';

-- ============================================================
-- 5. Verificación post-fix dentro de la transacción
-- ============================================================
select
  fd.order_id,
  count(*) filter (where coalesce(fd.status, 'active') = 'active') as active_docs,
  count(*) as total_docs,
  array_agg(fd.ncf_number order by fd.created_at desc) as ncfs,
  array_agg(fd.status order by fd.created_at desc) as statuses
from public.fiscal_documents fd
where fd.order_id is not null
group by fd.order_id
having count(*) > 1
order by active_docs desc, total_docs desc, fd.order_id;

-- ============================================================
-- 6. Verificación: pagos con más de un documento fiscal activo
-- ============================================================
select
  fd.payment_id,
  count(*) filter (where coalesce(fd.status, 'active') = 'active') as active_docs,
  count(*) as total_docs,
  array_agg(fd.ncf_number order by fd.created_at desc) as ncfs,
  array_agg(fd.status order by fd.created_at desc) as statuses
from public.fiscal_documents fd
where fd.payment_id is not null
group by fd.payment_id
having count(*) > 1
order by active_docs desc, total_docs desc, fd.payment_id;

COMMIT;
-- Aplicará el fix del trigger y la desactivación conservadora de duplicados.

-- ============================================================
-- 7. Variante estricta (NO ejecutar junto con la conservadora)
-- Mantener el más antiguo y cancelar los demás.
-- Dejada aquí solo como referencia.
-- ============================================================
-- with ranked as (
--   select
--     fd.id,
--     fd.order_id,
--     row_number() over (
--       partition by fd.order_id
--       order by fd.created_at asc, fd.id asc
--     ) as rn
--   from public.fiscal_documents fd
--   where fd.order_id is not null
-- ), to_deactivate as (
--   select id
--   from ranked
--   where rn > 1
-- )
-- update public.fiscal_documents fd
-- set status = 'cancelled'
-- where fd.id in (select id from to_deactivate)
--   and coalesce(fd.status, 'active') = 'active';
