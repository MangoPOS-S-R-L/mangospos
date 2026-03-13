begin;

drop policy if exists "select_own_business" on public.print_jobs;
drop policy if exists "print_jobs_select_by_business" on public.print_jobs;
drop policy if exists "print_jobs_insert_by_business" on public.print_jobs;
drop policy if exists "print_jobs_update_by_business" on public.print_jobs;
drop policy if exists "print_jobs_delete_by_business" on public.print_jobs;

create policy "print_jobs_select_by_business"
on public.print_jobs
for select
to authenticated
using (
  exists (
    select 1
    from public.businesses b
    where b.id = print_jobs.business_id
      and (
        b.owner_id = auth.uid()
        or b.id in (select public.current_user_business_ids())
      )
  )
);

create policy "print_jobs_insert_by_business"
on public.print_jobs
for insert
to authenticated
with check (
  exists (
    select 1
    from public.businesses b
    where b.id = print_jobs.business_id
      and (
        b.owner_id = auth.uid()
        or b.id in (select public.current_user_business_ids())
      )
  )
);

create policy "print_jobs_update_by_business"
on public.print_jobs
for update
to authenticated
using (
  exists (
    select 1
    from public.businesses b
    where b.id = print_jobs.business_id
      and (
        b.owner_id = auth.uid()
        or b.id in (select public.current_user_business_ids())
      )
  )
)
with check (
  exists (
    select 1
    from public.businesses b
    where b.id = print_jobs.business_id
      and (
        b.owner_id = auth.uid()
        or b.id in (select public.current_user_business_ids())
      )
  )
);

create policy "print_jobs_delete_by_business"
on public.print_jobs
for delete
to authenticated
using (
  exists (
    select 1
    from public.businesses b
    where b.id = print_jobs.business_id
      and (
        b.owner_id = auth.uid()
        or b.id in (select public.current_user_business_ids())
      )
  )
);

commit;
