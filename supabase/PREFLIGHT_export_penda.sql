-- =============================================================================
-- LA PENDA EXPRESS — chequeo de 10 segundos ANTES de exportar
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Tres cosas que, si están mal, se ven en el archivo del auditor y ya no hay
-- forma de arreglarlas sin volver a exportar.
-- =============================================================================

select
  s.code,
  coalesce(nullif(btrim(s.notes), ''), '⚠ SIN NOMBRE')      as nombre_del_conteo,
  w.name                                                    as bodega,
  s.status,
  count(l.*) filter (where l.counted_quantity is not null)   as contados,
  count(l.*) filter (where l.counted_quantity is not null
                       and coalesce(i.cost, 0) = 0)          as sin_costo,
  count(l.*) filter (where l.counted_quantity is not null
                       and lower(btrim(i.unit)) in ('l','lt','litro','litros')
                       and i.name !~* '\m(aceite|vinagre|jugo|leche|agua|salsa|sirope|jarabe|crema|refresco|vino|ron|whisky|cerveza|licor|soda)\M')
                                                             as solidos_en_litros,
  round(sum(l.counted_quantity * coalesce(i.cost, 0))
        filter (where l.counted_quantity is not null), 2)     as valor_contado,
  round(sum((l.counted_quantity - l.snapshot_quantity) * coalesce(i.cost, 0))
        filter (where l.counted_quantity is not null), 2)     as ajuste_al_cerrar,
  case
    when coalesce(btrim(s.notes), '') = ''  then '❌ ponerle nombre antes de exportar'
    when count(l.*) filter (where l.counted_quantity is not null
                              and lower(btrim(i.unit)) in ('l','lt','litro','litros')
                              and i.name !~* '\m(aceite|vinagre|jugo|leche|agua|salsa|sirope|jarabe|crema|refresco|vino|ron|whisky|cerveza|licor|soda)\M') > 0
                                            then '⚠️ quedan sólidos en litros'
    else                                         '✅ listo para exportar'
  end                                                        as veredicto
from public.physical_count_sessions s
join public.warehouses w on w.id = s.warehouse_id
left join public.physical_count_lines l on l.session_id = s.id
left join public.inventory_items i on i.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status in ('draft', 'in_progress', 'completed')
group by s.code, s.notes, w.name, s.status
order by s.code;
