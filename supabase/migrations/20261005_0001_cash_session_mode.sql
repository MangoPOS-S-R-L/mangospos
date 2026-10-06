-- =============================================================================
-- 20261005_0001 — Modo de caja del negocio ("1 sola caja" / multi caja)
--                 + dueño/admin con una caja por sucursal
-- =============================================================================
--
-- PROBLEMA
-- ────────
-- Desde que dos cajeros pueden abrir caja a la vez (20260401_0001/0002 en la
-- BD, la app lo empezó a permitir el 2026-09-06), un negocio con una sola
-- gaveta podía terminar con dos cajas abiertas en paralelo, cada una con su
-- arqueo. Además, el mismo usuario que cambiaba de PC veía "no tienes caja" y
-- al abrir recibía "ya tienes una caja abierta" (la app buscaba su caja solo
-- en la registradora del equipo; eso se corrige en la app).
--
-- Y el dueño multisucursal NUNCA pudo tener caja en dos sucursales:
-- 20260509_0002 lo eximió de "una caja por usuario" en la función, pero el
-- índice único `uq_cash_register_sessions_open_per_user` (20260401_0002) es
-- GLOBAL y lo rechazaba con un 23505 crudo.
--
-- REGLAS QUE QUEDAN
-- ─────────────────
-- 0. Modo del negocio (`business_settings.cash_session_mode`):
--    - 'single' (default): una sola caja abierta en el negocio. Si ya hay
--      una, NO se abre otra: se devuelve la existente
--      (BUSINESS_CASH_ALREADY_OPEN + session_id) y la app la adopta. Aplica
--      a todos, también al dueño.
--    - 'multi': cada cajero abre la suya.
--    DECISIÓN DEL DUEÑO (2026-10-05): TODOS los negocios existentes quedan en
--    'single'; quien necesite cajas en paralelo lo cambia en
--    Ajustes → Cajas → Modo de caja.
-- A. Una caja por equipo.
-- B. Una caja por usuario.
--    Para cajero/mesero/supervisor A y B son GLOBALES (como hasta hoy).
--    Para DUEÑO y ADMIN del negocio destino son POR NEGOCIO (pedido del dueño
--    2026-10-05): pueden abrir desde cualquier equipo y tener una caja en
--    cada sucursal, incluso desde el mismo equipo. Dentro de una misma
--    sucursal siguen teniendo una sola (si ya la tienen, se adopta).
--
-- QUÉ MÁS CAMBIA
-- ──────────────
-- - Los índices únicos globales por usuario y por equipo pasan a ser por
--   REGISTRADORA (respaldo contra duplicados en la misma caja). Las reglas
--   por negocio / globales las hace cumplir la función, serializada con
--   advisory locks (negocio → usuario → equipo, siempre en ese orden para no
--   provocar deadlocks).
-- - Todos los rechazos llevan error_code, session_id y business_id de la
--   caja que los causó: la app la adopta si es de este negocio y, si es de
--   otro, dice dónde está en vez de "ya hay una caja abierta".
-- - Registradora inexistente → REGISTER_NOT_FOUND (antes reventaba por FK).
--
-- SIN CAMBIOS: identidad forzada por auth.uid() (20260528_0004); no se
-- inserta depósito de apertura (20260513_0014).
--
-- RIESGO CONOCIDO: la sobrecarga vieja de 3 args (20260401_0001) sigue viva,
-- no aplica el modo ni la regla por equipo, y sin el índice global ya no
-- tiene respaldo para "una caja por usuario" entre registradoras distintas.
-- La app actual no la usa (memoria project_two_simultaneous_cash_sessions).
--
-- ANTES DE APLICAR: confirmar que la definición VIVA es la de
-- 20260528_0004 (bloque de verificación al final del archivo).
-- =============================================================================

begin;

-- ── 1. Ajuste del negocio ───────────────────────────────────────────────
alter table public.business_settings
  add column if not exists cash_session_mode text not null default 'single';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'business_settings_cash_session_mode_check'
      and conrelid = 'public.business_settings'::regclass
  ) then
    alter table public.business_settings
      add constraint business_settings_cash_session_mode_check
      check (cash_session_mode in ('single', 'multi'));
  end if;
end$$;

comment on column public.business_settings.cash_session_mode is
  'Modo de caja del negocio. single (default) = una sola caja abierta para '
  'todo el negocio; cualquier usuario, en cualquier equipo, trabaja con ella '
  'hasta que se cierre. multi = cada cajero abre la suya, con su propio arqueo '
  'y cierre. Lo aplica fn_open_cash_session. Negocio sin fila = single.';

-- ── 2. Índices: de globales a por registradora ──────────────────────────
drop index if exists public.uq_cash_register_sessions_open_per_user;
drop index if exists public.uq_cash_register_sessions_open_per_device;

create unique index if not exists uq_cash_register_sessions_open_per_user_register
  on public.cash_register_sessions (user_id, cash_register_id)
  where status = 'open' and closed_at is null;

create unique index if not exists uq_cash_register_sessions_open_per_device_register
  on public.cash_register_sessions (device_id, cash_register_id)
  where status = 'open' and closed_at is null and device_id is not null;

-- ── 3. Apertura ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_open_cash_session(
  p_cash_register_id uuid,
  p_user_id uuid,
  p_start_amount numeric,
  p_device_id text,
  p_device_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_session_id uuid;
    v_auth_uid uuid := auth.uid();
    v_effective_user_id uuid;
    v_device_id text;
    v_register_business_id uuid;
    v_mode text;
    v_is_admin boolean := false;
    v_existing_session uuid;
    v_existing_user uuid;
    v_existing_device_id text;
    v_existing_business uuid;
BEGIN
    -- ── Identidad forzada por JWT (20260528_0004) ───────────────────────
    IF v_auth_uid IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'AUTH_REQUIRED',
            'error', 'Debes estar autenticado para abrir una caja.'
        );
    END IF;

    IF p_user_id IS NOT NULL AND p_user_id <> v_auth_uid THEN
        RAISE NOTICE 'fn_open_cash_session: cliente intentó usar user_id=% pero el JWT es %; usando JWT.',
            p_user_id, v_auth_uid;
    END IF;

    v_effective_user_id := v_auth_uid;

    IF p_cash_register_id IS NULL THEN
        RETURN jsonb_build_object('error', 'cash_register_id es requerido');
    END IF;

    IF p_device_id IS NULL OR btrim(p_device_id) = '' THEN
        RETURN jsonb_build_object('error', 'device_id es requerido');
    END IF;

    v_device_id := btrim(p_device_id);

    SELECT cr.business_id
      INTO v_register_business_id
      FROM public.cash_registers cr
     WHERE cr.id = p_cash_register_id
     LIMIT 1;

    IF v_register_business_id IS NULL THEN
        RETURN jsonb_build_object(
            'error_code', 'REGISTER_NOT_FOUND',
            'error', 'La caja registradora no existe.'
        );
    END IF;

    -- ── Serializar aperturas ────────────────────────────────────────────
    -- Negocio (regla 0 y reglas por negocio del dueño/admin), usuario y
    -- equipo (reglas globales). Siempre en este orden. Se liberan al
    -- terminar la transacción.
    PERFORM pg_advisory_xact_lock(
        hashtextextended('fn_open_cash_session:business:' || v_register_business_id::text, 0)
    );
    PERFORM pg_advisory_xact_lock(
        hashtextextended('fn_open_cash_session:user:' || v_effective_user_id::text, 0)
    );
    PERFORM pg_advisory_xact_lock(
        hashtextextended('fn_open_cash_session:device:' || v_device_id, 0)
    );

    SELECT bs.cash_session_mode
      INTO v_mode
      FROM public.business_settings bs
     WHERE bs.business_id = v_register_business_id
     LIMIT 1;

    v_mode := COALESCE(v_mode, 'single');

    -- COALESCE: con rol NULL (sin fila) la comparación da NULL, no false.
    v_is_admin := COALESCE(
        public.user_business_role(v_effective_user_id, v_register_business_id)
            IN ('owner', 'admin'),
        false
    );

    -- ── Regla 0: "1 sola caja" ──────────────────────────────────────────
    -- No es un error para el cajero: la app adopta la caja devuelta.
    IF v_mode = 'single' THEN
        SELECT s.id, s.user_id
          INTO v_existing_session, v_existing_user
          FROM public.cash_register_sessions s
          JOIN public.cash_registers cr ON cr.id = s.cash_register_id
         WHERE cr.business_id = v_register_business_id
           AND s.status = 'open'
           AND s.closed_at IS NULL
         ORDER BY s.created_at DESC
         LIMIT 1;

        IF v_existing_session IS NOT NULL THEN
            RETURN jsonb_build_object(
                'error_code', 'BUSINESS_CASH_ALREADY_OPEN',
                'error', 'Este negocio trabaja con una sola caja y ya hay una abierta.',
                'session_id', v_existing_session,
                'user_id', v_existing_user,
                'business_id', v_register_business_id
            );
        END IF;
    END IF;

    -- ── Regla A: una caja por equipo (por negocio para dueño/admin) ─────
    SELECT s.id, cr.business_id
      INTO v_existing_session, v_existing_business
      FROM public.cash_register_sessions s
      LEFT JOIN public.cash_registers cr ON cr.id = s.cash_register_id
     WHERE s.device_id = v_device_id
       AND s.status = 'open'
       AND s.closed_at IS NULL
       AND (NOT v_is_admin OR cr.business_id = v_register_business_id)
     ORDER BY (cr.business_id = v_register_business_id) DESC NULLS LAST
     LIMIT 1;

    IF v_existing_session IS NOT NULL THEN
        RETURN jsonb_build_object(
            'error_code', 'DEVICE_ALREADY_OPEN',
            'error', 'Este dispositivo ya tiene una caja abierta',
            'session_id', v_existing_session,
            'business_id', v_existing_business
        );
    END IF;

    -- ── Regla B: una caja por usuario (por negocio para dueño/admin) ────
    SELECT s.id, s.device_id, cr.business_id
      INTO v_existing_session, v_existing_device_id, v_existing_business
      FROM public.cash_register_sessions s
      LEFT JOIN public.cash_registers cr ON cr.id = s.cash_register_id
     WHERE s.user_id = v_effective_user_id
       AND s.status = 'open'
       AND s.closed_at IS NULL
       AND (NOT v_is_admin OR cr.business_id = v_register_business_id)
     ORDER BY (cr.business_id = v_register_business_id) DESC NULLS LAST
     LIMIT 1;

    IF v_existing_session IS NOT NULL THEN
        RETURN jsonb_build_object(
            'error_code', 'USER_ALREADY_OPEN',
            'error', 'Ya tienes una caja abierta en otro dispositivo',
            'session_id', v_existing_session,
            'device_id', v_existing_device_id,
            'business_id', v_existing_business
        );
    END IF;

    -- ── INSERT — la fuente de verdad es auth.uid() ──────────────────────
    BEGIN
        INSERT INTO public.cash_register_sessions (
            cash_register_id,
            user_id,
            start_amount,
            status,
            device_id,
            device_name
        )
        VALUES (
            p_cash_register_id,
            v_effective_user_id,
            p_start_amount,
            'open',
            v_device_id,
            NULLIF(btrim(p_device_name), '')
        )
        RETURNING id INTO v_session_id;
    EXCEPTION WHEN unique_violation THEN
        -- Respaldo: los índices por registradora. Con las reglas de arriba
        -- serializadas no debería pasar; si pasa (p. ej. la sobrecarga de 3
        -- args abrió en paralelo), se devuelve la caja que choca en vez de
        -- un 23505 crudo.
        SELECT s.id, s.device_id
          INTO v_existing_session, v_existing_device_id
          FROM public.cash_register_sessions s
         WHERE s.cash_register_id = p_cash_register_id
           AND (s.user_id = v_effective_user_id OR s.device_id = v_device_id)
           AND s.status = 'open'
           AND s.closed_at IS NULL
         ORDER BY (s.user_id = v_effective_user_id) DESC
         LIMIT 1;

        RETURN jsonb_build_object(
            'error_code', 'USER_ALREADY_OPEN',
            'error', 'Ya tienes una caja abierta en otro dispositivo',
            'session_id', v_existing_session,
            'device_id', v_existing_device_id,
            'business_id', v_register_business_id
        );
    END;

    RETURN jsonb_build_object('success', true, 'session_id', v_session_id);
END;
$$;

comment on function public.fn_open_cash_session(uuid, uuid, numeric, text, text) is
  'Abre una sesión de caja asignada al dueño del JWT (auth.uid()); p_user_id '
  'se ignora. Respeta business_settings.cash_session_mode: en single, si el '
  'negocio ya tiene caja abierta devuelve BUSINESS_CASH_ALREADY_OPEN con esa '
  'session_id para que la app la adopte. Una caja por equipo y por usuario: '
  'globales para el personal, por negocio para dueño/admin (una por sucursal, '
  'desde cualquier equipo). Aperturas serializadas con advisory locks.';

commit;

-- =============================================================================
-- VERIFICACIÓN PREVIA (correr ANTES de aplicar, en una consulta aparte):
-- debe devolver la versión de 20260528_0004 (con AUTH_REQUIRED, Rule A,
-- Rule B con excepción de owner). Si trae algo más, NO aplicar sin fusionarlo.
--
--   select pg_get_functiondef(
--     'public.fn_open_cash_session(uuid, uuid, numeric, text, text)'::regprocedure
--   );
-- =============================================================================
