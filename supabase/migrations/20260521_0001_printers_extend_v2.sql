-- =============================================================================
-- Fase 1 — Printing v2: extender `printers` con campos unificados de transport.
--
-- CONTEXTO:
--   La tabla `printers` ya tiene un enum `type` (network/bluetooth/usb) y
--   campos sueltos (ip, ip_address, port, mac, bluetooth_address, device_path).
--   Para Printing v2 unificamos esos campos en `connection_config` jsonb,
--   agregamos `transport` (más flexible que el enum), `purpose` (rol por
--   defecto de la impresora) y `last_error` (diagnóstico).
--
--   No se elimina ni se modifica nada existente — solo se agregan columnas
--   nuevas. Los campos viejos se mantienen y el backfill los espeja al jsonb.
--   Cuando v2 esté estable se podrán deprecar (fase futura).
--
-- COMPATIBILIDAD:
--   Backwards-compatible 100%. Código existente que lee `type`, `ip`, `port`,
--   etc. sigue funcionando. Código nuevo lee `transport` y `connection_config`.
--
-- VALORES PERMITIDOS:
--   transport: 'lan' | 'usb' | 'bluetooth' | 'serial' | 'cups'
--     - 'lan' reemplaza conceptualmente al 'network' del enum viejo.
--     - 'serial' y 'cups' son nuevos.
--   purpose:   'receipt' | 'precheck' | 'kitchen' | 'label' | 'general'
--     - 'general' = sin rol fijo, el orchestrator decide en runtime.
--
-- CONNECTION_CONFIG ejemplos:
--   LAN:    {"ip":"192.168.1.60","port":9100,"timeout_ms":3000}
--   USB:    {"vendor_id":"04b8","product_id":"0e15","interface":0}
--   BT:     {"mac":"00:11:22:33:44:55","pin":"0000","profile":"spp","channel":1}
--   Serial: {"port":"COM3","baud":9600,"parity":"none"}
--   CUPS:   {"queue_name":"Epson_TM_T20III"}
-- =============================================================================

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Nuevas columnas
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.printers
  add column if not exists transport text;

alter table public.printers
  add column if not exists purpose text not null default 'general';

alter table public.printers
  add column if not exists connection_config jsonb not null default '{}'::jsonb;

alter table public.printers
  add column if not exists last_error text;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Backfill: derivar `transport` del enum viejo `type`
-- ─────────────────────────────────────────────────────────────────────────────

update public.printers
set transport = case type::text
    when 'network'   then 'lan'
    when 'bluetooth' then 'bluetooth'
    when 'usb'       then 'usb'
    else 'lan'  -- fallback seguro
  end
where transport is null;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Backfill: poblar `connection_config` desde campos sueltos
-- ─────────────────────────────────────────────────────────────────────────────

-- LAN: usar ip_address (text) primero, fallback a ip (inet)
update public.printers
set connection_config = jsonb_strip_nulls(jsonb_build_object(
  'ip',   coalesce(ip_address, host(ip)),
  'port', coalesce(port, 9100)
))
where transport = 'lan'
  and connection_config = '{}'::jsonb
  and (ip_address is not null or ip is not null);

-- Bluetooth: usar bluetooth_address o mac
update public.printers
set connection_config = jsonb_strip_nulls(jsonb_build_object(
  'mac',     coalesce(bluetooth_address, mac),
  'profile', 'spp'
))
where transport = 'bluetooth'
  and connection_config = '{}'::jsonb
  and (bluetooth_address is not null or mac is not null);

-- USB: usar device_path
update public.printers
set connection_config = jsonb_strip_nulls(jsonb_build_object(
  'device_path', device_path
))
where transport = 'usb'
  and connection_config = '{}'::jsonb
  and device_path is not null;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Hacer NOT NULL ahora que está poblado
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.printers
  alter column transport set not null;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. CHECK constraints
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.printers
  drop constraint if exists printers_transport_check;
alter table public.printers
  add constraint printers_transport_check
  check (transport in ('lan','usb','bluetooth','serial','cups'));

alter table public.printers
  drop constraint if exists printers_purpose_check;
alter table public.printers
  add constraint printers_purpose_check
  check (purpose in ('receipt','precheck','kitchen','label','general'));

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Comentarios
-- ─────────────────────────────────────────────────────────────────────────────

comment on column public.printers.transport is
  'Tecnología de conexión a la impresora. Reemplaza conceptualmente al enum `type` (que se mantiene por compat). Valores: lan|usb|bluetooth|serial|cups.';

comment on column public.printers.purpose is
  'Rol por defecto de la impresora. Si =general, el orchestrator decide en runtime según print_area_printers (legacy) o asignación explícita. Valores: receipt|precheck|kitchen|label|general.';

comment on column public.printers.connection_config is
  'Configuración de conexión específica del transport. Reemplaza conceptualmente a ip/port/mac/device_path. El backfill espeja los valores existentes. Esquema varía por transport — ver MANUAL_TECNICO_IMPRESION.md.';

comment on column public.printers.last_error is
  'Último mensaje de error registrado al imprimir. Se actualiza desde el agent. NULL = sin errores recientes.';

commit;
