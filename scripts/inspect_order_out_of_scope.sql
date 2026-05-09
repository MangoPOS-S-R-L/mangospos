-- =============================================================================
-- Inspeccion ORDER_OUT_OF_SCOPE
--
-- Caso: la orden 8851543e-998b-4e2f-9269-d9914880c16b lanza la asercion de
-- _assertOrderInBusinessScope (sales_repository.dart:47-64). Esa asercion
-- hace un INNER JOIN orders -> table_sessions filtrando por
-- table_sessions.business_id = current_business. El cliente Dart pasa el
-- _activeBusinessId desde sessionProvider.
--
-- Posibles causas:
--   1. orders.session_id apunta a una sesion con business_id != current
--   2. La sesion fue cerrada/borrada y RLS la oculta
--   3. El cliente esta enviando un business_id distinto al real
--
-- Como correrlo: ejecutalo desde el SQL editor de Supabase (login con tu
-- cuenta de owner para evitar RLS) y comparte el output.
-- =============================================================================

\set order_id '8851543e-998b-4e2f-9269-d9914880c16b'

-- ── 1. Estado crudo de la orden ─────────────────────────────────────────────
SELECT
  o.id                AS order_id,
  o.session_id,
  o.status_ext,
  o.closed_at,
  o.subtotal,
  o.tax,
  o.total,
  o.created_at,
  ts.id               AS session_id_resolved,
  ts.business_id      AS session_business_id,
  ts.table_id,
  ts.opened_at,
  ts.closed_at        AS session_closed_at,
  b.name              AS business_name
FROM public.orders o
LEFT JOIN public.table_sessions ts ON ts.id = o.session_id
LEFT JOIN public.businesses b      ON b.id = ts.business_id
WHERE o.id = :'order_id'::uuid;

-- ── 2. Items de esa orden (ultima actividad) ────────────────────────────────
SELECT
  oi.id,
  oi.product_name,
  oi.unit_price,
  oi.qty,
  oi.subtotal,
  oi.tax,
  oi.total,
  oi.status,
  oi.created_at
FROM public.order_items oi
WHERE oi.order_id = :'order_id'::uuid
ORDER BY oi.created_at DESC
LIMIT 20;

-- ── 3. Modificadores recientes en items de esa orden (sabores) ──────────────
SELECT
  oim.id,
  oim.item_id,
  oim.name,
  oim.qty,
  oim.price,
  oi.product_name,
  oi.created_at AS item_created_at
FROM public.order_item_modifiers oim
JOIN public.order_items oi ON oi.id = oim.item_id
WHERE oi.order_id = :'order_id'::uuid
ORDER BY oi.created_at DESC, oim.id DESC
LIMIT 20;

-- ── 4. Negocios accesibles por el usuario logueado (lo que ve el cliente) ───
-- Esto SOLO devuelve filas si lo corres con la JWT del usuario afectado.
-- Si lo corres como service_role/owner la lista incluye todos los negocios
-- a los que TU tienes acceso, no el usuario que tuvo el error.
SELECT
  ub.business_id,
  b.name,
  e.role_id,
  r.name AS role_name
FROM public.user_businesses ub
LEFT JOIN public.businesses b ON b.id = ub.business_id
LEFT JOIN public.employees e   ON e.business_id = ub.business_id AND e.user_id = ub.user_id
LEFT JOIN public.employee_roles er ON er.employee_id = e.id
LEFT JOIN public.roles r       ON r.id = er.role_id
WHERE ub.user_id = auth.uid();

-- ── 5. Comparacion directa: business_id de la sesion vs negocios del user ───
-- Si la fila aparece, el usuario SI tiene acceso al business de la sesion.
-- Si NO aparece, el cliente Dart estaba en otro negocio cuando intento leer
-- esta orden -> ese es el ORDER_OUT_OF_SCOPE.
SELECT
  'session_business_in_user_scope' AS check_name,
  EXISTS (
    SELECT 1
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    JOIN public.user_businesses ub ON ub.business_id = ts.business_id
    WHERE o.id = :'order_id'::uuid
      AND ub.user_id = auth.uid()
  ) AS user_has_access;

-- ── 6. Historial reciente de orders en la misma sesion (por si hubo merge) ──
SELECT
  o.id,
  o.session_id,
  o.status_ext,
  o.closed_at,
  o.created_at,
  ts.business_id,
  ts.closed_at AS session_closed_at
FROM public.orders o
JOIN public.table_sessions ts ON ts.id = o.session_id
WHERE o.session_id = (
  SELECT session_id FROM public.orders WHERE id = :'order_id'::uuid
)
ORDER BY o.created_at DESC
LIMIT 10;
