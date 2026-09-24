-- =============================================================================
-- F1b — La comanda de un pedido externo: cola de impresión con claim atómico
--
-- Ver docs/PRD_INTEGRACION_PINCER.md §9.1. Depende de 20260907_0005/0006.
--
-- EL PROBLEMA
--   Los bytes ESC/POS los arma Flutter, no el servidor (`print_jobs.data_hex`
--   llega ya renderizado). Un pedido que nace por API no tiene quién lo imprima:
--   el KDS lo ve solo, el papel no sale.
--
-- EL MODELO, COMO LO HACEN LOS AGREGADORES
--   El pedido entra y se ve en cocina AL INSTANTE (la ingesta ya deja los ítems
--   en 'pending'). La impresión es un proceso APARTE que reintenta: que falle el
--   papel nunca puede esconder el pedido. Una o más tablets del local corren un
--   worker que reclama pedidos sin imprimir y saca la comanda.
--
--   El claim es atómico (`for update skip locked`), así que con dos tablets
--   encendidas la comanda sale UNA sola vez — mismo patrón que
--   `fn_claim_print_job` para la cola de impresión normal.
--
-- POR QUÉ UN CLAIM CON VENCIMIENTO
--   Si la tablet que reclamó se queda sin batería a mitad del trabajo, el pedido
--   quedaría reclamado para siempre y nadie lo imprimiría. El claim vence a los
--   2 minutos y otra tablet lo retoma. El riesgo inverso (imprimir dos veces
--   porque la primera tardó) es preferible a no imprimir: dos comandas iguales
--   se notan, una que falta no.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Estado de impresión en el vínculo
-- ---------------------------------------------------------------------------
alter table public.external_orders
  add column if not exists printed_at        timestamptz,
  add column if not exists print_claimed_by  text,
  add column if not exists print_claimed_at  timestamptz,
  add column if not exists print_attempts    int not null default 0,
  add column if not exists print_error       text;

comment on column public.external_orders.printed_at is
  'Cuándo se ENCOLÓ la comanda en las impresoras, no cuándo salió el papel: '
  'eso depende de la red del local y se resuelve en el POS. NULL = pendiente.';

comment on column public.external_orders.print_claimed_by is
  'device_id de la tablet que lo está imprimiendo. El claim vence a los 2 min '
  'para que una tablet que se apagó a medias no deje el pedido sin comanda.';

-- Los que esperan papel. Parcial: la tabla crece con todos los pedidos, pero
-- los pendientes son siempre un puñado.
create index if not exists idx_ext_orders_pending_print
  on public.external_orders (business_id, created_at)
  where printed_at is null;

-- ---------------------------------------------------------------------------
-- 2. Reclamar pedidos para imprimir
-- ---------------------------------------------------------------------------
create or replace function public.fn_claim_external_orders_to_print(
  p_business_id uuid,
  p_device_id   text,
  p_limit       int default 5
) returns table (
  external_order_row uuid,
  order_id           uuid,
  external_number    text,
  channel            text,
  service_type       text,
  customer_name      text,
  attempts           int
)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  return query
  with candidatos as (
    select eo.id
      from public.external_orders eo
     where eo.business_id = p_business_id
       and eo.printed_at is null
       and eo.order_id is not null
       -- Los de prueba NO imprimen: no se gasta papel del local en un sandbox.
       and eo.environment = 'production'
       -- Nada viejo: si el POS estuvo caído toda la noche, al abrir no se
       -- imprime la madrugada entera de golpe.
       and eo.created_at > now() - interval '6 hours'
       -- Tope de reintentos: tras 5 fallos deja de intentar y queda visible
       -- en la pantalla de Órdenes para que alguien lo resuelva a mano.
       and eo.print_attempts < 5
       -- Libre, o con el claim de otra tablet ya vencido.
       and (eo.print_claimed_at is null
            or eo.print_claimed_at < now() - interval '2 minutes')
     order by eo.created_at
     limit greatest(coalesce(p_limit, 5), 1)
       for update skip locked
  )
  update public.external_orders eo
     set print_claimed_by = p_device_id,
         print_claimed_at = now(),
         print_attempts   = eo.print_attempts + 1
    from candidatos c
   where eo.id = c.id
  returning eo.id, eo.order_id, eo.external_number, eo.channel,
            eo.service_type, eo.customer_name, eo.print_attempts;
end;
$$;

comment on function public.fn_claim_external_orders_to_print(uuid, text, int) is
  'Reclama pedidos externos sin comanda impresa, en exclusiva para este device. '
  'Suma el intento AL RECLAMAR, no al fallar: si la tablet muere a mitad del '
  'trabajo, el contador ya subió y el pedido no se reintenta para siempre.';

-- ---------------------------------------------------------------------------
-- 3. Cerrar el intento
-- ---------------------------------------------------------------------------
create or replace function public.fn_mark_external_order_printed(
  p_external_order_row uuid,
  p_ok                 boolean,
  p_error              text default null
) returns void
language sql
security definer
set search_path to 'public'
as $$
  update public.external_orders
     set printed_at       = case when p_ok then now() else null end,
         print_error      = case when p_ok then null else left(p_error, 500) end,
         -- Liberar el claim: si falló, otra tablet puede intentarlo enseguida
         -- sin esperar los 2 minutos del vencimiento.
         print_claimed_at = case when p_ok then print_claimed_at else null end,
         print_claimed_by = case when p_ok then print_claimed_by else null end
   where id = p_external_order_row;
$$;

grant execute on function public.fn_claim_external_orders_to_print(uuid, text, int) to authenticated;
grant execute on function public.fn_mark_external_order_printed(uuid, boolean, text) to authenticated;

commit;
