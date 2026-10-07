-- =============================================================================
-- ROLLBACK de 20261007_0001_notification_events.sql
-- =============================================================================
-- Quita los avisos (tabla, triggers, funciones, cron). NO recrea
-- push_order_item_void (el push por cada ítem en 'void' que se creó a mano en
-- producción): era el origen de los avisos repetidos. Si hiciera falta,
-- recrearlo desde su SQL original.
-- =============================================================================

begin;

drop trigger if exists trg_zz_notif_items_deleted on public.order_items;
drop trigger if exists trg_zz_notif_item_reduced on public.order_items;
drop trigger if exists trg_zz_notif_order_void on public.orders;
drop trigger if exists trg_zz_notif_payment_cancel on public.payments;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job
     where jobname = 'notification_events_push_retry';
  end if;
exception when insufficient_privilege then
  raise notice 'Sin privilegio para pg_cron; desagendar notification_events_push_retry a mano.';
end $$;

do $$
begin
  if exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'notification_events'
  ) then
    alter publication supabase_realtime drop table public.notification_events;
  end if;
end $$;

drop table if exists public.notification_events;

drop function if exists public.fn_notification_event_refresh(uuid);
drop function if exists public.fn_notif_event_push();
drop function if exists public.fn_notif_on_items_deleted();
drop function if exists public.fn_notif_on_item_reduced();
drop function if exists public.fn_notif_on_order_void();
drop function if exists public.fn_notif_on_payment_cancel();
drop function if exists private.fn_run_notification_event_sweep();
drop function if exists private.fn_notif_call_push(jsonb);
drop function if exists private.fn_notif_add_removed_items(uuid, uuid, jsonb, uuid);
drop function if exists private.fn_notif_item_was_sent(jsonb);
drop function if exists private.fn_notif_is_rewrite();
drop function if exists private.fn_notif_text(text, uuid, uuid, jsonb, uuid[], uuid, timestamptz);
drop function if exists private.fn_notif_void_note(text);
drop function if exists private.fn_notif_place(uuid);
drop function if exists private.fn_notif_person(uuid, uuid, uuid);
drop function if exists private.fn_notif_qty(numeric);
drop function if exists private.fn_notif_money(numeric);

commit;
