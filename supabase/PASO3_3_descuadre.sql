-- =============================================================================
-- PASO 3.3 · Por que 3,673.71 de descuadre en un comprobante que SI se escribe
--
-- HIPOTESIS: fiscal_documents.tip. La funcion no la toca y una propina no es
-- base gravable, asi que la identidad correcta es
--     subtotal + ITBIS + LEY + TIP = total
-- y no la que verifique antes (sin tip).
--
-- SOLO LECTURA.
-- =============================================================================

-- A ─── Los 20 peores, con la propina al lado ─────────────────────────────────
--     Si `descuadre_sin_tip` == `tip`, la hipotesis se confirma y el
--     `descuadre_con_tip` sale en cero.
select
  s.ncf_number,
  s.issued_at::date                                     as fecha,
  s.subtotal_nuevo, s.itbis_nuevo, s.ley_nuevo,
  coalesce(d.tip, 0)                                    as tip,
  s.total_hoy,
  round(s.subtotal_nuevo + s.itbis_nuevo + s.ley_nuevo
        - s.total_hoy, 2)                               as descuadre_sin_tip,
  round(s.subtotal_nuevo + s.itbis_nuevo + s.ley_nuevo
        + coalesce(d.tip, 0) - s.total_hoy, 2)          as descuadre_con_tip,
  s.n_items, s.items_total, s.scope_total
from public._sim_607_penda s
join public.fiscal_documents d on d.id = s.id
where s.subtotal_nuevo is not null
order by abs(s.subtotal_nuevo + s.itbis_nuevo + s.ley_nuevo - s.total_hoy) desc
limit 20;


-- B ─── La identidad CORRECTA, agregada ───────────────────────────────────────
--     ESPERADO: descuadre y peor_caso en centavos.
select
  count(*)                                                          as comprobantes,
  round(sum(s.subtotal_nuevo + s.itbis_nuevo + s.ley_nuevo
          + coalesce(d.tip,0) - s.total_hoy), 2)                    as descuadre_con_tip,
  round(max(abs(s.subtotal_nuevo + s.itbis_nuevo + s.ley_nuevo
          + coalesce(d.tip,0) - s.total_hoy)), 2)                   as peor_caso_con_tip,
  count(*) filter (where abs(s.subtotal_nuevo + s.itbis_nuevo + s.ley_nuevo
          + coalesce(d.tip,0) - s.total_hoy) > 1.00)                as cuantos_pasan_de_1_peso
from public._sim_607_penda s
join public.fiscal_documents d on d.id = s.id
where s.subtotal_nuevo is not null;


-- C ─── Si la propina NO lo explica: donde esta la diferencia ─────────────────
--     Compara lo cobrado (pagos) contra lo que suman los items.
select
  s.ncf_number, s.issued_at::date as fecha,
  s.items_total                                    as suman_los_items,
  s.scope_total                                    as se_cobro,
  round(s.scope_total - s.items_total, 2)          as sobra_cobrado,
  coalesce(d.tip, 0)                               as tip,
  round(s.scope_total - s.items_total
        - coalesce(d.tip, 0), 2)                   as sin_explicar
from public._sim_607_penda s
join public.fiscal_documents d on d.id = s.id
where s.subtotal_nuevo is not null
  and abs(s.scope_total - s.items_total - coalesce(d.tip,0)) > 1.00
order by abs(s.scope_total - s.items_total - coalesce(d.tip,0)) desc
limit 20;
