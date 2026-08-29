-- =============================================================================
-- Habilitar Realtime para `memberships`.
--
-- PROBLEMA (verificado contra producción el 2026-08-29):
--   La pantalla Ajustes → Suscripción y pagos abre dos canales Realtime:
--   `memberships` (estado de billing) y `azul_payment_methods` (tarjeta).
--   Ninguna de las dos tablas está en la publication `supabase_realtime`, así
--   que el servidor responde al join:
--
--     {:error, "Unable to subscribe to changes with given parameters.
--      Please check Realtime is enabled ... table: memberships"}
--
--   El cliente Dart convierte eso en `channelError`, y el cliente de Supabase
--   mete un ERROR dentro del stream de `.stream()`. El repo de billing hacía
--   `await for` sobre ese stream, así que el error mataba el generador: la
--   pantalla quedaba trabada y el canal reintentaba en bucle (parpadeo).
--   El lado app ya quedó blindado; esta migración devuelve el tiempo real.
--
--   Mismo canal muerto sufría `AccountAccessRepository`, que escucha
--   `memberships` para enterarse al instante de una suspensión por falta de
--   pago: hoy solo se entera en el siguiente poll (hasta 30 min después).
--
-- POR QUÉ SOLO `memberships`:
--   `azul_payment_methods` NO se agrega a propósito. `authenticated` tiene
--   SELECT sobre la tabla base (lo necesita la vista con security_invoker),
--   y Realtime entrega la FILA COMPLETA a quien pase RLS — incluido
--   `data_vault_token`. Publicarla mandaría el token de la tarjeta a cada
--   dispositivo del negocio. La app cae a un poll de 45 s para ese caso.
--
-- SIN REPLICA IDENTITY FULL: los consumidores solo necesitan saber "algo
-- cambió, vuelve a leer" (releen con su propio SELECT), y `memberships` se
-- filtra por business_id en INSERT/UPDATE, que ya viajan completos. Evitamos
-- inflar el WAL sin necesidad.
--
-- IDEMPOTENTE: se omite si la tabla ya está en la publication.
-- =============================================================================

begin;

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    raise notice 'No existe la publication supabase_realtime; nada que hacer.';
    return;
  end if;

  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'memberships'
  ) then
    execute 'alter publication supabase_realtime add table public.memberships';
    raise notice 'memberships agregada a supabase_realtime.';
  else
    raise notice 'memberships ya estaba en supabase_realtime.';
  end if;
end $$;

commit;

-- Verificación:
--   select tablename from pg_publication_tables
--   where pubname = 'supabase_realtime' and schemaname = 'public'
--   order by tablename;
