-- Smoke checks for migration 20260227_0005_sales_cash_products_hardening.sql
-- Non-destructive verification script

begin;

create temporary table if not exists _smoke_results_0005 (
  check_id text primary key,
  ok boolean not null,
  details text
) on commit drop;

-- =====================================================
-- 1) Functions/RPCs exist with expected signatures
-- =====================================================
insert into _smoke_results_0005 (check_id, ok, details) values
(
  'F01_fn_update_item_qty',
  to_regprocedure('public.fn_update_item_qty(uuid,numeric)') is not null,
  'function public.fn_update_item_qty(uuid,numeric)'
),
(
  'F02_fn_update_item_notes',
  to_regprocedure('public.fn_update_item_notes(uuid,text)') is not null,
  'function public.fn_update_item_notes(uuid,text)'
),
(
  'F03_fn_delete_item',
  to_regprocedure('public.fn_delete_item(uuid)') is not null,
  'function public.fn_delete_item(uuid)'
),
(
  'F04_fn_assign_customer_to_session',
  to_regprocedure('public.fn_assign_customer_to_session(uuid,uuid,text)') is not null,
  'function public.fn_assign_customer_to_session(uuid,uuid,text)'
),
(
  'F05_fn_assign_manual_order_to_table',
  to_regprocedure('public.fn_assign_manual_order_to_table(uuid,uuid,uuid)') is not null,
  'function public.fn_assign_manual_order_to_table(uuid,uuid,uuid)'
),
(
  'F06_get_table_live',
  to_regprocedure('public.get_table_live(uuid)') is not null,
  'function public.get_table_live(uuid)'
),
(
  'F07_fn_require_open_cash_session',
  to_regprocedure('public.fn_require_open_cash_session(uuid)') is not null,
  'function public.fn_require_open_cash_session(uuid)'
),
(
  'F08_fn_open_table',
  to_regprocedure('public.fn_open_table(uuid,uuid,integer)') is not null,
  'function public.fn_open_table(uuid,uuid,integer)'
),
(
  'F09_fn_open_manual_or_quick',
  to_regprocedure('public.fn_open_manual_or_quick(public.order_origin,uuid,integer)') is not null,
  'function public.fn_open_manual_or_quick(public.order_origin,uuid,integer)'
),
(
  'F10_create_business_defaults',
  to_regprocedure('public.create_business_defaults(uuid)') is not null,
  'function public.create_business_defaults(uuid)'
);

-- =====================================================
-- 2) Schema/indexes exist
-- =====================================================
insert into _smoke_results_0005 (check_id, ok, details) values
(
  'S01_table_sessions_customer_id_column',
  exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'table_sessions'
      and column_name = 'customer_id'
  ),
  'column public.table_sessions.customer_id'
),
(
  'S02_uq_payment_methods_business_code_active',
  exists (
    select 1
    from pg_indexes
    where schemaname = 'public'
      and indexname = 'uq_payment_methods_business_code_active'
  ),
  'index public.uq_payment_methods_business_code_active'
),
(
  'S03_uq_open_session_per_register',
  exists (
    select 1
    from pg_indexes
    where schemaname = 'public'
      and indexname = 'uq_cash_register_sessions_open_per_register'
  ),
  'index public.uq_cash_register_sessions_open_per_register'
),
(
  'S04_uq_open_session_per_user',
  exists (
    select 1
    from pg_indexes
    where schemaname = 'public'
      and indexname = 'uq_cash_register_sessions_open_per_user'
  ),
  'index public.uq_cash_register_sessions_open_per_user'
);

-- =====================================================
-- 3) Data consistency checks
-- =====================================================
insert into _smoke_results_0005 (check_id, ok, details)
select
  'D01_every_business_has_settings',
  count(*) = 0,
  'businesses without business_settings: ' || count(*)
from public.businesses b
left join public.business_settings bs on bs.business_id = b.id
where bs.business_id is null;

insert into _smoke_results_0005 (check_id, ok, details)
select
  'D02_every_business_has_payment_methods_core',
  count(*) = 0,
  'businesses missing cash/card/transfer: ' || count(*)
from public.businesses b
where not exists (
  select 1 from public.payment_methods pm
  where pm.business_id = b.id and pm.code = 'cash'
)
or not exists (
  select 1 from public.payment_methods pm
  where pm.business_id = b.id and pm.code = 'card'
)
or not exists (
  select 1 from public.payment_methods pm
  where pm.business_id = b.id and pm.code = 'transfer'
);

insert into _smoke_results_0005 (check_id, ok, details)
select
  'D03_no_duplicate_active_payment_codes',
  count(*) = 0,
  'duplicated active (business_id,code): ' || count(*)
from (
  select business_id, code
  from public.payment_methods
  where is_active = true
  group by business_id, code
  having count(*) > 1
) t;

insert into _smoke_results_0005 (check_id, ok, details)
select
  'D04_no_duplicate_open_session_per_register',
  count(*) = 0,
  'registers with >1 open session: ' || count(*)
from (
  select cash_register_id
  from public.cash_register_sessions
  where status = 'open' and closed_at is null
  group by cash_register_id
  having count(*) > 1
) t;

insert into _smoke_results_0005 (check_id, ok, details)
select
  'D05_no_duplicate_open_session_per_user',
  count(*) = 0,
  'users with >1 open session: ' || count(*)
from (
  select user_id
  from public.cash_register_sessions
  where status = 'open' and closed_at is null
  group by user_id
  having count(*) > 1
) t;

insert into _smoke_results_0005 (check_id, ok, details)
select
  'D06_every_business_has_menu',
  count(*) = 0,
  'businesses without menus: ' || count(*)
from public.businesses b
where not exists (
  select 1 from public.menus m where m.business_id = b.id
);

insert into _smoke_results_0005 (check_id, ok, details)
select
  'D07_every_business_has_category',
  count(*) = 0,
  'businesses without categories: ' || count(*)
from public.businesses b
where not exists (
  select 1 from public.categories c where c.business_id = b.id
);

-- =====================================================
-- 4) Guard logic is present in function body
-- =====================================================
insert into _smoke_results_0005 (check_id, ok, details)
select
  'L01_open_table_calls_cash_guard',
  position('fn_require_open_cash_session' in lower(pg_get_functiondef(to_regprocedure('public.fn_open_table(uuid,uuid,integer)')))) > 0,
  'fn_open_table should call fn_require_open_cash_session';

insert into _smoke_results_0005 (check_id, ok, details)
select
  'L02_open_manual_quick_calls_cash_guard',
  position('fn_require_open_cash_session' in lower(pg_get_functiondef(to_regprocedure('public.fn_open_manual_or_quick(public.order_origin,uuid,integer)')))) > 0,
  'fn_open_manual_or_quick should call fn_require_open_cash_session';

insert into _smoke_results_0005 (check_id, ok, details)
select
  'L03_open_manual_quick_blocks_invalid_origin',
  position('origin_not_allowed' in lower(pg_get_functiondef(to_regprocedure('public.fn_open_manual_or_quick(public.order_origin,uuid,integer)')))) > 0,
  'fn_open_manual_or_quick should raise ORIGIN_NOT_ALLOWED';

-- =====================================================
-- Output
-- =====================================================
select
  check_id,
  case when ok then 'OK' else 'FAIL' end as status,
  details
from _smoke_results_0005
order by check_id;

do $$
declare
  v_fail_count integer;
begin
  select count(*) into v_fail_count
  from _smoke_results_0005
  where not ok;

  if v_fail_count > 0 then
    raise exception 'SMOKE_0005_FAILED: % check(s) in FAIL', v_fail_count;
  end if;
end $$;

commit;

