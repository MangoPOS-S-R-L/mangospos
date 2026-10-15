-- Esquema auxiliar y datos sintéticos del ensayo de ofertas.
alter table public.order_items add column total numeric default 0, add column promotion_id uuid, add column created_by_employee_id uuid;
alter table public.orders add column service_fee numeric default 0;
alter table public.order_checks add column subtotal numeric default 0, add column tax numeric default 0, add column discounts numeric default 0, add column service_fee numeric default 0;
alter table public.fiscal_documents add column subtotal numeric, add column itbis_amount numeric, add column service_fee numeric default 0, add column total numeric, add column discounts numeric default 0;
create table public.business_settings(business_id uuid, service_fee_enabled boolean default false, service_fee_rate numeric default 0);
create table public.menu_items(id uuid primary key, name text, price numeric);
create table public.promotions(id uuid primary key, promo_type text, discount_type text, buy_quantity integer, pay_quantity integer);
insert into public.promotions values
 ('70000000-0000-4000-8000-000000000001','bogo','bogo',2,1),
 ('70000000-0000-4000-8000-000000000002','bogo','bogo',4,3);
insert into menu_items values ('60000000-0000-4000-8000-000000000001','Margarita Chinola',400);
insert into menu_items values ('60000000-0000-4000-8000-000000000002','Presidente Normal',250);
create or replace function public.fn_resolve_order_item_tax_profile(p_product uuid,p_order uuid) returns table(tax_mode text,tax_rate numeric) language sql as $$ select 'inclusive'::text,28::numeric $$;
create table public.order_item_client_ops(client_op_id uuid primary key,order_id uuid not null,request_payload jsonb not null,item_id uuid,created_at timestamptz default now());

create function public.review_empty_order() returns uuid language plpgsql as $$
declare t uuid;s uuid;o uuid; begin
 insert into dining_tables(zone_id) values ('c0000000-0000-0000-0000-000000000001') returning id into t;
 insert into table_sessions(table_id,business_id) values(t,'b0000000-0000-0000-0000-000000000001') returning id into s;
 insert into orders(session_id) values(s) returning id into o; return o; end $$;
create function public.review_offer(o uuid) returns uuid language plpgsql as $$
declare r jsonb;begin r:=fn_add_offer_deal_idempotent(gen_random_uuid(),o,'60000000-0000-4000-8000-000000000001',2,400,'2x1 Margarita Chinola','70000000-0000-4000-8000-000000000001',1,null); return (r->>'item_id')::uuid; end $$;
