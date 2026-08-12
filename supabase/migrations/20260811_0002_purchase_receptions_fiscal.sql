-- =============================================================================
-- PRD 6.1 · F1 — Recepciones de compra con bloque fiscal (606) e idempotencia.
--
-- CONTEXTO:
--   El backend ya tiene recepción parcial (fn_receive_purchase_order_partial),
--   recepción libre (direct_receipts) y costeo ponderado
--   (fn_recompute_item_cost_weighted_avg). Lo que NO existe es la entidad
--   "recepción" con: costo real facturado por línea, bloque fiscal para el
--   606 (NCF, ITBIS, retenciones) e idempotencia de reenvío. Eso entrega
--   este archivo. La RPC fn_receive_purchase_order_v2 que escribe sobre
--   estas tablas llega en F3; las RPCs existentes NO se tocan.
--
-- ENTREGA:
--   - purchase_receptions: cabecera con bloque fiscal 606 + idempotency_key.
--   - purchase_reception_lines: líneas con costo real y variación vs. la OC.
--   - Índice único (business_id, idempotency_key): reenviar la misma
--     recepción N veces no puede duplicarla. La clave commitea en la MISMA
--     transacción que los efectos (contrato de la RPC v2).
--   - Índice único parcial en inventory_movements para
--     reference_type = 'purchase_reception_line': duplicar movimientos de
--     recepción es estructuralmente imposible aunque algún código futuro
--     esquive la RPC.
--   - RLS: lectura para miembros del negocio; escritura owner/admin/manager
--     (mismo patrón que direct_receipts).
--
-- IDEMPOTENTE / BACKWARDS-COMPATIBLE:
--   - Solo tablas e índices nuevos. Cero cambios a tablas o RPCs existentes.
--   - El índice parcial sobre inventory_movements no afecta filas existentes
--     (el reference_type es nuevo).
-- =============================================================================

begin;

-- ── Cabecera ────────────────────────────────────────────────────────────────

create table if not exists public.purchase_receptions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  warehouse_id uuid not null references public.warehouses(id),
  purchase_order_id uuid references public.purchase_orders(id),  -- null = recepción libre
  supplier_id uuid references public.suppliers(id),
  reception_date date not null default current_date,
  -- Bloque fiscal para el 606 (todos opcionales: una recepción sin factura
  -- fiscal sigue siendo válida para inventario).
  ncf text,
  ncf_type text,
  ncf_modified text,               -- NCF afectado por nota de crédito/débito
  document_date date,
  payment_date date,
  goods_amount numeric(14,2),
  services_amount numeric(14,2),
  itbis_invoiced numeric(14,2),
  itbis_withheld numeric(14,2),
  isr_withheld numeric(14,2),
  isc numeric(14,2),
  legal_tip numeric(14,2),
  payment_method text,
  -- Estado y auditoría
  status text not null default 'draft'
    check (status in ('draft', 'partial', 'short_closed', 'complete', 'cancelled')),
  idempotency_key text,
  received_by uuid,
  created_at timestamptz default now() not null
);

-- Reenviar la misma recepción con la misma clave nunca duplica. La RPC v2
-- inserta la cabecera y sus efectos en UNA transacción: si algo falla, la
-- clave también se revierte y el reintento arranca limpio.
create unique index if not exists uq_purchase_receptions_idem
  on public.purchase_receptions (business_id, idempotency_key)
  where idempotency_key is not null;

create index if not exists idx_purchase_receptions_business
  on public.purchase_receptions (business_id, reception_date desc);

create index if not exists idx_purchase_receptions_po
  on public.purchase_receptions (purchase_order_id)
  where purchase_order_id is not null;

comment on table public.purchase_receptions is
  'Recepción de mercancía (contra OC o libre) con el bloque fiscal del 606. '
  'idempotency_key la genera la app al INICIAR la recepción y sobrevive '
  'reinicios; la RPC v2 la usa para hacer el reenvío seguro.';

-- ── Líneas ──────────────────────────────────────────────────────────────────

create table if not exists public.purchase_reception_lines (
  id uuid primary key default gen_random_uuid(),
  reception_id uuid not null references public.purchase_receptions(id) on delete cascade,
  purchase_order_item_id uuid references public.purchase_order_items(id),
  item_id uuid references public.inventory_items(id),
  quantity_received numeric(14,3) not null check (quantity_received > 0),
  actual_unit_cost numeric(14,4) not null check (actual_unit_cost >= 0),
  -- Variación vs. unit_cost de la OC (null en recepción libre).
  cost_variance_pct numeric(8,4),
  -- Aprobación cuando la variación supera el umbral del negocio. La RPC v2
  -- registra auto-aprobación (mismo usuario) en vez de bloquear: lo que se
  -- vende es la trazabilidad.
  approved_by uuid,
  discrepancy text
    check (discrepancy in ('ok', 'short', 'over', 'extra') or discrepancy is null)
);

create index if not exists idx_purchase_reception_lines_reception
  on public.purchase_reception_lines (reception_id);

comment on column public.purchase_reception_lines.quantity_received is
  'Siempre en unidad BASE del ítem (el ledger completo opera en unidad base; '
  'la conversión empaque↔base ocurre en la app vía inventory_items.pack_size).';

-- ── Cinturón anti-duplicados en el ledger ───────────────────────────────────
-- Un movimiento de inventario por línea de recepción, garantizado por esquema.
create unique index if not exists uq_inventory_movements_reception_line
  on public.inventory_movements (reference_id)
  where reference_type = 'purchase_reception_line';

-- ── RLS (patrón direct_receipts) ────────────────────────────────────────────

alter table public.purchase_receptions enable row level security;

drop policy if exists "pr_select" on public.purchase_receptions;
create policy "pr_select" on public.purchase_receptions
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "pr_write" on public.purchase_receptions;
create policy "pr_write" on public.purchase_receptions
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  );

alter table public.purchase_reception_lines enable row level security;

drop policy if exists "prl_select" on public.purchase_reception_lines;
create policy "prl_select" on public.purchase_reception_lines
  for select to authenticated
  using (
    exists (
      select 1 from public.purchase_receptions pr
      where pr.id = purchase_reception_lines.reception_id
        and public.user_has_business_access(auth.uid(), pr.business_id)
    )
  );

drop policy if exists "prl_write" on public.purchase_reception_lines;
create policy "prl_write" on public.purchase_reception_lines
  to authenticated
  using (
    exists (
      select 1 from public.purchase_receptions pr
      where pr.id = purchase_reception_lines.reception_id
        and public.user_business_role(auth.uid(), pr.business_id)
          = any (array['owner','admin','manager'])
    )
  )
  with check (
    exists (
      select 1 from public.purchase_receptions pr
      where pr.id = purchase_reception_lines.reception_id
        and public.user_business_role(auth.uid(), pr.business_id)
          = any (array['owner','admin','manager'])
    )
  );

commit;
