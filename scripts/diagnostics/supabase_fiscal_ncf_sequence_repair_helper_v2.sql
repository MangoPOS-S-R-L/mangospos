-- Helper de reparación para secuencias NCF (v2)
-- Ajustado para no asumir columnas como updated_at.
--
-- Usa este archivo para:
-- 1) inspeccionar ncf_sequences
-- 2) comparar contra fiscal_documents
-- 3) preparar el UPDATE correcto manualmente

-- ============================================================
-- 1. Estructura real de fiscal_documents
-- ============================================================
select
  column_name,
  data_type,
  is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'fiscal_documents'
order by ordinal_position;

-- ============================================================
-- 2. Estructura real de ncf_sequences
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
-- 3. Contenido actual de ncf_sequences
-- ============================================================
select *
from public.ncf_sequences;

-- ============================================================
-- 4. Documentos fiscales recientes
-- ============================================================
select *
from public.fiscal_documents
order by created_at desc
limit 100;

-- ============================================================
-- 5. Si ya sabes el NCF problemático, reemplázalo aquí
-- ============================================================
select *
from public.fiscal_documents
where ncf_number = 'B0200000013';

-- ============================================================
-- 6. Duplicados por ncf_number
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
-- 7. Último NCF emitido por tipo y secuencia
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
-- 8. Extraer el sufijo numérico para formato tipo B0200000013
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
-- 9. Buscar también en el legado comprobantes
-- ============================================================
select *
from public.comprobantes
where ncf = 'B0200000013'
   or ncf_modificado = 'B0200000013';

-- ============================================================
-- 10. Funciones relacionadas a fiscal / NCF / receipts
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
-- 11. Plantilla de comparación manual con ncf_sequences
-- AJUSTA según columnas reales que veas en #2 y #3
-- ============================================================
-- Ejemplo orientativo solamente:
-- select
--   s.id,
--   s.ncf_type,
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
-- 12. Plantilla de UPDATE (NO ejecutar sin ajustar columnas)
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
-- select * from public.ncf_sequences;
-- ROLLBACK;
-- -- cambia a COMMIT cuando valides
