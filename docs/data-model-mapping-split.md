# Data Model Mapping: Split Bill

## Frontend vs Backend

| Frontend Model | Backend Table | Notes |
|---|---|---|
| `Order` | `orders` | Master record. |
| `OrderItem` | `order_items` | Contains `check_id` foreign key. |
| `OrderCheck` | `order_checks` | Represents a sub-bill. Linked to Order. |
| `Payment` | `payments` | Linked to `order_id` AND `check_id` (new). |

## Relationships

1. **Order -> Checks**: One-to-Many.
2. **Check -> Items**: One-to-Many.
3. **Payemnt -> Check**: Many-to-One (Payment belongs to a check).

## Flow

1. **Open Split**: `fn_create_split_bill` creates rows in `order_checks`.
2. **Assign Items**: `fn_move_item_to_check` updates `check_id` in `order_items`.
3. **Calculate Totals**: Backend triggers or View (`order_checks_summary`) sums items by `check_id`.
4. **Pay**: `processPayment` receives `check_id`. Payment is recorded.
   - If `check.total` is fully paid, `check.is_closed = true`.
   - If all checks are closed, `order.status = 'paid'`.
