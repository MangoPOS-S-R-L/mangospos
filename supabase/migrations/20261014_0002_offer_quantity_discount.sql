-- Recalcular descuentos de paquetes al cambiar unidades, también desde Hub
-- y cola offline. Sin backfill: no modifica cuentas ni documentos existentes.
begin;
set local lock_timeout = '5s';

create or replace function public.fn_offer_quantity_discount()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_notes text;
  v_match text[];
  v_rule text[];
  v_buy integer;
  v_pay integer;
  v_discount numeric;
  v_old_qty numeric;
  v_qty numeric;
  v_promo uuid;
  v_type text;
  v_old_marker text;
begin
  -- Las líneas cobradas/anuladas no se reinterpretan al marcar un pago.
  if tg_op = 'UPDATE' and old.status::text in ('paid', 'void') then
    return new;
  end if;
  v_notes := case when tg_op = 'UPDATE' then old.notes else new.notes end;
  v_match := regexp_match(coalesce(v_notes, ''), '\[DEAL:([0-9a-fA-F-]{36})\]');
  if v_match is null then return new; end if;
  v_promo := v_match[1]::uuid;
  v_qty := coalesce(new.qty, new.quantity, 1);

  -- La regla original prevalece sobre notas copiadas de otra fila agrupada.
  v_rule := regexp_match(coalesce(v_notes, ''), '\[DEAL_RULE:([0-9]+):([0-9]+(?:\.[0-9]+)?)\]');
  if v_rule is not null then
    v_buy := v_rule[1]::integer;
    v_discount := v_rule[2]::numeric;
    if v_buy < 2 then raise exception 'INVALID_OFFER_RULE'; end if;
  else
    select coalesce(p.promo_type, p.discount_type), p.buy_quantity, p.pay_quantity
      into v_type, v_buy, v_pay from public.promotions p where p.id = v_promo;
    if not found and tg_op = 'UPDATE'
       and v_qty is distinct from coalesce(old.qty, old.quantity, 1) then
      raise exception 'OFFER_RULE_NOT_FOUND: falta la regla original de esta oferta; revisa la promoción';
    end if;
    if v_type is distinct from 'bogo' then return new; end if;
    if v_buy is null or v_buy < 2 or v_pay is null or v_pay < 1 or v_pay > v_buy then
      raise exception 'INVALID_OFFER_RULE';
    end if;
    -- Altas antiguas pueden haber consolidado varios paquetes. El descuento
    -- de la venta se conserva por paquete, sin usar el precio actual del menú.
    v_old_qty := case when tg_op = 'UPDATE'
      then coalesce(old.qty, old.quantity, 1) else v_qty end;
    if mod(v_old_qty, v_buy) = 0 and v_old_qty >= v_buy then
      v_discount := round((case when tg_op = 'UPDATE'
        then old.discounts else new.discounts end) / (v_old_qty / v_buy), 2);
    elsif tg_op = 'INSERT' then
      v_discount := round(coalesce(new.unit_price, 0) * (v_buy - v_pay), 2);
    else
      -- Una fila legacy ya fraccionada no permite reconstruir el descuento
      -- histórico con certeza. No convertir una suposición en un cobro.
      raise exception 'OFFER_RULE_SNAPSHOT_REQUIRED: esta oferta ya está fraccionada y necesita revisión';
    end if;
  end if;

  if v_qty <= 0 or v_qty <> trunc(v_qty) or v_discount is null or v_discount < 0 then
    raise exception 'INVALID_OFFER_QUANTITY';
  end if;
  v_old_marker := '[DEAL_RULE:' || v_buy || ':' || round(v_discount, 2) || ']';
  new.notes := btrim(regexp_replace(coalesce(new.notes, ''),
    '\[DEAL_RULE:[^\]]*\]', '', 'g'), E'\n ');
  -- Un modal antiguo puede omitir el marcador; no debe desactivar la oferta.
  if position('[DEAL:' in new.notes) = 0 then
    new.notes := concat_ws(E'\n', nullif(new.notes, ''), '[DEAL:' || v_promo || ']');
  end if;
  new.notes := concat_ws(E'\n', nullif(new.notes, ''), v_old_marker);

  -- No sustituye descuentos manuales/cortesías al editar notas o descuento.
  -- Cambiar unidades sí exige volver a contar paquetes, nunca prorratearlos.
  if (tg_op = 'INSERT' or v_qty is distinct from coalesce(old.qty, old.quantity, 1))
     and position('[CORTESIA:' in coalesce(new.notes, '')) = 0 then
    new.discounts := round(floor(v_qty / v_buy) * v_discount, 2);
  end if;
  return new;
end;
$$;

revoke all on function public.fn_offer_quantity_discount() from public, anon, authenticated;

-- Los BEFORE de PostgreSQL ejecutan por nombre: primero descuento, después
-- fn_compute_item_totals, sin reemplazar el motor fiscal ni las auditorías.
drop trigger if exists a00_offer_quantity_discount on public.order_items;
create trigger a00_offer_quantity_discount
before insert or update of qty, quantity, discounts, notes on public.order_items
for each row execute function public.fn_offer_quantity_discount();

do $$ begin
  if not exists (
    select 1 from pg_trigger t where t.tgrelid = 'public.order_items'::regclass
      and t.tgfoid = 'public.fn_compute_item_totals()'::regprocedure
      and not t.tgisinternal and (t.tgtype & 2) = 2
      and t.tgname > 'a00_offer_quantity_discount'
  ) then
    raise exception 'OFFER_RULE_REQUIRES_LATER_PRICING_TRIGGER';
  end if;
end $$;
notify pgrst, 'reload schema';
commit;
