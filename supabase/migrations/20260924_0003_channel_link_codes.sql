-- =============================================================================
-- Autoservicio: conectar un canal de pedidos (Pincer) desde la POS
--
-- Ver docs/PRD_INTEGRACION_PINCER.md §11 (F2).
--
-- EL PROBLEMA
--   Hoy la credencial se emite corriendo `fn_provision_external_channel` contra
--   la base, y las claves se le pasan al canal por mensaje. Para el piloto
--   alcanza; para el quinto restaurante no: cada alta cuesta SSH, SQL y un
--   secreto viajando por un chat.
--
-- EL MODELO: CODIGO DE VINCULACION
--   El dueño entra a Ajustes → Integraciones, toca Conectar, y la POS le muestra
--   un código corto tipo `TROP-4K7X`. Se lo dicta al canal por teléfono o se lo
--   manda por donde sea: NO es un secreto peligroso, porque vence en 15 minutos
--   y solo sirve una vez.
--
--   El canal lo canjea contra nuestro endpoint y recibe la API key y el secreto
--   SERVIDOR A SERVIDOR. Las llaves nunca pasan por el chat, ni por el dueño,
--   ni por nosotros.
--
--   Es el mismo patrón de "vincular dispositivo" que usan las TV y las consolas,
--   y resuelve lo mismo: pasar una credencial larga por un canal inseguro.
--
-- ALFABETO DEL CODIGO
--   Sin 0/O/1/I/L: el código se dicta por teléfono y esas cuatro son las que
--   siempre se confunden. Quedan 32 símbolos; 8 posiciones son 10^12
--   combinaciones para una ventana de 15 minutos.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Los códigos
-- ---------------------------------------------------------------------------
create table if not exists public.external_channel_link_codes (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  channel      text not null check (channel in ('pincer', 'uber_eats', 'pedidos_ya')),
  code         text not null unique,
  environment  text not null default 'production'
                 check (environment in ('sandbox', 'production')),
  created_by   uuid,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  redeemed_at  timestamptz,
  attempts     int not null default 0
);

comment on table public.external_channel_link_codes is
  'Códigos de un solo uso para que un canal externo canjee su credencial sin '
  'que la API key viaje por un chat. Vencen en 15 minutos.';

create index if not exists idx_channel_link_codes_open
  on public.external_channel_link_codes (business_id, channel)
  where redeemed_at is null;

alter table public.external_channel_link_codes enable row level security;

-- El dueño ve los códigos de SU negocio (para mostrarlos en pantalla mientras
-- están vivos). Emitirlos y canjearlos pasa por los RPC de abajo.
drop policy if exists channel_link_codes_select on public.external_channel_link_codes;
create policy channel_link_codes_select on public.external_channel_link_codes
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

grant select on public.external_channel_link_codes to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Generar un código (lo llama la POS)
-- ---------------------------------------------------------------------------
create or replace function public.fn_create_channel_link_code(
  p_business_id uuid,
  p_channel     text default 'pincer',
  p_environment text default 'production'
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_user_id uuid := auth.uid();
  v_rol     text;
  v_alfabeto constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_code    text := '';
  v_i       int;
  v_id      uuid;
  v_expira  timestamptz := now() + interval '15 minutes';
begin
  if v_user_id is null then
    raise exception 'LINK_NO_AUTH: hay que iniciar sesión' using errcode = 'P0001';
  end if;

  -- Conectar un canal es dar de alta un acceso de escritura al POS: solo el
  -- dueño o un administrador. Un cajero no debería poder abrirlo.
  v_rol := public.user_business_role(v_user_id, p_business_id);
  if coalesce(v_rol, '') not in ('owner', 'admin') then
    raise exception 'LINK_NO_PERMISO: solo el propietario o un administrador puede conectar un canal'
      using errcode = 'P0001';
  end if;

  -- Un código vivo por canal: si el dueño toca Conectar dos veces, el anterior
  -- deja de servir. Que anden dos códigos buenos sueltos no le ayuda a nadie.
  update public.external_channel_link_codes
     set expires_at = now()
   where business_id = p_business_id
     and channel = p_channel
     and redeemed_at is null
     and expires_at > now();

  for v_i in 1..8 loop
    v_code := v_code || substr(
      v_alfabeto, 1 + floor(random() * length(v_alfabeto))::int, 1);
  end loop;
  -- Con guion al medio para dictarlo: ABCD-2345.
  v_code := substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4);

  insert into public.external_channel_link_codes
    (business_id, channel, code, environment, created_by, expires_at)
  values (p_business_id, p_channel, v_code, p_environment, v_user_id, v_expira)
  returning id into v_id;

  return jsonb_build_object(
    'code', v_code,
    'expires_at', v_expira,
    'channel', p_channel,
    'environment', p_environment
  );
end;
$$;

revoke all on function public.fn_create_channel_link_code(uuid, text, text) from public;
grant execute on function public.fn_create_channel_link_code(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Canjearlo (lo llama la edge function, nunca la app)
-- ---------------------------------------------------------------------------
create or replace function public.fn_redeem_channel_link_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_row public.external_channel_link_codes;
  v_cred jsonb;
begin
  select * into v_row
    from public.external_channel_link_codes
   where code = upper(btrim(coalesce(p_code, '')))
   for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'code_not_found');
  end if;

  update public.external_channel_link_codes
     set attempts = attempts + 1
   where id = v_row.id;

  if v_row.redeemed_at is not null then
    return jsonb_build_object('ok', false, 'error', 'code_already_used');
  end if;

  if v_row.expires_at <= now() then
    return jsonb_build_object('ok', false, 'error', 'code_expired');
  end if;

  -- Emite (o rota) la credencial del canal para ese negocio.
  v_cred := public.fn_provision_external_channel(
    v_row.business_id, v_row.channel, v_row.environment);

  update public.external_channel_link_codes
     set redeemed_at = now()
   where id = v_row.id;

  return jsonb_build_object(
    'ok', true,
    'business_id', v_row.business_id,
    'business_name', (select b.business_name from public.businesses b
                       where b.id = v_row.business_id),
    'channel', v_row.channel,
    'environment', v_row.environment,
    'api_key', v_cred->>'api_key',
    'hmac_secret', v_cred->>'hmac_secret'
  );
end;
$$;

revoke all on function public.fn_redeem_channel_link_code(text) from public;
grant execute on function public.fn_redeem_channel_link_code(text) to service_role;

-- ---------------------------------------------------------------------------
-- 4. Estado del canal (lo pinta la tarjeta de Ajustes)
-- ---------------------------------------------------------------------------
create or replace function public.fn_channel_link_status(
  p_business_id uuid,
  p_channel     text default 'pincer'
) returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'connected', (k.id is not null),
    'environment', k.environment,
    'key_prefix', k.key_prefix,
    'connected_at', k.created_at,
    'last_used_at', k.last_used_at,
    'orders_today', (
      select count(*) from public.external_orders eo
       where eo.business_id = p_business_id
         and eo.channel = p_channel
         and eo.created_at >= date_trunc('day', now())
    ),
    'orders_total', (
      select count(*) from public.external_orders eo
       where eo.business_id = p_business_id and eo.channel = p_channel
    ),
    'last_order_at', (
      select max(eo.created_at) from public.external_orders eo
       where eo.business_id = p_business_id and eo.channel = p_channel
    ),
    'pending_code', (
      select jsonb_build_object('code', c.code, 'expires_at', c.expires_at)
        from public.external_channel_link_codes c
       where c.business_id = p_business_id and c.channel = p_channel
         and c.redeemed_at is null and c.expires_at > now()
       order by c.created_at desc limit 1
    )
  )
  from (select 1) dummy
  left join public.external_api_keys k
    on k.business_id = p_business_id
   and k.channel = p_channel
   and k.is_active
   and k.revoked_at is null;
$$;

grant execute on function public.fn_channel_link_status(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Desconectar
-- ---------------------------------------------------------------------------
create or replace function public.fn_disconnect_channel(
  p_business_id uuid,
  p_channel     text default 'pincer'
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_rol text;
  v_n   int;
begin
  v_rol := public.user_business_role(auth.uid(), p_business_id);
  if coalesce(v_rol, '') not in ('owner', 'admin') then
    raise exception 'LINK_NO_PERMISO: solo el propietario o un administrador puede desconectar un canal'
      using errcode = 'P0001';
  end if;

  update public.external_api_keys
     set is_active = false, revoked_at = now()
   where business_id = p_business_id
     and channel = p_channel
     and is_active;
  get diagnostics v_n = row_count;

  -- Los códigos sin canjear mueren con la desconexión.
  update public.external_channel_link_codes
     set expires_at = now()
   where business_id = p_business_id and channel = p_channel
     and redeemed_at is null and expires_at > now();

  -- El método de pago NO se borra: si ya cobró pedidos, `payments` lo
  -- referencia y el histórico tiene que seguir cuadrando.
  return jsonb_build_object('revoked', v_n);
end;
$$;

revoke all on function public.fn_disconnect_channel(uuid, text) from public;
grant execute on function public.fn_disconnect_channel(uuid, text) to authenticated;

commit;
