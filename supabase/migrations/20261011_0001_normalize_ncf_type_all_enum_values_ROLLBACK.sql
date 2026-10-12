-- =============================================================================
-- ROLLBACK 20261011_0001 — normalize_ncf_type vuelve a los 6 tipos originales
-- =============================================================================
--
-- Restaura la version de 20260327_0008. OJO: despues de esto, cobrar con
-- B16 / E33 / E34 / E44 / E45 vuelve a fallar con INVALID_NCF_TYPE.
-- =============================================================================

create or replace function public.normalize_ncf_type(p_raw text)
returns public.ncf_type
language plpgsql
immutable
as $$
declare
  v_value text := upper(trim(coalesce(p_raw, '')));
begin
  case v_value
    when '' then return null;
    when '01' then return 'B01'::public.ncf_type;
    when 'B01' then return 'B01'::public.ncf_type;
    when '02' then return 'B02'::public.ncf_type;
    when 'B02' then return 'B02'::public.ncf_type;
    when '14' then return 'B14'::public.ncf_type;
    when 'B14' then return 'B14'::public.ncf_type;
    when '15' then return 'B15'::public.ncf_type;
    when 'B15' then return 'B15'::public.ncf_type;
    when '31' then return 'E31'::public.ncf_type;
    when 'E31' then return 'E31'::public.ncf_type;
    when '32' then return 'E32'::public.ncf_type;
    when 'E32' then return 'E32'::public.ncf_type;
    else
      raise exception 'INVALID_NCF_TYPE';
  end case;
end;
$$;

comment on function public.normalize_ncf_type(text) is null;
