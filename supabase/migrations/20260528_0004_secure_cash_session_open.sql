-- =============================================================================
-- 20260528_0004 — Hardening de fn_open_cash_session: fuerza user_id := auth.uid()
-- =============================================================================
--
-- PROBLEMA QUE RESUELVE
-- ─────────────────────
-- La versión previa (20260513_0014) aceptaba `p_user_id` del cliente y lo
-- insertaba directamente en `cash_register_sessions.user_id` sin validarlo
-- contra el JWT del caller. Como la función es SECURITY DEFINER, esto
-- significaba que cualquier usuario autenticado válido podía abrir una
-- sesión de caja asignada a CUALQUIER otro user_id del sistema:
--
--   - Spoofing: atacante abre cajas a nombre del dueño/admin.
--   - Cliente buggy/stale: si el Flutter pasa un userId viejo (logout
--     incompleto, JWT cacheado, multimesero sin rotación de auth), la
--     sesión queda atribuida al usuario anterior y enturbia reportes
--     contables de quién cobró qué.
--
-- FIX
-- ───
-- El RPC ahora:
--   1. Rechaza llamadas sin JWT válido (auth.uid() IS NULL).
--   2. IGNORA p_user_id del cliente — siempre usa auth.uid() para el
--      INSERT. Esto cierra el agujero de spoofing/staleness sin
--      necesidad de cambiar el cliente Flutter (sigue pudiendo pasar
--      el parámetro por compat, el server lo sobrescribe en silencio).
--   3. Si el cliente intentó pasar un user_id distinto, lo loggea como
--      WARNING via RAISE NOTICE — útil para detectar clientes con bugs
--      o intentos de abuso, sin romper el flow.
--
-- Mantiene el resto de la lógica intacta (Rule A device-bound, Rule B
-- per-user con excepción para owners, no-INSERT-de-deposit del fix
-- 20260513_0014).
--
-- SAFE DEPLOY
-- ───────────
-- Backwards-compatible con el cliente actual: el cliente sigue pasando
-- p_user_id, el server lo sobrescribe. No requiere actualización del
-- Flutter. Si en una versión futura quitamos el parámetro del cliente,
-- esta migración aún funciona porque ya lo ignora.
--
-- CASO LEGÍTIMO "ADMIN ABRE EN NOMBRE DE EMPLEADO"
-- ────────────────────────────────────────────────
-- Si en el futuro se necesita que un admin abra caja en nombre de otro
-- empleado, debe hacerse con un RPC SEPARADO (ej. fn_open_cash_session_for)
-- que registre `opened_on_behalf_of` en una columna de audit. Esta función
-- queda dedicada al caso normal "el cajero abre su propia caja".
-- =============================================================================

begin;

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
    v_existing_device_session uuid;
    v_existing_user_session uuid;
    v_existing_user_device_id text;
    v_register_business_id uuid;
    v_is_owner_of_target boolean := false;
    v_auth_uid uuid := auth.uid();
    v_effective_user_id uuid;
BEGIN
    -- ── HARDENING: identidad forzada por JWT ────────────────────────────
    -- Si el caller no tiene JWT válido, no puede abrir caja. Esto cubre
    -- llamadas anónimas o desde el service_role (que NO debe abrir caja
    -- a nombre de un usuario; eso requiere otro RPC dedicado).
    IF v_auth_uid IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'AUTH_REQUIRED',
            'error', 'Debes estar autenticado para abrir una caja.'
        );
    END IF;

    -- Si el cliente mandó un user_id distinto al del JWT, lo loggeamos
    -- y lo SOBRESCRIBIMOS con auth.uid(). No fallamos para mantener
    -- backwards-compat con el cliente que aún pasa el parámetro — el
    -- server simplemente ignora la sugerencia del cliente y usa la
    -- identidad real del JWT.
    IF p_user_id IS NOT NULL AND p_user_id <> v_auth_uid THEN
        RAISE NOTICE 'fn_open_cash_session: cliente intentó usar user_id=% pero el JWT es %; usando JWT.',
            p_user_id, v_auth_uid;
    END IF;

    v_effective_user_id := v_auth_uid;

    -- ── Validaciones de parámetros restantes ────────────────────────────
    IF p_cash_register_id IS NULL THEN
        RETURN jsonb_build_object('error', 'cash_register_id es requerido');
    END IF;

    IF p_device_id IS NULL OR btrim(p_device_id) = '' THEN
        RETURN jsonb_build_object('error', 'device_id es requerido');
    END IF;

    -- ── Rule A: per-device ──────────────────────────────────────────────
    -- Un device físico no puede tener 2 cajas abiertas al mismo tiempo.
    SELECT id
      INTO v_existing_device_session
      FROM public.cash_register_sessions
     WHERE device_id = btrim(p_device_id)
       AND status = 'open'
       AND closed_at IS NULL
     LIMIT 1;

    IF v_existing_device_session IS NOT NULL THEN
        RETURN jsonb_build_object(
            'error', 'Este dispositivo ya tiene una caja abierta',
            'session_id', v_existing_device_session
        );
    END IF;

    -- ── Rule B: per-user (excepción para owners multi-sucursal) ─────────
    SELECT cr.business_id
      INTO v_register_business_id
      FROM public.cash_registers cr
     WHERE cr.id = p_cash_register_id
     LIMIT 1;

    IF v_register_business_id IS NOT NULL THEN
        v_is_owner_of_target :=
          public.user_business_role(v_effective_user_id, v_register_business_id) = 'owner';
    END IF;

    IF NOT v_is_owner_of_target THEN
        SELECT id, device_id
          INTO v_existing_user_session, v_existing_user_device_id
          FROM public.cash_register_sessions
         WHERE user_id = v_effective_user_id
           AND status = 'open'
           AND closed_at IS NULL
         LIMIT 1;

        IF v_existing_user_session IS NOT NULL THEN
            RETURN jsonb_build_object(
                'error', 'Ya tienes una caja abierta en otro dispositivo',
                'session_id', v_existing_user_session,
                'device_id', v_existing_user_device_id
            );
        END IF;
    END IF;

    -- ── INSERT — la fuente de verdad es v_effective_user_id (= auth.uid())
    -- NO usamos p_user_id en ningún punto del INSERT. Esto cierra el
    -- agujero de spoofing por mucho que el cliente intente forzarlo.
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
        btrim(p_device_id),
        NULLIF(btrim(p_device_name), '')
    )
    RETURNING id INTO v_session_id;

    RETURN jsonb_build_object('success', true, 'session_id', v_session_id);
END;
$$;

comment on function public.fn_open_cash_session(uuid, uuid, numeric, text, text) is
  'Abre una sesión de caja asignada al dueño del JWT (auth.uid()). El '
  'parámetro p_user_id existe por backwards-compat pero el server lo '
  'IGNORA y siempre usa auth.uid() — evita spoofing y staleness del '
  'cliente. Para que un admin abra caja en nombre de otro empleado se '
  'requiere un RPC distinto con audit explícito (no esta función).';

commit;
