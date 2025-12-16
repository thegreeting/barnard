class RingBuffer<T> {
  RingBuffer(this.capacity) : assert(capacity > 0);

  final int capacity;
  final List<T?> _buffer = <T?>[];
  int _start = 0;
  int _length = 0;

  int get length => _length;

  void add(T value) {
    if (_buffer.isEmpty) {
      _buffer.addAll(List<T?>.filled(capacity, null));
    }

    final int index = (_start + _length) % capacity;
    _buffer[index] = value;
    if (_length < capacity) {
      _length += 1;
      return;
    }
    _start = (_start + 1) % capacity;
  }

  List<T> toList({int? limit}) {
    final int effectiveLimit = limit == null ? _length : limit.clamp(0, _length);
    final List<T> out = <T>[];
    final int startIndex = (_length - effectiveLimit);
    for (int i = 0; i < effectiveLimit; i++) {
      final int idx = (_start + startIndex + i) % capacity;
      final T? v = _buffer[idx];
      if (v != null) out.add(v);
    }
    return out;
  }
}
