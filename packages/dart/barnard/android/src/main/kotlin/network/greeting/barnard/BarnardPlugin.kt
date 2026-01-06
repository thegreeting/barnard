package network.greeting.barnard

import io.flutter.embedding.engine.plugins.FlutterPlugin

class BarnardPlugin : FlutterPlugin {
    private var controller: BarnardController? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        controller = BarnardController(binding.applicationContext, binding.binaryMessenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        controller?.dispose()
        controller = null
    }
}

