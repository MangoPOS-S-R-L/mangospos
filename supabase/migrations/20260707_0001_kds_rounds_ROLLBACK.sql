-- ROLLBACK de 20260707_0001_kds_rounds.sql
-- Recrea las vistas SIN kitchen_sent_at y elimina la columna.
-- (Reaplica luego 20260527_0002 / 20260616_0002 si necesitas la versión previa
--  exacta; aquí se reproduce la misma def menos la columna nueva.)

begin;

create or replace view public.kds_active_items as
 SELECT oi.id, oi.order_id, "left"(oi.order_id::text, 8) AS order_number,
    oi.product_name, COALESCE(oi.quantity::numeric, oi.qty, 1::numeric) AS quantity,
    oi.notes, oi.status, oi.created_at, oi.started_at, oi.ready_at,
        CASE
            WHEN dt.id IS NOT NULL THEN COALESCE(dt.label, dt.code, 'Mesa'::text)
            WHEN ts.origin = 'manual'::order_origin THEN 'Venta manual'::text
            WHEN ts.origin = 'quick'::order_origin THEN 'Venta rapida'::text
            ELSE 'Venta'::text
        END AS table_name,
    p.full_name AS waiter_name, z.business_id, oi.print_area_code AS area_code,
    COALESCE(mods.modifiers, '[]'::json) AS modifiers, oi.is_takeout, pa.name AS area_name
   FROM order_items oi
     JOIN orders o ON o.id = oi.order_id
     JOIN table_sessions ts ON ts.id = o.session_id
     LEFT JOIN dining_tables dt ON dt.id = ts.table_id
     LEFT JOIN zones z ON z.id = dt.zone_id
     LEFT JOIN profiles p ON p.id = ts.waiter_user_id
     LEFT JOIN print_areas pa ON pa.code = oi.print_area_code AND pa.business_id = z.business_id
     LEFT JOIN LATERAL ( SELECT json_agg(json_build_object('id', m.id, 'name', m.name, 'quantity', m.qty)) AS modifiers
           FROM order_item_modifiers m WHERE m.item_id = oi.id) mods ON true
  WHERE oi.status = ANY (ARRAY['pending'::item_status, 'preparing'::item_status, 'ready'::item_status]);

create or replace view public.kds_open_orders as
 SELECT oi.id, oi.order_id, "left"(oi.order_id::text, 8) AS order_number,
    oi.product_name, COALESCE(oi.quantity::numeric, oi.qty, 1::numeric) AS quantity,
    oi.notes, oi.status, oi.created_at, oi.started_at, oi.ready_at,
        CASE
            WHEN dt.id IS NOT NULL THEN COALESCE(dt.label, dt.code, 'Mesa'::text)
            WHEN ts.origin = 'manual'::order_origin THEN 'Venta manual'::text
            WHEN ts.origin = 'quick'::order_origin THEN 'Venta rapida'::text
            ELSE 'Venta'::text
        END AS table_name,
    p.full_name AS waiter_name, o.business_id, oi.print_area_code AS area_code,
    oi.is_takeout, pa.name AS area_name
   FROM order_items oi
     JOIN orders o ON o.id = oi.order_id
     JOIN table_sessions ts ON ts.id = o.session_id
     LEFT JOIN dining_tables dt ON dt.id = ts.table_id
     LEFT JOIN profiles p ON p.id = ts.waiter_user_id
     LEFT JOIN print_areas pa ON pa.code = oi.print_area_code AND pa.business_id = o.business_id
  WHERE o.kitchen_done_at IS NULL AND o.created_at >= (now() - '2 days'::interval) AND oi.status <> 'void'::item_status;

alter table public.order_items drop column if exists kitchen_sent_at;

commit;
