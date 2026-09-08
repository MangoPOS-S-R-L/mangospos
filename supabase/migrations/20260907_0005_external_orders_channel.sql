-- =============================================================================
-- F0 — Canal de pedidos externos (Pincer, y despues Uber Eats / PedidosYa)
--
-- Ver docs/PRD_INTEGRACION_PINCER.md (R3).
--
-- QUE HACE
--   1. Agrega 'pincer' al CHECK de table_sessions.delivery_type.
--   2. orders.tip — la propina no existia en el flujo de venta (solo en
--      fiscal_documents.tip, y ahi por DIFERENCIA implicita).
--   3. Tablas del canal: credenciales, inbox, vinculo de orden, mapeo de items
--      y cola de webhooks salientes.
--   4. fn_provision_external_channel() — da de alta el canal en UN negocio
--      (metodo de pago + credencial) sin ensuciar a los demas.
--   5. Permiso ventas.ordenes.ver en el catalogo + grant a los roles de sistema.
--
-- QUE **NO** TOCA (a proposito)
--   - `calculate_order_totals`. La columna `tip` entra AQUI pero **todavia no
--     suma al total de la orden**. Sumarla es un CREATE OR REPLACE de una
--     funcion fiscal que VIVE DIVERGENTE del repo
--     ([[project_db_diverges_from_repo_migrations]]), y no se hace a ciegas.
--     Va en F1a, con el mismo cuidado que se tuvo con `delivery_fee`
--     (20260625_0001), y capturando antes el cuerpo vivo con:
--
--       SELECT pg_get_functiondef('public.calculate_order_totals(uuid)'::regprocedure);
--
--     Mientras tanto la propina se registra en `payments.amount` (total + tip),
--     que es lo que de verdad se cobro. Eso es SEGURO frente al guard de
--     cobertura de `fn_process_payment_v3`: ese guard solo bloquea SUB-cobro
--     (pagado < items); pagar de mas es la direccion segura y nunca bloquea
--     (ver 20260708_0001, nota 3).
--   - `fn_process_payment_v3`, `fn_add_item_from_menu`, `fn_open_delivery_order`
--     ni ninguna funcion fiscal.
--   - Los metodos de pago de negocios que no usen el canal.
--
-- RIESGO: bajo. Todo aditivo. El unico cambio sobre algo existente es ampliar
--   un CHECK (acepta un valor mas) y agregar dos columnas con DEFAULT.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. 'pincer' como tipo de delivery
-- ---------------------------------------------------------------------------
-- El CHECK original (20260408_0002) solo acepta own/uber_eats/pedidos_ya.
-- Ojo: re-crear el CHECK re-valida la tabla entera con ACCESS EXCLUSIVE. En
-- table_sessions eso son segundos, pero es un lock: correrlo fuera de hora pico.
alter table public.table_sessions
  drop constraint if exists chk_delivery_type;

alter table public.table_sessions
  add constraint chk_delivery_type
  check (delivery_type is null
         or delivery_type in ('own', 'uber_eats', 'pedidos_ya', 'pincer'));

-- ---------------------------------------------------------------------------
-- 2. Propina a nivel de orden
-- ---------------------------------------------------------------------------
-- Cargo EXENTO, igual que delivery_fee: no entra en la base imponible ni paga
-- ITBIS ni Ley 10%. Pincer la cobra al cliente y es del RESTAURANTE (ellos no
-- retienen comision).
alter table public.orders
  add column if not exists tip numeric(12,2) not null default 0;

comment on column public.orders.tip is
  'Propina cobrada por un canal externo (Pincer). EXENTA: fuera de la base '
  'imponible. Todavia NO suma a orders.total — ver F1a en el PRD.';

-- ---------------------------------------------------------------------------
-- 3. Credenciales por negocio y canal
-- ---------------------------------------------------------------------------
create table if not exists public.external_api_keys (
  id                 uuid primary key default gen_random_uuid(),
  business_id        uuid not null references public.businesses(id) on delete restrict,
  channel            text not null check (channel in ('pincer', 'uber_eats', 'pedidos_ya')),
  key_prefix         text not null,          -- 8 chars visibles, para reconocerla en el panel
  key_hash           text not null unique,   -- encode(sha256(clave), 'hex'); la clave se muestra UNA vez
  hmac_secret        text not null,          -- secreto de firma; distinto de la key, rotable aparte
  environment        text not null default 'sandbox'
                       check (environment in ('sandbox', 'production')),
  scopes             text[] not null default '{orders:write,orders:cancel,catalog:read}',
  rate_limit_rpm     int not null default 60 check (rate_limit_rpm > 0),
  cancel_webhook_url text,                   -- a donde avisamos si el POS anula
  is_active          boolean not null default true,
  last_used_at       timestamptz,
  created_at         timestamptz not null default now(),
  revoked_at         timestamptz,
  unique (business_id, channel, environment)
);

comment on table public.external_api_keys is
  'Credenciales de canales de pedidos externos. hmac_secret y key_hash NO se '
  'exponen a authenticated: la validacion la hace la edge function con service_role.';

-- ---------------------------------------------------------------------------
-- 4. Inbox: nada se pierde, ni lo que falla
-- ---------------------------------------------------------------------------
create table if not exists public.external_order_inbox (
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid references public.businesses(id) on delete restrict,
  channel           text not null,
  external_order_id text,
  payload           jsonb not null,
  headers           jsonb,
  signature_valid   boolean,
  http_status       int,
  processed         boolean not null default false,
  error             text,
  received_at       timestamptz not null default now()
);

comment on table public.external_order_inbox is
  'Todo lo que entra por el canal queda aqui ANTES de ingerirse, incluso si la '
  'firma es invalida o la ingesta revienta. business_id puede ser NULL: si la '
  'API key no resolvio, igual se guarda para poder depurarlo.';

-- ---------------------------------------------------------------------------
-- 5. Vinculo 1:1 pedido externo <-> orden del POS
-- ---------------------------------------------------------------------------
create table if not exists public.external_orders (
  id                 uuid primary key default gen_random_uuid(),
  business_id        uuid not null references public.businesses(id) on delete restrict,
  channel            text not null,
  external_order_id  text not null,   -- su ID interno, unico global -> IDEMPOTENCIA
  external_number    text,            -- su contador por restaurante -> es el que se IMPRIME
  order_id           uuid references public.orders(id) on delete restrict,
  session_id         uuid references public.table_sessions(id) on delete restrict,
  service_type       text check (service_type in ('delivery', 'pickup')),
  paid_externally    boolean not null default false,
  external_total     numeric(12,2),   -- lo que ellos cobraron, propina incluida
  tip_amount         numeric(12,2) not null default 0,
  payment_reference  text,
  customer_name      text,
  customer_phone     text,
  customer_rnc       text,
  delivery_address   text,
  placed_at          timestamptz,     -- cuando ORDENO el cliente
  accepted_at        timestamptz,     -- cuando la cajera ACEPTO en la tablet de Pincer
  accepted_by        text,
  cancel_state       text not null default 'none'
                       check (cancel_state in ('none', 'cancelled_by_channel', 'cancelled_by_pos')),
  cancel_reason      text,
  cancelled_by       text,            -- 'pincer:<usuario>' | 'pos:<user_id>' — anulacion con dueno
  cancel_notified_at timestamptz,
  raw_order          jsonb,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint uq_external_orders_idempotency unique (business_id, external_order_id)
);

comment on constraint uq_external_orders_idempotency
  on public.external_orders is
  'La idempotencia es COMPUESTA: el numero de orden de Pincer es un contador '
  'por restaurante y se repite entre negocios. La clave real es su ID interno.';

-- ---------------------------------------------------------------------------
-- 6. Mapeo de items — red de seguridad
-- ---------------------------------------------------------------------------
-- Pincer manda nuestro menu_items.id, asi que con ellos esta tabla queda vacia.
-- Existe para el dia que un canal mande un id propio (Uber Eats si lo hace).
create table if not exists public.external_item_map (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references public.businesses(id) on delete restrict,
  channel          text not null,
  external_item_id text not null,
  menu_item_id     uuid not null references public.menu_items(id) on delete cascade,
  created_at       timestamptz not null default now(),
  unique (business_id, channel, external_item_id)
);

-- ---------------------------------------------------------------------------
-- 7. Cola de webhooks SALIENTES (la vuelta)
-- ---------------------------------------------------------------------------
-- Si el supervisor anula en el POS, el canal tiene que enterarse o el cliente
-- se queda cobrado. Se drena con pg_net, igual que el cron de Azul.
create table if not exists public.external_webhook_outbox (
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid not null references public.businesses(id) on delete restrict,
  channel           text not null,
  event             text not null,   -- 'order.cancelled'
  external_order_id text not null,
  payload           jsonb not null,
  attempts          int not null default 0,
  next_attempt_at   timestamptz not null default now(),
  delivered_at      timestamptz,
  last_error        text,
  created_at        timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 8. Indices
-- ---------------------------------------------------------------------------
create index if not exists idx_ext_inbox_unprocessed
  on public.external_order_inbox (received_at)
  where processed = false;

create index if not exists idx_ext_orders_order
  on public.external_orders (order_id);

create index if not exists idx_ext_orders_business_created
  on public.external_orders (business_id, created_at desc);

create index if not exists idx_ext_outbox_pending
  on public.external_webhook_outbox (next_attempt_at)
  where delivered_at is null;

-- ---------------------------------------------------------------------------
-- 9. updated_at
-- ---------------------------------------------------------------------------
create or replace function public.tg_external_orders_touch()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_external_orders_touch on public.external_orders;
create trigger trg_external_orders_touch
  before update on public.external_orders
  for each row execute function public.tg_external_orders_touch();

-- ---------------------------------------------------------------------------
-- 10. RLS
-- ---------------------------------------------------------------------------
-- Patron Alanube: el inbox, la cola de salida y las credenciales son SOLO
-- service_role (sin policies para authenticated = 0 filas para la app).
-- El POS si puede LEER sus pedidos externos, que es lo que pinta la seccion
-- "Ordenes". Escribir, no: eso pasa por la edge function.
alter table public.external_api_keys       enable row level security;
alter table public.external_order_inbox    enable row level security;
alter table public.external_orders         enable row level security;
alter table public.external_item_map       enable row level security;
alter table public.external_webhook_outbox enable row level security;

drop policy if exists ext_orders_select on public.external_orders;
create policy ext_orders_select on public.external_orders
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists ext_item_map_select on public.external_item_map;
create policy ext_item_map_select on public.external_item_map
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists ext_item_map_write on public.external_item_map;
create policy ext_item_map_write on public.external_item_map
  for all to authenticated
  using (public.user_has_business_access(auth.uid(), business_id))
  with check (public.user_has_business_access(auth.uid(), business_id));

grant select on public.external_orders   to authenticated;
grant select, insert, update, delete on public.external_item_map to authenticated;

-- ---------------------------------------------------------------------------
-- 11. Alta del canal en UN negocio
-- ---------------------------------------------------------------------------
-- No sembramos el metodo de pago "Pincer" en todos los negocios: el 99% no usa
-- el canal y les apareceria un metodo de cobro que no existe para ellos.
-- Se llama una vez por restaurante que se integra. Devuelve la clave EN CLARO:
-- es la unica vez que se puede ver, despues solo queda el hash.
create or replace function public.fn_provision_external_channel(
  p_business_id uuid,
  p_channel     text default 'pincer',
  p_environment text default 'sandbox'
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_key        text;
  v_secret     text;
  v_prefix     text;
  v_label      text;
  v_method_id  uuid;
  v_key_id     uuid;
begin
  if not exists (select 1 from public.businesses where id = p_business_id) then
    raise exception 'Negocio % no existe', p_business_id using errcode = 'P0002';
  end if;

  v_label := initcap(replace(p_channel, '_', ' '));

  -- Metodo de pago del canal (payment_methods no tiene UNIQUE por code).
  select id into v_method_id
    from public.payment_methods
   where business_id = p_business_id and code = p_channel
   limit 1;

  if v_method_id is null then
    insert into public.payment_methods (business_id, name, code, position, icon)
    values (p_business_id, v_label, p_channel,
            coalesce((select max(position) + 1 from public.payment_methods
                       where business_id = p_business_id), 1),
            'smartphone')
    returning id into v_method_id;
  end if;

  -- Credencial. `gen_random_uuid` dos veces = 256 bits de entropia, suficiente
  -- y sin depender de pgcrypto.
  v_key    := 'mgp_' || left(p_environment, 4) || '_'
              || replace(gen_random_uuid()::text, '-', '')
              || replace(gen_random_uuid()::text, '-', '');
  v_secret := replace(gen_random_uuid()::text, '-', '')
              || replace(gen_random_uuid()::text, '-', '');
  v_prefix := left(v_key, 8);

  insert into public.external_api_keys
    (business_id, channel, key_prefix, key_hash, hmac_secret, environment)
  values
    (p_business_id, p_channel, v_prefix,
     encode(sha256(convert_to(v_key, 'utf8')), 'hex'), v_secret, p_environment)
  on conflict (business_id, channel, environment) do update
    set key_prefix   = excluded.key_prefix,
        key_hash     = excluded.key_hash,
        hmac_secret  = excluded.hmac_secret,
        is_active    = true,
        revoked_at   = null
  returning id into v_key_id;

  return jsonb_build_object(
    'api_key_id',        v_key_id,
    'api_key',           v_key,      -- GUARDALA: no se puede volver a ver
    'hmac_secret',       v_secret,   -- idem
    'environment',       p_environment,
    'payment_method_id', v_method_id
  );
end;
$$;

revoke all on function public.fn_provision_external_channel(uuid, text, text) from public;
grant execute on function public.fn_provision_external_channel(uuid, text, text) to service_role;

comment on function public.fn_provision_external_channel(uuid, text, text) is
  'Da de alta un canal externo en un negocio: crea el metodo de pago y emite la '
  'credencial. Devuelve la clave y el secreto EN CLARO una sola vez. Solo '
  'service_role: no se llama desde la app.';

-- ---------------------------------------------------------------------------
-- 12. Permiso de la seccion "Ordenes"
-- ---------------------------------------------------------------------------
-- Sin la fila en el catalogo, el join del RPC de permisos lo descarta EN
-- SILENCIO y el gate no pega nunca ([[project_permission_codes_missing_in_db_catalog]]).
insert into public.permissions (code, name, module, description) values
  ('ventas.ordenes.ver',
   'Ver pedidos de canales externos',
   'operations',
   'Da acceso a la seccion Ordenes en Ventas: los pedidos que entran por Pincer u otro canal externo, su estado y la reimpresion de la comanda.')
on conflict (code) do update
  set name        = excluded.name,
      module      = excluded.module,
      description = excluded.description;

insert into public.role_permissions (role_id, permission_id, allow)
select r.id, p.id, true
from public.roles r
cross join public.permissions p
where r.is_system = true
  and lower(r.name) in ('owner', 'admin', 'manager', 'cashier')
  and p.code = 'ventas.ordenes.ver'
on conflict (role_id, permission_id) do nothing;

commit;
