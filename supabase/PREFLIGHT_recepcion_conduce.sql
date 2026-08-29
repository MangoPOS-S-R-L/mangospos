-- Preflight de la recepción de mercancía (conduce).
-- Corre esto ANTES de aplicar 20260828_0001_goods_receipt_conduce.sql
-- para saber qué tiene tu servidor y qué le falta.

select 'tabla purchase_receptions'          as objeto,
       to_regclass('public.purchase_receptions') is not null as existe
union all
select 'tabla purchase_reception_lines',
       to_regclass('public.purchase_reception_lines') is not null
union all
select 'columna business_settings.cost_variance_threshold_pct',
       exists (select 1 from information_schema.columns
               where table_schema='public' and table_name='business_settings'
                 and column_name='cost_variance_threshold_pct')
union all
select 'columna purchase_receptions.reception_number  <-- la crea 20260828_0001',
       exists (select 1 from information_schema.columns
               where table_schema='public' and table_name='purchase_receptions'
                 and column_name='reception_number')
union all
select 'columna business_settings.require_goods_receipt  <-- la crea 20260828_0001',
       exists (select 1 from information_schema.columns
               where table_schema='public' and table_name='business_settings'
                 and column_name='require_goods_receipt')
union all
select 'funcion fn_receive_purchase_order_v2',
       exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
               where n.nspname='public' and p.proname='fn_receive_purchase_order_v2')
union all
select 'funcion user_has_business_permission (motor de permisos)',
       exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
               where n.nspname='public' and p.proname='user_has_business_permission')
order by 1;
