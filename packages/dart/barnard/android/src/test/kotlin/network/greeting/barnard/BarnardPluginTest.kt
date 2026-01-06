package network.greeting.barnard

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test

/*
 * This demonstrates a simple unit test of the Kotlin portion of this plugin's implementation.
 *
 * Once you have built the plugin's example app, you can run these tests from the command
 * line by running `./gradlew testDebugUnitTest` in the `example/android/` directory, or
 * you can run them directly from IDEs that support JUnit such as Android Studio.
 */

internal class BarnardPluginTest {
    @Test
    fun onMethodCall_getCapabilities_returnsMap() {
        val context = Mockito.mock(android.content.Context::class.java)
        val prefs = Mockito.mock(android.content.SharedPreferences::class.java)
        val manager = Mockito.mock(android.bluetooth.BluetoothManager::class.java)

        Mockito.`when`(context.getSharedPreferences("barnard", android.content.Context.MODE_PRIVATE)).thenReturn(prefs)
        Mockito.`when`(context.getSystemService(android.content.Context.BLUETOOTH_SERVICE)).thenReturn(manager)

        val messenger = Mockito.mock(io.flutter.plugin.common.BinaryMessenger::class.java)

        val controller = BarnardController(context, messenger)
        val call = MethodCall("getCapabilities", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        controller.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).success(Mockito.anyMap<String, Any>())
    }
}
