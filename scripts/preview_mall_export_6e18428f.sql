-- ============================================================================
-- Vista previa del archivo que la app sube por SFTP a la plaza
-- Negocio 6e18428f-fdd6-4c58-af0e-dae2403fbf1d (LA COCINA MEXICANA AUTENTICA)
--
-- SOLO LECTURA. Reproduce byte por byte lo que arma MallSalesExportService
-- .buildCsv() (core/services/mall_sales_export_service.dart:63-95): mismo
-- orden de campos, mismos decimales y mismo ID_TRANSACCION.
-- Lo único que no se ve aquí es el CRLF al final de cada línea.
--
-- Cambia la fecha en el CTE `d` para revisar otro día.
-- ============================================================================

with d as (
  select (current_date - 1)::date as dia          -- ← ayer; edítalo si hace falta
),
cfg as (
  select client_code, exchange_rate, file_prefix
  from public.business_sales_export_config
  where business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
),
r as (
  select *
  from public.fn_mall_sales_by_hour(
    '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid,
    (select dia from d)
  )
)
select
  (select file_prefix from cfg) || '_' ||
  to_char((select dia from d), 'DDMMYYYY') || '.txt'    as archivo,
  0                                                     as ord,
  'ID_TRANSACCION,NUMSERIE,FECHA,HORA,TOTALTRANSVENTA,'
  'TOTALART,TASA,TOTALBRUTO,TOTALIMPUESTOS,TOTALNETO'   as linea
union all
select
  (select file_prefix from cfg) || '_' ||
  to_char((select dia from d), 'DDMMYYYY') || '.txt',
  1,
  to_char((select dia from d), 'DDMMYY')
    || lpad(r.sale_hour::text, 2, '0')                            || ','
    || cfg.client_code                                            || ','
    || to_char((select dia from d), 'DD/MM/YYYY')                 || ','
    || r.sale_hour::text                                          || ','
    || r.tx_count::text                                           || ','
    || to_char(r.total_items, 'FM999999990.000000')               || ','
    || case when cfg.exchange_rate = round(cfg.exchange_rate)
            then to_char(cfg.exchange_rate, 'FM999999990')
            else to_char(cfg.exchange_rate, 'FM999999990.00') end || ','
    -- Convención de la plaza (confirmada 2026-08-13):
    --   TOTALBRUTO = base sin impuesto  ← total_net
    --   TOTALNETO  = base + impuesto    ← total_gross
    || to_char(r.total_net,   'FM999999990.00')                   || ','
    || to_char(r.total_tax,   'FM999999990.00')                   || ','
    || to_char(r.total_gross, 'FM999999990.00')
from r cross join cfg
order by ord, linea;


-- ─── Cuadre: NETO debe ser igual a BRUTO + IMPUESTOS ────────────────────────
select
  sum(total_net)                                  as bruto_del_archivo,
  sum(total_tax)                                  as impuestos,
  sum(total_gross)                                as neto_del_archivo,
  sum(total_gross) - sum(total_tax) - sum(total_net) as diferencia,
  count(*)                                        as horas_con_venta,
  sum(tx_count)                                   as transacciones
from public.fn_mall_sales_by_hour(
  '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid,
  (current_date - 1)
);
