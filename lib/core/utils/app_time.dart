class AppTime {
  AppTime._();

  static const Duration astOffset = Duration(hours: -4);

  /// Hora actual de negocio en AST como fecha/hora de pared.
  static DateTime nowAst() => astFromInstant(DateTime.now());

  /// Convierte un instante real a su representación de pared en AST.
  static DateTime astFromInstant(DateTime instant) {
    final utc = instant.isUtc ? instant : instant.toUtc();
    final ast = utc.add(astOffset);
    return DateTime(
      ast.year,
      ast.month,
      ast.day,
      ast.hour,
      ast.minute,
      ast.second,
      ast.millisecond,
      ast.microsecond,
    );
  }

  static DateTime todayAstDate() {
    final now = nowAst();
    return DateTime(now.year, now.month, now.day);
  }

  static DateTime astToUtc(DateTime astDateTime) {
    return DateTime.utc(
      astDateTime.year,
      astDateTime.month,
      astDateTime.day,
      astDateTime.hour,
      astDateTime.minute,
      astDateTime.second,
      astDateTime.millisecond,
      astDateTime.microsecond,
    ).subtract(astOffset);
  }

  static String astToUtcIso(DateTime astDateTime) {
    return astToUtc(astDateTime).toIso8601String();
  }

  static ({DateTime fromUtc, DateTime toUtc}) astDayRangeUtc(DateTime astDay) {
    final fromAst = DateTime(astDay.year, astDay.month, astDay.day);
    final toAst = fromAst.add(const Duration(days: 1));
    return (fromUtc: astToUtc(fromAst), toUtc: astToUtc(toAst));
  }

  static ({DateTime fromUtc, DateTime toUtc}) todayRangeUtc() {
    return astDayRangeUtc(todayAstDate());
  }

  static DateTime? tryParseServerToAst(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return astFromInstant(value);

    final raw = value.toString().trim();
    if (raw.isEmpty) return null;

    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    return astFromInstant(parsed);
  }
}
