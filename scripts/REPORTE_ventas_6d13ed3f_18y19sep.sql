-- =============================================================================
-- REPORTE DE VENTAS — negocio 6d13ed3f, noches del 18 y 19 de septiembre 2026
--
-- Dos ventanas en hora RD (America/Santo_Domingo), lado a lado:
--   18→19 : 18-sep 3:00 PM  →  19-sep 8:00 AM
--   19→20 : 19-sep 3:00 PM  →  20-sep 9:00 AM
-- y una columna "ambas" con la suma.
--
-- CRITERIO: las secciones RESUMEN, MÉTODO DE PAGO, HORA, ZONA, CATEGORÍA, ÁREA
-- y PRODUCTOS salen de public.get_sales_summary_v2, la MISMA función del
-- reporte de ventas de la app: cuenta lo COBRADO dentro de la ventana
-- (payments.created_at, amount - change_amount, pagos completados). Así los
-- números pegan con lo que muestra la app para ese rango.
--
-- POR MESERO(A) es otro criterio (el del reporte "Ventas por mesero"):
-- consumo DIGITADO en la ventana (order_items.created_at), neto de descuentos,
-- atribuido a quien agregó el ítem o, si no, a quien abrió la mesa. Incluye
-- cuentas que todavía no se habían cobrado, por eso su total no es igual al
-- cobrado.
--
-- CONTROL: cobros que caen FUERA de las ventanas (antes de la 1, entre las dos
-- y después de la 2). Si alguna da un monto grande, la ventana está cortando
-- ventas de la noche y hay que mover la hora en `ventanas`.
--
-- Para cambiar las horas: editar solo el CTE `ventanas` (hora local RD).
-- Devuelve UN solo resultado (el SQL Editor muestra solo el último), en el
-- orden de la columna "#".
-- =============================================================================

with params as (
  select
    '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'::uuid as bid,
    'America/Santo_Domingo'::text               as tz
),

ventanas as (
  select v.n,
         (v.desde at time zone p.tz) as desde,
         (v.hasta at time zone p.tz) as hasta
  from params p
  cross join (values
    (1, timestamp '2026-09-18 15:00', timestamp '2026-09-19 08:00'),
    (2, timestamp '2026-09-19 15:00', timestamp '2026-09-20 09:00')
  ) v(n, desde, hasta)
),

-- Huecos que quedan fuera de las ventanas (solo para la sección CONTROL).
huecos as (
  select h.ord, h.concepto,
         (h.desde at time zone p.tz) as desde,
         (h.hasta at time zone p.tz) as hasta
  from params p
  cross join (values
    (1, 'Cobros 18-sep 8:00 AM → 3:00 PM (antes de la ventana 18→19)',
        timestamp '2026-09-18 08:00', timestamp '2026-09-18 15:00'),
    (2, 'Cobros 19-sep 8:00 AM → 3:00 PM (entre las dos ventanas)',
        timestamp '2026-09-19 08:00', timestamp '2026-09-19 15:00'),
    (3, 'Cobros 20-sep 9:00 AM → 3:00 PM (después de la ventana 19→20)',
        timestamp '2026-09-20 09:00', timestamp '2026-09-20 15:00')
  ) h(ord, concepto, desde, hasta)
),

r as (
  select v.n, public.get_sales_summary_v2(p.bid, v.desde, v.hasta) as j
  from ventanas v
  cross join params p
),

-- Consumo digitado por mesero(a) dentro de cada ventana.
mesero as (
  select v.n,
         coalesce(e.first_name || coalesce(' ' || nullif(btrim(e.last_name), ''), ''),
                  '(sin mesero atribuido)') as nombre,
         oi.subtotal + oi.tax - coalesce(oi.discounts, 0) as neto,
         coalesce(nullif(oi.qty, 0), oi.quantity, 0)        as unidades
  from ventanas v
  cross join params p
  join public.order_items oi
    on oi.business_id = p.bid
   and oi.created_at >= v.desde
   and oi.created_at <  v.hasta
  join public.orders o on o.id = oi.order_id
  left join public.table_sessions ts on ts.id = o.session_id
  left join public.employees e
    on e.id = coalesce(oi.created_by_employee_id, ts.opened_by_employee_id)
  where oi.status <> 'void'
    and o.status_ext is distinct from 'void'
),

-- Todo aplanado a: ventana, sección, concepto, monto, cantidad.
-- `sumable` = false para filas que no se pueden sumar entre ventanas.
filas as (
  select r.n, 10 as sec, '1. RESUMEN' as seccion, k.ord, k.concepto,
         k.monto, k.cant, k.sumable
  from r
  cross join lateral (values
    (1, 'Total cobrado (ventas netas) · cant = pagos',
        (r.j->>'total_sales')::numeric, (r.j->>'payments_count')::numeric, true),
    (2, 'Ticket promedio (por pago)',
        (r.j->>'avg_ticket')::numeric, null::numeric, false),
    (3, 'Artículos vendidos',
        null::numeric, (r.j->>'items_sold')::numeric, true),
    (4, 'Descuentos · cant = líneas',
        (r.j->>'discounts_total')::numeric, (r.j->>'discounted_lines_count')::numeric, true),
    (5, 'Cortesías · cant = líneas',
        (r.j->>'courtesy_total')::numeric, (r.j->>'courtesy_lines_count')::numeric, true),
    (6, 'Propina voluntaria (cobrado por encima del total de las órdenes)',
        (r.j->>'voluntary_tip')::numeric, null::numeric, true),
    (7, 'Pagos anulados (NO suman al total) · cant = pagos',
        (r.j->>'voided_sales')::numeric, (r.j->>'voided_payments_count')::numeric, true)
  ) k(ord, concepto, monto, cant, sumable)

  union all
  select r.n, 20, '2. MÉTODO DE PAGO (cant = pagos)', null, e->>'label',
         (e->>'amount')::numeric, (e->>'count')::numeric, true
  from r cross join lateral jsonb_array_elements(coalesce(r.j->'sales_by_method', '[]'::jsonb)) e

  union all
  -- Orden de la noche: de 12:00 PM en adelante, luego la madrugada.
  select r.n, 30, '3. POR HORA DE COBRO (cant = pagos)',
         ((e->>'hour')::int + 12) % 24,
         lpad(e->>'hour', 2, '0') || ':00 – ' || lpad(e->>'hour', 2, '0') || ':59',
         (e->>'amount')::numeric, (e->>'count')::numeric, true
  from r cross join lateral jsonb_array_elements(coalesce(r.j->'sales_by_hour', '[]'::jsonb)) e

  union all
  select m.n, 40, '4. POR MESERO(A) — consumo digitado, incluye cuentas sin cobrar (cant = unidades)',
         0, 'TOTAL consumo digitado', sum(m.neto), sum(m.unidades), true
  from mesero m group by m.n

  union all
  select m.n, 40, '4. POR MESERO(A) — consumo digitado, incluye cuentas sin cobrar (cant = unidades)',
         null, m.nombre, sum(m.neto), sum(m.unidades), true
  from mesero m group by m.n, m.nombre

  union all
  select r.n, 50, '5. POR ZONA (cant = órdenes)', null, e->>'label',
         (e->>'amount')::numeric, (e->>'count')::numeric, true
  from r cross join lateral jsonb_array_elements(coalesce(r.j->'sales_by_zone', '[]'::jsonb)) e

  union all
  select r.n, 60, '6. POR CATEGORÍA (cobrado repartido · cant = unidades)', null, e->>'label',
         (e->>'amount')::numeric, (e->>'quantity')::numeric, true
  from r cross join lateral jsonb_array_elements(coalesce(r.j->'sales_by_category', '[]'::jsonb)) e

  union all
  select r.n, 70, '7. POR ÁREA DE PRODUCCIÓN (cobrado repartido · cant = unidades)', null, e->>'label',
         (e->>'amount')::numeric, (e->>'quantity')::numeric, true
  from r cross join lateral jsonb_array_elements(coalesce(r.j->'sales_by_production_area', '[]'::jsonb)) e

  union all
  -- net_sales de la función = subtotal + impuesto, ANTES de descuentos
  -- (subtotal es la base pre-descuento). Categoría y área sí reparten lo cobrado.
  select r.n, 80, '8. PRODUCTOS (antes de descuentos · cant = unidades)', null,
         coalesce(e->>'product', 'Sin nombre')
           || coalesce('  [' || nullif(e->>'category', '') || ']', ''),
         (e->>'net_sales')::numeric, (e->>'quantity_sold')::numeric, true
  from r cross join lateral jsonb_array_elements(coalesce(r.j->'product_sales', '[]'::jsonb)) e

  union all
  -- n = 0: no pertenece a ninguna ventana, solo llena la columna "ambas".
  select 0, 90, '9. CONTROL — cobros FUERA de las ventanas (cant = pagos)', h.ord, h.concepto,
         coalesce(sum(pa.amount - coalesce(pa.change_amount, 0)), 0), count(pa.id), true
  from huecos h
  cross join params p
  left join public.payments pa
    on pa.business_id = p.bid
   and (pa.status = 'completed' or pa.status is null)
   and pa.created_at >= h.desde
   and pa.created_at <  h.hasta
  group by h.ord, h.concepto
),

agg as (
  select sec, seccion, concepto,
         min(ord) as ord,
         sum(monto) filter (where n = 1) as m1,
         sum(cant)  filter (where n = 1) as c1,
         sum(monto) filter (where n = 2) as m2,
         sum(cant)  filter (where n = 2) as c2,
         case when bool_and(sumable) then sum(monto) end as mt,
         case when bool_and(sumable) then sum(cant)  end as ct
  from filas
  group by sec, seccion, concepto
)

select
  row_number() over (
    order by sec, ord nulls last, coalesce(mt, m1, m2, 0) desc, concepto
  )                 as "#",
  seccion,
  concepto,
  round(m1, 2)      as "18→19 monto",
  round(c1, 2)      as "18→19 cant",
  round(m2, 2)      as "19→20 monto",
  round(c2, 2)      as "19→20 cant",
  round(mt, 2)      as "ambas monto",
  round(ct, 2)      as "ambas cant"
from agg
order by 1;
