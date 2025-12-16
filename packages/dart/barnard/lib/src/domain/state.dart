class BarnardState {
  const BarnardState({
    required this.isScanning,
    required this.isAdvertising,
  });

  static const idle = BarnardState(isScanning: false, isAdvertising: false);

  final bool isScanning;
  final bool isAdvertising;

  @override
  String toString() => "BarnardState(isScanning=$isScanning, isAdvertising=$isAdvertising)";
}
