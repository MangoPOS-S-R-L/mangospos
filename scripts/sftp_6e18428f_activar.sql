-- ============================================================================
-- Activar la exportación de ventas por SFTP a la plaza comercial
-- Negocio 6e18428f-fdd6-4c58-af0e-dae2403fbf1d (LA COCINA MEXICANA AUTENTICA)
-- Plaza: Ágora Santiago Center
-- ============================================================================
--
-- ✅ APLICADO EN PROD EL 2026-08-11 (pasos A1.0 + A1.1). Queda como registro
--    de lo que se hizo y para reusar el A2 al dar de alta otro local.
--    Estado tras aplicar: enabled=true, client_code='LCM00',
--    archivo del día `Ventas_11082026.txt`, last_sent_at aún null (falta el
--    primer envío real desde la app).
--
-- Correr los pasos EN ORDEN en Supabase Studio (SQL Editor).
-- El PASO A0 es SOLO LECTURA.
--
-- El 10% de ley va en scripts aparte:
--   scripts/diag_6e18428f_impuestos.sql   (diagnóstico)
--   scripts/ley10_6e18428f_aplicar.sql    (aplicar)
-- ============================================================================

-- ════════════════════════════════════════════════════════════════════════════
-- PASO A0 — Diagnóstico (SOLO LECTURA). Corre los 3 bloques y mándame la salida
--   si algo no cuadra. Aquí se decide si hay que usar el PASO A1 o el A2.
-- ════════════════════════════════════════════════════════════════════════════

-- A0.1 ¿Qué negocio es y tiene ya fila de configuración?
select
  b.id,
  b.business_name,
  c.id            as config_id,
  c.enabled,
  c.send_on_cash_close,
  c.host,
  c.port,
  c.username,
  (c.password <> '')       as tiene_password,
  c.remote_dir,
  c.client_code,
  c.file_prefix,
  c.exchange_rate,
  c.last_sent_at,
  c.last_error
from public.businesses b
left join public.business_sales_export_config c on c.business_id = b.id
where b.id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid;

-- A0.2 Todas las filas de la tabla — para copiar credenciales de otro local de
--      la misma plaza y, sobre todo, para DETECTAR COLISIÓN de archivo.
--      El archivo remoto se llama `<file_prefix>_DDMMYYYY.txt` y se SOBRESCRIBE.
--      Dos negocios con el MISMO host+usuario+remote_dir+file_prefix se pisan
--      el archivo entre ellos. El `client_code` (NUMSERIE) debe ser distinto.
select
  c.business_id,
  b.business_name,
  c.enabled,
  c.host,
  c.port,
  c.username,
  c.remote_dir,
  c.client_code,
  c.file_prefix,
  c.last_sent_at,
  left(coalesce(c.last_error, ''), 120) as last_error
from public.business_sales_export_config c
join public.businesses b on b.id = c.business_id
order by c.host, c.username, c.file_prefix;

-- A0.3 ¿Hay ventas ayer para probar el envío? (si da 0 filas, no hay qué subir)
select *
from public.fn_mall_sales_by_hour(
  '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid,
  (current_date - 1)
);


-- ════════════════════════════════════════════════════════════════════════════
-- PASO A1 — ESTE ES EL CASO (confirmado con A0.1 el 2026-08-11).
--
--   LA COCINA MEXICANA AUTENTICA ya tiene la fila completa:
--     agorasantiagocenter.serveftp.net:22 · user lacocinamx · password ✓
--     remote_dir '/' · file_prefix 'Ventas' · tasa 1
--   Lo único que falta: enabled = true y client_code (NUMSERIE), que está
--   VACÍO. Sin NUMSERIE la plaza no identifica el local — es el 2º campo de
--   cada línea del archivo, iría en blanco.
--
--   ⚠ Antes del UPDATE corre el A1.0: si el negocio de prueba "cristian"
--     (misma credencial y mismo prefijo 'Ventas') queda enabled, los dos
--     escriben el MISMO Ventas_DDMMYYYY.txt y el último sobrescribe al otro.
-- ════════════════════════════════════════════════════════════════════════════

-- A1.0 Colisión: cualquier OTRO negocio que suba al mismo archivo.
--      Debe salir 0 filas, o todas con enabled = false.
select
  c.business_id,
  b.business_name,
  c.enabled,
  c.client_code,
  c.file_prefix
from public.business_sales_export_config c
join public.businesses b on b.id = c.business_id
where c.business_id <> '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
  and lower(c.host) = 'agorasantiagocenter.serveftp.net'
  and lower(c.username) = 'lacocinamx'
  and coalesce(nullif(c.remote_dir, ''), '/') = '/'
  and c.file_prefix = 'Ventas';

-- A1.0-fix — SOLO si el A1.0 devolvió alguna fila con enabled = true.
--   Apaga a los colisionadores (el de prueba "cristian"), no al negocio real.
-- update public.business_sales_export_config c
--   set enabled = false
-- where c.business_id <> '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
--   and lower(c.host) = 'agorasantiagocenter.serveftp.net'
--   and lower(c.username) = 'lacocinamx'
--   and coalesce(nullif(c.remote_dir, ''), '/') = '/'
--   and c.file_prefix = 'Ventas'
--   and c.enabled;

-- A1.1 ACTIVAR. 'LCM00' es el NUMSERIE que se definió el 2026-07-27 —
--      si la plaza asignó otro, cámbialo aquí antes de correr.
update public.business_sales_export_config
set
  enabled            = true,
  send_on_cash_close = true,
  client_code        = 'LCM00',
  last_error         = null
where business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
returning business_id, enabled, send_on_cash_close, host, username,
          remote_dir, client_code, file_prefix;


-- ════════════════════════════════════════════════════════════════════════════
-- PASO A2 — NO HACE FALTA en este negocio (la fila ya existía completa; ver
--   PASO A1). Se deja para reusar cuando se dé de alta OTRO local de la plaza:
--   crea/completa la fila desde cero y aborta si otro negocio ya usa la misma
--   combinación host+usuario+directorio+prefijo (se pisarían el archivo).
-- ════════════════════════════════════════════════════════════════════════════

do $$
declare
  -- ▼▼▼ DATOS QUE DA LA PLAZA COMERCIAL ────────────────────────────────────
  v_host        text    := 'agorasantiagocenter.serveftp.net';
  v_port        int     := 22;
  v_username    text    := 'PONER_USUARIO';
  v_password    text    := 'PONER_PASSWORD';
  v_remote_dir  text    := '/';          -- destino (suele ser la raíz, chroot)
  v_client_code text    := 'PONER_NUMSERIE';  -- código del local, ej. LCM00
  v_file_prefix text    := 'Ventas';     -- archivo: <prefijo>_DDMMYYYY.txt
  v_rate        numeric := 1.0;          -- campo TASA (tasa cambiaria)
  -- ▲▲▲ ─────────────────────────────────────────────────────────────────────

  v_business uuid := '6e18428f-fdd6-4c58-af0e-dae2403fbf1d';
  v_clash    text;
begin
  if v_username like 'PONER_%' or v_password like 'PONER_%'
     or v_client_code like 'PONER_%' then
    raise exception
      'Faltan datos: usuario, password y código de cliente (NUMSERIE) son '
      'obligatorios. Pídelos a la plaza y edita el bloque de arriba.';
  end if;

  -- Guarda: colisión de archivo con otro negocio.
  select string_agg(b.business_name, ', ')
    into v_clash
  from public.business_sales_export_config c
  join public.businesses b on b.id = c.business_id
  where c.business_id <> v_business
    and lower(c.host)      = lower(v_host)
    and lower(c.username)  = lower(v_username)
    and coalesce(nullif(c.remote_dir, ''), '/') = coalesce(nullif(v_remote_dir, ''), '/')
    and c.file_prefix      = v_file_prefix;

  if v_clash is not null then
    raise exception
      'ABORTADO: % ya sube a %@% en % con el prefijo "%". El archivo del día '
      'se sobrescribe completo, así que ambos negocios se pisarían. Usa otro '
      'file_prefix (o apaga el otro negocio) antes de continuar.',
      v_clash, v_username, v_host, v_remote_dir, v_file_prefix;
  end if;

  insert into public.business_sales_export_config as c (
    business_id, enabled, send_on_cash_close, host, port, username, password,
    remote_dir, client_code, file_prefix, exchange_rate
  ) values (
    v_business, true, true, v_host, v_port, v_username, v_password,
    v_remote_dir, v_client_code, v_file_prefix, v_rate
  )
  on conflict (business_id) do update set
    enabled            = true,
    send_on_cash_close = true,
    host               = excluded.host,
    port               = excluded.port,
    username           = excluded.username,
    password           = excluded.password,
    remote_dir         = excluded.remote_dir,
    client_code        = excluded.client_code,
    file_prefix        = excluded.file_prefix,
    exchange_rate      = excluded.exchange_rate;

  raise notice 'OK — SFTP activado. Sube %_DDMMYYYY.txt a %@%:% (dir %) con NUMSERIE %.',
               v_file_prefix, v_username, v_host, v_port, v_remote_dir, v_client_code;
end $$;


-- ════════════════════════════════════════════════════════════════════════════
-- PASO A3 — Verificación (solo lectura). Después, en la APP:
--   Configuración → Modo de cierre de caja → "Reporte a plaza comercial"
--   → "Probar conexión" y luego "Enviar hoy". El envío automático ocurre al
--   cerrar caja. Ojo: no funciona en Web (usa sockets crudos).
-- ════════════════════════════════════════════════════════════════════════════

select
  b.business_name,
  c.enabled,
  c.send_on_cash_close,
  c.host, c.port, c.username, c.remote_dir, c.client_code, c.file_prefix,
  c.file_prefix || '_' || to_char(current_date, 'DDMMYYYY') || '.txt'
    as archivo_de_hoy,
  c.last_sent_at,
  c.last_error
from public.business_sales_export_config c
join public.businesses b on b.id = c.business_id
where c.business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid;


