abstract class SplitLogic {
  /// Distributes [items] equally into [numberOfChecks] checks.
  /// Returns a map of check index to list of items.
  static Map<int, List<String>> distributeEqually(
    List<String> itemIds,
    int numberOfChecks,
  ) {
    // Logic moved to Backend/ViewModel but kept here for domain purity reference.
    if (numberOfChecks < 1) return {};
    final distribution = <int, List<String>>{};

    int checkIndex = 0;
    for (final id in itemIds) {
      if (!distribution.containsKey(checkIndex)) {
        distribution[checkIndex] = [];
      }
      distribution[checkIndex]!.add(id);
      checkIndex = (checkIndex + 1) % numberOfChecks;
    }
    return distribution;
  }

  /// Validates if a split configuration is complete (all items assigned).
  static bool validateSplit(int totalItems, int assignedItems) {
    return totalItems == assignedItems;
  }
}
