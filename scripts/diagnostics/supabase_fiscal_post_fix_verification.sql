-- Verificación post-fix fiscal
-- Ejecutar después de aplicar:
--   supabase_fiscal_trigger_and_dedup_fix.sql

-- ============================================================
-- 1. Órdenes con más de un documento fiscal activo
-- Esperado: 0 filas
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
having count(*) filter (where coalesce(fd.status, 'active') = 'active') > 1
order by active_docs desc, total_docs desc, fd.order_id;

-- ============================================================
-- 2. Pagos con más de un documento fiscal activo
-- Esperado: 0 filas
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
having count(*) filter (where coalesce(fd.status, 'active') = 'active') > 1
order by active_docs desc, total_docs desc, fd.payment_id;

-- ============================================================
-- 3. Órdenes con múltiples documentos pero solo uno activo
-- Esperado: puede devolver filas históricas saneadas, eso está bien
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
order by total_docs desc, fd.order_id;

-- ============================================================
-- 4. Estado actual de ncf_sequences
-- ============================================================
select *
from public.ncf_sequences
order by created_at desc nulls last;

-- ============================================================
-- 5. Comparación secuencia vs último emitido
-- Gap positivo = secuencia atrasada
-- Esperado: gap <= 0 en todas
-- ============================================================
select
  s.id,
  s.business_id,
  s.ncf_type,
  s.prefix,
  s.current_number,
  s.range_end,
  s.is_active,
  s.expiration_date,
  d.max_numeric_suffix,
  (d.max_numeric_suffix - s.current_number) as gap
from public.ncf_sequences s
left join (
  select
    business_id,
    left(ncf_number, 3) as prefix,
    max(cast(substring(ncf_number from 4) as bigint)) as max_numeric_suffix
  from public.fiscal_documents
  where ncf_number ~ '^[A-Z][0-9]{2}[0-9]+$'
  group by business_id, left(ncf_number, 3)
) d on d.business_id = s.business_id
   and d.prefix = s.prefix
order by s.ncf_type, s.prefix, s.created_at desc nulls last;

-- ============================================================
-- 6. Secuencias atrasadas específicamente
-- Esperado: 0 filas
-- ============================================================
select
  s.id,
  s.business_id,
  s.ncf_type,
  s.prefix,
  s.current_number,
  d.max_numeric_suffix,
  (d.max_numeric_suffix - s.current_number) as gap
from public.ncf_sequences s
join (
  select
    business_id,
    left(ncf_number, 3) as prefix,
    max(cast(substring(ncf_number from 4) as bigint)) as max_numeric_suffix
  from public.fiscal_documents
  where ncf_number ~ '^[A-Z][0-9]{2}[0-9]+$'
  group by business_id, left(ncf_number, 3)
) d on d.business_id = s.business_id
   and d.prefix = s.prefix
where s.current_number < d.max_numeric_suffix
order by gap desc;

-- ============================================================
-- 7. Últimos documentos fiscales emitidos
-- Útil para revisar que las ventas nuevas salgan una sola vez
-- ============================================================
select
  id,
  business_id,
  order_id,
  payment_id,
  ncf_number,
  ncf_type,
  ncf_sequence_id,
  status,
  created_at
from public.fiscal_documents
order by created_at desc
limit 50;

-- ============================================================
-- 8. Trigger activo sobre payments
-- Confirmar que sigue conectado
-- ============================================================
select
  tg.tgname as trigger_name,
  c.relname as table_name,
  p.proname as function_name
from pg_trigger tg
join pg_class c on c.oid = tg.tgrelid
join pg_proc p on p.oid = tg.tgfoid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'payments'
  and not tg.tgisinternal
order by tg.tgname;

-- ============================================================
-- 9. Definición actual del trigger function
-- Confirmar que usa create_fiscal_document()
-- ============================================================
select pg_get_functiondef(p.oid)
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'trigger_issue_fiscal_on_payment';

-- ============================================================
-- 10. Opcional: validar una orden específica
-- Descomenta y reemplaza UUID si quieres inspección puntual
-- ============================================================
-- select
--   o.id as order_id,
--   p.id as payment_id,
--   p.status as payment_status,
--   fd.id as fiscal_document_id,
--   fd.ncf_number,
--   fd.ncf_type,
--   fd.ncf_sequence_id,
--   fd.status as fiscal_status,
--   fd.created_at as fiscal_created_at
-- from public.orders o
-- left join public.payments p on p.order_id = o.id
-- left join public.fiscal_documents fd on fd.order_id = o.id or fd.payment_id = p.id
-- where o.id = '<UUID_REAL_AQUI>'
-- order by p.created_at desc nulls last, fd.created_at desc nulls last;
