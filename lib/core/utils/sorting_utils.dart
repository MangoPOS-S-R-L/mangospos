// lib/core/utils/sorting_utils.dart

class SortingUtils {
  /// Realiza una comparación natural de strings (ej: 'Mesa 2' < 'Mesa 10').
  static int naturalCompare(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 0;
    if (a.isEmpty) return -1;
    if (b.isEmpty) return 1;

    final RegExp re = RegExp(r'(\d+)|(\D+)');
    final List<String> partsA = re.allMatches(a).map((m) => m.group(0)!).toList();
    final List<String> partsB = re.allMatches(b).map((m) => m.group(0)!).toList();

    final int len = partsA.length < partsB.length ? partsA.length : partsB.length;

    for (int i = 0; i < len; i++) {
      final String partA = partsA[i];
      final String partB = partsB[i];

      final bool isDigitA = _isDigit(partA[0]);
      final bool isDigitB = _isDigit(partB[0]);

      if (isDigitA && isDigitB) {
        final BigInt? nA = BigInt.tryParse(partA);
        final BigInt? nB = BigInt.tryParse(partB);
        if (nA != null && nB != null) {
          if (nA != nB) return nA.compareTo(nB);
        } else {
          // Fallback if numbers are somehow too large or malformed
          final int res = partA.compareTo(partB);
          if (res != 0) return res;
        }
      } else {
        final int res = partA.toLowerCase().compareTo(partB.toLowerCase());
        if (res != 0) return res;
      }
    }

    return partsA.length.compareTo(partsB.length);
  }

  static bool _isDigit(String char) {
    return char.codeUnitAt(0) >= 48 && char.codeUnitAt(0) <= 57;
  }
}
