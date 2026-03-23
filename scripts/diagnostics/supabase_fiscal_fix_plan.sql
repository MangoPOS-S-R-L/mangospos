-- Plan de corrección fiscal / NCF
-- Versión segura: no usa placeholders que rompan por UUID inválido.
--
-- HALLAZGOS CLAVE
-- 1) generate_ncf() usa public.ncf_sequences.current_number
-- 2) issue_fiscal_document() llama generate_ncf() y luego inserta en fiscal_documents
-- 3) create_fiscal_document() SÍ tiene idempotencia
-- 4) trigger_issue_fiscal_on_payment() NO usa create_fiscal_document(); llama issue_fiscal_document() directo
--
-- Eso deja dos riesgos:
-- A) secuencia corrida / current_number atrasado
-- B) doble emisión por trigger + llamada explícita en app/backend

-- ============================================================
-- 1. Ver triggers reales sobre payments
-- ============================================================
select
  event_object_table as table_name,
  trigger_name,
  action_timing,
  event_manipulation,
  action_statement
from information_schema.triggers
where trigger_schema = 'public'
  and event_object_table = 'payments'
order by trigger_name;

-- ============================================================
-- 2. Confirmar si trigger_issue_fiscal_on_payment está conectado a payments
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
-- 3. Ver estado actual de ncf_sequences
-- ============================================================
select *
from public.ncf_sequences
order by created_at desc nulls last;

-- ============================================================
-- 4. Ver último NCF emitido por secuencia
-- ============================================================
select
  fd.ncf_sequence_id,
  fd.ncf_type,
  left(fd.ncf_number, 3) as prefix,
  max(cast(substring(fd.ncf_number from 4) as bigint)) as max_numeric_suffix,
  max(fd.ncf_number) as max_ncf_text,
  count(*) as docs_count
from public.fiscal_documents fd
where fd.ncf_number ~ '^[A-Z][0-9]{2}[0-9]+$'
group by fd.ncf_sequence_id, fd.ncf_type, left(fd.ncf_number, 3)
order by fd.ncf_type, fd.ncf_sequence_id;

-- ============================================================
-- 5. Comparación directa secuencia vs emitidos
-- Si gap > 0, current_number está por detrás de lo emitido.
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
    ncf_sequence_id,
    max(cast(substring(ncf_number from 4) as bigint)) as max_numeric_suffix
  from public.fiscal_documents
  where ncf_number ~ '^[A-Z][0-9]{2}[0-9]+$'
  group by ncf_sequence_id
) d on d.ncf_sequence_id = s.id
order by s.ncf_type, s.prefix, s.created_at desc nulls last;

-- ============================================================
-- 6. Detectar secuencias atrasadas
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
    ncf_sequence_id,
    max(cast(substring(ncf_number from 4) as bigint)) as max_numeric_suffix
  from public.fiscal_documents
  where ncf_number ~ '^[A-Z][0-9]{2}[0-9]+$'
  group by ncf_sequence_id
) d on d.ncf_sequence_id = s.id
where s.current_number < d.max_numeric_suffix
order by gap desc;

-- ============================================================
-- 7. REPARACIÓN SEGURA de secuencias atrasadas (probar con ROLLBACK)
-- Cambia ROLLBACK por COMMIT solo cuando valides.
-- ============================================================
BEGIN;

update public.ncf_sequences s
set current_number = d.max_numeric_suffix
from (
  select
    ncf_sequence_id,
    max(cast(substring(ncf_number from 4) as bigint)) as max_numeric_suffix
  from public.fiscal_documents
  where ncf_number ~ '^[A-Z][0-9]{2}[0-9]+$'
  group by ncf_sequence_id
) d
where d.ncf_sequence_id = s.id
  and s.current_number < d.max_numeric_suffix;

select
  s.id,
  s.business_id,
  s.ncf_type,
  s.prefix,
  s.current_number,
  s.range_end,
  s.is_active
from public.ncf_sequences s
order by s.ncf_type, s.prefix, s.created_at desc nulls last;

ROLLBACK;

-- ============================================================
-- 8. PATCH SUGERIDO DE IDEMPOTENCIA EN TRIGGER
-- Recomendación: usar create_fiscal_document() en lugar de issue_fiscal_document()
-- ============================================================
-- BEGIN;
--
-- create or replace function public.trigger_issue_fiscal_on_payment()
-- returns trigger
-- language plpgsql
-- as $function$
-- begin
--   if NEW.status = 'completed' then
--     perform public.create_fiscal_document(
--       NEW.order_id,
--       NEW.id,
--       null,
--       null
--     );
--   end if;
--   return NEW;
-- end;
-- $function$;
--
-- COMMIT;

-- ============================================================
-- 9. BUSCAR pagos con más de un documento fiscal asociado
-- ============================================================
select
  fd.payment_id,
  count(*) as fiscal_docs,
  array_agg(fd.id order by fd.created_at) as doc_ids,
  array_agg(fd.ncf_number order by fd.created_at) as ncfs
from public.fiscal_documents fd
where fd.payment_id is not null
group by fd.payment_id
having count(*) > 1
order by fiscal_docs desc;

-- ============================================================
-- 10. BUSCAR órdenes con más de un documento fiscal asociado
-- ============================================================
select
  fd.order_id,
  count(*) as fiscal_docs,
  array_agg(fd.id order by fd.created_at) as doc_ids,
  array_agg(fd.ncf_number order by fd.created_at) as ncfs,
  array_agg(fd.status order by fd.created_at) as statuses
from public.fiscal_documents fd
where fd.order_id is not null
group by fd.order_id
having count(*) > 1
order by fiscal_docs desc;

-- ============================================================
-- 11. OPCIONAL: diagnóstico por una orden específica
-- Reemplaza el UUID real solo si ya lo tienes.
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
