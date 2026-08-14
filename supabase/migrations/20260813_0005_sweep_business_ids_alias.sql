-- =============================================================================
-- 20260813_0005 — Barrido: access checks rotos por el alias de
--                 current_user_business_ids()  (42703)
-- =============================================================================
--
-- LA TRAMPA: desde 20260708_0001, `public.current_user_business_ids()` devuelve
--   **SETOF uuid**, así que su única columna se llama `current_user_business_ids`.
--   Un
--
--       SELECT 1 FROM public.current_user_business_ids() c WHERE c.business_id = ...
--
--   lanza `42703 column c.business_id does not exist` para el caller
--   `authenticated` — o sea, para la app. Con `service_role` el access check se
--   salta entero, y POR ESO probar la función a mano en el SQL Editor siempre
--   "funciona": el fallo solo existe desde el POS. Es la razón de que estos
--   bugs vivan meses sin detectarse.
--
--   Ya se corrigió puntualmente en 20260710_0001 (productos por área),
--   20260717_0001 (ventas del mall) y 20260813_0004 (dividir cuentas).
--
-- POR QUÉ NO SE REESCRIBEN LAS FUNCIONES DESDE EL REPO: esta base diverge de
--   las migraciones. Un CREATE OR REPLACE con el cuerpo del repo pisaría
--   cambios vivos que nadie registró. Esto lee la definición VIVA con
--   `pg_get_functiondef`, le cambia solo el access check, y la re-ejecuta.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- QUÉ SE REESCRIBE, COMO UNIDAD
--
--   from current_user_business_ids() <alias>  where <alias>.<col> = …
--        →
--   from current_user_business_ids() AS <alias>(business_id)  where <alias>.business_id = …
--
--   Se exige que el WHERE referencie EL MISMO alias inmediatamente después:
--   esa es la firma del access check y de nada más. No se tocan alias sueltos
--   ni se hacen reemplazos globales.
--
-- ⚠ POR QUÉ ESO IMPORTA — el intento anterior de esta migración hacía dos
--   reemplazos sueltos (el alias por un lado, `.bid` por otro) y era PELIGROSO:
--
--     · `get_products_catalog` tenía `current_user_business_ids() cub(bid)` con
--       `cub.bid`. Eso es CORRECTO —lleva alias explícito de columna, solo que
--       llamada `bid`— y el patrón lo destrozaba en `AS cu(business_id)b(bid)`,
--       porque el motor retrocedía a un prefijo del alias para satisfacer el
--       lookahead. Ahora la captura lleva `\M` (fin de palabra) y no puede
--       partir el alias por la mitad.
--
--     · Esa misma función usa el alias `c` para `categories`. Un reemplazo
--       global de `c.<algo>` habría reescrito las CTEs del catálogo entero.
--       Por eso el WHERE va DENTRO del patrón y no se toca nada fuera de él.
--
-- QUÉ NO SE TOCA, A PROPÓSITO:
--   · `current_user_business_ids() cub(bid)` — ya tiene alias de columna: es
--     válido y funciona. No es lo mismo "distinto del estándar" que "roto".
--   · `FROM current_user_business_ids() LIMIT 1` — no lleva alias.
--   · `SELECT bid … FROM current_user_business_ids() AS bid` — ahí `bid` es
--     alias de TABLA y se selecciona a pelo; otro patrón, va aparte.
--   · Texto en comentarios: el patrón exige `from` … `where` de verdad.
--
-- IDEMPOTENTE: relee y compara. Correrla dos veces no cambia nada la segunda.
--
-- ⚠ CORRER PRIMERO EL PASO 0 Y REVISAR LA LISTA.
-- =============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- PASO 0 — SIMULACRO. Solo lectura. Muestra el access check actual de cada
--          función que se tocaría Y cómo quedaría, para poder compararlos
--          lado a lado antes de aplicar nada.
-- ════════════════════════════════════════════════════════════════════════════

WITH pat AS (
  SELECT
    '(?i)(from\s+(?:public\.)?current_user_business_ids\(\))\s+(?:as\s+)?'
    '([a-z_][a-z0-9_]*)\M(?!\s*\()(\s+where\s+)\2\.[a-z_][a-z0-9_]*(\s*=)' AS re
)
SELECT
  p.proname                                 AS funcion,
  pg_get_function_identity_arguments(p.oid) AS argumentos,
  (regexp_match(pg_get_functiondef(p.oid), pat.re))[0] IS NOT NULL AS coincide,
  substring(pg_get_functiondef(p.oid) FROM pat.re)      AS antes,
  substring(
    regexp_replace(pg_get_functiondef(p.oid), pat.re,
                   '\1 AS \2(business_id)\3\2.business_id\4', 'g')
    FROM '(?i)from\s+(?:public\.)?current_user_business_ids\(\)[^\n]*'
  )                                                     AS despues
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN pat
WHERE n.nspname = 'public'
  AND p.prokind = 'f'
  AND pg_get_functiondef(p.oid) ~ pat.re
ORDER BY p.proname;


-- ════════════════════════════════════════════════════════════════════════════
-- PASO 1 — Aplicar. Cada función se re-crea con su propio cuerpo vivo y solo
--          el access check corregido. Un NOTICE por función parcheada.
-- ════════════════════════════════════════════════════════════════════════════

begin;

DO $sweep$
DECLARE
  -- El WHERE con el MISMO alias va dentro del patrón: sin eso, un reemplazo
  -- suelto puede pisar otro uso del alias en el cuerpo (ver cabecera).
  c_re CONSTANT text :=
    '(?i)(from\s+(?:public\.)?current_user_business_ids\(\))\s+(?:as\s+)?'
    '([a-z_][a-z0-9_]*)\M(?!\s*\()(\s+where\s+)\2\.[a-z_][a-z0-9_]*(\s*=)';
  r       record;
  v_def   text;
  v_new   text;
  v_fixed int := 0;
BEGIN
  FOR r IN
    SELECT p.oid,
           p.proname,
           pg_get_function_identity_arguments(p.oid) AS args
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.prokind = 'f'
       AND pg_get_functiondef(p.oid) ~ c_re
     ORDER BY p.proname
  LOOP
    v_def := pg_get_functiondef(r.oid);
    v_new := regexp_replace(v_def, c_re,
                            '\1 AS \2(business_id)\3\2.business_id\4', 'g');

    IF v_new IS DISTINCT FROM v_def THEN
      EXECUTE v_new;
      v_fixed := v_fixed + 1;
      RAISE NOTICE 'parcheada: %(%)', r.proname, r.args;
    END IF;
  END LOOP;

  RAISE NOTICE '--- funciones parcheadas: % ---', v_fixed;

  IF v_fixed = 0 THEN
    RAISE NOTICE 'Nada que hacer: ninguna función tiene el patrón roto.';
  END IF;
END
$sweep$;

commit;


-- ════════════════════════════════════════════════════════════════════════════
-- PASO 2 — Verificación.
-- ════════════════════════════════════════════════════════════════════════════

-- a) No queda ningún access check sin alias de columna. Esperado: 0 filas.
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS argumentos
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.prokind = 'f'
  AND pg_get_functiondef(p.oid) ~
      '(?i)(from\s+(?:public\.)?current_user_business_ids\(\))\s+(?:as\s+)?([a-z_][a-z0-9_]*)\M(?!\s*\()(\s+where\s+)\2\.[a-z_][a-z0-9_]*(\s*=)'
ORDER BY p.proname;

-- b) Control de daños: ninguna función debe tener un alias partido del tipo
--    `AS xx(business_id)yy(...)`. Esperado: 0 filas. Si alguna sale aquí,
--    quedó corrupta y hay que restaurarla desde su migración original.
SELECT p.proname
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.prokind = 'f'
  AND pg_get_functiondef(p.oid) ~ '\(business_id\)[a-z_]'
ORDER BY p.proname;

-- c) Todas las funciones del esquema siguen siendo compilables. Esta consulta
--    falla si alguna quedó con SQL inválido en el cuerpo.
SELECT count(*) AS funciones_ok
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prokind = 'f'
  AND pg_get_functiondef(p.oid) IS NOT NULL;


-- ════════════════════════════════════════════════════════════════════════════
-- PASO 3 — Prueba funcional desde la APP, no desde el SQL Editor.
--
-- El editor corre como service_role y se salta el access check: ahí todo
-- "funciona" incluso con el bug puesto. Hay que tocar cada flujo desde el POS
-- con un usuario normal:
--
--   · Dividir cuentas → "Aplicar división"
--   · Catálogo de productos (get_products_catalog)
--   · Cierre de caja con desglose de productos por área
--   · Reportes de ventas: resumen, por área de producción, margen
--   · Resumen fiscal · Auditoría de ventas · Exportación del mall
-- ════════════════════════════════════════════════════════════════════════════
