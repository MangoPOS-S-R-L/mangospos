-- =============================================================================
-- VERIFICAR 20260915_0005 (Compras F2, órdenes en lote) — SOLO LECTURA
-- Correr DESPUÉS de aplicar 20260915_0003, 0004 y 0005. No crea órdenes: la
-- función se prueba de verdad desde la pantalla «Pedido sugerido».
-- =============================================================================

-- 1) Las tres funciones de compras están y la app (authenticated) puede usarlas.
select p.proname                                                        as funcion,
       pg_get_function_identity_arguments(p.oid)                        as argumentos,
       has_function_privilege('authenticated', p.oid, 'execute')::text  as authenticated_puede,
       case when p.prosecdef then 'DEFINER (revisar)' else 'INVOKER' end as seguridad
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('fn_purchase_order_create',
                     'fn_purchase_projection',
                     'fn_purchase_orders_create_batch')
 order by p.proname;
-- Esperado: 3 filas, authenticated_puede = true, seguridad = INVOKER.

-- 2) Órdenes creadas desde el pedido sugerido (después de usar la pantalla).
select po.order_number                         as orden,
       s.name                                  as suplidor,
       po.status                               as estado,
       po.expected_date                        as entrega,
       po.total,
       count(poi.id)                           as lineas,
       split_part(po.idempotency_key, ':', 1)  as lote,
       po.created_at
  from public.purchase_orders po
  left join public.suppliers s on s.id = po.supplier_id
  left join public.purchase_order_items poi on poi.purchase_order_id = po.id
 where po.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and po.idempotency_key like 'pedido-sugerido-%'
 group by po.id, s.name
 order by po.created_at desc
 limit 30;
