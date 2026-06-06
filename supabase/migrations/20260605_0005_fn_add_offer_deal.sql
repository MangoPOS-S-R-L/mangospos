-- =============================================================================
-- 20260605_0005 — fn_add_offer_deal: oferta como UNA línea con descuento visible
-- =============================================================================
--
-- OBJETIVO
-- ────────
-- Tocar el tile de una oferta agrega UNA sola línea (cantidad N) a PRECIO
-- ORIGINAL con el descuento del deal en el campo `discounts`, en UN viaje. Así:
--   - 1 sola línea (no se separan).
--   - El descuento se ve ABAJO en los totales (línea "Descuento").
--   - Sin nota.
--
-- POR QUÉ AHORA SÍ CUADRA (antes daba 710):
--   Los totales mostrados/cobrados los calcula el cliente con
--   `summarizeOrderPricing`, que computa los impuestos sobre (subtotal -
--   descuento) por línea. Por eso 1 línea qty N con `discounts` da el total
--   correcto (ej. 4x3 de 250 → Subtotal 1000, Descuento 250, Total 960). El
--   error previo (710) venía de una versión vieja de esta RPC.
--
-- La línea lleva `[DEAL:<promo>]` en notes (oculto) para que el motor de
-- auto-ofertas la IGNORE, y promotion_id para el reporte.
-- =============================================================================

begin;

drop function if exists public.fn_add_offer_deal(uuid, uuid, numeric, numeric, uuid, integer);
drop function if exists public.fn_add_offer_deal(uuid, uuid, integer, integer);
drop function if exists public.fn_add_offer_deal(uuid, uuid, numeric, numeric, text, uuid, integer);
drop function if exists public.fn_add_offer_deal(uuid, uuid, integer, integer, numeric, uuid, integer);
drop function if exists public.fn_add_offer_deal(uuid, uuid, numeric, numeric, text, text, uuid, integer);

create or replace function public.fn_add_offer_deal(
  p_order_id uuid,
  p_menu_item_id uuid,
  p_qty numeric default 1,
  p_discount numeric default 0,   -- descuento total del deal (ej. 250 para 4x3)
  p_name text default null,       -- etiqueta de la línea (ej. "4x3 Presidente")
  p_promotion_id uuid default null,
  p_check_position integer default 1
) returns uuid
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_name text;
  v_price numeric(12,2);
  v_tax_mode text;
  v_tax_rate numeric := 0;
  v_check uuid;
  v_item_id uuid;
  v_qty numeric(10,3);
  v_disc numeric(12,2);
begin
  v_qty := greatest(coalesce(p_qty, 1), 1);

  select name, price into v_name, v_price
  from public.menu_items where id = p_menu_item_id limit 1;
  if v_name is null then
    raise exception 'MENU_ITEM_NOT_FOUND';
  end if;

  v_name := coalesce(nullif(btrim(coalesce(p_name, '')), ''), v_name);
  v_disc := round(greatest(coalesce(p_discount, 0), 0), 2);

  select profile.tax_mode, profile.tax_rate into v_tax_mode, v_tax_rate
  from public.fn_resolve_order_item_tax_profile(p_menu_item_id, p_order_id) profile;

  v_check := public.fn_get_or_create_check(p_order_id, coalesce(p_check_position, 1));

  insert into public.order_items(
    order_id, check_id, product_id, product_name, qty, quantity,
    unit_price, tax_mode, tax_rate, is_takeout, notes, status,
    discounts, promotion_id
  ) values (
    p_order_id, v_check, p_menu_item_id, v_name, v_qty,
    greatest(round(v_qty), 1)::int,
    v_price, coalesce(v_tax_mode, 'exclusive'), coalesce(v_tax_rate, 0),
    false, '[DEAL:' || coalesce(p_promotion_id::text, '') || ']', 'draft',
    v_disc, p_promotion_id
  )
  returning id into v_item_id;

  perform public.fn_recalc_order_totals(p_order_id);
  return v_item_id;
end;
$$;

grant execute on function
  public.fn_add_offer_deal(uuid, uuid, numeric, numeric, text, uuid, integer)
  to authenticated;

commit;
