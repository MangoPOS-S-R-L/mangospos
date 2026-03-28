-- Repair patch for promotions.days_of_week constraint
-- Use this if the previous migration was attempted manually or partially.

begin;

alter table public.promotions
  drop constraint if exists promotions_days_of_week_values_check;

alter table public.promotions
  add constraint promotions_days_of_week_values_check
  check (
    days_of_week is null
    or days_of_week <@ array[0,1,2,3,4,5,6]::integer[]
  );

commit;
