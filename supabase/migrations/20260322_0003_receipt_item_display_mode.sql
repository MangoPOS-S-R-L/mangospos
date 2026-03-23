begin;

alter table public.business_settings
  add column if not exists receipt_item_display_mode text default 'grouped';

update public.business_settings
set receipt_item_display_mode = case
  when receipt_item_display_mode in ('grouped', 'separate')
    then receipt_item_display_mode
  else 'grouped'
end
where receipt_item_display_mode is distinct from case
  when receipt_item_display_mode in ('grouped', 'separate')
    then receipt_item_display_mode
  else 'grouped'
end;

commit;
