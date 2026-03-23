-- Diagnóstico de split bills / precuentas / pagos en Supabase
-- Pega bloques individuales en SQL Editor o ejecuta todo según necesites.

-- ============================================================
-- 1. Definición actual de funciones clave
-- ============================================================
select
  n.nspname as schema_name,
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as args,
  pg_get_functiondef(p.oid) as definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'fn_create_split_bill',
    'fn_process_payment_v3',
    'calculate_check_totals'
  )
order by p.proname;

-- ============================================================
-- 2. Estructura de tablas del flujo split/payment
-- ============================================================
select
  table_name,
  column_name,
  data_type,
  is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name in ('orders', 'order_items', 'order_checks', 'payments')
order by table_name, ordinal_position;

-- ============================================================
-- 3. Foreign keys importantes
-- ============================================================
select
  tc.table_name,
  kcu.column_name,
  ccu.table_name as foreign_table_name,
  ccu.column_name as foreign_column_name,
  tc.constraint_name
from information_schema.table_constraints tc
join information_schema.key_column_usage kcu
  on tc.constraint_name = kcu.constraint_name
  and tc.table_schema = kcu.table_schema
join information_schema.constraint_column_usage ccu
  on ccu.constraint_name = tc.constraint_name
  and ccu.table_schema = tc.table_schema
where tc.constraint_type = 'FOREIGN KEY'
  and tc.table_schema = 'public'
  and tc.table_name in ('order_items', 'payments', 'order_checks')
order by tc.table_name, tc.constraint_name;

-- ============================================================
-- 4. Triggers relacionados a orders/checks/items
-- ============================================================
select
  event_object_table as table_name,
  trigger_name,
  action_timing,
  event_manipulation,
  action_statement
from information_schema.triggers
where trigger_schema = 'public'
  and event_object_table in ('order_items', 'order_checks', 'orders')
order by event_object_table, trigger_name;

-- ============================================================
-- 5. Definición actual de fn_process_payment_v3
-- Busca especialmente si limpia check_id = null cuando p_check_id es null
-- ============================================================
select pg_get_functiondef(p.oid)
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'fn_process_payment_v3';

-- ============================================================
-- 6. Diagnóstico por order_id
-- Reemplaza AQUÍ_EL_ORDER_ID por el UUID real
-- ============================================================
select
  oi.id,
  oi.order_id,
  oi.check_id,
  oc.label as check_label,
  oi.product_name,
  oi.quantity,
  oi.unit_price,
  oi.subtotal,
  oi.tax,
  oi.discounts,
  oi.total,
  oi.status,
  oi.notes,
  oi.created_at
from public.order_items oi
left join public.order_checks oc on oc.id = oi.check_id
where oi.order_id = 'AQUÍ_EL_ORDER_ID'
order by oc.position nulls first, oi.product_name, oi.created_at;

-- ============================================================
-- 7. Resumen agrupado por check
-- ============================================================
select
  oi.check_id,
  oc.label as check_label,
  count(*) as line_count,
  sum(oi.quantity) as qty_total,
  sum(oi.subtotal) as subtotal,
  sum(oi.tax) as tax,
  sum(oi.discounts) as discounts,
  sum(oi.total) as total
from public.order_items oi
left join public.order_checks oc on oc.id = oi.check_id
where oi.order_id = 'AQUÍ_EL_ORDER_ID'
group by oi.check_id, oc.label, oc.position
order by oc.position nulls first;

-- ============================================================
-- 8. Duplicados lógicos dentro del mismo check
-- ============================================================
select
  oi.check_id,
  oc.label as check_label,
  oi.product_name,
  oi.unit_price,
  coalesce(oi.notes, '') as notes,
  oi.status,
  count(*) as rows_found,
  sum(oi.quantity) as qty_total,
  sum(oi.total) as total_sum
from public.order_items oi
left join public.order_checks oc on oc.id = oi.check_id
where oi.order_id = 'AQUÍ_EL_ORDER_ID'
group by
  oi.check_id,
  oc.label,
  oc.position,
  oi.product_name,
  oi.unit_price,
  coalesce(oi.notes, ''),
  oi.status
having count(*) > 1
order by oc.position nulls first, oi.product_name;

-- ============================================================
-- 9. Pagos ligados a checks
-- ============================================================
select
  p.id,
  p.order_id,
  p.check_id,
  oc.label as check_label,
  p.amount,
  p.status,
  p.created_at
from public.payments p
left join public.order_checks oc on oc.id = p.check_id
where p.order_id = 'AQUÍ_EL_ORDER_ID'
order by p.created_at desc;

-- ============================================================
-- 10. Checks de la orden
-- ============================================================
select
  id,
  order_id,
  label,
  position,
  is_closed,
  subtotal,
  tax,
  discounts,
  total,
  closed_at
from public.order_checks
where order_id = 'AQUÍ_EL_ORDER_ID'
order by position;
