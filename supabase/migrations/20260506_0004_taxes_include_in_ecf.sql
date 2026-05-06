-- 20260506_0004_taxes_include_in_ecf.sql
--
-- Scope: añadir flag include_in_ecf a taxes. Permite al negocio decidir,
-- por impuesto, cuáles van al e-CF DGII y cuáles son cargos extra-fiscales
-- (típicamente la Propina Legal 10%).
--
-- Default sensato (backfill):
-- - is_service_fee=false (ITBIS, ISC, otros impuestos del estado)  -> true
-- - is_service_fee=true  (Propina Legal a favor de empleados)      -> false
--
-- Razón: la Propina Legal (Ley 16-92 art. 228) es cargo a favor de los
-- empleados, NO es ingreso del negocio, y DGII no la reconoce como
-- "impuesto adicional" en sentido estricto. Por defecto la excluimos
-- del e-CF; el cliente puede activar el toggle en su tax si su contador
-- prefiere declararla.

begin;

alter table public.taxes
  add column if not exists include_in_ecf boolean;

-- Backfill: ITBIS-like va al e-CF, propina-like no.
update public.taxes
set include_in_ecf = (is_service_fee is not true)
where include_in_ecf is null;

-- Default para registros nuevos: true (caso ITBIS-like es lo más común).
-- Si is_service_fee=true, el viewmodel debe forzar default=false al crear.
alter table public.taxes
  alter column include_in_ecf set not null,
  alter column include_in_ecf set default true;

comment on column public.taxes.include_in_ecf is
  'Si TRUE: el impuesto se incluye en el cálculo del e-CF DGII '
  '(itbis_amount, taxable_amount, totalAmount). '
  'Si FALSE: se cobra al cliente pero NO se declara en el e-CF '
  '(uso típico: Propina Legal 10% que es cargo a favor de empleados). '
  'Default sensato al crear: true para ITBIS-like, false para is_service_fee=true.';

commit;
