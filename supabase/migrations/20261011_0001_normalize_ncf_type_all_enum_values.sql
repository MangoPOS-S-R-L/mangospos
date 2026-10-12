-- =============================================================================
-- 20261011_0001 — normalize_ncf_type: cubrir los 11 tipos del enum ncf_type
-- =============================================================================
--
-- PROBLEMA. `public.normalize_ncf_type` (20260327_0008) traduce el tipo que
-- manda el cliente al enum `public.ncf_type`, aceptando tanto el codigo
-- completo ('B02') como el numero suelto ('02'). Solo contemplaba 6 de los 11
-- valores del enum:
--
--     cubiertos : B01 B02 B14 B15 E31 E32
--     faltantes : B16 E33 E34 E44 E45
--
-- Todo lo demas caia en `raise exception 'INVALID_NCF_TYPE'`. Como el RPC de
-- cobro (`fn_process_payment_v3`) resuelve el tipo con esta funcion, un negocio
-- que marcara cualquiera de esos cinco como comprobante predefinido —o que lo
-- eligiera al cobrar— no podia facturar: el cobro abortaba con INVALID_NCF_TYPE
-- aunque la secuencia estuviera activa y con rango disponible.
--
-- Los cinco faltantes no son casos de borde: B16 es exportaciones, E33/E34 son
-- las notas de debito y credito electronicas, y E44/E45 los regimenes especiales
-- y gubernamental en e-CF.
--
-- SOLUCION. Se enumeran los 11 valores del enum con sus dos formas de entrada
-- (numero suelto y codigo completo). El numero determina la serie sin
-- ambiguedad en la numeracion de la DGII (02 siempre es B02, 31 siempre E31),
-- asi que el mapeo numero -> codigo es 1 a 1 y no hay que adivinar nada.
--
-- Se conserva el contrato: '' / null -> null (= usar el default del negocio),
-- entrada desconocida -> INVALID_NCF_TYPE. La funcion sigue siendo IMMUTABLE,
-- asi que los indices o vistas que dependan de ella no cambian de semantica.
--
-- IDEMPOTENTE. `create or replace`: se puede correr varias veces.
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

    -- NCF en papel (serie B)
    when '01' then return 'B01'::public.ncf_type;  -- Credito Fiscal
    when 'B01' then return 'B01'::public.ncf_type;
    when '02' then return 'B02'::public.ncf_type;  -- Consumidor Final
    when 'B02' then return 'B02'::public.ncf_type;
    when '14' then return 'B14'::public.ncf_type;  -- Regimenes Especiales
    when 'B14' then return 'B14'::public.ncf_type;
    when '15' then return 'B15'::public.ncf_type;  -- Gubernamental
    when 'B15' then return 'B15'::public.ncf_type;
    when '16' then return 'B16'::public.ncf_type;  -- Exportaciones
    when 'B16' then return 'B16'::public.ncf_type;

    -- Comprobantes electronicos (serie E)
    when '31' then return 'E31'::public.ncf_type;  -- e-CF Credito Fiscal
    when 'E31' then return 'E31'::public.ncf_type;
    when '32' then return 'E32'::public.ncf_type;  -- e-CF Consumidor Final
    when 'E32' then return 'E32'::public.ncf_type;
    when '33' then return 'E33'::public.ncf_type;  -- e-CF Nota de Debito
    when 'E33' then return 'E33'::public.ncf_type;
    when '34' then return 'E34'::public.ncf_type;  -- e-CF Nota de Credito
    when 'E34' then return 'E34'::public.ncf_type;
    when '44' then return 'E44'::public.ncf_type;  -- e-CF Regimenes Especiales
    when 'E44' then return 'E44'::public.ncf_type;
    when '45' then return 'E45'::public.ncf_type;  -- e-CF Gubernamental
    when 'E45' then return 'E45'::public.ncf_type;

    else
      raise exception 'INVALID_NCF_TYPE';
  end case;
end;
$$;

comment on function public.normalize_ncf_type(text) is
  'Traduce un tipo de comprobante (numero suelto "02" o codigo completo "B02") '
  'al enum public.ncf_type. Cubre los 11 valores del enum. '
  'Vacio/null -> null (usar default_ncf_type del negocio); '
  'desconocido -> excepcion INVALID_NCF_TYPE.';
