# USB printing readiness report — comandas + precuentas

## What was finalized

### 1) The existing local-agent path is now the real USB path for operational tickets
No parallel architecture was added. The current stack stays:

`tablet / web / desktop -> PrintingRepository / PrintingService -> LocalPrintService -> MangoPOS Agent -> USB printer`

Completed in app code:
- `LocalPrintService` now resolves assigned printers by multiple identifiers (`id`, `ip:port`, `device_path`, `mac`).
- `PrintingRepository.printEscPos(...)` now uses the local agent for USB on Web and falls back to the agent on native/desktop if direct USB fails.
- `PrintingRepository.printRawViaAgentToPrinter(...)` was added so assigned USB printers can receive raw ESC/POS through the same repository path already used by kitchen/prebill flows.

### 2) Kitchen routing for commandas was closed end-to-end
In `PrintingService`:
- kitchen items still route by `print_area_code`
- each area still resolves its assigned printers from `print_area_printers`
- USB printers now print through the local agent on Web
- native/local USB still tries direct print first and falls back to the agent
- partial-success behavior remains safe: if one printer for an area succeeds, the kitchen dispatch is treated as printed and the rest are logged as partial failures

This keeps the existing area-based routing model intact for waiter/tablet send-to-kitchen flows.

### 3) Precuentas / prebills now follow the same assigned-printer path
The table-order precheck flow already resolved an assigned printer via `getAssignedPrinterForType(...)` and printed ESC/POS through `printEscPos(...)`.

Because `printEscPos(...)` now supports USB through the local agent, precuentas now use the same production path as kitchen tickets instead of a separate implementation.

### 4) Cash-close routing priority was corrected
A miswiring remained in cashier close printing: the lookup order still preferred `cashier` before `cash_close`.

That was fixed so cash-close tickets now prefer the dedicated `cash_close` area first.

### 5) Assigned-printer resolution inside the Node agent was fixed
This was the main remaining runtime gap.

Before this fix, the app could send an assigned USB printer to the local agent, but the agent only resolved printers from its own config by matching `printerId` exactly (or `ip:port` for network printers). That meant a MangoPOS-assigned USB printer could still fail if the agent config used a different identifier.

Now the agent:
- accepts inline printer metadata on `/print`
- refreshes configured printers from runtime config instead of keeping a stale startup snapshot
- resolves a configured printer by multiple identifiers, including:
  - `id`
  - `endpoint`
  - `name`
  - `ip` / `ipAddress`
  - `devicePath` / `device_path`
  - `mac`
  - `portName` / `port_name`
  - derived `ip:port`
- falls back to the inline printer object from MangoPOS if no configured printer matches

This was applied to both agent codepaths present in the repo:
- `agent/src/...`
- `agent/MangoPOS-Agent/src/...`

### 6) USB labels/config UX was polished
To reduce setup mistakes in the printing settings UI:
- USB assignment cards now show USB/device identifiers instead of misleading MAC/IP-only labels
- receipt assignment UI distinguishes precuenta vs receipt printer assignments more clearly
- printer configuration hints were updated so USB users understand what value belongs in the identifier field
- settings test-print now supports USB on Web through the local agent path

## What still must be manually configured on the business PC

These are still real-world deployment steps; code alone cannot do them automatically.

1. **Run the MangoPOS local agent on the same PC where the USB printer is physically connected.**
2. **Use the same agent token that the app expects** (default in repo is `MANGOPOS_SECURE_TOKEN_123` unless deployment overrides it).
3. **Verify the agent is reachable locally** on one of the supported ports (`9100` is the main target).
4. **Make sure the USB printer is visible to the OS and can print locally**.
5. **If there are multiple USB printers on the same PC, verify each one resolves consistently**:
   - preferred: keep the agent printer config/discovery aligned with the real printer names/endpoints
   - minimum: confirm each assigned printer prints to the correct physical device during test prints
6. **In MangoPOS settings, assign printers intentionally**:
   - kitchen areas: printers with `prints_orders = true`
   - `cashier`: printer with `prints_prebills = true`
   - `fiscal`: printer with `prints_receipts = true`
   - `cash_close`: printer with `prints_receipts = true` for close tickets
7. **Verify every product has the correct `print_area_code`**; otherwise kitchen items fall back to `kitchen_hot`.

## Exact smoke-test steps: tablet -> PC -> USB printer

### A. Agent and USB readiness on the business PC
1. Connect the USB printer to the business PC.
2. Start the MangoPOS local agent.
3. Confirm `http://127.0.0.1:9100/status` responds.
4. In MangoPOS printing settings on that same environment, run a **test print** against the USB printer.
5. Confirm the paper output comes from the expected physical printer.

### B. Kitchen comanda from waiter tablet
1. In printing settings, assign a USB printer to `kitchen_hot` (or the target kitchen area) with **orders/comandas enabled**.
2. Ensure at least one product used in the test order has that same `print_area_code`.
3. From the waiter/tablet flow, create/open a table.
4. Add one or more products for that kitchen area.
5. Send the order to kitchen.
6. Verify on the PC-connected USB printer:
   - a comanda prints
   - only the items for that kitchen area print
   - table name is correct
   - waiter name is correct
   - there is no duplicate print on the wrong printer

### C. Mixed-area routing test
1. Assign a second area (for example `bar` or `kitchen_cold`) to a different printer.
2. Create one order containing items from both areas.
3. Send to kitchen.
4. Verify:
   - printer A receives only area A items
   - printer B receives only area B items
   - no cross-printing happens

### D. Precuenta from waiter/tablet
1. Assign the target USB printer to the `cashier` area with **prebills/precuentas enabled**.
2. Open a table with a few items.
3. From the table/order screen, print **precuenta**.
4. Verify on the USB printer:
   - the precuenta prints successfully
   - table and waiter are correct
   - items and totals are correct
   - the print uses the assigned precuenta printer, not a kitchen printer

### E. Final receipt / invoice sanity check
1. Assign the receipt printer to `fiscal` with receipts enabled.
2. Print/reprint a final receipt.
3. Confirm it does **not** hijack the precuenta printer unless intentionally configured that way.

### F. Cash-close sanity check
1. Assign a printer to `cash_close` with receipts enabled.
2. Print a cash-close ticket.
3. Confirm it prefers the `cash_close` printer before the general cashier receipt printer.

### G. Failure behavior check
1. Stop the local agent on the PC.
2. From a Web/tablet flow, try to print to an assigned USB printer.
3. Verify the app shows a clear agent-required error and does not pretend the print succeeded.
4. Start the agent again and retry.
5. Confirm printing recovers without changing MangoPOS assignments.

## Validation performed
- `flutter analyze` on all touched Flutter printing/settings/cashier files: **passed**
- `node --check` on both agent variants (`agent/src/...` and `agent/MangoPOS-Agent/src/...`): **passed**
- `flutter test test/sales/print_ticket_service_test.dart`: not reliable in this environment due Flutter runner process error (`Resource deadlock avoided`), so no trustworthy automated result from that command

## Files changed
- `lib/core/services/local_print_service.dart`
- `lib/data/repositories/printing_repository.dart`
- `lib/data/repositories/printing_service.dart`
- `lib/presentation/cashier/services/print_service.dart`
- `lib/presentation/settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart`
- `lib/presentation/settings/more settings/printing/receipts/view/printing_receipts_view.dart`
- `lib/presentation/settings/more settings/printing/widgets/area_assignments_page.dart`
- `lib/presentation/settings/more settings/printing/widgets/printer_configuration_dialog.dart`
- `agent/src/api/server.js`
- `agent/src/core/printer_manager.js`
- `agent/MangoPOS-Agent/src/api/server.js`
- `agent/MangoPOS-Agent/src/core/printer_manager.js`
