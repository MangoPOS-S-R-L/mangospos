class Zone {
  final String id;
  final String name;
  final int sortIndex;
  Zone({required this.id, required this.name, required this.sortIndex});
  factory Zone.fromMap(Map<String,dynamic> j) =>
    Zone(id: j['id'], name: j['name'], sortIndex: (j['sort_index']??0));
}
