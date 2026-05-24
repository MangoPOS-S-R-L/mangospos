-- 2026-05-24 — fix: fn_update_item_details no recomputaba tax al cambiar is_takeout.
--
-- Bug observado: al editar un item desde el modal de detalle y cambiar
-- "Para llevar" a ON, el item quedaba con:
--   is_takeout = true   ✓
--   tax_rate   = 10     ❌ (debería ser 0 si LEY tiene apply_on_takeout=false)
--   tax_lines  = LEY30  ❌
--
-- Causa: la función UPDATE-aba is_takeout y llamaba calculate_order_totals
-- (que solo SUMA oi.subtotal/oi.tax) pero NO disparaba el recompute del
-- tax_rate del item ni repoblaba tax_lines. Solo `fn_toggle_item_takeout`
-- hacía ese recompute, y solo se invoca desde el toggle dedicado.
--
-- Fix: tras el UPDATE, si is_takeout cambió, re-resolver tax_rate via
-- fn_resolve_order_item_tax_profile pasando el nuevo flag y repoblar
-- tax_lines. Igual patrón que migración 20260502_0002 para el toggle.

create or replace function public.fn_update_item_details(
  p_item_id uuid,
  p_product_name text,
  p_qty numeric,
  p_is_takeout boolean,
  p_discounts numeric,
  p_notes text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order_id uuid;
  v_check_id uuid;
  v_qty numeric(10,3);
  v_discount numeric(12,2);
  v_product_id uuid;
  v_prev_is_takeout boolean;
  v_new_is_takeout boolean;
  v_tax_mode text;
  v_tax_rate numeric := 0;
begin
  v_qty := round(greatest(coalesce(p_qty, 1), 0.001), 3);
  v_discount := round(greatest(coalesce(p_discounts, 0), 0), 2);
  v_new_is_takeout := coalesce(p_is_takeout, false);

  -- Leer el valor previo de is_takeout antes del UPDATE para detectar el cambio.
  select product_id, coalesce(is_takeout, false)
    into v_product_id, v_prev_is_takeout
  from public.order_items
  where id = p_item_id;

  if v_product_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  update public.order_items
     set product_name = coalesce(nullif(trim(coalesce(p_product_name, '')), ''), product_name),
         qty = v_qty,
         quantity = greatest(round(v_qty), 1),
         is_takeout = v_new_is_takeout,
         discounts = v_discount,
         notes = nullif(trim(coalesce(p_notes, '')), '')
   where id = p_item_id
   returning order_id, check_id into v_order_id, v_check_id;

  if v_order_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  -- Si is_takeout cambió, re-resolver tax_rate Y repoblar tax_lines con
  -- el filtro apply_on_takeout. Sin esto, un item editado de "para acá"
  -- a "para llevar" mantiene la LEY cobrada aunque el toggle del tax
  -- diga que no aplica para llevar.
  if v_prev_is_takeout is distinct from v_new_is_takeout then
    select profile.tax_mode, profile.tax_rate
      into v_tax_mode, v_tax_rate
    from public.fn_resolve_order_item_tax_profile(
      v_product_id, v_order_id, v_new_is_takeout
    ) profile;

    update public.order_items
       set tax_rate = coalesce(v_tax_rate, 0),
           original_tax_rate = coalesce(v_tax_rate, 0),
           tax_mode = coalesce(v_tax_mode, tax_mode)
     where id = p_item_id;

    perform public.fn_populate_item_tax_lines(p_item_id);
  end if;

  perform public.calculate_order_totals(v_order_id);
  if v_check_id is not null then
    perform public.calculate_check_totals(v_check_id);
  end if;
end;
$$;

grant execute on function public.fn_update_item_details(uuid, text, numeric, boolean, numeric, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Backfill correctivo para items ya rotos
-- ═══════════════════════════════════════════════════════════════════════════════
-- Los items existentes que se marcaron takeout vía updateItemDetails antes
-- de esta migración tienen tax_rate y tax_lines stale. Forzar recompute en
-- TODOS los items takeout de órdenes abiertas para limpiar el drift.
-- Idempotente: si el item ya está bien, el resolver devuelve el mismo
-- tax_rate y populate_tax_lines reescribe iguales.
do $$
declare
  r record;
  v_mode text;
  v_rate numeric;
begin
  for r in
    select oi.id as item_id, oi.product_id, oi.order_id, oi.is_takeout
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
     where o.closed_at is null
       and oi.is_takeout = true
       and oi.status not in ('paid', 'void')
  loop
    select profile.tax_mode, profile.tax_rate
      into v_mode, v_rate
    from public.fn_resolve_order_item_tax_profile(
      r.product_id, r.order_id, true
    ) profile;

    update public.order_items
       set tax_rate = coalesce(v_rate, 0),
           original_tax_rate = coalesce(v_rate, 0),
           tax_mode = coalesce(v_mode, tax_mode)
     where id = r.item_id;

    perform public.fn_populate_item_tax_lines(r.item_id);
  end loop;

  -- Recalcular totales de todas las órdenes abiertas afectadas.
  for r in
    select distinct oi.order_id
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
     where o.closed_at is null
  loop
    perform public.calculate_order_totals(r.order_id);
  end loop;
end$$;
