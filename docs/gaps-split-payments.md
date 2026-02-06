# Backend Gaps & SQL Implementation

## Status
The codebase relies on `order_checks` table and several RPC functions that may not exist in the current Supabase instance.

## 1. Missing Tables

### `order_checks`
Stores the split bill sub-accounts (checks).

```sql
CREATE TABLE IF NOT EXISTS public.order_checks (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    order_id uuid REFERENCES public.orders(id) ON DELETE CASCADE,
    label text NOT NULL, -- e.g. "Cuenta 1", "Cuenta 2"
    position integer DEFAULT 1,
    is_closed boolean DEFAULT false,
    subtotal numeric DEFAULT 0,
    discounts numeric DEFAULT 0,
    tax numeric DEFAULT 0,
    total numeric DEFAULT 0,
    created_at timestamptz DEFAULT now(),
    -- Ensure unique position per order to avoid confusion
    UNIQUE(order_id, position)
);

-- Index
CREATE INDEX IF NOT EXISTS idx_order_checks_order_id ON public.order_checks(order_id);
```

## 2. Missing Columns
`order_items` needs `check_id`.

```sql
ALTER TABLE public.order_items 
ADD COLUMN IF NOT EXISTS check_id uuid REFERENCES public.order_checks(id) ON DELETE SET NULL;
```

## 3. Required RPC Functions

### `fn_create_split_bill` (Improved)
Creates N *additional* checks for an order, automatically handling positioning to avoid duplicates.

```sql
create or replace function fn_create_split_bill(
    p_order_id uuid,
    p_number_of_checks int
)
returns setof order_checks
language plpgsql
as $$
declare
    v_i int;
    v_max_pos int;
begin
    -- Get current max position, default to 0
    select coalesce(max(position), 0) into v_max_pos
    from order_checks
    where order_id = p_order_id;

    -- Insert N checks starting from max_pos + 1
    for v_i in 1..p_number_of_checks loop
        insert into order_checks (order_id, label, position)
        values (
            p_order_id, 
            'Cuenta ' || (v_max_pos + v_i), 
            (v_max_pos + v_i)
        );
    end loop;

    return query select * from order_checks where order_id = p_order_id order by position;
end;
$$;
```

### `fn_move_item_to_check`
Moves an item (or part of it) to a check.

```sql
create or replace function fn_move_item_to_check(
    p_item_id uuid,
    p_check_position int -- 0 for unassigned
)
returns void
language plpgsql
as $$
declare
    v_check_id uuid;
begin
    if p_check_position = 0 then
        v_check_id := null;
    else
        select id into v_check_id 
        from order_checks 
        where id = (select order_id from order_items where id = p_item_id)
        and position = p_check_position;
    end if;

    update order_items set check_id = v_check_id where id = p_item_id;
    
    -- Recalculate check totals here or via trigger if implemented
end;
$$;
```

## 4. Gaps in Logic
- **Split by Custom Amount**: Current implementation supports Splitting by Item and Equal Split (distributing items). true "Custom (Arbitrary) Amount" split requires splitting line items or virtual payments, which is not fully covered.
- **Payment & Order Closure**: When a check is paid, the system verifies if `isLast`. Logic for `closeOrder` needs to ensure all checks are paid before closing the master `order`.
