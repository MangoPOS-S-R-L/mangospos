-- =============================================================================
-- 20260930_0053 — Tarjetas de sellos (cliente frecuente): «cada N, 1 gratis».
--
-- PEDIDO DEL DUEÑO (2026-09-30): «tengo tarjetas con 10 marcas; cada 10 cafés
-- le damos 1 gratis, pero pueden ser 20 cafés y 1 gratis, o 5 pizzas y una
-- gratis». Hoy no existe nada que funcione: `loyalty_programs` /
-- `customer_points` son andamiaje de PUNTOS POR DINERO que ninguna pantalla
-- lee ni escribe. Una tarjeta de sellos es otra cosa (cuenta UNIDADES de
-- ciertos productos), por eso tablas propias.
--
-- QUÉ ES UNA MARCA (count_mode, por tarjeta):
--   · 'visit' (default): UNA marca por compra (orden) cobrada que traiga al
--     menos un producto de la tarjeta, lleve 1 o 3. Es como se sella el
--     cartón en caja. Caso real: The Pizza Hot Villa Tapia, 5 marcas y la 6ª
--     pizza gratis (cualquiera, con sus extras). Una compra en la que solo se
--     llevó la pizza del premio NO suma marca.
--   · 'unit': cada unidad cobrada suma una marca («cada 10 cafés»).
--
-- MODELO — los sellos NO se guardan, se CALCULAN de las ventas cobradas:
--   sellos = compras (o unidades) cobradas con productos del programa
--            (desde starts_at)
--          + ajustes manuales (cargar la tarjeta física, corregir)
--          − sellos de premios ya cobrados (canjeados)
--          − sellos de premios puestos en una cuenta todavía abierta (reservados)
--
--   Por qué calcular y no acumular con un trigger al cobrar:
--   · Una anulación (ítems a 'void', o la subcuenta reabierta con los ítems en
--     'served') devuelve los sellos sola. Un trigger tendría que conocer cada
--     camino de anulación, y hay varios (ver sales_repository.annulPayment).
--   · Los cobros offline cuentan en cuanto sincronizan, sin hook extra.
--   · Si el cajero pone el cliente DESPUÉS de cobrar, los sellos aparecen.
--   · No se agrega trabajo al camino caliente de order_items.
--
-- CUÁNDO UNA LÍNEA CUENTA COMO VENDIDA (fn_loyalty_item_sold):
--   no anulada, orden no anulada, la orden tiene un pago 'completed' y además
--   el ítem está en 'paid' o su subcuenta / su orden quedó cerrada. No basta
--   con `status = 'paid'`: el KDS puede pisarlo después del cobro.
--
-- A QUIÉN SE LE ACREDITA: al cliente efectivo de la línea =
--   coalesce(order_checks.customer_id, table_sessions.customer_id). Es la
--   misma regla con la que se emite el comprobante (subcuenta > mesa).
--
-- NO SUMAN SELLOS: líneas regaladas enteras (cortesía, 100 %, la unidad
--   gratis de un 2x1 guardada aparte) ni las unidades gratis de un premio.
--
-- EL PREMIO: fn_loyalty_redeem_reward pone 1 unidad gratis en una línea
--   abierta del cliente, por el MISMO canal que el resto de descuentos
--   (order_items.discounts + calculate_*_totals), con el marcador
--   `[LOYALTY:<id del canje>:<unidades>]` en las notas. El canje vale mientras el
--   marcador siga en la línea: si una cortesía o un descuento lo reemplaza, o
--   la línea se borra/anula, los sellos vuelven solos. El impuesto se trata
--   igual que cualquier descuento (ver project_offer_discount_tax_base).
--
-- RPC (todas SECURITY DEFINER, validan acceso al negocio):
--   fn_loyalty_customer_cards(p_customer_id)                     → jsonb[]
--   fn_loyalty_redeem_reward(p_program_id, p_customer_id,
--                            p_order_item_id, p_units = 1)       → jsonb
--   fn_loyalty_cancel_reward(p_order_item_id)                    → jsonb
--   fn_loyalty_adjust_stamps(p_program_id, p_customer_id,
--                            p_stamps, p_reason)                 → jsonb
--   Los programas se crean/editan directo en la tabla (RLS).
--
-- QUIÉN:
--   · Configurar programas: owner/admin/manager o
--     `settings.descuentos_propinas.gestionar` (el mismo de Ofertas).
--   · Canjear: cualquiera con acceso al negocio (el premio ya se ganó).
--   · Ajustar sellos a mano: owner/admin/manager o `clientes.crear_editar`.
--     Motivo obligatorio y queda quién lo hizo.
--
-- Índice nuevo en order_checks(customer_id): se construye leyendo la tabla
-- entera; aplicar fuera de la hora pico.
--
-- Prueba local: bash supabase/tests/loyalty_stamp_cards_local_test.sh
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Programas
-- ---------------------------------------------------------------------------
create table if not exists public.loyalty_stamp_programs (
  id              uuid primary key default gen_random_uuid(),
  business_id     uuid not null references public.businesses(id) on delete cascade,
  name            text not null,
  target_scope    text not null default 'product',
  target_ids      uuid[] not null default '{}',
  stamps_required integer not null,
  count_mode      text not null default 'visit',
  starts_at       timestamptz not null default now(),
  is_active       boolean not null default true,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint loyalty_stamp_programs_name_chk
    check (length(btrim(name)) between 1 and 80),
  constraint loyalty_stamp_programs_scope_chk
    check (target_scope in ('product', 'category')),
  constraint loyalty_stamp_programs_targets_chk
    check (cardinality(target_ids) between 1 and 500),
  constraint loyalty_stamp_programs_stamps_chk
    check (stamps_required between 2 and 100),
  constraint loyalty_stamp_programs_count_mode_chk
    check (count_mode in ('visit', 'unit'))
);

create index if not exists idx_loyalty_stamp_programs_business
  on public.loyalty_stamp_programs (business_id);

drop trigger if exists set_loyalty_stamp_programs_updated_at
  on public.loyalty_stamp_programs;
create trigger set_loyalty_stamp_programs_updated_at
  before update on public.loyalty_stamp_programs
  for each row execute function public.trigger_set_updated_at();

-- Los productos / categorías del programa tienen que ser del mismo negocio:
-- un id ajeno haría contar ventas que no son de esta tarjeta.
create or replace function public.fn_loyalty_programs_validate_targets()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_found integer;
begin
  new.target_ids := array(select distinct unnest(new.target_ids));
  if new.target_scope = 'product' then
    select count(*) into v_found
      from public.menu_items mi
     where mi.id = any (new.target_ids)
       and mi.business_id = new.business_id;
  else
    select count(*) into v_found
      from public.categories c
     where c.id = any (new.target_ids)
       and c.business_id = new.business_id;
  end if;
  if v_found <> cardinality(new.target_ids) then
    raise exception 'LOYALTY_TARGETS_INVALID';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_loyalty_programs_validate_targets
  on public.loyalty_stamp_programs;
create trigger trg_loyalty_programs_validate_targets
  before insert or update of target_scope, target_ids, business_id
  on public.loyalty_stamp_programs
  for each row execute function public.fn_loyalty_programs_validate_targets();

-- ---------------------------------------------------------------------------
-- 2. Ajustes manuales (cargar la tarjeta física, corregir un error)
-- ---------------------------------------------------------------------------
create table if not exists public.loyalty_stamp_adjustments (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  program_id  uuid not null references public.loyalty_stamp_programs(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  stamps      integer not null,
  reason      text not null,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  constraint loyalty_stamp_adjustments_stamps_chk
    check (stamps <> 0 and stamps between -1000 and 1000),
  constraint loyalty_stamp_adjustments_reason_chk
    check (length(btrim(reason)) between 3 and 200)
);

create index if not exists idx_loyalty_stamp_adjustments_customer
  on public.loyalty_stamp_adjustments (customer_id, program_id, created_at desc);

-- ---------------------------------------------------------------------------
-- 3. Canjes. La fila guarda cuánto costó (el programa puede cambiar mañana);
--    si el canje VALE lo decide el marcador en la línea (ver arriba).
--    order_item_id es informativo: consolidar/dividir recrea ítems.
-- ---------------------------------------------------------------------------
create table if not exists public.loyalty_stamp_redemptions (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.businesses(id) on delete cascade,
  program_id    uuid not null references public.loyalty_stamp_programs(id) on delete cascade,
  customer_id   uuid not null references public.customers(id) on delete cascade,
  order_id      uuid not null references public.orders(id) on delete cascade,
  order_item_id uuid,
  units         integer not null,
  stamps        integer not null,
  discount      numeric(12,2) not null,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  constraint loyalty_stamp_redemptions_units_chk check (units between 1 and 20),
  constraint loyalty_stamp_redemptions_stamps_chk check (stamps > 0),
  constraint loyalty_stamp_redemptions_discount_chk check (discount >= 0)
);

create index if not exists idx_loyalty_stamp_redemptions_customer
  on public.loyalty_stamp_redemptions (customer_id, program_id);
create index if not exists idx_loyalty_stamp_redemptions_order
  on public.loyalty_stamp_redemptions (order_id);

-- Para juntar las ventas de un cliente cuando se le asignó a la SUBCUENTA.
-- (table_sessions.customer_id ya tiene idx_table_sessions_customer_id.)
create index if not exists idx_order_checks_customer_id
  on public.order_checks (customer_id)
  where customer_id is not null;

-- ---------------------------------------------------------------------------
-- 4. RLS: lectura para quien tenga acceso al negocio. Los programas los
--    escribe quien administra ofertas; ajustes y canjes SOLO por RPC.
-- ---------------------------------------------------------------------------
create or replace function public.fn_loyalty_can_manage(p_business uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.user_business_role(auth.uid(), p_business), '')
           in ('owner', 'admin', 'manager')
      or public.user_has_business_permission(
           p_business, 'settings.descuentos_propinas.gestionar');
$$;

alter table public.loyalty_stamp_programs enable row level security;
alter table public.loyalty_stamp_adjustments enable row level security;
alter table public.loyalty_stamp_redemptions enable row level security;

drop policy if exists lsp_select on public.loyalty_stamp_programs;
create policy lsp_select on public.loyalty_stamp_programs
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists lsp_write on public.loyalty_stamp_programs;
create policy lsp_write on public.loyalty_stamp_programs
  for all to authenticated
  using (public.fn_loyalty_can_manage(business_id))
  with check (public.fn_loyalty_can_manage(business_id));

drop policy if exists lsa_select on public.loyalty_stamp_adjustments;
create policy lsa_select on public.loyalty_stamp_adjustments
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists lsr_select on public.loyalty_stamp_redemptions;
create policy lsr_select on public.loyalty_stamp_redemptions
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

grant select, insert, update, delete on public.loyalty_stamp_programs to authenticated;
grant select on public.loyalty_stamp_adjustments to authenticated;
grant select on public.loyalty_stamp_redemptions to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Piezas internas
-- ---------------------------------------------------------------------------

-- Id del canje en las notas de una línea, o null. El marcador es
-- `[LOYALTY:<uuid del canje>:<unidades gratis>]`; las unidades las usa la app
-- para que un descuento manual encima respete el premio.
-- El patrón exige la forma exacta de un uuid: el cast no puede fallar, y un
-- texto raro en las notas no tumba el cálculo de nadie.
create or replace function public.fn_loyalty_marker_id(p_notes text)
returns uuid
language sql
immutable
as $$
  select (regexp_match(
            coalesce(p_notes, ''),
            '\[LOYALTY:([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(:[0-9]+)?\]'
         ))[1]::uuid;
$$;

-- Productos que suman sellos en el programa (categoría → sus productos).
create or replace function public.fn_loyalty_program_products(p_program_id uuid)
returns table (product_id uuid)
language sql
stable
security definer
set search_path = public
as $$
  select distinct t.product_id
    from public.loyalty_stamp_programs p
    cross join lateral unnest(p.target_ids) as t(product_id)
   where p.id = p_program_id
     and p.target_scope = 'product'
  union
  select mi.id
    from public.loyalty_stamp_programs p
    join public.menu_items mi
      on mi.category_id = any (p.target_ids)
     and mi.business_id = p.business_id
   where p.id = p_program_id
     and p.target_scope = 'category';
$$;

-- ¿La línea está VENDIDA (cobrada y no anulada)? Ver cabecera.
create or replace function public.fn_loyalty_item_sold(
  p_item_status     text,
  p_check_id        uuid,
  p_check_closed    boolean,
  p_order_id        uuid,
  p_order_closed_at timestamptz,
  p_order_status    text
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(p_item_status, '') <> 'void'
     and coalesce(p_order_status, '') <> 'void'
     and (
          p_item_status = 'paid'
       or (p_check_id is not null and coalesce(p_check_closed, false))
       or (p_check_id is null and p_order_closed_at is not null)
     )
     and exists (
       select 1 from public.payments pay
        where pay.order_id = p_order_id
          and pay.status = 'completed'
     );
$$;

-- Totales de sellos por programa ACTIVO del negocio del cliente.
-- No valida acceso: la llaman los RPC de abajo, que sí lo hacen.
create or replace function public.fn_loyalty_stamp_totals(p_customer_id uuid)
returns table (
  program_id  uuid,
  earned      numeric,
  adjustments numeric,
  redeemed    numeric,
  reserved    numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with progs as (
    select p.*
      from public.loyalty_stamp_programs p
      join public.customers c on c.business_id = p.business_id
     where c.id = p_customer_id
       and p.is_active
  ),
  prog_products as materialized (
    select p.id as program_id, x.product_id
      from progs p
      cross join lateral public.fn_loyalty_program_products(p.id) x
  ),
  cand_orders as materialized (
    select o.id
      from public.table_sessions ts
      join public.orders o on o.session_id = ts.id
     where ts.customer_id = p_customer_id
    union
    select oc.order_id
      from public.order_checks oc
     where oc.customer_id = p_customer_id
  ),
  sold_lines as materialized (
    select oi.order_id,
           oi.product_id,
           oi.created_at,
           greatest(
             coalesce(oi.quantity, oi.qty, 0) - coalesce(r.units, 0),
             0
           ) as units
      from cand_orders co
      join public.orders o          on o.id = co.id
      join public.table_sessions ts on ts.id = o.session_id
      join public.order_items oi    on oi.order_id = o.id
      left join public.order_checks oc on oc.id = oi.check_id
      left join public.loyalty_stamp_redemptions r
             on r.id = public.fn_loyalty_marker_id(oi.notes)
     where coalesce(oc.customer_id, ts.customer_id) = p_customer_id
       and public.fn_loyalty_item_sold(
             oi.status::text, oi.check_id, oc.is_closed,
             o.id, o.closed_at, o.status_ext::text)
       -- Línea regalada entera (cortesía, 100 %, unidad gratis aparte):
       -- no es una compra.
       and coalesce(oi.discounts, 0)
             < coalesce(oi.subtotal, 0) + coalesce(oi.tax, 0) - 0.01
       and coalesce(oi.notes, '') not like '%[CORTESIA:%'
  ),
  redemption_state as materialized (
    select r.program_id,
           r.stamps,
           case
             when exists (
               select 1
                 from public.order_items oi
                 join public.orders o on o.id = oi.order_id
                 left join public.order_checks oc on oc.id = oi.check_id
                where oi.order_id = r.order_id
                  and public.fn_loyalty_marker_id(oi.notes) = r.id
                  and public.fn_loyalty_item_sold(
                        oi.status::text, oi.check_id, oc.is_closed,
                        o.id, o.closed_at, o.status_ext::text)
             ) then 'redeemed'
             when exists (
               select 1
                 from public.order_items oi
                 join public.orders o on o.id = oi.order_id
                where oi.order_id = r.order_id
                  and public.fn_loyalty_marker_id(oi.notes) = r.id
                  and oi.status::text not in ('paid', 'void')
                  and o.closed_at is null
                  and coalesce(o.status_ext::text, '') <> 'void'
             ) then 'reserved'
             else 'void'
           end as state
      from public.loyalty_stamp_redemptions r
     where r.customer_id = p_customer_id
  )
  select p.id,
         case
           when p.count_mode = 'unit' then coalesce((
             select floor(sum(s.units))
               from sold_lines s
               join prog_products pp
                 on pp.program_id = p.id
                and pp.product_id = s.product_id
              where s.created_at >= p.starts_at
           ), 0)
           -- 'visit': una marca por orden con algo PAGADO de la tarjeta (la
           -- unidad del premio ya viene restada en `units`).
           else (
             select count(*)
               from (
                 select s.order_id
                   from sold_lines s
                   join prog_products pp
                     on pp.program_id = p.id
                    and pp.product_id = s.product_id
                  where s.created_at >= p.starts_at
                  group by s.order_id
                 having sum(s.units) > 0
               ) visits
           )
         end,
         coalesce((
           select sum(a.stamps)
             from public.loyalty_stamp_adjustments a
            where a.program_id = p.id
              and a.customer_id = p_customer_id
         ), 0),
         coalesce((
           select sum(rs.stamps) from redemption_state rs
            where rs.program_id = p.id and rs.state = 'redeemed'
         ), 0),
         coalesce((
           select sum(rs.stamps) from redemption_state rs
            where rs.program_id = p.id and rs.state = 'reserved'
         ), 0)
    from progs p;
$$;

revoke all on function public.fn_loyalty_stamp_totals(uuid) from public;
revoke all on function public.fn_loyalty_item_sold(text, uuid, boolean, uuid, timestamptz, text) from public;
revoke all on function public.fn_loyalty_program_products(uuid) from public;
revoke all on function public.fn_loyalty_programs_validate_targets() from public;

-- ---------------------------------------------------------------------------
-- 6. Tarjetas del cliente (lo que pinta la caja y la ficha del cliente)
-- ---------------------------------------------------------------------------
create or replace function public.fn_loyalty_customer_cards(p_customer_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_business uuid;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;
  select c.business_id into v_business
    from public.customers c where c.id = p_customer_id;
  if v_business is null then
    raise exception 'CUSTOMER_NOT_FOUND';
  end if;
  if not public.user_has_business_access(auth.uid(), v_business) then
    raise exception 'LOYALTY_ACCESS_DENIED';
  end if;

  return coalesce((
    select jsonb_agg(
             jsonb_build_object(
               'program_id',        p.id,
               'name',              p.name,
               'stamps_required',   p.stamps_required,
               'target_scope',      p.target_scope,
               'count_mode',        p.count_mode,
               'starts_at',         p.starts_at,
               'earned',            t.earned,
               'adjustments',       t.adjustments,
               'redeemed',          t.redeemed,
               'reserved',          t.reserved,
               'balance',           b.balance,
               'available_rewards', floor(greatest(b.balance, 0) / p.stamps_required),
               'progress',          mod(greatest(b.balance, 0), p.stamps_required),
               'eligible_product_ids', coalesce((
                 select jsonb_agg(x.product_id)
                   from public.fn_loyalty_program_products(p.id) x
               ), '[]'::jsonb)
             )
             order by p.name
           )
      from public.fn_loyalty_stamp_totals(p_customer_id) t
      join public.loyalty_stamp_programs p on p.id = t.program_id
      cross join lateral (
        select t.earned + t.adjustments - t.redeemed - t.reserved as balance
      ) b
  ), '[]'::jsonb);
end;
$$;

grant execute on function public.fn_loyalty_customer_cards(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Canjear: N unidades gratis en una línea abierta del cliente
-- ---------------------------------------------------------------------------
create or replace function public.fn_loyalty_redeem_reward(
  p_program_id    uuid,
  p_customer_id   uuid,
  p_order_item_id uuid,
  p_units         integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid           uuid := auth.uid();
  v_program       public.loyalty_stamp_programs;
  v_cust_business uuid;
  v_item          record;
  v_balance       numeric;
  v_cost          integer;
  v_gross         numeric;
  v_discount      numeric(12,2);
  v_redemption_id uuid;
  v_notes         text;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;
  if p_units is null or p_units < 1 or p_units > 20 then
    raise exception 'LOYALTY_INVALID_UNITS';
  end if;

  select * into v_program
    from public.loyalty_stamp_programs where id = p_program_id;
  if not found or not v_program.is_active then
    raise exception 'LOYALTY_PROGRAM_NOT_FOUND';
  end if;

  select c.business_id into v_cust_business
    from public.customers c where c.id = p_customer_id;
  if v_cust_business is distinct from v_program.business_id then
    raise exception 'CUSTOMER_NOT_FOUND';
  end if;

  if not public.user_has_business_access(v_uid, v_program.business_id) then
    raise exception 'LOYALTY_ACCESS_DENIED';
  end if;

  -- Dos cajas canjeando a la vez para el mismo cliente no gastan los mismos
  -- sellos: el saldo se lee DESPUÉS de tomar este candado.
  perform pg_advisory_xact_lock(
    hashtextextended(
      'loyalty:' || p_customer_id::text || ':' || p_program_id::text, 0));

  select oi.id,
         oi.order_id,
         oi.check_id,
         oi.product_id,
         oi.status::text                       as status,
         coalesce(oi.quantity, oi.qty, 0)      as qty,
         coalesce(oi.subtotal, 0)              as subtotal,
         coalesce(oi.tax, 0)                   as tax,
         coalesce(oi.discounts, 0)             as discounts,
         oi.notes,
         o.closed_at,
         o.status_ext::text                    as order_status,
         coalesce(oc.is_closed, false)         as check_closed,
         coalesce(oc.customer_id, ts.customer_id) as customer_id,
         coalesce(z.business_id, ts.business_id)   as business_id
    into v_item
    from public.order_items oi
    join public.orders o          on o.id = oi.order_id
    join public.table_sessions ts on ts.id = o.session_id
    left join public.dining_tables dt on dt.id = ts.table_id
    left join public.zones z          on z.id = dt.zone_id
    left join public.order_checks oc  on oc.id = oi.check_id
   where oi.id = p_order_item_id
     for update of oi;

  if not found
     or (v_item.business_id is not null
         and v_item.business_id <> v_program.business_id) then
    raise exception 'ITEM_NOT_FOUND';
  end if;
  if v_item.status in ('paid', 'void')
     or v_item.closed_at is not null
     or v_item.check_closed
     or coalesce(v_item.order_status, '') = 'void' then
    raise exception 'ITEM_NOT_OPEN';
  end if;
  if v_item.customer_id is distinct from p_customer_id then
    raise exception 'ITEM_NOT_FOR_CUSTOMER';
  end if;
  if not exists (
    select 1 from public.fn_loyalty_program_products(p_program_id) x
     where x.product_id = v_item.product_id
  ) then
    raise exception 'ITEM_NOT_IN_PROGRAM';
  end if;
  if v_item.qty < p_units then
    raise exception 'LOYALTY_INVALID_UNITS';
  end if;
  -- Una línea con otro descuento (oferta, cortesía, manual) no se pisa.
  if v_item.discounts > 0.009
     or coalesce(v_item.notes, '')
          ~ '(^|\n)\s*\[(CORTESIA:|PROMO_AUTO:|DEAL|LOYALTY:)' then
    raise exception 'ITEM_ALREADY_DISCOUNTED';
  end if;

  v_gross := v_item.subtotal + v_item.tax;
  if v_gross <= 0 or v_item.qty <= 0 then
    raise exception 'ITEM_HAS_NO_PRICE';
  end if;

  select t.earned + t.adjustments - t.redeemed - t.reserved
    into v_balance
    from public.fn_loyalty_stamp_totals(p_customer_id) t
   where t.program_id = p_program_id;
  v_cost := p_units * v_program.stamps_required;
  if coalesce(v_balance, 0) < v_cost then
    raise exception 'NOT_ENOUGH_STAMPS';
  end if;

  -- Misma cuenta que el reparto del 2x1 (bogo_promo_allocator.dart):
  -- gross de la línea / unidades × unidades gratis.
  v_discount := round(least(v_gross / v_item.qty * p_units, v_gross), 2);

  insert into public.loyalty_stamp_redemptions (
    business_id, program_id, customer_id, order_id, order_item_id,
    units, stamps, discount, created_by)
  values (
    v_program.business_id, p_program_id, p_customer_id, v_item.order_id,
    v_item.id, p_units, v_cost, v_discount, v_uid)
  returning id into v_redemption_id;

  v_notes := concat_ws(
    E'\n',
    nullif(btrim(coalesce(v_item.notes, '')), ''),
    '[LOYALTY:' || v_redemption_id::text || ':' || p_units::text || ']');

  update public.order_items
     set discounts = v_discount,
         notes = v_notes
   where id = v_item.id;

  perform public.calculate_order_totals(v_item.order_id);
  if v_item.check_id is not null then
    perform public.calculate_check_totals(v_item.check_id);
  end if;

  return jsonb_build_object(
    'redemption_id', v_redemption_id,
    'order_item_id', v_item.id,
    'units',         p_units,
    'stamps',        v_cost,
    'discount',      v_discount,
    'balance_after', v_balance - v_cost);
end;
$$;

grant execute on function
  public.fn_loyalty_redeem_reward(uuid, uuid, uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Quitar el premio de una línea abierta (los sellos vuelven)
-- ---------------------------------------------------------------------------
create or replace function public.fn_loyalty_cancel_reward(p_order_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid        uuid := auth.uid();
  v_item       record;
  v_redemption public.loyalty_stamp_redemptions;
  v_rid        uuid;
  v_notes      text;
  v_discount   numeric(12,2);
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select oi.id, oi.order_id, oi.check_id, oi.status::text as status,
         coalesce(oi.discounts, 0) as discounts, oi.notes,
         o.closed_at, o.status_ext::text as order_status,
         coalesce(oc.is_closed, false) as check_closed,
         coalesce(z.business_id, ts.business_id) as business_id
    into v_item
    from public.order_items oi
    join public.orders o          on o.id = oi.order_id
    join public.table_sessions ts on ts.id = o.session_id
    left join public.dining_tables dt on dt.id = ts.table_id
    left join public.zones z          on z.id = dt.zone_id
    left join public.order_checks oc  on oc.id = oi.check_id
   where oi.id = p_order_item_id
     for update of oi;
  if not found then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  v_rid := public.fn_loyalty_marker_id(v_item.notes);
  if v_rid is null then
    raise exception 'NO_LOYALTY_REWARD';
  end if;
  select * into v_redemption
    from public.loyalty_stamp_redemptions where id = v_rid;

  if not public.user_has_business_access(
       v_uid, coalesce(v_redemption.business_id, v_item.business_id)) then
    raise exception 'LOYALTY_ACCESS_DENIED';
  end if;
  if v_item.status in ('paid', 'void')
     or v_item.closed_at is not null
     or v_item.check_closed
     or coalesce(v_item.order_status, '') = 'void' then
    raise exception 'ITEM_NOT_OPEN';
  end if;

  v_notes := nullif(btrim(regexp_replace(
               v_item.notes, '\s*\[LOYALTY:[^]]*\]', '', 'g')), '');
  -- Se quita solo lo que puso el premio: si encima había un descuento manual
  -- (que respeta el premio), ese resto se queda.
  v_discount := round(greatest(
                  v_item.discounts
                  - coalesce(v_redemption.discount, v_item.discounts), 0), 2);

  update public.order_items
     set discounts = v_discount,
         notes = v_notes
   where id = v_item.id;

  perform public.calculate_order_totals(v_item.order_id);
  if v_item.check_id is not null then
    perform public.calculate_check_totals(v_item.check_id);
  end if;

  delete from public.loyalty_stamp_redemptions where id = v_rid;

  return jsonb_build_object(
    'order_item_id', v_item.id,
    'discount',      v_discount,
    'stamps_returned', coalesce(v_redemption.stamps, 0));
end;
$$;

grant execute on function public.fn_loyalty_cancel_reward(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. Ajuste manual (cargar la tarjeta física, corregir)
-- ---------------------------------------------------------------------------
create or replace function public.fn_loyalty_adjust_stamps(
  p_program_id  uuid,
  p_customer_id uuid,
  p_stamps      integer,
  p_reason      text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid           uuid := auth.uid();
  v_program       public.loyalty_stamp_programs;
  v_cust_business uuid;
  v_balance       numeric;
  v_reason        text := btrim(coalesce(p_reason, ''));
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;
  if p_stamps is null or p_stamps = 0 or abs(p_stamps) > 1000 then
    raise exception 'LOYALTY_INVALID_STAMPS';
  end if;
  if length(v_reason) < 3 then
    raise exception 'LOYALTY_REASON_REQUIRED';
  end if;

  select * into v_program
    from public.loyalty_stamp_programs where id = p_program_id;
  if not found or not v_program.is_active then
    raise exception 'LOYALTY_PROGRAM_NOT_FOUND';
  end if;
  select c.business_id into v_cust_business
    from public.customers c where c.id = p_customer_id;
  if v_cust_business is distinct from v_program.business_id then
    raise exception 'CUSTOMER_NOT_FOUND';
  end if;

  if coalesce(public.user_business_role(v_uid, v_program.business_id), '')
       not in ('owner', 'admin', 'manager')
     and not public.user_has_business_permission(
       v_program.business_id, 'clientes.crear_editar') then
    raise exception 'LOYALTY_ADJUST_DENIED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'loyalty:' || p_customer_id::text || ':' || p_program_id::text, 0));

  select t.earned + t.adjustments - t.redeemed - t.reserved
    into v_balance
    from public.fn_loyalty_stamp_totals(p_customer_id) t
   where t.program_id = p_program_id;
  v_balance := coalesce(v_balance, 0);
  if v_balance + p_stamps < 0 then
    raise exception 'NOT_ENOUGH_STAMPS';
  end if;

  insert into public.loyalty_stamp_adjustments (
    business_id, program_id, customer_id, stamps, reason, created_by)
  values (
    v_program.business_id, p_program_id, p_customer_id, p_stamps, v_reason, v_uid);

  return jsonb_build_object(
    'program_id',    p_program_id,
    'customer_id',   p_customer_id,
    'stamps',        p_stamps,
    'balance_after', v_balance + p_stamps);
end;
$$;

grant execute on function
  public.fn_loyalty_adjust_stamps(uuid, uuid, integer, text) to authenticated;

commit;

notify pgrst, 'reload schema';
