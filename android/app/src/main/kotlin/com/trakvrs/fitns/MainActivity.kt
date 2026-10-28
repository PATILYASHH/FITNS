package com.trakvrs.fitns

import android.Manifest
import android.content.Intent
import android.hardware.Sensor
import android.hardware.SensorManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the sensor bridges. No plugins: a step counter, an accelerometer and
 * a proximity sensor are a few hundred lines here, where a plugin would bring
 * Google Play Services or a dependency F-Droid has to vet.
 *
 * Channel names must match `lib/core/steps/step_sensor.dart` and
 * `lib/core/motion/motion_sensors.dart` byte for byte — no test can cover
 * the pairing.
 */
class MainActivity : FlutterActivity() {
    private var pendingPermission: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val sensors = getSystemService(SENSOR_SERVICE) as SensorManager

        MethodChannel(messenger, STEP_METHODS).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(status(sensors))
                "requestPermission" -> requestPermission(sensors, result)
                // Once the user has said "don't ask again", only the app's
                // system settings page can grant it.
                "openSettings" -> {
                    startActivity(
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.fromParts("package", packageName, null),
                        ),
                    )
                    result.success(null)
                }
                "setBackgroundCounting" -> {
                    val on = call.arguments as? Boolean ?: false
                    StepLog.setAllDay(this, on)
                    if (on) StepCounterService.start(this) else StepCounterService.stop(this)
                    result.success(null)
                }
                "drainLog" -> result.success(StepLog.drain(this))
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, STEP_EVENTS).setStreamHandler(StepCounterStream(sensors))

        MethodChannel(messenger, MOTION_METHODS).setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(
                    mapOf(
                        "accelerometer" to (sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) != null),
                        "proximity" to (sensors.getDefaultSensor(Sensor.TYPE_PROXIMITY) != null),
                    ),
                )
                // While counting reps the phone sits in a pocket or on the
                // floor; a screen timeout would stop the sensors with it.
                "keepScreenOn" -> {
                    if (call.arguments as? Boolean == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // 100 Hz: a landing impact lasts only a few tens of milliseconds.
        EventChannel(messenger, ACCELEROMETER_EVENTS)
            .setStreamHandler(MotionStream(sensors, Sensor.TYPE_ACCELEROMETER, 10_000))
        EventChannel(messenger, PROXIMITY_EVENTS)
            .setStreamHandler(MotionStream(sensors, Sensor.TYPE_PROXIMITY, SensorManager.SENSOR_DELAY_GAME))
    }

    /** `unavailable` (no sensor), `denied` or `granted`. */
    private fun status(sensors: SensorManager): String = when {
        sensors.getDefaultSensor(Sensor.TYPE_STEP_COUNTER) == null -> "unavailable"
        StepCounterService.canCount(this) -> "granted"
        else -> "denied"
    }

    private fun requestPermission(sensors: SensorManager, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || StepCounterService.canCount(this)) {
            result.success(status(sensors))
            return
        }
        // A second request while the dialog is up would orphan the first.
        pendingPermission?.success(status(sensors))
        pendingPermission = result
        requestPermissions(arrayOf(Manifest.permission.ACTIVITY_RECOGNITION), PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PERMISSION_REQUEST) return
        val sensors = getSystemService(SENSOR_SERVICE) as SensorManager
        pendingPermission?.success(status(sensors))
        pendingPermission = null
    }

    companion object {
        private const val STEP_METHODS = "fitns/steps"
        private const val STEP_EVENTS = "fitns/steps/events"
        private const val MOTION_METHODS = "fitns/motion"
        private const val ACCELEROMETER_EVENTS = "fitns/motion/accelerometer"
        private const val PROXIMITY_EVENTS = "fitns/motion/proximity"
        private const val PERMISSION_REQUEST = 4101
    }
}
