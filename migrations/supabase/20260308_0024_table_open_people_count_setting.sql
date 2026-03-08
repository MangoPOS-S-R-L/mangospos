begin;

alter table public.business_settings
  add column if not exists prompt_people_count_on_table_open boolean default false;

update public.business_settings
set prompt_people_count_on_table_open = coalesce(
  prompt_people_count_on_table_open,
  false
)
where prompt_people_count_on_table_open is null;

commit;
