-- =============================================================================
-- Rollback de 20260907_0005_external_orders_channel.sql
--
-- ⚠️  LEE ESTO ANTES DE CORRERLO
--
--   Este rollback sirve para deshacer una instalacion que TODAVIA NO recibio
--   pedidos. Si ya entro aunque sea una orden por el canal, NO lo corras
--   completo: borrarias el vinculo entre la orden del POS y el pedido del
--   canal, y el paso 5 va a fallar de todas formas.
--
--   Tres cosas concretas que se pueden atravesar:
--
--   a) `table_sessions` con delivery_type = 'pincer'. El paso 5 falla con
--      violacion de CHECK. Miralas antes:
--         select id, business_id, opened_at from public.table_sessions
--          where delivery_type = 'pincer';
--      Y decide: reasignarlas a 'own' o no revertir el CHECK.
--
--   b) `orders.tip` con valores distintos de 0. Al borrar la columna se pierde
--      el desglose de la propina. Los pagos NO se tocan (el monto cobrado vive
--      en payments.amount), pero el reparto entre venta y propina se pierde.
--      Revisalo antes:
--         select count(*), sum(tip) from public.orders where tip <> 0;
--
--   c) El metodo de pago creado por fn_provision_external_channel NO se borra
--      aqui: si ya cobro algo, `payments` lo referencia y el delete falla. Si
--      de verdad lo quieres fuera, desactivalo en vez de borrarlo.
--
--   El orden de abajo es el inverso de la instalacion.
-- =============================================================================

begin;

-- 1. Permiso -----------------------------------------------------------------
delete from public.user_permission_overrides o
using public.permissions p
where p.id = o.permission_id
  and p.code = 'ventas.ordenes.ver';

delete from public.role_permissions rp
using public.permissions p
where p.id = rp.permission_id
  and p.code = 'ventas.ordenes.ver';

delete from public.permissions
where code = 'ventas.ordenes.ver';

-- 2. Alta de canal -----------------------------------------------------------
drop function if exists public.fn_provision_external_channel(uuid, text, text);

-- 3. Trigger de updated_at ---------------------------------------------------
drop trigger if exists trg_external_orders_touch on public.external_orders;
drop function if exists public.tg_external_orders_touch();

-- 4. Tablas del canal --------------------------------------------------------
-- Sin dependencias entre ellas, pero se borran en orden inverso por prolijidad.
drop table if exists public.external_webhook_outbox;
drop table if exists public.external_item_map;
drop table if exists public.external_orders;
drop table if exists public.external_order_inbox;
drop table if exists public.external_api_keys;

-- 5. CHECK de delivery_type --------------------------------------------------
-- Falla si quedo alguna sesion en 'pincer' (ver nota (a) arriba).
alter table public.table_sessions
  drop constraint if exists chk_delivery_type;

alter table public.table_sessions
  add constraint chk_delivery_type
  check (delivery_type is null
         or delivery_type in ('own', 'uber_eats', 'pedidos_ya'));

-- 6. Propina -----------------------------------------------------------------
-- Comentada A PROPOSITO: borrar la columna pierde datos (ver nota (b) arriba).
-- Descomentala solo si confirmaste que no hay propinas registradas.
--
-- alter table public.orders drop column if exists tip;

commit;
