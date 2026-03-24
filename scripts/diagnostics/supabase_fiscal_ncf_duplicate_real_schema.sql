-- Diagnóstico fiscal ajustado al esquema real
-- Tablas detectadas:
--   - public.fiscal_documents
--   - public.fiscal_settings
--   - public.ncf_sequences
-- Además existe legado en public.comprobantes / public.v_comprobantes
--
-- Error objetivo:
--   duplicate key value violates unique constraint "fiscal_documents_ncf_number_key"
--   Key (ncf_number)=(B0200000013) already exists.

-- ============================================================
-- 1. Ver el NCF duplicado en fiscal_documents
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
-- 2. Últimos NCF emitidos de esa serie en fiscal_documents
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
where ncf_number like 'B02%'
order by created_at desc, ncf_number desc
limit 50;

-- ============================================================
-- 3. Buscar duplicados por ncf_number en fiscal_documents
-- ============================================================
select
  ncf_number,
  count(*) as copies,
  min(created_at) as first_seen,
  max(created_at) as last_seen
from public.fiscal_documents
group by ncf_number
having count(*) > 1
order by copies desc, ncf_number;

-- ============================================================
-- 4. Configuración fiscal actual
-- ============================================================
select *
from public.fiscal_settings
order by created_at desc nulls last;

-- ============================================================
-- 5. Secuencias NCF actuales
-- OJO: aquí veremos el estado real del consecutivo
-- ============================================================
select *
from public.ncf_sequences
order by created_at desc nulls last;

-- ============================================================
-- 6. Estructura de ncf_sequences
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
-- 7. Ver el último NCF por tipo y secuencia
-- ============================================================
select
  ncf_type,
  ncf_sequence_id,
  max(ncf_number) as max_ncf_number,
  count(*) as docs_count
from public.fiscal_documents
group by ncf_type, ncf_sequence_id
order by ncf_type, ncf_sequence_id;

-- ============================================================
-- 8. Buscar mismatch entre ncf_sequences y documentos emitidos
-- Ajusta nombres según columnas reales de ncf_sequences si hace falta.
-- Primero inspecciona el resultado de la query #6.
-- ============================================================
-- Ejemplo genérico para revisar manualmente:
select *
from public.ncf_sequences
limit 20;

-- ============================================================
-- 9. Ver funciones relacionadas a fiscal / NCF / receipts
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
-- 10. Índices y constraints sobre fiscal_documents
-- ============================================================
select
  schemaname,
  tablename,
  indexname,
  indexdef
from pg_indexes
where schemaname = 'public'
  and tablename = 'fiscal_documents'
order by indexname;

select
  tc.constraint_name,
  tc.constraint_type,
  kcu.column_name
from information_schema.table_constraints tc
left join information_schema.key_column_usage kcu
  on tc.constraint_name = kcu.constraint_name
  and tc.table_schema = kcu.table_schema
where tc.table_schema = 'public'
  and tc.table_name = 'fiscal_documents'
order by tc.constraint_name, kcu.ordinal_position;

-- ============================================================
-- 11. Triggers sobre fiscal_documents
-- ============================================================
select
  event_object_table as table_name,
  trigger_name,
  action_timing,
  event_manipulation,
  action_statement
from information_schema.triggers
where trigger_schema = 'public'
  and event_object_table = 'fiscal_documents'
order by trigger_name;

-- ============================================================
-- 12. Si conoces el order_id, revisar si ya tiene documento fiscal
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
  fd.created_at as fiscal_created_at
from public.orders o
left join public.fiscal_documents fd on fd.order_id = o.id
where o.id = 'AQUI_EL_ORDER_ID';

-- ============================================================
-- 13. Si conoces el order_id, revisar pagos de la orden
-- Reemplaza AQUI_EL_ORDER_ID
-- ============================================================
select
  p.id,
  p.order_id,
  p.check_id,
  p.amount,
  p.status,
  p.reference,
  p.created_at
from public.payments p
where p.order_id = 'AQUI_EL_ORDER_ID'
order by p.created_at desc;

-- ============================================================
-- 14. Buscar si el mismo NCF aparece también en el legado
-- ============================================================
select *
from public.comprobantes
where ncf = 'B0200000013'
   or ncf_modificado = 'B0200000013';

-- ============================================================
-- 15. Comparar fiscal_documents vs comprobantes legado
-- ============================================================
select
  'fiscal_documents' as source,
  fd.ncf_number as ncf,
  fd.order_id::text as order_ref,
  fd.created_at
from public.fiscal_documents fd
where fd.ncf_number like 'B02%'

union all

select
  'comprobantes' as source,
  c.ncf as ncf,
  null::text as order_ref,
  null::timestamp as created_at
from public.comprobantes c
where c.ncf like 'B02%'
order by ncf desc;

-- ============================================================
-- 16. Detectar si el consecutivo en ncf_sequences parece atrasado
-- NOTA: esta query puede requerir ajuste según nombres reales en ncf_sequences.
-- Primero mira el resultado de #6 y adapta si hace falta.
-- Ejemplo de inspección rápida:
-- ============================================================
select *
from public.ncf_sequences
limit 20;
