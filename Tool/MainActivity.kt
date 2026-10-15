package app.vordoo.vordoo

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vordoo/intent").setMethodCallHandler { call, result ->
            if (call.method == "get") {
                val uri = intent?.data
                result.success(if (uri != null) contentResolver.openInputStream(uri)?.use { it.readBytes() } else null)
            } else {
                result.notImplemented()
            }
        }
    }
}
