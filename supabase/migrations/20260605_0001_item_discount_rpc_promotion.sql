-- =============================================================================
-- 20260605_0001 — fn_update_item_discount_and_notes: escribir promotion_id
-- =============================================================================
--
-- PROBLEMA QUE RESUELVE
-- ─────────────────────
-- El motor de ofertas (`_applyAutomaticPromotionsIfNeeded` en
-- lib/presentation/sales/viewmodel/sales_viewmodel.dart) aplica la promo a una
-- línea vía `fn_update_item_discount_and_notes`, pero esa RPC SOLO escribe
-- `order_items.discounts` + `order_items.notes`. La atribución de qué promo se
-- aplicó vive hoy únicamente como marcador de texto `[PROMO_AUTO:<id>]` dentro
-- de `notes` — frágil para aplicar/reportar (PRD Ofertas/Combos/Inventario, R6).
--
-- La columna estructurada `order_items.promotion_id` ya existe (migración
-- 20260604_0001). Falta que la RPC de descuento la pueble.
--
-- FIX
-- ───
-- Se reemplaza `fn_update_item_discount_and_notes(uuid, numeric, text)` por una
-- versión con un 4º parámetro OPCIONAL `p_promotion_id uuid default null` que
-- escribe `order_items.promotion_id`. Como es un único parámetro con default:
--   - Callers que pasan 3 args (cortesía, descuento manual, clientes viejos)
--     siguen funcionando: `promotion_id` queda en NULL (semántica correcta —
--     esas operaciones NO son una promo, igual que hoy borran el marcador en
--     notes vía _stripManagedNotes).
--   - El motor de ofertas pasa el 4º arg con el id de la promo (o NULL al
--     limpiarla), poblando la fuente de verdad estructurada.
--
-- NOTAS DE SEGURIDAD
--   - ADITIVA en comportamiento: el set de columnas escritas solo CRECE en una
--     columna nullable; ninguna venta existente cambia de valor.
--   - Se hace DROP de la firma de 3 args para evitar AMBIGÜEDAD de overload
--     (3-arg vs 4-arg-con-default). La nueva firma cubre ambos casos de llamada.
--   - Depende de que exista `order_items.promotion_id` (20260604_0001). Aplicar
--     esa migración ANTES que esta.
-- =============================================================================

begin;

-- Evita ambigüedad de overload: la nueva firma de 4 args (con default) cubre
-- también las llamadas de 3 args.
drop function if exists public.fn_update_item_discount_and_notes(uuid, numeric, text);

create or replace function public.fn_update_item_discount_and_notes(
  p_item_id uuid,
  p_discounts numeric,
  p_notes text,
  p_promotion_id uuid default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order_id uuid;
  v_check_id uuid;
  v_discount numeric(12,2);
begin
  v_discount := round(greatest(coalesce(p_discounts, 0), 0), 2);

  update public.order_items
     set discounts = v_discount,
         notes = nullif(trim(coalesce(p_notes, '')), ''),
         promotion_id = p_promotion_id
   where id = p_item_id
   returning order_id, check_id into v_order_id, v_check_id;

  if v_order_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  perform public.calculate_order_totals(v_order_id);
  if v_check_id is not null then
    perform public.calculate_check_totals(v_check_id);
  end if;
end;
$$;

grant execute on function
  public.fn_update_item_discount_and_notes(uuid, numeric, text, uuid) to authenticated;

commit;
