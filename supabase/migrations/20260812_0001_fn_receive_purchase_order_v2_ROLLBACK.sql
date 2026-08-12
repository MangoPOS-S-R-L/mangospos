-- Rollback de 20260812_0001_fn_receive_purchase_order_v2.sql
-- Solo elimina la función nueva; las tablas de recepción (20260811_0002) y
-- las RPCs v1/parcial no se tocan.

begin;

drop function if exists public.fn_receive_purchase_order_v2(
  uuid, jsonb, text, uuid, uuid, jsonb, text, text
);

commit;
