-- =============================================================================
-- PASO 5 · Verificacion posterior al backfill — La Penda Express
-- SOLO LECTURA.
-- =============================================================================

-- A ─── El respaldo existe y esta completo ────────────────────────────────────
--     ESPERADO: 6007 filas. Sin esto no hay vuelta atras.
select count(*) as filas_respaldadas,
       min(respaldado_en) as cuando
from public._backup_fd_607_penda_agosto;


-- B ─── Los 46 con ITBIS en cero: por que ─────────────────────────────────────
--     ESPERADO: la mayoria por 'items exentos o solo Ley' (ITBIS 0 es correcto).
--     Si aparecen muchos en 'impuesto sin desglosar', quedo trabajo pendiente.
select
  case
    when d.total = 0                                   then 'comprobante en cero'
    when coalesce(d.service_fee,0) > 0                 then 'solo Ley (ITBIS 0 correcto)'
    when abs(coalesce(d.subtotal,0) - coalesce(d.total,0)) < 0.01
                                                       then 'exento (sin impuesto)'
    else 'IMPUESTO SIN DESGLOSAR  <-- revisar'
  end                                                  as motivo,
  count(*)                                             as comprobantes,
  round(sum(d.total), 2)                               as facturado,
  round(sum(coalesce(d.total,0) - coalesce(d.subtotal,0)
          - coalesce(d.service_fee,0)), 2)             as impuesto_sin_asignar
from public.fiscal_documents d
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.status = 'active'
  and (d.issued_at at time zone 'America/Santo_Domingo')::date
      between date '2026-08-01' and date '2026-08-31'
  and coalesce(d.itbis_amount,0) = 0
group by 1
order by comprobantes desc;


-- C ─── Los 8 que no cierran, uno por uno ─────────────────────────────────────
--     Deben ser los 4 excluidos + los de H-4. Ninguno deberia ser sorpresa.
select d.ncf_number, d.issued_at::date as fecha,
       d.subtotal, d.itbis_amount, d.service_fee, d.total,
       round(coalesce(d.subtotal,0) + coalesce(d.itbis_amount,0)
           + coalesce(d.service_fee,0) - coalesce(d.total,0), 2) as descuadre,
       (b.itbis_amount is distinct from d.itbis_amount) as lo_toco_el_backfill
from public.fiscal_documents d
join public._backup_fd_607_penda_agosto b on b.id = d.id
where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and d.status = 'active'
  and (d.issued_at at time zone 'America/Santo_Domingo')::date
      between date '2026-08-01' and date '2026-08-31'
  and abs(coalesce(d.subtotal,0) + coalesce(d.itbis_amount,0)
        + coalesce(d.service_fee,0) - coalesce(d.total,0)) > 1.00
order by abs(coalesce(d.subtotal,0) + coalesce(d.itbis_amount,0)
           + coalesce(d.service_fee,0) - coalesce(d.total,0)) desc;


-- D ─── Lo que ningun UPDATE debio mover: total y ventas del mes ──────────────
--     ESPERADO: cambiaron_de_total = 0  y  diferencia_en_ventas = 0.00
select
  count(*)                                                     as comprobantes,
  count(*) filter (where abs(d.total - b.total) > 0.005)       as cambiaron_de_total,
  round(sum(d.total - b.total), 2)                             as diferencia_en_ventas,
  round(sum(b.itbis_amount), 2)                                as itbis_antes,
  round(sum(d.itbis_amount), 2)                                as itbis_ahora
from public.fiscal_documents d
join public._backup_fd_607_penda_agosto b on b.id = d.id;
