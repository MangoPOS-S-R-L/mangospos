-- Evita fallos de pago cuando fiscal_settings.default_ncf_type viene NULL.
-- Además alinea la emision fiscal con un fallback seguro:
--   - E32 si el negocio usa e-CF
--   - B02 en caso contrario

create or replace function public.issue_fiscal_document(_order_id uuid, _payment_id uuid)
returns uuid
language plpgsql
security definer
as $$
declare
  o record;
  fs record;
  ncf text;
  doc_id uuid;
  v_business_id uuid;
  v_ncf_type public.ncf_type;
begin
  select * into o from public.orders where id = _order_id;

  -- 1) Preferir business_id del pago
  select p.business_id into v_business_id
  from public.payments p
  where p.id = _payment_id;

  -- 2) Fallback: resolver por sesion/mesa/zona
  if v_business_id is null then
    select z.business_id into v_business_id
    from public.table_sessions ts
    join public.dining_tables dt on dt.id = ts.table_id
    join public.zones z on z.id = dt.zone_id
    where ts.id = o.session_id;
  end if;

  if v_business_id is null then
    raise exception 'No se pudo resolver business_id para order %', _order_id;
  end if;

  select * into fs from public.fiscal_settings where business_id = v_business_id;

  v_ncf_type := coalesce(
    fs.default_ncf_type,
    case
      when coalesce(fs.ecf_enabled, false) then 'E32'::public.ncf_type
      else 'B02'::public.ncf_type
    end
  );

  ncf := public.generate_ncf(v_business_id, v_ncf_type);

  insert into public.fiscal_documents (
    business_id, order_id, payment_id,
    ncf_type, ncf_number,
    customer_name,
    subtotal, itbis_amount, total,
    is_electronic
  ) values (
    v_business_id, o.id, _payment_id,
    v_ncf_type, ncf,
    'Consumidor Final',
    o.subtotal, o.tax, o.total,
    coalesce(fs.ecf_enabled, false)
  )
  returning id into doc_id;

  return doc_id;
end;
$$;