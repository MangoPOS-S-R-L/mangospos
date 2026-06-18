-- Happy hour: franja horaria diaria opcional para promociones.
--
-- start_time / end_time se interpretan como HORA DE PARED LOCAL del negocio
-- (tipo `time` sin zona horaria). Esto es a propósito y distinto de
-- start_date/end_date, que sí se guardan en UTC: la franja horaria debe
-- evaluarse contra la hora del dispositivo/caja, igual que ya se evalúa
-- days_of_week con DateTime.now() en el motor de auto-promos.
--
-- NULL en ambas columnas = sin restricción horaria => aplica todo el día
-- (comportamiento actual, totalmente retrocompatible).
--
-- Si end_time < start_time, la franja CRUZA LA MEDIANOCHE
-- (ej. 22:00 -> 02:00 para un happy hour nocturno).
alter table public.promotions
  add column if not exists start_time time without time zone,
  add column if not exists end_time   time without time zone;

comment on column public.promotions.start_time is
  'Happy hour: hora de inicio (local, sin tz) de la franja diaria. NULL = sin restricción horaria.';
comment on column public.promotions.end_time is
  'Happy hour: hora de fin (local, sin tz) de la franja diaria. Si < start_time, la franja cruza la medianoche.';
