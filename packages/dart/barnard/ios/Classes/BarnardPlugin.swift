import Flutter
import Foundation

public final class BarnardPlugin: NSObject, FlutterPlugin {
  private let controller = BarnardBleController()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = BarnardPlugin()

    let methods = FlutterMethodChannel(name: "barnard/methods", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)

    let events = FlutterEventChannel(name: "barnard/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance.controller.eventsStreamHandler)

    let debugEvents = FlutterEventChannel(name: "barnard/debugEvents", binaryMessenger: registrar.messenger())
    debugEvents.setStreamHandler(instance.controller.debugEventsStreamHandler)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    controller.handle(call, result: result)
  }
}
