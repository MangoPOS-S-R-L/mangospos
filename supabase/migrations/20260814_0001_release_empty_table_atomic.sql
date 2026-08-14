-- =============================================================================
-- 20260814_0001 — Liberar mesa vacía de forma ATÓMICA (órdenes huérfanas)
-- =============================================================================
--
-- EL BUG (confirmado en prod, Sophisticated Managment SRL, 2026-08-13):
--   `SalesRepository.releaseEmptyTableIfNeeded` hacía CUATRO viajes sueltos,
--   sin transacción ni lock:
--
--     1. SELECT ítems vivos de la orden          → vacío
--     2. UPDATE orders  → status_ext='void'
--     3. SELECT otras órdenes abiertas de la sesión → vacío
--     4. UPDATE table_sessions → closed_at        → la mesa desaparece
--
--   Entre el 3 y el 4 cabe un `fn_open_table` concurrente. Timeline real
--   (mesa MESA9, sesión 8a76adcc):
--
--     11:43:10.468  fn_open_table → sesión + orden 9ac906b3
--     11:43:17.822  paso 2: se anula 9ac906b3
--     11:43:17.895  nace f5ab74d7 en la MISMA sesión (73 ms después)
--     11:43:18.077  paso 4: se cierra la sesión, sin ver a f5ab74d7
--     11:43:47      entra el plato a f5ab74d7, ya sin mesa
--
--   El paso 3 no podía ver la orden nueva: en Postgres `created_at = now()`
--   es el instante de INICIO de la transacción, no el del COMMIT. La orden
--   ya "existía" a las .895 pero seguía sin committear.
--
--   Resultado: orden viva (`closed_at` NULL, ítems `pending`) colgando de una
--   sesión cerrada. No sale en el salón ni en cuentas abiertas, nadie la cobra,
--   y como su comanda SÍ se imprimió, `consume_inventory_from_order` ya
--   descontó los insumos. El mesero reteclea la orden → se descuentan OTRA VEZ.
--   Medido 2026-08-13: 98 órdenes en 20 negocios desde 2026-03-30.
--
-- EL ARREGLO: una sola transacción, tomando EL MISMO LOCK que la apertura.
--   `fn_open_table` YA se serializa por mesa, y lo hace bien — antes de leer
--   la sesión:
--
--     -- Serialize by table to avoid double-open races.
--     perform pg_advisory_xact_lock(hashtextextended(p_table_id::text, 0));
--
--   El problema nunca fue que faltara el lock: fue que la liberación no
--   participaba de él. Aquí se toma la MISMA llave (misma expresión, o son
--   dos locks distintos y no se ven entre sí — un `FOR UPDATE` sobre
--   dining_tables tampoco serviría, los row locks y los advisory locks no
--   se bloquean mutuamente). Con las dos rutas en la misma llave:
--     · si fn_open_table va primero → esperamos, y al re-chequear DESPUÉS del
--       lock vemos su orden ya committeada → no cerramos nada.
--     · si vamos primero → fn_open_table espera, y como su lock está ANTES
--       del `select` de la sesión, al continuar la ve cerrada y abre una
--       nueva. Limpio, y sin tocar fn_open_table.
--
--   CASO RESIDUAL que el lock NO cubre, y de quién es: si el mesero reentra a
--   la mesa mientras hay una liberación en vuelo, fn_open_table le devuelve la
--   MISMA orden (todavía abierta) y después la liberación la anula igual. Eso
--   no lo puede saber el servidor — sabe que la mesa se abrió, no que hay una
--   pantalla montada encima. Lo resuelve el cliente: la liberación se programa
--   con una ventana de gracia y CUALQUIER apertura la cancela
--   (SalesRepository.scheduleEmptyTableRelease / emptyTableReleaseDelay).
--   Las dos capas son complementarias; ninguna sobra.
--
-- Además arregla de paso el desfase de 4 h: la app guardaba `closed_at` con
-- `DateTime.now().toIso8601String()` (hora local marcada como UTC) y dejaba
-- sesiones cerradas ANTES de abrirse. Aquí se usa `now()` del servidor.
--
-- IDEMPOTENTE: CREATE OR REPLACE, función NUEVA. No toca datos existentes.
-- =============================================================================

begin;

CREATE OR REPLACE FUNCTION public.fn_release_empty_table(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_session_id     uuid;
  v_table_id       uuid;
  v_business_id    uuid;
  v_live_items     integer;
  v_other_orders   integer;
  v_closed_session boolean := false;
BEGIN
  IF p_order_id IS NULL THEN
    RETURN jsonb_build_object('released', false, 'reason', 'null_order');
  END IF;

  SELECT o.session_id,
         ts.table_id,
         coalesce(ts.business_id, z.business_id)
    INTO v_session_id, v_table_id, v_business_id
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
    LEFT JOIN public.zones z ON z.id = dt.zone_id
   WHERE o.id = p_order_id;

  IF v_session_id IS NULL THEN
    RETURN jsonb_build_object('released', false, 'reason', 'order_not_found');
  END IF;

  -- Access check. El alias de columna va EXPLÍCITO: current_user_business_ids()
  -- devuelve SETOF uuid, así que un `c.business_id` sin `AS c(business_id)`
  -- lanza 42703 para el caller `authenticated` y NUNCA falla con service_role
  -- (ver project_current_user_business_ids_alias_42703).
  IF v_business_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
         FROM public.current_user_business_ids() AS c(business_id)
        WHERE c.business_id = v_business_id
     ) THEN
    RAISE EXCEPTION 'No autorizado para liberar mesas de este negocio';
  END IF;

  -- ─── EL LOCK ───────────────────────────────────────────────────────────
  -- MISMA expresión que fn_open_table ("Serialize by table to avoid
  -- double-open races"). Tiene que ser idéntica: otra llave = otro lock = no
  -- se bloquean entre sí y el arreglo no arregla nada. Es xact-scoped, así
  -- que se suelta solo al terminar esta función.
  IF v_table_id IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtextextended(v_table_id::text, 0));
  END IF;

  -- ─── RE-CHEQUEO DESPUÉS DEL LOCK ───────────────────────────────────────
  -- Aquí está toda la diferencia con la versión de la app: estas lecturas ven
  -- lo que se committeó mientras esperábamos el lock.
  SELECT count(*)
    INTO v_live_items
    FROM public.order_items oi
   WHERE oi.order_id = p_order_id
     AND oi.status IS DISTINCT FROM 'void';

  IF v_live_items > 0 THEN
    RETURN jsonb_build_object('released', false, 'reason', 'order_has_items');
  END IF;

  -- Solo se anula la orden si sigue abierta. `status` se deja como estaba a
  -- propósito: la versión anterior tampoco lo tocaba y hay consultas por todo
  -- el repo que filtran por él.
  UPDATE public.orders
     SET status_ext = 'void',
         closed_at  = now()
   WHERE id = p_order_id
     AND closed_at IS NULL;

  SELECT count(*)
    INTO v_other_orders
    FROM public.orders o
   WHERE o.session_id = v_session_id
     AND o.id <> p_order_id
     AND o.closed_at IS NULL
     AND o.status_ext NOT IN ('paid', 'void');

  IF v_other_orders = 0 THEN
    UPDATE public.table_sessions
       SET closed_at = now()
     WHERE id = v_session_id
       AND closed_at IS NULL;

    v_closed_session := true;

    IF v_table_id IS NOT NULL THEN
      UPDATE public.dining_tables
         SET state = 'available'
       WHERE id = v_table_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'released',       true,
    'closed_session', v_closed_session,
    'session_id',     v_session_id,
    'table_id',       v_table_id,
    'other_orders',   v_other_orders
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_release_empty_table(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_release_empty_table(uuid) TO authenticated;

COMMENT ON FUNCTION public.fn_release_empty_table(uuid) IS
  'Libera la mesa de una orden vacía en UNA transacción, tomando el MISMO '
  'pg_advisory_xact_lock(hashtextextended(table_id::text,0)) que fn_open_table. '
  'Sustituye a los 4 viajes sueltos de '
  'SalesRepository.releaseEmptyTableIfNeeded, que no participaban de esa '
  'serialización y dejaban órdenes huérfanas (sesión cerrada + orden viva) '
  'cuando una apertura de mesa concurrente committeaba entre el chequeo y el '
  'cierre. Si cambias la expresión del lock, cámbiala en las DOS funciones.';

commit;

-- =============================================================================
-- VERIFICACIÓN
-- =============================================================================
-- 1) La función existe y es SECURITY DEFINER. Esperado: 1 fila.
-- SELECT p.proname, p.prosecdef
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public' AND p.proname = 'fn_release_empty_table';
--
-- 2) El access check lleva alias explícito. Esperado: 0 filas.
-- SELECT 1 FROM pg_proc p
--  WHERE p.proname = 'fn_release_empty_table'
--    AND pg_get_functiondef(p.oid) LIKE '%current_user_business_ids() c%';
--
-- 2b) LO MÁS IMPORTANTE: las dos funciones toman la MISMA llave de lock.
--     Esperado: 2 filas, las dos con tiene_lock = true. Si fn_open_table
--     apareciera en false, alguien le cambió el lock y este arreglo quedó
--     desarmado sin que nada falle visiblemente.
-- SELECT p.proname,
--        pg_get_functiondef(p.oid) LIKE '%hashtextextended(%::text, 0)%' AS tiene_lock
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public'
--    AND p.proname IN ('fn_open_table', 'fn_release_empty_table');
--
-- 3) Desde la app: abrir una mesa, no cargar nada, salir. La mesa debe quedar
--    libre. Repetir entrando y saliendo rápido varias veces seguidas: NO debe
--    quedar ninguna orden huérfana (verificar con
--    scripts/diag_ordenes_huerfanas_global.sql bloque 3).
--
-- 4) Que no vuelvan a aparecer sesiones cerradas "antes de abrirse".
--    Esperado: 0 filas nuevas a partir del despliegue.
-- SELECT count(*) FROM public.table_sessions
--  WHERE closed_at < opened_at AND opened_at >= now() - interval '1 day';
-- =============================================================================
