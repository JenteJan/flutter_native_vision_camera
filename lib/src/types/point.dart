/// Represents a 2D point in a coordinate system.
///
/// Used for tap-to-focus and code scanner corner positions.
///
/// Maps to `Point` from react-native-vision-camera.
class Point {
  /// The X coordinate.
  final double x;

  /// The Y coordinate.
  final double y;

  /// Creates a [Point] with the given coordinates.
  const Point({required this.x, required this.y});

  /// Deserializes a [Point] from a platform map.
  factory Point.fromMap(Map<String, dynamic> map) {
    return Point(
      x: (map['x'] as num).toDouble(),
      y: (map['y'] as num).toDouble(),
    );
  }

  /// Serializes this point to a map.
  Map<String, dynamic> toMap() => {'x': x, 'y': y};

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Point && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Point($x, $y)';
}
