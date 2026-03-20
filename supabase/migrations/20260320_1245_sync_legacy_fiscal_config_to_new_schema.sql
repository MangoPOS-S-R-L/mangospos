-- Sincroniza configuracion fiscal legacy con el esquema real usado por el cobro.
-- Origen legacy:
--   - businesses.prefer_electronic_billing / fiscal_rnc / fiscal_name
--   - secuencias_ncf
-- Destino real:
--   - fiscal_settings
--   - ncf_sequences

insert into public.fiscal_settings (
  business_id,
  rnc,
  business_legal_name,
  ecf_enabled,
  default_ncf_type
)
select
  b.id as business_id,
  coalesce(nullif(b.fiscal_rnc, ''), 'PENDIENTE') as rnc,
  coalesce(nullif(b.fiscal_name, ''), b.name, 'Negocio sin nombre') as business_legal_name,
  coalesce(b.prefer_electronic_billing, false) as ecf_enabled,
  case
    when coalesce(b.prefer_electronic_billing, false) then 'E32'::public.ncf_type
    else 'B02'::public.ncf_type
  end as default_ncf_type
from public.businesses b
on conflict (business_id) do update
set
  rnc = excluded.rnc,
  business_legal_name = excluded.business_legal_name,
  ecf_enabled = excluded.ecf_enabled,
  default_ncf_type = excluded.default_ncf_type,
  updated_at = now();

insert into public.ncf_sequences (
  business_id,
  ncf_type,
  serie,
  prefix,
  range_start,
  range_end,
  current_number,
  is_active,
  created_at
)
select
  s.business_id,
  (s.serie || s.tipo)::public.ncf_type as ncf_type,
  s.serie,
  (s.serie || s.tipo) as prefix,
  1 as range_start,
  s.maximo_seq as range_end,
  s.ultimo_seq as current_number,
  coalesce(s.activo, true) as is_active,
  coalesce(s.created_at, now()) as created_at
from public.secuencias_ncf s
where (s.serie || s.tipo) in ('B01','B02','B14','B15','B16','E31','E32','E33','E34','E44','E45')
on conflict (business_id, ncf_type, serie) do update
set
  prefix = excluded.prefix,
  range_end = excluded.range_end,
  current_number = excluded.current_number,
  is_active = excluded.is_active;