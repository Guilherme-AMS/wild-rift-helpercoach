package com.riftHelper.wildrift_helper

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rift/overlay")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canDraw" -> result.success(
                        Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(this)
                    )
                    "requestPermission" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")
                            )
                        )
                        result.success(null)
                    }
                    "start" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 11)
                        }
                        OverlayService.pendingJson = call.argument<String>("json")
                        OverlayService.pendingGuides = call.argument<String>("guides")
                        val i = Intent(this, OverlayService::class.java)
                            .setAction(OverlayService.ACTION_START)
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
                        result.success(true)
                    }
                    "stop" -> {
                        startService(
                            Intent(this, OverlayService::class.java)
                                .setAction(OverlayService.ACTION_STOP)
                        )
                        result.success(null)
                    }
                    "isRunning" -> result.success(OverlayService.running)
                    else -> result.notImplemented()
                }
            }
    }
}
