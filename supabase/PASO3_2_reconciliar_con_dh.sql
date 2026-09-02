-- =============================================================================
-- PASO 3.2 · Reconciliar mi cifra (794,566.14) con la de DH (779,169.11)
-- Diferencia: 15,397.03
--
-- HIPOTESIS: son las 103 facturas de cuentas divididas que DH dejo fuera de su
-- comparacion producto-por-producto (nota de alcance del informe, RD$106,353.73).
-- El ITBIS contenido en ese monto seria ~106,353.73 x 18/128 = 14,956.
--
-- SOLO LECTURA. Corre sobre la tabla de trabajo del paso 3.1.
-- =============================================================================

-- A ─── Cuentas divididas vs orden completa ───────────────────────────────────
--     Si el ITBIS de las divididas ronda los 15,400, la hipotesis se confirma.
select
  case when check_id is not null then 'cuenta dividida' else 'orden completa' end as tipo,
  count(*)                                          as comprobantes,
  round(sum(total_hoy), 2)                          as facturado,
  round(sum(coalesce(itbis_nuevo, itbis_hoy)), 2)   as itbis_nuevo,
  round(sum(itbis_hoy), 2)                          as itbis_hoy
from public._sim_607_penda
group by 1
order by 1;


-- B ─── Los 16 que la funcion no toca ─────────────────────────────────────────
--     Deberian ser los 9 de H-4 (todo anulado) + vecinos. Ver por que.
select ncf_number, issued_at::date as fecha, total_hoy, itbis_hoy,
       n_items, scope_total,
       case when scope_total <= 0 then 'sin pagos'
            when n_items = 0     then 'sin items vivos'
            else '?' end as motivo
from public._sim_607_penda
where subtotal_nuevo is null
order by total_hoy desc;


-- C ─── Reparto por tasa: de donde sale cada peso del ITBIS nuevo ─────────────
--     Verifica que la regla se aplico como esperamos y no hay tasas raras.
select oi.tax_rate,
       count(*)                                   as lineas,
       round(sum(oi.subtotal), 2)                 as base,
       round(sum(coalesce(oi.tax,0)), 2)          as impuesto_cobrado,
       round(sum(coalesce(oi.tax,0)) * 18/28, 2)  as si_fuera_28,
       round(sum(coalesce(oi.tax,0)), 2)          as si_fuera_18
from public.order_items oi
where oi.status <> 'void'
  and oi.order_id in (select order_id from public._sim_607_penda where order_id is not null)
group by oi.tax_rate
order by oi.tax_rate;


-- D ─── Identidad: base + ITBIS + LEY debe dar el total ───────────────────────
--     El descuadre agregado tiene que ser centavos, no miles.
select
  count(*)                                                            as comprobantes,
  round(sum(coalesce(subtotal_nuevo, subtotal_hoy)
          + coalesce(itbis_nuevo, itbis_hoy)
          + coalesce(ley_nuevo, ley_hoy)
          - total_hoy), 2)                                            as descuadre_total,
  round(max(abs(coalesce(subtotal_nuevo, subtotal_hoy)
          + coalesce(itbis_nuevo, itbis_hoy)
          + coalesce(ley_nuevo, ley_hoy)
          - total_hoy)), 2)                                           as peor_caso
from public._sim_607_penda;
