-- =============================================================================
-- DIAGNÓSTICO — Compras (antes de F0 del PRD_COMPRAS_PEDIDO_SUGERIDO.md)
-- SOLO LECTURA. Correr cada bloque por separado y pegar los resultados.
-- =============================================================================

-- 1) Estados de orden que admite la base. Si no aparece 'pending', el botón
--    «Crear OC» de Reorden (que manda status = 'pending') falla.
select enum_range(null::public.purchase_status)::text as estados_de_orden;

-- 2) ¿Alguien logró crear órdenes desde Reorden? (número REORD-…)
select coalesce(po.status::text, '—') as estado, count(*) as ordenes_reorden
  from public.purchase_orders po
 where po.order_number like 'REORD-%'
 group by 1
union all
select 'TOTAL', count(*) from public.purchase_orders where order_number like 'REORD-%';

-- 3) La Penda, últimos 60 días: qué movimientos hay, para definir «consumo».
select im.movement_type::text      as tipo,
       coalesce(im.reference_type, '—') as referencia,
       count(*)                    as movimientos,
       round(sum(im.quantity), 2)  as cantidad_neta
  from public.inventory_movements im
 where im.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and im.created_at > now() - interval '60 days'
 group by 1, 2
 order by movimientos desc;

-- 4) La Penda: qué datos de suplidores hay para proyectar y comparar.
select 'suplidores activos'                          as dato,
       count(*)::text                                as valor
  from public.suppliers s
 where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and coalesce(s.is_active, true)
union all
select 'con tiempo de entrega', count(*)::text from public.suppliers s
 where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and coalesce(s.lead_time_days, 0) > 0
union all
select 'con pedido mínimo', count(*)::text from public.suppliers s
 where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and coalesce(s.min_order_amount, 0) > 0
union all
select 'con WhatsApp', count(*)::text from public.suppliers s
 where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and coalesce(s.whatsapp, '') <> ''
union all
select 'vínculos insumo-suplidor activos', count(*)::text from public.supplier_items si
 where si.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and si.is_active
union all
select 'vínculos con empaque > 1', count(*)::text from public.supplier_items si
 where si.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and coalesce(si.pack_size, 1) > 1
union all
select 'vínculos con precio de lista', count(*)::text from public.supplier_items si
 where si.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and coalesce(si.last_price, 0) > 0
union all
-- `preferred_supplier_id` llega con 20260813_0001, que puede no estar aplicada:
-- se lee por JSON para que la consulta no falle si la columna no existe.
select 'columna preferred_supplier_id existe', exists (
         select 1 from information_schema.columns
          where table_schema = 'public' and table_name = 'inventory_items'
            and column_name = 'preferred_supplier_id')::text
union all
select 'insumos con suplidor preferido',
       count(*) filter (where to_jsonb(ii) ->> 'preferred_supplier_id' is not null)::text
  from public.inventory_items ii
 where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
union all
select 'insumos activos', count(*)::text from public.inventory_items ii
 where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and coalesce(ii.is_active, true);

-- 5) La Penda: órdenes y recepciones (fuente de precios reales del comparador).
select 'orden · ' || po.status::text as documento,
       count(*)                       as cantidad,
       min(po.created_at)::date       as desde,
       max(po.created_at)::date       as hasta
  from public.purchase_orders po
 where po.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
 group by po.status
union all
select 'recepción · ' || pr.status, count(*), min(pr.reception_date), max(pr.reception_date)
  from public.purchase_receptions pr
 where pr.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
 group by pr.status
order by 1;
