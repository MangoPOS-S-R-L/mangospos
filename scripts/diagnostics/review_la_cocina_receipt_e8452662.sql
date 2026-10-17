-- SOLO LECTURA: diferencia entre factura y reimpresión de las fotos del 16/10.
-- Orden E8452662, NCF B0200000248. No corrige documentos ni pagos históricos.
-- Los papeles muestran subtotal 5,312.50 + ITBIS 956.25 + Ley 531.25 = 6,800;
-- reimpresión y pago registrado muestran 6,900. Revisar cada fuente por separado.
with target as (
  select o.*
    from public.orders o
   where o.id::text ilike 'e8452662%'
), docs as (
  select f.*
    from public.fiscal_documents f
    join target o on o.id = f.order_id
), rows as (
  select 1 as position, 'ORDEN' as source, o.id::text as id,
         jsonb_build_object(
           'estado', o.status, 'subtotal', o.subtotal, 'impuestos', o.tax,
           'servicio', o.service_fee, 'descuento', o.discounts, 'total', o.total,
           'delivery', to_jsonb(o) -> 'delivery_fee'
         ) as detail
    from target o
  union all
  select 2, 'COMPROBANTE', f.id::text,
         jsonb_build_object(
           'ncf', f.ncf_number, 'estado', f.status,
           'subtotal', f.subtotal, 'itbis', f.itbis_amount,
           'ley', f.service_fee, 'total', f.total,
           'delivery', to_jsonb(f) -> 'delivery_fee',
           'componentes_antes_de_descuento',
             f.subtotal + f.itbis_amount + coalesce(f.service_fee, 0)
             + coalesce((to_jsonb(f) ->> 'delivery_fee')::numeric, 0)
         )
    from docs f
  union all
  select 3, 'PRODUCTO', i.id::text,
         jsonb_build_object(
           'nombre', i.product_name, 'estado', i.status, 'cantidad', i.qty,
           'unitario', i.unit_price, 'subtotal', i.subtotal,
           'descuento', i.discounts, 'impuestos', i.tax, 'total', i.total,
           'modo_impuesto', i.tax_mode, 'tasa', i.tax_rate,
           'cuenta', i.check_id
         )
    from public.order_items i
    join target o on o.id = i.order_id
  union all
  select 4, 'PAGO', p.id::text,
         jsonb_build_object(
           'estado', p.status, 'monto', p.amount, 'cambio', p.change_amount,
           'neto', p.amount - coalesce(p.change_amount, 0),
           'metodo', p.payment_method_id, 'comprobante', p.fiscal_document_id,
           'cuenta', p.check_id, 'fecha', p.created_at
         )
    from public.payments p
    join target o on o.id = p.order_id
)
select source, id, detail from rows order by position, id;
