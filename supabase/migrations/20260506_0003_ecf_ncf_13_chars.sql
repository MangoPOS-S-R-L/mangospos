-- 20260506_0003_ecf_ncf_13_chars.sql
--
-- Scope:
-- Corregir generate_ncf() para que los e-CF (Exx) tengan 13 caracteres
-- exactos como exige DGII: Serie (1) + Tipo (2) + Secuencial (10).
--
-- Antes:
--   prefix='E32' || lpad(n, 8, '0')  -> 'E3209708001' (11 chars)  BUG
-- Ahora:
--   prefix='E32' || lpad(n, 10, '0') -> 'E320009708001' (13 chars) OK
--
-- NCF físico (Bxx) sigue con padding 8 (formato tradicional B + 2 + 8 = 11
-- chars), no se toca.
--
-- Compatibilidad con datos existentes:
-- - Registros viejos en fiscal_documents con padding 8 (ej: E3209708001)
--   NO se renombran (ya fueron enviados a Alanube/DGII).
-- - La query interna de detección de colisiones hace `substring(ncf from
--   char_length(prefix)+1)` que parsea los dígitos sin importar el padding,
--   asi que coexisten sin chocar (E3209708001 y E320009708001 ambos
--   parsean al mismo número 9708001 → max+1 da el siguiente correcto).
-- - El sandbox de Alanube nos dió rango 9708001-9709000 (7 dígitos) que
--   con padding 10 caben perfectamente en 10.

begin;

create or replace function public.generate_ncf(
  _business_id uuid,
  _ncf_type public.ncf_type
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  _sequence public.ncf_sequences%rowtype;
  _max_used bigint := 0;
  _new_number bigint;
  _padding integer;
begin
  select *
    into _sequence
  from public.ncf_sequences
  where business_id = _business_id
    and ncf_type = _ncf_type
    and is_active = true
    and current_number < range_end
    and (expiration_date is null or expiration_date > current_date)
  order by created_at desc, id desc
  limit 1
  for update;

  if not found then
    raise exception 'No hay secuencia NCF disponible para tipo %', _ncf_type;
  end if;

  -- DGII: e-CF (Exx) requiere 10 dígitos secuenciales (13 chars total).
  -- NCF físico tradicional (Bxx) usa 8 dígitos (11 chars total).
  if left(_ncf_type::text, 1) = 'E' then
    _padding := 10;
  else
    _padding := 8;
  end if;

  -- Detección de colisión: parsea el número sin importar el padding,
  -- asi que tolera registros viejos con padding distinto al actual.
  select coalesce(
           max(
             cast(
               substring(fd.ncf_number from char_length(_sequence.prefix) + 1)
               as bigint
             )
           ),
           0
         )
    into _max_used
  from public.fiscal_documents fd
  where fd.business_id = _business_id
    and fd.ncf_number like _sequence.prefix || '%'
    and substring(fd.ncf_number from char_length(_sequence.prefix) + 1) ~ '^[0-9]+$';

  _new_number := greatest(
    _sequence.current_number + 1,
    _sequence.range_start,
    _max_used + 1
  );

  if _new_number > _sequence.range_end then
    raise exception 'Secuencia NCF agotada para tipo %', _ncf_type;
  end if;

  update public.ncf_sequences
  set current_number = _new_number
  where id = _sequence.id;

  return _sequence.prefix || lpad(_new_number::text, _padding, '0');
end;
$$;

commit;
