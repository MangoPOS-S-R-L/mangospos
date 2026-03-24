begin;

alter table public.order_checks
  add column if not exists customer_id uuid null references public.customers(id) on delete set null,
  add column if not exists customer_name text null;

create index if not exists idx_order_checks_customer_id
  on public.order_checks(customer_id);

commit;
