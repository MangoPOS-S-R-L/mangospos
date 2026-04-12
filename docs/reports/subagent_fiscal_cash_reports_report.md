# Subagent report — fiscal / cash reports UI

## Done
- Reworked **Impuestos** report into a cleaner fiscal dashboard with:
  - white cards
  - MangoPOS orange accents/actions
  - 10px corner radius
  - serious ledger-style detail rows
- Reworked **Cierres de caja** report with:
  - executive summary hero
  - real closure detail cards
  - expected vs reported comparison
  - visible cuadre/diferencia status per session
- Reworked **Detalle de cierre / cuadre** presentation inside the finance report using session-level closure cards.
- Reworked **Ventas por recibo / comprobante** direction inside fiscal reports so the UI now treats:
  - **date range** (top toolbar)
  - **tipo de comprobante** (local first-class filter chips)
  as primary filters.

## Data / logic added
- Extended `ReportsRepository.getCashSummary()` to return `cash_closures` with session-level detail:
  - cashier
  - register
  - expected cash/card/transfer/total
  - reported cash/card/transfer/total
  - difference
  - status / timestamps
- Added fiscal type filter state + helpers in `reports_viewmodel.dart`.

## Visual rules applied
Cristian’s hard rules were applied to the touched reports UI:
- white card backgrounds
- MangoPOS-colored buttons / primary accents
- no pill buttons
- 10px radius
- clean, serious layout language

## Validation
### Passed
- `flutter analyze lib/presentation/reports lib/data/repositories/reports_repository.dart`

### Could not complete in this environment
- `flutter test test/cashier`
- `flutter test test/cashier/blind_cash_close_calculator_test.dart`
- `flutter test test/cashier/cash_close_formatters_test.dart`

All of the above failed before executing assertions with the same host/runtime issue:
- `Resource deadlock avoided`
- failure while spawning `flutter_tester`

## Main files touched
- `lib/data/repositories/reports_repository.dart`
- `lib/presentation/reports/viewmodel/reports_viewmodel.dart`
- `lib/presentation/reports/view/reports_view.dart`
- `lib/presentation/reports/state/reports_state.dart`
