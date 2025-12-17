import Flutter
import Foundation

final class BarnardStreamHandler: NSObject, FlutterStreamHandler {
  var onListen: ((@escaping FlutterEventSink) -> Void)?
  var onCancel: (() -> Void)?

  func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    onListen?(events)
    return nil
  }

  func onCancel(withArguments _: Any?) -> FlutterError? {
    onCancel?()
    return nil
  }
}

