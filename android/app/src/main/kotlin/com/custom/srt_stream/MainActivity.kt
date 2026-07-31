package com.custom.srt_stream

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.app.PendingIntent
import android.os.Bundle
import android.os.IBinder
import android.view.SurfaceHolder
import android.content.pm.ActivityInfo
import com.pedro.common.ConnectChecker
import com.pedro.library.view.OpenGlView
import com.pedro.library.base.Camera2Base
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity(), ConnectChecker {
    private val CHANNEL = "com.custom.srt_stream/control"
    private var methodChannel: MethodChannel? = null
    
    private var openGlView: OpenGlView? = null
    private var streamingService: StreamingForegroundService? = null
    private var isBound = false

    private var targetWidth = 1280
    private var targetHeight = 720
    private var targetBitrate = 2000000
    private var targetFps = 30
    private var streamType = "rtmp"
    private var lastAppliedZoom = 1.0f

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            val binder = service as StreamingForegroundService.LocalBinder
            streamingService = binder.getService()
            isBound = true
            
            openGlView?.let { view ->
                streamingService?.initCamera(view, this@MainActivity, streamType)
                streamingService?.updateOrientation()
                startPreviewWhenSurfaceReady(view)
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            streamingService = null
            isBound = false
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep screen permanently awake while the app is active
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // Allow dynamic orientation switching via Flutter SystemChrome per view
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Register the platform view under the channel ID so Flutter can render openGlView
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "com.custom.srt_stream/video_view",
            SrtVideoViewFactory(this)
        )

        flutterEngine.platformViewsController.registry.registerViewFactory(
            "com.custom.srt_stream/pip_view",
            PipVideoViewFactory(this)
        )

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            handleMethodCall(call, result)
        }
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initStream" -> {
                targetWidth = call.argument<Int>("width") ?: 1280
                targetHeight = call.argument<Int>("height") ?: 720
                targetBitrate = call.argument<Int>("bitrate") ?: 2000000
                targetFps = call.argument<Int>("fps") ?: 30
                streamType = call.argument<String>("streamType") ?: "rtmp"
                val ipVersion = call.argument<String>("ipVersion") ?: "ipv4"

                // Configure JVM socket resolution for IPv4 or IPv6
                if (ipVersion == "ipv6") {
                    System.setProperty("java.net.preferIPv4Stack", "false")
                    System.setProperty("java.net.preferIPv6Addresses", "true")
                } else {
                    System.setProperty("java.net.preferIPv4Stack", "true")
                    System.setProperty("java.net.preferIPv6Addresses", "false")
                }

                // Spin up and bind our Foreground Service to keep streaming alive in background
                StreamingForegroundService.startService(this)
                val intent = Intent(this, StreamingForegroundService::class.java)
                bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
                
                result.success(true)
            }
            "startStream" -> {
                val url = call.argument<String>("url")
                if (url == null) {
                    result.error("INVALID_URL", "Stream URL is required", null)
                    return
                }

                val view = openGlView
                if (view == null || view.holder.surface?.isValid != true) {
                    result.error("SURFACE_NOT_READY", "Camera preview surface is not ready yet", null)
                    return
                }

                if (isBound && streamingService != null) {
                    val errorMsg = streamingService!!.startStream(
                        url, targetWidth, targetHeight, targetBitrate, targetFps
                    )
                    if (errorMsg == null) {
                        result.success(true)
                    } else {
                        result.error("STREAM_START_FAILED", errorMsg, null)
                    }
                } else {
                    result.error("SERVICE_NOT_READY", "Streaming service not initialized or bound yet", null)
                }
            }
            "stopStream" -> {
                if (isBound && streamingService != null) {
                    streamingService?.stopStream()
                }
                result.success(true)
            }
            "closeStream" -> {
                if (isBound && streamingService != null) {
                    streamingService?.stopStream()
                    streamingService?.releaseCamera()
                }
                if (isBound) {
                    unbindService(serviceConnection)
                    isBound = false
                }
                StreamingForegroundService.stopService(this)
                result.success(true)
            }
            "switchCamera" -> {
                val rawCameraId = call.argument<String>("cameraId")
                if (isBound && streamingService != null) {
                    val camera = StreamingForegroundService.camera
                    if (camera != null) {
                        try {
                            // Resolve synthetic usb_ IDs to real Camera2 external IDs
                            val targetId = if (rawCameraId != null && rawCameraId.startsWith("usb_")) {
                                resolveExternalCameraId(rawCameraId)
                            } else {
                                rawCameraId
                            }

                            // If this is a USB/external camera, check USB host permission first
                            if (rawCameraId != null && rawCameraId.startsWith("usb_")) {
                                val usbDeviceId = rawCameraId.removePrefix("usb_").toIntOrNull()
                                if (usbDeviceId != null) {
                                    val usbManager = getSystemService(Context.USB_SERVICE) as? android.hardware.usb.UsbManager
                                    val usbDevice = usbManager?.deviceList?.values?.find { it.deviceId == usbDeviceId }
                                    if (usbDevice != null && usbManager != null && !usbManager.hasPermission(usbDevice)) {
                                        // Request USB permission — user will need to re-tap after granting
                                        val permIntent = PendingIntent.getBroadcast(
                                            this, 0,
                                            Intent("com.custom.srt_stream.USB_PERMISSION"),
                                            PendingIntent.FLAG_IMMUTABLE
                                        )
                                        usbManager.requestPermission(usbDevice, permIntent)
                                        result.error("USB_PERMISSION_REQUIRED",
                                            "USB permission requested. Please grant permission and try again.", null)
                                        return
                                    }
                                }
                            }

                            if (targetId != null) {
                                android.util.Log.d("MainActivity", "Switching camera to: $targetId (from: $rawCameraId)")
                                camera.switchCamera(targetId)
                            } else {
                                camera.switchCamera()
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            android.util.Log.e("MainActivity", "switchCamera failed for '$rawCameraId': ${e.message}", e)
                            // Fallback: try to recover by switching to the default back camera
                            try {
                                camera.switchCamera("0")
                                android.util.Log.w("MainActivity", "Fell back to default camera '0' after switch failure")
                            } catch (_: Exception) {}
                            result.error("CAMERA_SWITCH_FAILED",
                                "Failed to switch to camera '$rawCameraId': ${e.message}", null)
                        }
                    } else {
                        result.error("CAMERA_NULL", "Camera is not initialized", null)
                    }
                } else {
                    result.error("SERVICE_NOT_READY", "Streaming service is not active", null)
                }
            }
            "enableAudio" -> {
                if (isBound && streamingService != null) {
                    streamingService?.enableAudio()
                    result.success(true)
                } else {
                    result.error("SERVICE_NOT_READY", "Streaming service is not active", null)
                }
            }
            "disableAudio" -> {
                if (isBound && streamingService != null) {
                    streamingService?.disableAudio()
                    result.success(true)
                } else {
                    result.error("SERVICE_NOT_READY", "Streaming service is not active", null)
                }
            }
            "isAudioEnabled" -> {
                if (isBound && streamingService != null) {
                    result.success(streamingService?.isAudioEnabled == true)
                } else {
                    result.success(true)
                }
            }
            "toggleFlashlight" -> {
                if (isBound && streamingService != null) {
                    val isLightOn = streamingService?.toggleFlashlight() ?: false
                    result.success(isLightOn)
                } else {
                    result.error("SERVICE_NOT_READY", "Streaming service is not active", null)
                }
            }
            "setVideoBitrate" -> {
                val bitrate = call.argument<Int>("bitrate") ?: 2000000
                if (isBound && streamingService != null) {
                    streamingService?.setVideoBitrateOnFly(bitrate)
                    result.success(true)
                } else {
                    result.error("SERVICE_NOT_READY", "Streaming service is not active", null)
                }
            }
            "getNetworkType" -> {
                try {
                    val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
                    val activeNetwork = cm.activeNetwork
                    val caps = cm.getNetworkCapabilities(activeNetwork)
                    if (caps != null) {
                        when {
                            caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) -> result.success("Wi-Fi")
                            caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) -> result.success("5G/4G")
                            caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET) -> result.success("LAN")
                            else -> result.success("Online")
                        }
                    } else {
                        result.success("Offline")
                    }
                } catch (_: Exception) {
                    result.success("Cellular")
                }
            }
            "getAudioInputs" -> {
                try {
                    val audioManager = getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
                    val inputDevices = mutableListOf<Map<String, String>>()
                    
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                        val devices = audioManager.getDevices(android.media.AudioManager.GET_DEVICES_INPUTS)
                        for (dev in devices) {
                            val typeName = when (dev.type) {
                                android.media.AudioDeviceInfo.TYPE_BUILTIN_MIC -> "Built-in Microphone"
                                android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO, android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth Headset"
                                android.media.AudioDeviceInfo.TYPE_USB_DEVICE, android.media.AudioDeviceInfo.TYPE_USB_HEADSET -> "USB Audio Interface"
                                android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Wired Headset Mic"
                                else -> "Audio Input (${dev.type})"
                            }
                            val name = dev.productName.toString().ifEmpty { typeName }
                            inputDevices.add(mapOf(
                                "id" to dev.id.toString(),
                                "name" to name,
                                "type" to typeName
                            ))
                        }
                    }
                    if (inputDevices.isEmpty()) {
                        inputDevices.add(mapOf("id" to "0", "name" to "Internal Mic Array", "type" to "Built-in Microphone"))
                    }
                    result.success(inputDevices)
                } catch (e: Exception) {
                    result.success(listOf(mapOf("id" to "0", "name" to "Internal Mic Array", "type" to "Built-in Microphone")))
                }
            }
            "tapToFocus" -> {
                val x = call.argument<Double>("x")?.toFloat() ?: 0f
                val y = call.argument<Double>("y")?.toFloat() ?: 0f
                val view = openGlView
                if (isBound && streamingService != null && view != null) {
                    val focused = streamingService?.tapToFocus(view, x, y) ?: false
                    result.success(focused)
                } else {
                    result.error("SERVICE_NOT_READY", "Streaming service or view is not active", null)
                }
            }
            "setExposure" -> {
                val exposure = call.argument<Int>("exposure") ?: 0
                if (isBound && streamingService != null) {
                    streamingService?.setExposure(exposure)
                    result.success(true)
                } else {
                    result.error("SERVICE_NOT_READY", "Streaming service is not active", null)
                }
            }
            "getExposureRange" -> {
                if (isBound && streamingService != null) {
                    result.success(streamingService?.getExposureRange())
                } else {
                    result.success(mapOf("min" to 0, "max" to 0, "current" to 0))
                }
            }
            "setZoom" -> {
                val zoom = call.argument<Double>("zoom")?.toFloat() ?: 1.0f
                if (isBound && streamingService != null) {
                    val camera = StreamingForegroundService.camera
                    if (camera != null) {
                        try {
                            if (kotlin.math.abs(zoom - lastAppliedZoom) >= 0.02f) {
                                lastAppliedZoom = zoom
                                camera.setZoom(zoom)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ZOOM_ERROR", e.message, null)
                        }
                    } else {
                        result.error("CAMERA_NULL", "Camera is not initialized", null)
                    }
                } else {
                    result.error("SERVICE_NOT_READY", "Streaming service is not active", null)
                }
            }
            "getZoomRange" -> {
                if (isBound && streamingService != null) {
                    val camera = StreamingForegroundService.camera
                    if (camera != null) {
                        try {
                            val range = camera.zoomRange
                            result.success(mapOf(
                                "min" to (range?.lower ?: 1.0f).toDouble(),
                                "max" to (range?.upper ?: 10.0f).toDouble()
                            ))
                        } catch (_: Exception) {
                            result.success(mapOf("min" to 1.0, "max" to 10.0))
                        }
                    } else {
                        result.success(mapOf("min" to 1.0, "max" to 10.0))
                    }
                } else {
                    result.success(mapOf("min" to 1.0, "max" to 10.0))
                }
            }
            "getAvailableCameras" -> {
                try {
                    val cameraManager = getSystemService(Context.CAMERA_SERVICE) as android.hardware.camera2.CameraManager
                    val resultList = mutableListOf<Map<String, String>>()
                    val processedIds = mutableSetOf<String>()

                    for (id in cameraManager.cameraIdList) {
                        val characteristics = cameraManager.getCameraCharacteristics(id)
                        
                        // On Android P (API 28+), inspect physical camera IDs behind logical multi-cameras
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                            val physicalCameraIds = characteristics.physicalCameraIds
                            if (physicalCameraIds.isNotEmpty()) {
                                for (physicalId in physicalCameraIds) {
                                    if (!processedIds.contains(physicalId)) {
                                        try {
                                            val physDetails = extractCameraDetails(cameraManager, physicalId, isPhysical = true)
                                            resultList.add(physDetails)
                                            processedIds.add(physicalId)
                                        } catch (_: Exception) {}
                                    }
                                }
                            }
                        }

                        if (!processedIds.contains(id)) {
                            try {
                                val details = extractCameraDetails(cameraManager, id, isPhysical = false)
                                resultList.add(details)
                                processedIds.add(id)
                            } catch (_: Exception) {}
                        }
                    }

                    // Also scan USB OTG host hardware bus for external USB webcams (e.g. Logitech Brio 100)
                    // for Android ROMs (Oppo, iQOO, Xiaomi) that hide external cameras from CameraManager.cameraIdList.
                    // We cross-reference USB video devices with Camera2 LENS_FACING_EXTERNAL entries to provide
                    // the real Camera2 ID (not a synthetic one) so switchCamera() works correctly.
                    try {
                        val usbManager = getSystemService(Context.USB_SERVICE) as? android.hardware.usb.UsbManager
                        val deviceList = usbManager?.deviceList
                        if (deviceList != null) {
                            // Pre-collect all Camera2 external-facing camera IDs for cross-referencing
                            val externalCamera2Ids = mutableListOf<String>()
                            for (camId in cameraManager.cameraIdList) {
                                try {
                                    val chars = cameraManager.getCameraCharacteristics(camId)
                                    val facing = chars.get(android.hardware.camera2.CameraCharacteristics.LENS_FACING)
                                    if (facing == android.hardware.camera2.CameraMetadata.LENS_FACING_EXTERNAL) {
                                        externalCamera2Ids.add(camId)
                                    }
                                } catch (_: Exception) {}
                            }

                            for ((_, device) in deviceList) {
                                var isVideoDevice = device.deviceClass == 14 // USB_CLASS_VIDEO (0x0E)
                                if (!isVideoDevice) {
                                    for (i in 0 until device.interfaceCount) {
                                        if (device.getInterface(i).interfaceClass == 14) {
                                            isVideoDevice = true
                                            break
                                        }
                                    }
                                }
                                if (isVideoDevice) {
                                    // Try to find a matching Camera2 external ID that isn't already listed
                                    val matchedCamera2Id = externalCamera2Ids.firstOrNull { !processedIds.contains(it) }

                                    if (matchedCamera2Id != null && !processedIds.contains(matchedCamera2Id)) {
                                        // Use the REAL Camera2 ID — this is what Camera2Base.switchCamera() needs
                                        try {
                                            val realDetails = extractCameraDetails(cameraManager, matchedCamera2Id, isPhysical = true)
                                            val productName = device.productName ?: "External USB Webcam"
                                            val enrichedDetails = realDetails.toMutableMap()
                                            enrichedDetails["lensType"] = "$productName (USB OTG)"
                                            enrichedDetails["vendorId"] = device.vendorId.toString()
                                            enrichedDetails["productId"] = device.productId.toString()
                                            enrichedDetails["usbDeviceId"] = device.deviceId.toString()
                                            resultList.add(enrichedDetails)
                                            processedIds.add(matchedCamera2Id)
                                            externalCamera2Ids.remove(matchedCamera2Id)
                                        } catch (_: Exception) {}
                                    } else {
                                        // Fallback: no Camera2 external entry found — use synthetic USB ID
                                        // (this camera likely won't be switchable via Camera2, but we still show it)
                                        val usbId = "usb_${device.deviceId}"
                                        if (!processedIds.contains(usbId)) {
                                            val productName = device.productName ?: "External USB Webcam"
                                            val webcamDetails = mapOf(
                                                "id" to usbId,
                                                "facing" to "External",
                                                "maxWidth" to "1920",
                                                "maxHeight" to "1080",
                                                "hasAutoFocus" to "true",
                                                "sensorOrientation" to "0",
                                                "lensType" to "$productName (USB OTG)",
                                                "fovDegrees" to "90",
                                                "focalLength" to "3.6",
                                                "isPhysical" to "true",
                                                "vendorId" to device.vendorId.toString(),
                                                "productId" to device.productId.toString(),
                                                "usbDeviceId" to device.deviceId.toString()
                                            )
                                            resultList.add(webcamDetails)
                                            processedIds.add(usbId)
                                        }
                                    }
                                }
                            }
                        }
                    } catch (_: Exception) {}

                    result.success(resultList)
                } catch (e: Exception) {
                    result.error("CAMERA_ERROR", e.message, null)
                }
            }
            "installApk" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_PATH", "APK path is required", null)
                    return
                }
                try {
                    val file = java.io.File(path)
                    if (!file.exists()) {
                        result.error("FILE_NOT_FOUND", "APK file not found at: $path", null)
                        return
                    }

                    val uri = androidx.core.content.FileProvider.getUriForFile(
                        this,
                        "${applicationContext.packageName}.fileprovider",
                        file
                    )

                    val installIntent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, "application/vnd.android.package-archive")
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION
                    }
                    startActivity(installIntent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("INSTALL_FAILED", e.message, null)
                }
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    private fun extractCameraDetails(
        cameraManager: android.hardware.camera2.CameraManager,
        id: String,
        isPhysical: Boolean
    ): Map<String, String> {
        val characteristics = cameraManager.getCameraCharacteristics(id)
        val facing = characteristics.get(android.hardware.camera2.CameraCharacteristics.LENS_FACING)
        val facingStr = when (facing) {
            android.hardware.camera2.CameraMetadata.LENS_FACING_FRONT -> "Front"
            android.hardware.camera2.CameraMetadata.LENS_FACING_BACK -> "Back"
            android.hardware.camera2.CameraMetadata.LENS_FACING_EXTERNAL -> "External"
            else -> "Unknown"
        }

        // Get max supported resolution
        val streamConfigMap = characteristics.get(
            android.hardware.camera2.CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP
        )
        val outputSizes = streamConfigMap?.getOutputSizes(android.graphics.SurfaceTexture::class.java)
        var maxWidth = 0
        var maxHeight = 0
        outputSizes?.forEach { size ->
            if (size.width * size.height > maxWidth * maxHeight) {
                maxWidth = size.width
                maxHeight = size.height
            }
        }

        // Check autofocus support
        val afModes = characteristics.get(
            android.hardware.camera2.CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES
        )
        val hasAutoFocus = afModes?.any {
            it == android.hardware.camera2.CameraMetadata.CONTROL_AF_MODE_AUTO ||
            it == android.hardware.camera2.CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_VIDEO ||
            it == android.hardware.camera2.CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_PICTURE
        } ?: false

        // Get sensor orientation
        val sensorOrientation = characteristics.get(
            android.hardware.camera2.CameraCharacteristics.SENSOR_ORIENTATION
        ) ?: 0

        // Automated Camera Lens Detection based on physical specs (Focal Length & Sensor Size)
        val focalLengths = characteristics.get(
            android.hardware.camera2.CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS
        )
        val focalLength = focalLengths?.firstOrNull() ?: 0f

        val sensorSize = characteristics.get(
            android.hardware.camera2.CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE
        )
        val sensorWidth = sensorSize?.width ?: 0f

        // Calculate horizontal Field of View (FOV) in degrees
        val fovDegrees = if (focalLength > 0f && sensorWidth > 0f) {
            val fovRad = 2.0 * Math.atan((sensorWidth / (2.0 * focalLength)).toDouble())
            Math.toDegrees(fovRad).toFloat()
        } else 0f

        val lensType = when {
            facing == android.hardware.camera2.CameraMetadata.LENS_FACING_FRONT -> "Selfie"
            facing == android.hardware.camera2.CameraMetadata.LENS_FACING_EXTERNAL -> "External USB Webcam"
            fovDegrees >= 94f || (focalLength > 0f && focalLength <= 2.7f) -> "Ultra Wide"
            (fovDegrees in 60f..93f) || (focalLength in 2.8f..6.0f) -> "Main Wide (64MP/Primary)"
            (fovDegrees > 0f && fovDegrees < 60f) || focalLength > 6.0f -> "Telephoto"
            else -> "Wide Angle"
        }

        return mapOf(
            "id" to id,
            "facing" to facingStr,
            "maxWidth" to maxWidth.toString(),
            "maxHeight" to maxHeight.toString(),
            "hasAutoFocus" to hasAutoFocus.toString(),
            "sensorOrientation" to sensorOrientation.toString(),
            "lensType" to lensType,
            "fovDegrees" to fovDegrees.toInt().toString(),
            "focalLength" to String.format(java.util.Locale.US, "%.1f", focalLength),
            "isPhysical" to isPhysical.toString()
        )
    }

    /**
     * Resolves a synthetic USB camera ID (e.g. "usb_1002") to a real Camera2
     * LENS_FACING_EXTERNAL device ID that Camera2Base.switchCamera() can use.
     * Falls back to null if no external Camera2 device is found.
     */
    private fun resolveExternalCameraId(syntheticId: String): String? {
        try {
            val cameraManager = getSystemService(Context.CAMERA_SERVICE) as android.hardware.camera2.CameraManager
            for (id in cameraManager.cameraIdList) {
                try {
                    val chars = cameraManager.getCameraCharacteristics(id)
                    val facing = chars.get(android.hardware.camera2.CameraCharacteristics.LENS_FACING)
                    if (facing == android.hardware.camera2.CameraMetadata.LENS_FACING_EXTERNAL) {
                        android.util.Log.d("MainActivity", "Resolved synthetic '$syntheticId' -> Camera2 external ID '$id'")
                        return id
                    }
                } catch (_: Exception) {}
            }
        } catch (_: Exception) {}
        android.util.Log.w("MainActivity", "No Camera2 external device found for synthetic ID '$syntheticId'")
        return null
    }

    private fun startPreviewWhenSurfaceReady(view: OpenGlView) {
        val holder = view.holder
        if (holder.surface?.isValid == true) {
            view.post { startPreviewIfNeeded() }
            return
        }

        holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                holder.removeCallback(this)
                view.post { startPreviewIfNeeded() }
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                if (holder.surface?.isValid == true) {
                    holder.removeCallback(this)
                    view.post { startPreviewIfNeeded() }
                }
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                holder.removeCallback(this)
            }
        })
    }

    private fun startPreviewIfNeeded() {
        val camera = StreamingForegroundService.camera ?: return
        if (!camera.isOnPreview) {
            // Pre-configure 16:9 preview resolution to match the stream output aspect ratio.
            // This ensures the OpenGL texture matrix is set to 16:9 from the very start,
            // so there is zero FOV shift/jump when startStream() later calls prepareVideo().
            camera.startPreview(1920, 1080)
        }
    }

    // Orientation is now handled by OrientationEventListener in StreamingForegroundService.
    // The activity is locked to portrait, so onConfigurationChanged won't fire for rotation.

    override fun onDestroy() {
        if (isBound) {
            unbindService(serviceConnection)
            isBound = false
        }
        super.onDestroy()
    }

    // --- ConnectChecker Callbacks ---
    override fun onConnectionStarted(url: String) {
    }

    override fun onConnectionSuccess() {
        runOnUiThread {
            methodChannel?.invokeMethod("onConnectionSuccess", null)
        }
    }

    override fun onConnectionFailed(reason: String) {
        runOnUiThread {
            methodChannel?.invokeMethod("onConnectionFailed", reason)
        }
    }

    override fun onNewBitrate(bitrate: Long) {
        runOnUiThread {
            methodChannel?.invokeMethod("onNewBitrate", bitrate)
        }
    }

    override fun onDisconnect() {
        runOnUiThread {
            methodChannel?.invokeMethod("onDisconnect", null)
        }
    }

    override fun onAuthError() {
        runOnUiThread {
            methodChannel?.invokeMethod("onAuthError", null)
        }
    }

    override fun onAuthSuccess() {
        runOnUiThread {
            methodChannel?.invokeMethod("onAuthSuccess", null)
        }
    }

    fun setOpenGlView(view: OpenGlView) {
        this.openGlView = view
        if (isBound && streamingService != null) {
            // During lock/unlock, Android destroys the old surface and creates a new one.
            // We MUST wait for the new surface to be fully valid before handing it to the
            // streaming engine. Passing an invalid surface causes an OpenGL crash.
            val holder = view.holder
            if (holder.surface?.isValid == true) {
                // Surface is already valid (cold start or fast re-creation)
                safeSwapView(view)
            } else {
                // Surface not ready yet (unlock transition) — wait for Android to signal it
                holder.addCallback(object : SurfaceHolder.Callback {
                    override fun surfaceCreated(h: SurfaceHolder) {
                        h.removeCallback(this)
                        view.post { safeSwapView(view) }
                    }
                    override fun surfaceChanged(h: SurfaceHolder, fmt: Int, w: Int, ht: Int) {}
                    override fun surfaceDestroyed(h: SurfaceHolder) {
                        h.removeCallback(this)
                    }
                })
            }
        }
    }

    /**
     * Safely swap the OpenGlView into the streaming engine and restart preview.
     * Called only after the surface is confirmed valid.
     */
    private fun safeSwapView(view: OpenGlView) {
        try {
            streamingService?.initCamera(view, this, streamType)
            streamingService?.updateOrientation()
            startPreviewWhenSurfaceReady(view)
        } catch (e: Exception) {
            // Swallow GL errors during rapid lock/unlock transitions
            android.util.Log.w("MainActivity", "safeSwapView error (non-fatal): ${e.message}")
        }
    }

    fun clearOpenGlView() {
        this.openGlView = null
    }
}
