-- Helper de reparación para secuencias NCF
-- Objetivo: detectar si ncf_sequences está atrasada respecto a fiscal_documents
-- y preparar el ajuste correcto sin adivinar.
--
-- IMPORTANTE:
-- 1) Ejecuta primero los bloques de inspección.
-- 2) NO corras un UPDATE a ciegas hasta confirmar los nombres reales de columnas.
-- 3) Este archivo está hecho para ayudarte a sacar el UPDATE exacto según tu esquema.

-- ============================================================
-- 1. Ver estructura real de ncf_sequences
-- ============================================================
select
  column_name,
  data_type,
  is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'ncf_sequences'
order by ordinal_position;

-- ============================================================
-- 2. Ver contenido real de ncf_sequences
-- ============================================================
select *
from public.ncf_sequences
order by created_at desc nulls last;

-- ============================================================
-- 3. Ver último NCF emitido por tipo y secuencia
-- ============================================================
select
  ncf_type,
  ncf_sequence_id,
  max(ncf_number) as last_issued_ncf,
  count(*) as docs_count
from public.fiscal_documents
group by ncf_type, ncf_sequence_id
order by ncf_type, ncf_sequence_id;

-- ============================================================
-- 4. Ver todos los documentos fiscales recientes
-- ============================================================
select
  id,
  business_id,
  order_id,
  ncf_number,
  ncf_type,
  ncf_sequence_id,
  status,
  created_at
from public.fiscal_documents
order by created_at desc
limit 100;

-- ============================================================
-- 5. Buscar NCF duplicados en fiscal_documents
-- ============================================================
select
  ncf_number,
  count(*) as copies,
  array_agg(id order by created_at) as document_ids,
  array_agg(order_id order by created_at) as order_ids
from public.fiscal_documents
group by ncf_number
having count(*) > 1
order by copies desc, ncf_number;

-- ============================================================
-- 6. Si ya sabes el NCF problemático, reemplázalo aquí
-- ============================================================
select
  id,
  business_id,
  order_id,
  ncf_number,
  ncf_type,
  ncf_sequence_id,
  status,
  created_at,
  updated_at
from public.fiscal_documents
where ncf_number = 'B0200000013';

-- ============================================================
-- 7. Buscar también en el legado comprobantes
-- ============================================================
select *
from public.comprobantes
where ncf = 'B0200000013'
   or ncf_modificado = 'B0200000013';

-- ============================================================
-- 8. Funciones que probablemente generan o consumen NCF
-- ============================================================
select
  n.nspname as schema_name,
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as args,
  pg_get_functiondef(p.oid) as definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and (
    p.proname ilike '%fiscal%'
    or p.proname ilike '%ncf%'
    or p.proname ilike '%receipt%'
    or p.proname ilike '%voucher%'
    or p.proname ilike '%comprobante%'
    or p.proname ilike '%dgii%'
  )
order by p.proname;

-- ============================================================
-- 9. Plantilla para calcular el siguiente consecutivo numérico
-- AJUSTA según tu formato real de ncf_number.
-- Para formato tipo B0200000013:
--   prefijo = primeros 3 chars -> B02
--   secuencia numérica = resto
-- ============================================================
select
  ncf_type,
  ncf_sequence_id,
  left(ncf_number, 3) as prefix,
  max(cast(substring(ncf_number from 4) as bigint)) as max_numeric_suffix
from public.fiscal_documents
where ncf_number ~ '^[A-Z][0-9]{2}[0-9]+$'
group by ncf_type, ncf_sequence_id, left(ncf_number, 3)
order by ncf_type, ncf_sequence_id;

-- ============================================================
-- 10. Plantilla para comparar contra ncf_sequences
-- OJO: AJUSTAR los nombres reales en ncf_sequences después de ver #1/#2.
--
-- Ejemplo de columnas esperables (pueden variar):
--   id
--   business_id
--   ncf_type
--   prefix / serie
--   current_number / next_number / last_number
-- ============================================================
-- Reemplaza current_number por el nombre real de tu columna numérica.
-- Reemplaza prefix por el nombre real del prefijo/serie si existe.
--
-- select
--   s.id,
--   s.business_id,
--   s.ncf_type,
--   s.prefix,
--   s.current_number,
--   d.max_numeric_suffix,
--   (d.max_numeric_suffix - s.current_number) as gap
-- from public.ncf_sequences s
-- left join (
--   select
--     ncf_sequence_id,
--     max(cast(substring(ncf_number from 4) as bigint)) as max_numeric_suffix
--   from public.fiscal_documents
--   where ncf_number ~ '^[A-Z][0-9]{2}[0-9]+$'
--   group by ncf_sequence_id
-- ) d on d.ncf_sequence_id = s.id;

-- ============================================================
-- 11. Plantilla de UPDATE correctivo (NO EJECUTAR sin ajustar columnas)
--
-- Idea: mover la secuencia al último número emitido, o al siguiente.
-- Según tu implementación, puede ser current_number = max_numeric_suffix
-- o next_number = max_numeric_suffix + 1.
-- ============================================================
-- BEGIN;
--
-- update public.ncf_sequences s
-- set current_number = d.max_numeric_suffix
-- from (
--   select
--     ncf_sequence_id,
--     max(cast(substring(ncf_number from 4) as bigint)) as max_numeric_suffix
--   from public.fiscal_documents
--   where ncf_number ~ '^[A-Z][0-9]{2}[0-9]+$'
--   group by ncf_sequence_id
-- ) d
-- where d.ncf_sequence_id = s.id
--   and s.current_number < d.max_numeric_suffix;
--
-- -- revisar antes de commit
-- select * from public.ncf_sequences;
--
-- ROLLBACK;
-- -- cuando confirmes, cambia a COMMIT;

-- ============================================================
-- 12. Ver si el problema viene de retry/reuso sobre una misma orden
-- Reemplaza AQUI_EL_ORDER_ID
-- ============================================================
select
  o.id as order_id,
  o.status,
  o.total,
  o.created_at,
  fd.id as fiscal_document_id,
  fd.ncf_number,
  fd.ncf_type,
  fd.ncf_sequence_id,
  fd.status as fiscal_status,
  fd.created_at as fiscal_created_at,
  p.id as payment_id,
  p.amount as payment_amount,
  p.status as payment_status,
  p.created_at as payment_created_at
from public.orders o
left join public.fiscal_documents fd on fd.order_id = o.id
left join public.payments p on p.order_id = o.id
where o.id = 'AQUI_EL_ORDER_ID'
order by p.created_at desc nulls last, fd.created_at desc nulls last;
