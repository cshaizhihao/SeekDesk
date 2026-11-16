/// A document-relative location, independent of author metadata above it.
/// Pixels remain the fallback for old saved records and removed floors.
class ReaderBodyAnchor {
  const ReaderBodyAnchor({required this.floor, required this.dy});

  final String floor;
  final double dy;

  static ReaderBodyAnchor? parse(Object? value) {
    if (value is! Map) return null;
    final floor = value['floor'], dy = value['dy'];
    if (floor is! String ||
        floor.isEmpty ||
        floor.length > 12 ||
        floor.codeUnits.any((unit) => unit < 48 || unit > 57) ||
        dy is! num ||
        !dy.isFinite ||
        dy.abs() > 100000000) {
      return null;
    }
    return ReaderBodyAnchor(floor: floor, dy: dy.toDouble());
  }

  Map<String, Object> toJson() => {'floor': floor, 'dy': dy};
}
