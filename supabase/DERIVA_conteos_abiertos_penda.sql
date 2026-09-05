-- =============================================================================
-- ¿Cuánto se pierde por dejar los conteos abiertos?
--
-- Al cerrar, el stock queda EXACTAMENTE en lo contado: el delta se calcula
-- contra la existencia viva, no contra el snapshot. Todo movimiento ocurrido
-- entre el conteo y el cierre se borra de la posición de inventario.
--
-- Esta consulta mide ese movimiento: cuántas ventas, recepciones y ajustes
-- hubo desde que se congeló cada sesión, sobre los artículos YA CONTADOS.
-- Es el número que se va a perder si se cierra hoy.
-- =============================================================================

select
  s.code                                   as sesion,
  coalesce(s.notes, '(sin área)')          as area,
  (s.frozen_at at time zone 'America/Santo_Domingo')::date as congelada,
  (now()::date - s.frozen_at::date)        as dias_abierta,
  count(distinct l.item_id) filter (where l.counted_quantity is not null)
                                           as articulos_contados,
  -- Movimiento posterior al congelado, SOLO en los artículos ya contados.
  count(m.id)                              as movimientos_despues,
  round(sum(m.quantity) filter (where m.movement_type = 'sale'), 2)
                                           as unidades_vendidas,
  round(sum(m.quantity) filter (where m.movement_type <> 'sale'), 2)
                                           as unidades_otros_movimientos,
  round(sum(abs(m.quantity) * coalesce(ii.cost, 0)), 2)
                                           as valor_en_juego
from public.physical_count_sessions s
join public.physical_count_lines l on l.session_id = s.id
join public.inventory_items ii on ii.id = l.item_id
left join public.inventory_movements m
       on m.item_id = l.item_id
      and m.warehouse_id = s.warehouse_id
      and m.created_at > s.frozen_at
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status = 'in_progress'
  and l.counted_quantity is not null
group by s.code, s.notes, s.frozen_at
order by s.code;

-- CÓMO LEERLO:
--   `valor_en_juego` es lo que el cierre va a revertir. Con un número chico
--   no pasa nada: el conteo es más confiable que el sistema, para eso se
--   cuenta. Si crece, el conteo deja de reflejar la realidad del día del
--   cierre y hay que recontar lo que se movió.
--
--   El detalle, artículo por artículo:
--
-- select ii.name, l.counted_quantity as contado,
--        (select coalesce(sum(st.quantity),0) from public.inventory_stock st
--          where st.item_id = l.item_id and st.warehouse_id = s.warehouse_id)
--          as stock_hoy,
--        count(m.id) as movimientos
--   from public.physical_count_sessions s
--   join public.physical_count_lines l on l.session_id = s.id
--   join public.inventory_items ii on ii.id = l.item_id
--   join public.inventory_movements m on m.item_id = l.item_id
--        and m.warehouse_id = s.warehouse_id and m.created_at > s.frozen_at
--  where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
--    and s.status = 'in_progress' and l.counted_quantity is not null
--  group by ii.name, l.counted_quantity, l.item_id, s.warehouse_id
--  order by count(m.id) desc;
