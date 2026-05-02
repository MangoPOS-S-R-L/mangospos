-- supabase/PRD09/001_phase0_schema.sql
-- PRD 9 — Módulo de Inventario · Fase 0 (Schema completo)
--
-- Scope:
--   1) Extender enums: movement_type (+5 valores), purchase_status (+1 valor)
--   2) Extender inventory_items (costing_method, barcode, updated_at) e
--      inventory_stock (average_cost, quantity_reserved)
--   3) Crear las 14 tablas nuevas: document_sequences, stock_layers,
--      goods_receipts/_items, supplier_invoices/_lines, accounts_payable,
--      supplier_payments/_applications, stock_transfers/_items,
--      inventory_adjustments/_items
--   4) Funciones helper: next_document_number, ensure_in_transit_warehouse,
--      bootstrap_menu_to_inventory_links, fn_inventory_items_touch
--   5) RLS multi-tenant en todas las tablas nuevas (patrón
--      user_business_role/user_has_business_access ya en uso)
--   6) Índices de soporte para queries críticas de Fase 2-9
--
-- NO se redefine: fn_inventory_record_movement, fn_receive_purchase_order,
--   consume_inventory_from_order, fn_confirm_order_to_kitchen,
--   fn_sync_inventory_stock_on_movement (todas existen y se mantienen).
--
-- Idempotencia: todo el archivo es seguro de re-ejecutar.

-- ─────────────────────────────────────────────────────────────────────
-- 1. Extender enums (FUERA de begin/commit — ALTER TYPE ADD VALUE
--    requiere commit propio y no puede usar el valor en la misma txn).
-- ─────────────────────────────────────────────────────────────────────

alter type public.movement_type add value if not exists 'receipt_provisional';
alter type public.movement_type add value if not exists 'sale_return';
alter type public.movement_type add value if not exists 'cost_adjustment';
alter type public.movement_type add value if not exists 'adjustment_in';
alter type public.movement_type add value if not exists 'adjustment_out';

alter type public.purchase_status add value if not exists 'closed';

-- ─────────────────────────────────────────────────────────────────────
-- 2. Resto del schema en una transacción.
-- ─────────────────────────────────────────────────────────────────────
begin;

-- 2.1 Extender inventory_items ───────────────────────────────────────
alter table public.inventory_items
  add column if not exists costing_method text not null default 'average';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'inventory_items_costing_method_check'
      and conrelid = 'public.inventory_items'::regclass
  ) then
    alter table public.inventory_items
      add constraint inventory_items_costing_method_check
      check (costing_method in ('average', 'fifo'));
  end if;
end $$;

alter table public.inventory_items
  add column if not exists barcode text;

alter table public.inventory_items
  add column if not exists updated_at timestamptz not null default now();

create or replace function public.fn_inventory_items_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_inventory_items_touch on public.inventory_items;
create trigger trg_inventory_items_touch
before update on public.inventory_items
for each row
execute function public.fn_inventory_items_touch_updated_at();

-- 2.2 Extender inventory_stock ───────────────────────────────────────
alter table public.inventory_stock
  add column if not exists average_cost numeric(14,4) not null default 0;

alter table public.inventory_stock
  add column if not exists quantity_reserved numeric(14,4) not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'inventory_stock_quantity_reserved_check'
      and conrelid = 'public.inventory_stock'::regclass
  ) then
    alter table public.inventory_stock
      add constraint inventory_stock_quantity_reserved_check
      check (quantity_reserved >= 0);
  end if;
end $$;

-- ─────────────────────────────────────────────────────────────────────
-- 3. Tabla de numeración correlativa
-- ─────────────────────────────────────────────────────────────────────
create table if not exists public.document_sequences (
  business_id    uuid not null references public.businesses(id) on delete cascade,
  document_type  text not null,
  prefix         text not null,
  current_number bigint not null default 0,
  primary key (business_id, document_type)
);

alter table public.document_sequences enable row level security;

drop policy if exists "ds_select" on public.document_sequences;
create policy "ds_select" on public.document_sequences
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "ds_write" on public.document_sequences;
create policy "ds_write" on public.document_sequences
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  );

create or replace function public.next_document_number(
  p_business_id    uuid,
  p_document_type  text
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prefix  text := upper(p_document_type);
  v_number  bigint;
  v_returned_prefix text;
begin
  insert into public.document_sequences
    (business_id, document_type, prefix, current_number)
  values
    (p_business_id, v_prefix, v_prefix, 1)
  on conflict (business_id, document_type)
  do update
     set current_number = public.document_sequences.current_number + 1
  returning current_number, prefix into v_number, v_returned_prefix;

  return format('%s-%s', v_returned_prefix, lpad(v_number::text, 6, '0'));
end;
$$;

grant execute on function public.next_document_number(uuid, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- 4. Stock layers (capas de costo — soporte FIFO + auditoría uniforme)
-- ─────────────────────────────────────────────────────────────────────
create table if not exists public.stock_layers (
  id                 uuid not null default gen_random_uuid() primary key,
  business_id        uuid not null references public.businesses(id) on delete cascade,
  item_id            uuid not null references public.inventory_items(id) on delete cascade,
  warehouse_id       uuid not null references public.warehouses(id) on delete cascade,
  source_type        text not null,    -- goods_receipt, transfer_in, adjustment_in, opening_balance
  source_id          uuid,             -- id del documento que originó la capa
  quantity_initial   numeric(14,4) not null check (quantity_initial > 0),
  quantity_remaining numeric(14,4) not null check (quantity_remaining >= 0),
  unit_cost          numeric(14,4) not null check (unit_cost >= 0),
  is_provisional     boolean not null default false,
  received_at        timestamptz not null default now(),
  finalized_at       timestamptz,
  created_at         timestamptz not null default now(),
  check (quantity_remaining <= quantity_initial)
);

create index if not exists idx_stock_layers_fifo
  on public.stock_layers (item_id, warehouse_id, received_at)
  where quantity_remaining > 0;

create index if not exists idx_stock_layers_business
  on public.stock_layers (business_id);

alter table public.stock_layers enable row level security;

drop policy if exists "sl_select" on public.stock_layers;
create policy "sl_select" on public.stock_layers
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "sl_write" on public.stock_layers;
create policy "sl_write" on public.stock_layers
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  );

-- ─────────────────────────────────────────────────────────────────────
-- 5. Goods receipts (recepciones)
-- ─────────────────────────────────────────────────────────────────────
create table if not exists public.goods_receipts (
  id                uuid not null default gen_random_uuid() primary key,
  business_id       uuid not null references public.businesses(id) on delete cascade,
  warehouse_id      uuid not null references public.warehouses(id),
  supplier_id       uuid references public.suppliers(id),
  purchase_order_id uuid references public.purchase_orders(id),
  receipt_number    text not null,
  status            text not null default 'draft'
                      check (status in ('draft','confirmed','cancelled')),
  received_at       timestamptz not null default now(),
  notes             text,
  created_by        uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  unique (business_id, receipt_number)
);

create index if not exists idx_goods_receipts_business_status
  on public.goods_receipts (business_id, status, received_at desc);

create index if not exists idx_goods_receipts_po
  on public.goods_receipts (purchase_order_id)
  where purchase_order_id is not null;

alter table public.goods_receipts enable row level security;

drop policy if exists "gr_select" on public.goods_receipts;
create policy "gr_select" on public.goods_receipts
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "gr_write" on public.goods_receipts;
create policy "gr_write" on public.goods_receipts
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  );

create table if not exists public.goods_receipt_items (
  id                       uuid not null default gen_random_uuid() primary key,
  goods_receipt_id         uuid not null references public.goods_receipts(id) on delete cascade,
  purchase_order_item_id   uuid references public.purchase_order_items(id),
  inventory_item_id        uuid not null references public.inventory_items(id),
  quantity_received        numeric(14,4) not null check (quantity_received >= 0),
  quantity_rejected        numeric(14,4) not null default 0 check (quantity_rejected >= 0),
  unit_cost                numeric(14,4) not null check (unit_cost >= 0),
  notes                    text
);

create index if not exists idx_goods_receipt_items_parent
  on public.goods_receipt_items (goods_receipt_id);

create index if not exists idx_goods_receipt_items_item
  on public.goods_receipt_items (inventory_item_id);

alter table public.goods_receipt_items enable row level security;

drop policy if exists "gri_select" on public.goods_receipt_items;
create policy "gri_select" on public.goods_receipt_items
  for select to authenticated
  using (
    exists (
      select 1 from public.goods_receipts gr
      where gr.id = goods_receipt_items.goods_receipt_id
        and public.user_has_business_access(auth.uid(), gr.business_id)
    )
  );

drop policy if exists "gri_write" on public.goods_receipt_items;
create policy "gri_write" on public.goods_receipt_items
  to authenticated
  using (
    exists (
      select 1 from public.goods_receipts gr
      where gr.id = goods_receipt_items.goods_receipt_id
        and public.user_business_role(auth.uid(), gr.business_id)
              = any (array['owner','admin','manager'])
    )
  )
  with check (
    exists (
      select 1 from public.goods_receipts gr
      where gr.id = goods_receipt_items.goods_receipt_id
        and public.user_business_role(auth.uid(), gr.business_id)
              = any (array['owner','admin','manager'])
    )
  );

-- ─────────────────────────────────────────────────────────────────────
-- 6. Supplier invoices (facturas de proveedor)
-- ─────────────────────────────────────────────────────────────────────
create table if not exists public.supplier_invoices (
  id              uuid not null default gen_random_uuid() primary key,
  business_id     uuid not null references public.businesses(id) on delete cascade,
  supplier_id     uuid not null references public.suppliers(id),
  invoice_number  text not null,
  ncf             text,
  issue_date      date not null,
  due_date        date,
  subtotal        numeric(14,2) not null default 0 check (subtotal >= 0),
  itbis           numeric(14,2) not null default 0 check (itbis >= 0),
  other_charges   numeric(14,2) not null default 0 check (other_charges >= 0),
  total           numeric(14,2) not null default 0 check (total >= 0),
  status          text not null default 'pending'
                    check (status in ('pending','finalized','cancelled')),
  notes           text,
  created_by      uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  unique (business_id, supplier_id, invoice_number)
);

create index if not exists idx_supplier_invoices_business_status
  on public.supplier_invoices (business_id, status, due_date);

create index if not exists idx_supplier_invoices_supplier
  on public.supplier_invoices (supplier_id);

alter table public.supplier_invoices enable row level security;

drop policy if exists "si_select" on public.supplier_invoices;
create policy "si_select" on public.supplier_invoices
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "si_write" on public.supplier_invoices;
create policy "si_write" on public.supplier_invoices
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  );

create table if not exists public.supplier_invoice_lines (
  id                    uuid not null default gen_random_uuid() primary key,
  supplier_invoice_id   uuid not null references public.supplier_invoices(id) on delete cascade,
  goods_receipt_item_id uuid references public.goods_receipt_items(id),
  inventory_item_id     uuid references public.inventory_items(id),
  description           text,
  quantity              numeric(14,4) not null check (quantity > 0),
  unit_cost             numeric(14,4) not null check (unit_cost >= 0),
  tax_rate              numeric(5,2) not null default 18 check (tax_rate >= 0),
  line_total            numeric(14,2) not null check (line_total >= 0)
);

create index if not exists idx_supplier_invoice_lines_parent
  on public.supplier_invoice_lines (supplier_invoice_id);

create index if not exists idx_supplier_invoice_lines_grit
  on public.supplier_invoice_lines (goods_receipt_item_id)
  where goods_receipt_item_id is not null;

alter table public.supplier_invoice_lines enable row level security;

drop policy if exists "sil_select" on public.supplier_invoice_lines;
create policy "sil_select" on public.supplier_invoice_lines
  for select to authenticated
  using (
    exists (
      select 1 from public.supplier_invoices si
      where si.id = supplier_invoice_lines.supplier_invoice_id
        and public.user_has_business_access(auth.uid(), si.business_id)
    )
  );

drop policy if exists "sil_write" on public.supplier_invoice_lines;
create policy "sil_write" on public.supplier_invoice_lines
  to authenticated
  using (
    exists (
      select 1 from public.supplier_invoices si
      where si.id = supplier_invoice_lines.supplier_invoice_id
        and public.user_business_role(auth.uid(), si.business_id)
              = any (array['owner','admin','manager'])
    )
  )
  with check (
    exists (
      select 1 from public.supplier_invoices si
      where si.id = supplier_invoice_lines.supplier_invoice_id
        and public.user_business_role(auth.uid(), si.business_id)
              = any (array['owner','admin','manager'])
    )
  );

-- ─────────────────────────────────────────────────────────────────────
-- 7. Accounts payable (CxP)
-- ─────────────────────────────────────────────────────────────────────
create table if not exists public.accounts_payable (
  id                  uuid not null default gen_random_uuid() primary key,
  business_id         uuid not null references public.businesses(id) on delete cascade,
  supplier_id         uuid not null references public.suppliers(id),
  supplier_invoice_id uuid not null unique references public.supplier_invoices(id) on delete cascade,
  total_amount        numeric(14,2) not null check (total_amount >= 0),
  paid_amount         numeric(14,2) not null default 0 check (paid_amount >= 0),
  due_date            date,
  status              text not null default 'pending'
                        check (status in ('pending','partially_paid','paid','cancelled')),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (paid_amount <= total_amount)
);

create index if not exists idx_ap_business_status_due
  on public.accounts_payable (business_id, status, due_date);

create index if not exists idx_ap_supplier
  on public.accounts_payable (supplier_id);

drop trigger if exists trg_accounts_payable_touch on public.accounts_payable;
create trigger trg_accounts_payable_touch
before update on public.accounts_payable
for each row
execute function public.fn_inventory_items_touch_updated_at();

alter table public.accounts_payable enable row level security;

drop policy if exists "ap_select" on public.accounts_payable;
create policy "ap_select" on public.accounts_payable
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "ap_write" on public.accounts_payable;
create policy "ap_write" on public.accounts_payable
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  );

-- ─────────────────────────────────────────────────────────────────────
-- 8. Supplier payments + applications
-- ─────────────────────────────────────────────────────────────────────
create table if not exists public.supplier_payments (
  id              uuid not null default gen_random_uuid() primary key,
  business_id     uuid not null references public.businesses(id) on delete cascade,
  supplier_id     uuid not null references public.suppliers(id),
  payment_number  text not null,
  payment_date    date not null default current_date,
  amount          numeric(14,2) not null check (amount > 0),
  payment_method  text,
  reference       text,
  notes           text,
  created_by      uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  unique (business_id, payment_number)
);

create index if not exists idx_supplier_payments_business_date
  on public.supplier_payments (business_id, payment_date desc);

create index if not exists idx_supplier_payments_supplier
  on public.supplier_payments (supplier_id);

alter table public.supplier_payments enable row level security;

drop policy if exists "sp_select" on public.supplier_payments;
create policy "sp_select" on public.supplier_payments
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "sp_write" on public.supplier_payments;
create policy "sp_write" on public.supplier_payments
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  );

create table if not exists public.supplier_payment_applications (
  id                   uuid not null default gen_random_uuid() primary key,
  supplier_payment_id  uuid not null references public.supplier_payments(id) on delete cascade,
  accounts_payable_id  uuid not null references public.accounts_payable(id),
  amount_applied       numeric(14,2) not null check (amount_applied > 0)
);

create index if not exists idx_spa_payment
  on public.supplier_payment_applications (supplier_payment_id);

create index if not exists idx_spa_ap
  on public.supplier_payment_applications (accounts_payable_id);

alter table public.supplier_payment_applications enable row level security;

drop policy if exists "spa_select" on public.supplier_payment_applications;
create policy "spa_select" on public.supplier_payment_applications
  for select to authenticated
  using (
    exists (
      select 1 from public.supplier_payments p
      where p.id = supplier_payment_applications.supplier_payment_id
        and public.user_has_business_access(auth.uid(), p.business_id)
    )
  );

drop policy if exists "spa_write" on public.supplier_payment_applications;
create policy "spa_write" on public.supplier_payment_applications
  to authenticated
  using (
    exists (
      select 1 from public.supplier_payments p
      where p.id = supplier_payment_applications.supplier_payment_id
        and public.user_business_role(auth.uid(), p.business_id)
              = any (array['owner','admin','manager'])
    )
  )
  with check (
    exists (
      select 1 from public.supplier_payments p
      where p.id = supplier_payment_applications.supplier_payment_id
        and public.user_business_role(auth.uid(), p.business_id)
              = any (array['owner','admin','manager'])
    )
  );

-- ─────────────────────────────────────────────────────────────────────
-- 9. Stock transfers (entre bodegas, vía __IN_TRANSIT__)
-- ─────────────────────────────────────────────────────────────────────
create table if not exists public.stock_transfers (
  id                uuid not null default gen_random_uuid() primary key,
  business_id       uuid not null references public.businesses(id) on delete cascade,
  from_warehouse_id uuid not null references public.warehouses(id),
  to_warehouse_id   uuid not null references public.warehouses(id),
  transfer_number   text not null,
  status            text not null default 'draft'
                      check (status in ('draft','sent','received','cancelled')),
  sent_at           timestamptz,
  received_at       timestamptz,
  notes             text,
  created_by        uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  unique (business_id, transfer_number),
  check (from_warehouse_id <> to_warehouse_id)
);

create index if not exists idx_stock_transfers_business_status
  on public.stock_transfers (business_id, status, sent_at desc);

alter table public.stock_transfers enable row level security;

drop policy if exists "st_select" on public.stock_transfers;
create policy "st_select" on public.stock_transfers
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "st_write" on public.stock_transfers;
create policy "st_write" on public.stock_transfers
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  );

create table if not exists public.stock_transfer_items (
  id                  uuid not null default gen_random_uuid() primary key,
  stock_transfer_id   uuid not null references public.stock_transfers(id) on delete cascade,
  inventory_item_id   uuid not null references public.inventory_items(id),
  quantity_sent       numeric(14,4) not null check (quantity_sent > 0),
  quantity_received   numeric(14,4),
  variance_reason     text
);

create index if not exists idx_stock_transfer_items_parent
  on public.stock_transfer_items (stock_transfer_id);

alter table public.stock_transfer_items enable row level security;

drop policy if exists "sti_select" on public.stock_transfer_items;
create policy "sti_select" on public.stock_transfer_items
  for select to authenticated
  using (
    exists (
      select 1 from public.stock_transfers t
      where t.id = stock_transfer_items.stock_transfer_id
        and public.user_has_business_access(auth.uid(), t.business_id)
    )
  );

drop policy if exists "sti_write" on public.stock_transfer_items;
create policy "sti_write" on public.stock_transfer_items
  to authenticated
  using (
    exists (
      select 1 from public.stock_transfers t
      where t.id = stock_transfer_items.stock_transfer_id
        and public.user_business_role(auth.uid(), t.business_id)
              = any (array['owner','admin','manager'])
    )
  )
  with check (
    exists (
      select 1 from public.stock_transfers t
      where t.id = stock_transfer_items.stock_transfer_id
        and public.user_business_role(auth.uid(), t.business_id)
              = any (array['owner','admin','manager'])
    )
  );

-- ─────────────────────────────────────────────────────────────────────
-- 10. Inventory adjustments (ajustes manuales, conteos físicos)
-- ─────────────────────────────────────────────────────────────────────
create table if not exists public.inventory_adjustments (
  id                 uuid not null default gen_random_uuid() primary key,
  business_id        uuid not null references public.businesses(id) on delete cascade,
  warehouse_id       uuid not null references public.warehouses(id),
  adjustment_number  text not null,
  reason             text not null
                       check (reason in ('physical_count','breakage','expiration',
                                         'theft','correction','other')),
  notes              text,
  status             text not null default 'draft'
                       check (status in ('draft','confirmed','cancelled')),
  created_by         uuid references auth.users(id),
  created_at         timestamptz not null default now(),
  unique (business_id, adjustment_number)
);

create index if not exists idx_inv_adj_business_status
  on public.inventory_adjustments (business_id, status, created_at desc);

alter table public.inventory_adjustments enable row level security;

drop policy if exists "ia_select" on public.inventory_adjustments;
create policy "ia_select" on public.inventory_adjustments
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "ia_write" on public.inventory_adjustments;
create policy "ia_write" on public.inventory_adjustments
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  );

create table if not exists public.inventory_adjustment_items (
  id                       uuid not null default gen_random_uuid() primary key,
  inventory_adjustment_id  uuid not null references public.inventory_adjustments(id) on delete cascade,
  inventory_item_id        uuid not null references public.inventory_items(id),
  quantity_before          numeric(14,4) not null,
  quantity_counted         numeric(14,4) not null,
  difference               numeric(14,4) generated always as (quantity_counted - quantity_before) stored
);

create index if not exists idx_inv_adj_items_parent
  on public.inventory_adjustment_items (inventory_adjustment_id);

alter table public.inventory_adjustment_items enable row level security;

drop policy if exists "iai_select" on public.inventory_adjustment_items;
create policy "iai_select" on public.inventory_adjustment_items
  for select to authenticated
  using (
    exists (
      select 1 from public.inventory_adjustments a
      where a.id = inventory_adjustment_items.inventory_adjustment_id
        and public.user_has_business_access(auth.uid(), a.business_id)
    )
  );

drop policy if exists "iai_write" on public.inventory_adjustment_items;
create policy "iai_write" on public.inventory_adjustment_items
  to authenticated
  using (
    exists (
      select 1 from public.inventory_adjustments a
      where a.id = inventory_adjustment_items.inventory_adjustment_id
        and public.user_business_role(auth.uid(), a.business_id)
              = any (array['owner','admin','manager'])
    )
  )
  with check (
    exists (
      select 1 from public.inventory_adjustments a
      where a.id = inventory_adjustment_items.inventory_adjustment_id
        and public.user_business_role(auth.uid(), a.business_id)
              = any (array['owner','admin','manager'])
    )
  );

-- ─────────────────────────────────────────────────────────────────────
-- 11. Helpers
-- ─────────────────────────────────────────────────────────────────────

-- 11.1 ensure_in_transit_warehouse(business_id) → uuid
-- Crea o devuelve la bodega virtual __IN_TRANSIT__ del business.
create or replace function public.ensure_in_transit_warehouse(
  p_business_id uuid
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '28000', message = 'AUTH_REQUIRED';
  end if;

  if public.user_business_role(auth.uid(), p_business_id) is null then
    raise exception using errcode = '42501', message = 'NOT_AUTHORIZED';
  end if;

  select id into v_id
  from public.warehouses
  where business_id = p_business_id
    and name = '__IN_TRANSIT__'
  limit 1;

  if v_id is null then
    insert into public.warehouses (business_id, name, address, is_main, is_active)
    values (p_business_id, '__IN_TRANSIT__', null, false, true)
    returning id into v_id;
  end if;

  return v_id;
end;
$$;

grant execute on function public.ensure_in_transit_warehouse(uuid) to authenticated;

-- 11.2 bootstrap_menu_to_inventory_links(business_id) → jsonb
-- Genera, para un business, los inventory_items + recipes + recipe_ingredients
-- faltantes a partir de los menu_items activos. Idempotente (dedupe por sku
-- y por nombre normalizado).
create or replace function public.bootstrap_menu_to_inventory_links(
  p_business_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_role         text;
  v_items_created       int := 0;
  v_recipes_created     int := 0;
  v_ingredients_created int := 0;
begin
  if auth.uid() is null then
    raise exception using errcode = '28000', message = 'AUTH_REQUIRED';
  end if;

  v_caller_role := public.user_business_role(auth.uid(), p_business_id);
  if v_caller_role is null
     or v_caller_role not in ('owner','admin','manager') then
    raise exception using errcode = '42501', message = 'NOT_AUTHORIZED';
  end if;

  -- Paso 1: crear inventory_items faltantes (1 por menu_item activo).
  -- Match: si menu_item.sku no es vacío y existe inventory_item con ese sku,
  -- reusar; si no, comparar por nombre normalizado (lower+trim).
  with new_items as (
    insert into public.inventory_items
      (business_id, sku, name, unit, cost, min_stock, is_active)
    select
      mi.business_id,
      nullif(trim(mi.sku), ''),
      mi.name,
      'unidad',
      coalesce(mi.cost, 0),
      0,
      true
    from public.menu_items mi
    where mi.business_id = p_business_id
      and mi.is_active = true
      and not exists (
        select 1
        from public.inventory_items ii
        where ii.business_id = mi.business_id
          and (
            (mi.sku is not null and trim(mi.sku) <> '' and ii.sku = mi.sku)
            or (lower(trim(ii.name)) = lower(trim(mi.name)))
          )
      )
    returning id
  )
  select count(*)::int into v_items_created from new_items;

  -- Paso 2: crear una recipe (1:1) por menu_item activo sin receta.
  with new_recipes as (
    insert into public.recipes (menu_item_id, yield_quantity)
    select mi.id, 1
    from public.menu_items mi
    where mi.business_id = p_business_id
      and mi.is_active = true
      and not exists (
        select 1 from public.recipes r where r.menu_item_id = mi.id
      )
    returning id
  )
  select count(*)::int into v_recipes_created from new_recipes;

  -- Paso 3: crear recipe_ingredients (qty=1) en recipes que aún no tengan
  -- ingredientes, apuntando al inventory_item match (sku > nombre).
  with new_ings as (
    insert into public.recipe_ingredients
      (recipe_id, inventory_item_id, quantity, unit)
    select
      r.id,
      ii_match.id,
      1,
      coalesce(ii_match.unit, 'unidad')
    from public.recipes r
    join public.menu_items mi on mi.id = r.menu_item_id
    join lateral (
      select ii.id, ii.unit
      from public.inventory_items ii
      where ii.business_id = mi.business_id
        and (
          (mi.sku is not null and trim(mi.sku) <> '' and ii.sku = mi.sku)
          or (lower(trim(ii.name)) = lower(trim(mi.name)))
        )
      order by
        case when mi.sku is not null and trim(mi.sku) <> '' and ii.sku = mi.sku
             then 0 else 1 end,
        ii.created_at
      limit 1
    ) ii_match on true
    where mi.business_id = p_business_id
      and not exists (
        select 1 from public.recipe_ingredients ri where ri.recipe_id = r.id
      )
    returning id
  )
  select count(*)::int into v_ingredients_created from new_ings;

  return jsonb_build_object(
    'business_id',          p_business_id,
    'items_created',        v_items_created,
    'recipes_created',      v_recipes_created,
    'ingredients_created',  v_ingredients_created
  );
end;
$$;

grant execute on function public.bootstrap_menu_to_inventory_links(uuid) to authenticated;

commit;
