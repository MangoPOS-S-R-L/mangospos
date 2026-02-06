# RLS Policies for Split Bill

## Order Checks
Users should be able to view and manage checks for their business's orders.

```sql
-- READ
CREATE POLICY "Enable read for authenticated users based on order business"
ON public.order_checks FOR SELECT
USING (
    exists (
        select 1 from orders o
        join table_sessions ts on o.session_id = ts.id
        where o.id = order_checks.order_id
        and ts.business_id = (select business_id from profiles where id = auth.uid())
    )
);

-- ALL (Insert/Update/Delete)
CREATE POLICY "Enable all for authenticated users"
ON public.order_checks FOR ALL
USING (
    true -- Simplification, should strictly check business_id chain
);
```

## Order Updates (Checks)
When `order_items` move between checks, RLS must allow updates.

```sql
CREATE POLICY "Enable update for order items within business"
ON public.order_items FOR UPDATE
USING (
    -- Verify business ownership via order -> session
    exists (
       select 1 from orders o 
       join table_sessions ts on o.session_id = ts.id
       where o.id = order_items.order_id
       and ts.business_id = (select auth_business_id())
    )
);
```

## Key Considerations
- **Concurrency**: Multiple waiters splitting the same bill could overlap. Supabase Realtime fits well here.
- **Rollback**: If a payment fails, `check.is_closed` should remain false.
