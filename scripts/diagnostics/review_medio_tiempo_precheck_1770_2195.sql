-- SOLO LECTURA: Medio Tiempo Bar, precuenta 1,770 y caja 2,195 (diferencia 425).
-- No modifica ventas, pagos ni comprobantes. Ventana inicial: últimos 30 días.
-- Ejecutar cada bloque por separado. Confirmar el negocio/mesa antes de
-- interpretar una candidata; un producto repetido no prueba una duplicación.
-- precheck_printed_at conserva la marca más reciente, no el detalle histórico
-- ni necesariamente la primera precuenta. Una fecha posterior de un ítem
-- demuestra llegada posterior a esa marca, no cuándo se tocó en el teléfono.
-- created_at puede conservarse al dividir una línea o moverse entre cuentas;
-- contrastar ediciones, comandas y client_op_id antes de atribuir una causa.

-- 1. Candidatas y sus líneas, con hora local, autor, opciones e identidad.
-- Si no devuelve filas, comprobar nombre de negocio y ampliar la ventana.
with params as (
  select now() - interval '30 days' as desde,
         1770::numeric as precuenta_reportada,
         2195::numeric as caja_reportada,
         425::numeric as diferencia
), biz as (
  select b.id,
         b.business_name || coalesce(' · ' || nullif(to_jsonb(b)->>'branch_name', ''), '') as negocio
    from public.businesses b
   where b.business_name ilike '%medio%tiempo%'
      or to_jsonb(b)->>'branch_name' ilike '%medio%tiempo%'
), ventas as (
  select o.*, biz.id as business_id, biz.negocio,
         dt.code as mesa, ts.table_id,
         nullif(to_jsonb(ts)->>'precheck_printed_at', '')::timestamptz as precuenta_impresa_at,
         to_jsonb(ts)->>'opened_by_employee_id' as mesero_apertura_id,
         to_jsonb(ts)->>'waiter_user_id' as mesero_usuario_id
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    left join public.dining_tables dt on dt.id = ts.table_id
    left join public.zones z on z.id = dt.zone_id
    join biz on biz.id = coalesce(nullif(to_jsonb(ts)->>'business_id', '')::uuid, z.business_id)
    cross join params p
   where o.created_at >= p.desde
), candidatas as (
  select v.*,
         p.precuenta_reportada, p.caja_reportada, p.diferencia,
         it.total_productos,
         (select coalesce(sum(pay.amount - coalesce(pay.change_amount, 0)), 0)
            from public.payments pay
           where pay.order_id = v.id and pay.status::text in ('pending', 'completed')) as pagos_netos,
         (select jsonb_agg(jsonb_build_object(
              'ncf', f.ncf_number, 'total', f.total, 'estado', f.status,
              'creado_rd', f.created_at at time zone 'America/Santo_Domingo')
              order by f.created_at)
            from public.fiscal_documents f where f.order_id = v.id) as comprobantes
    from ventas v
    cross join params p
    cross join lateral (
      select coalesce(sum(oi.total) filter (where oi.status::text <> 'void'), 0) as total_productos
        from public.order_items oi where oi.order_id = v.id
    ) it
   where abs(v.total - p.caja_reportada) < 0.01
      or abs(v.total - p.precuenta_reportada) < 0.01
      or abs(it.total_productos - p.caja_reportada) < 0.01
      or exists (select 1 from public.payments pay where pay.order_id = v.id
                  and abs(pay.amount - coalesce(pay.change_amount, 0) - p.caja_reportada) < 0.01)
      or exists (select 1 from public.fiscal_documents f where f.order_id = v.id
                  and abs(f.total - p.caja_reportada) < 0.01)
), lineas as (
  select c.*, i.id as item_id, i.product_id, i.product_name,
         i.qty, i.unit_price, i.subtotal as item_subtotal,
         i.discounts as item_descuentos, i.tax as item_impuestos,
         i.total as item_total, i.status::text as item_estado,
         i.created_at as item_created_at,
         nullif(to_jsonb(i)->>'kitchen_sent_at', '')::timestamptz as cocina_at,
         to_jsonb(i)->>'created_by_employee_id' as autor_item_id,
         coalesce(nullif(btrim(concat_ws(' ', e.first_name, e.last_name)), ''), 'Sin autor registrado') as autor_item,
         to_jsonb(i)->>'notes' as item_notas,
         mods.modificadores, mods.precio_por_unidad as precio_modificadores,
         count(*) filter (where i.status::text <> 'void') over (
           partition by c.id, i.product_id, i.product_name, i.unit_price
         ) as lineas_del_mismo_producto,
         lag(i.created_at) over (
           partition by c.id, i.product_id, i.product_name, i.unit_price
           order by i.created_at, i.id
         ) as linea_anterior_at
    from candidatas c
    join public.order_items i on i.order_id = c.id
    left join public.employees e on e.id::text = to_jsonb(i)->>'created_by_employee_id'
    cross join lateral (
      select coalesce(sum(m.qty * m.price), 0) as precio_por_unidad,
             jsonb_agg(jsonb_build_object('nombre', m.name, 'cantidad', m.qty, 'precio', m.price)
               order by m.name, m.id) as modificadores
        from public.order_item_modifiers m where m.item_id = i.id
    ) mods
)
select negocio, business_id, mesa, table_id, id as order_id,
       coalesce(to_jsonb(lineas)->>'status_ext', to_jsonb(lineas)->>'status') as orden_estado,
       total as total_orden, total_productos, pagos_netos, comprobantes,
       precuenta_reportada, caja_reportada, diferencia,
       created_at at time zone 'America/Santo_Domingo' as orden_creada_rd,
       precuenta_impresa_at at time zone 'America/Santo_Domingo' as ultima_precuenta_rd,
       item_id, product_id, product_name, item_estado, qty, unit_price,
       precio_modificadores, item_subtotal, item_descuentos, item_impuestos, item_total,
       (abs(item_total - diferencia) < 0.01
         or abs(item_total / nullif(qty, 0) - diferencia) < 0.01
         or abs(unit_price + precio_modificadores - diferencia) < 0.01) as coincide_con_425,
       item_created_at at time zone 'America/Santo_Domingo' as producto_creado_rd,
       cocina_at at time zone 'America/Santo_Domingo' as enviado_cocina_rd,
       item_created_at > precuenta_impresa_at as creado_despues_de_ultima_precuenta,
       extract(epoch from (item_created_at - precuenta_impresa_at)) as segundos_desde_precuenta,
       autor_item_id, autor_item, mesero_apertura_id, mesero_usuario_id,
       lineas_del_mismo_producto,
       extract(epoch from (item_created_at - linea_anterior_at)) as segundos_desde_linea_anterior,
       item_notas, modificadores
  from lineas
 order by created_at desc, id, item_created_at, item_id;

-- 2. Bitácora idempotente, SOLO si la tabla está instalada (20260929_0001).
-- Sustituir el UUID por la orden confirmada del bloque 1. Misma operación
-- reintentada conserva un client_op_id y un item_id; dos operaciones distintas
-- no permiten decidir por sí solas si hubo dos toques o un cliente antiguo.
-- request_payload sirve para comparar producto, cantidad y check de origen.
select op.client_op_id, op.order_id, op.item_id,
       op.created_at at time zone 'America/Santo_Domingo' as operacion_creada_rd,
       op.request_payload,
       i.product_name, i.qty, i.unit_price, i.total,
       i.created_at at time zone 'America/Santo_Domingo' as producto_creado_rd,
       to_jsonb(i)->>'created_by_employee_id' as autor_item_id,
       i.id is null as producto_borrado_despues
  from public.order_item_client_ops op
  left join public.order_items i on i.id = op.item_id
 where op.order_id = '00000000-0000-0000-0000-000000000000'::uuid
 order by op.created_at, op.client_op_id;
