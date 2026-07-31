package com.custom.srt_stream

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Binder
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.PowerManager
import android.view.OrientationEventListener
import android.view.Surface
import android.media.MediaRecorder
import com.pedro.common.ConnectChecker
import com.pedro.encoder.TimestampMode
import com.pedro.library.base.Camera2Base
import com.pedro.library.rtmp.RtmpCamera2
import com.pedro.library.srt.SrtCamera2
import com.pedro.library.view.OpenGlView
import com.pedro.library.view.GlStreamInterface
import com.pedro.encoder.input.video.CameraHelper

class StreamingForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var orientationListener: OrientationEventListener? = null
    private var currentDeviceRotation = 270

    private val binder = LocalBinder()

    companion object {
        private const val CHANNEL_ID = "SrtStreamingChannel"
        private const val NOTIFICATION_ID = 8889
        
        var camera: Camera2Base? = null
            private set
        
        var isStreaming = false
            private set
            
        var currentUrl: String? = null
            private set

        fun startService(context: Context) {
            val intent = Intent(context, StreamingForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stopService(context: Context) {
            val intent = Intent(context, StreamingForegroundService::class.java)
            context.stopService(intent)
        }
    }

    inner class LocalBinder : Binder() {
        fun getService(): StreamingForegroundService = this@StreamingForegroundService
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        acquireLocks()
        startOrientationListener()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            var serviceType = ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                serviceType = serviceType or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            startForeground(NOTIFICATION_ID, createNotification(), serviceType)
        } else {
            startForeground(NOTIFICATION_ID, createNotification())
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder {
        return binder
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val name = "Live Streaming Service"
            val descriptionText = "Keeps camera streaming active in the background"
            val importance = NotificationManager.IMPORTANCE_LOW
            val channel = NotificationChannel(CHANNEL_ID, name, importance).apply {
                description = descriptionText
            }
            val notificationManager: NotificationManager =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun createNotification(): Notification {
        val notificationIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, notificationIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Camera Streaming Node")
            .setContentText("Broadcasting live video stream...")
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    var isAudioEnabled = true
        private set

    private var currentStreamType: String = "rtmp"

    fun initCamera(openGlView: OpenGlView, connectChecker: ConnectChecker, streamType: String = "rtmp") {
        // If camera exists but the stream type changed, we MUST release and recreate
        if (camera != null && currentStreamType != streamType) {
            releaseCamera()
        }

        if (camera == null) {
            camera = if (streamType == "srt") {
                SrtCamera2(openGlView, connectChecker)
            } else {
                RtmpCamera2(openGlView, connectChecker)
            }
            currentStreamType = streamType
        } else {
            try {
                camera?.replaceView(openGlView)
            } catch (e: Exception) {
                // Camera in bad state — recreate it
                android.util.Log.w("StreamingService", "replaceView failed, recreating camera: ${e.message}")
                releaseCamera()
                camera = if (streamType == "srt") {
                    SrtCamera2(openGlView, connectChecker)
                } else {
                    RtmpCamera2(openGlView, connectChecker)
                }
                currentStreamType = streamType
            }
        }
        // BUFFER mode: timestamps derived from exact buffer durations (21.33ms audio / 33.33ms video)
        // instead of System.nanoTime(), eliminating OpenGL pipeline delay offset between A/V tracks
        camera?.setTimestampMode(TimestampMode.BUFFER, TimestampMode.BUFFER)
        updateOrientation()
    }

    fun releaseCamera() {
        try { camera?.stopPreview() } catch (_: Exception) {}
        try { camera?.stopStream() } catch (_: Exception) {}
        camera = null
        isStreaming = false
        currentUrl = null
    }

    fun enableAudio() {
        camera?.enableAudio()
        isAudioEnabled = true
    }

    fun disableAudio() {
        camera?.disableAudio()
        isAudioEnabled = false
    }

    fun toggleFlashlight(): Boolean {
        val cam = camera ?: return false
        try {
            if (cam.isLanternEnabled) {
                cam.disableLantern()
                return false
            } else {
                cam.enableLantern()
                return true
            }
        } catch (e: Exception) {
            android.util.Log.e("StreamingService", "Toggle flashlight failed: ${e.message}")
            return false
        }
    }

    fun setVideoBitrateOnFly(bitrateBps: Int) {
        try {
            camera?.setVideoBitrateOnFly(bitrateBps)
        } catch (e: Exception) {
            android.util.Log.e("StreamingService", "setVideoBitrateOnFly failed: ${e.message}")
        }
    }

    fun tapToFocus(view: android.view.View, x: Float, y: Float): Boolean {
        val cam = camera ?: return false
        return try {
            val time = android.os.SystemClock.uptimeMillis()
            val event = android.view.MotionEvent.obtain(time, time, android.view.MotionEvent.ACTION_DOWN, x, y, 0)
            cam.tapToFocus(view, event)
            event.recycle()
            true
        } catch (e: Exception) {
            android.util.Log.e("StreamingService", "tapToFocus failed: ${e.message}")
            false
        }
    }

    fun setExposure(value: Int) {
        try {
            camera?.exposure = value
        } catch (e: Exception) {
            android.util.Log.e("StreamingService", "setExposure failed: ${e.message}")
        }
    }

    fun getExposureRange(): Map<String, Int> {
        val cam = camera ?: return mapOf("min" to 0, "max" to 0, "current" to 0)
        return try {
            mapOf(
                "min" to cam.minExposure,
                "max" to cam.maxExposure,
                "current" to cam.exposure
            )
		} catch (_: Exception) {
            mapOf("min" to 0, "max" to 0, "current" to 0)
        }
    }

    fun updateOrientation() {
        val cam = camera ?: return
        try {
            val glInterface = cam.getGlInterface() as? GlStreamInterface
            glInterface?.autoHandleOrientation = true
        } catch (e: Exception) {
            // Ignore if GL interface is not initialized yet
        }
    }

    /**
     * Starts an OrientationEventListener to track physical device rotation.
     * Restricts camera stream output rotation to landscape modes only (90 or 270).
     */
    private fun startOrientationListener() {
        orientationListener = object : OrientationEventListener(applicationContext) {
            override fun onOrientationChanged(orientation: Int) {
                if (orientation == ORIENTATION_UNKNOWN) return
                // Restrict stream rotation strictly to landscape modes (90 or 270 degrees)
                val newRotation = when {
                    orientation in 45..134 -> 270   // Landscape (right)
                    orientation in 225..314 -> 90   // Landscape (left)
                    else -> if (currentDeviceRotation == 90) 90 else 270 // Lock to landscape
                }
                if (newRotation != currentDeviceRotation) {
                    currentDeviceRotation = newRotation
                    applyStreamRotation(newRotation)
                }
            }
        }
        if (orientationListener?.canDetectOrientation() == true) {
            orientationListener?.enable()
        }
    }

    /**
     * Applies the rotation to the stream encoder output without affecting the preview.
     */
    private fun applyStreamRotation(rotationDegrees: Int) {
        val cam = camera ?: return
        try {
            val glInterface = cam.getGlInterface() as? GlStreamInterface
            glInterface?.setStreamRotation(rotationDegrees)
        } catch (e: Exception) {
            // GL interface may not be ready yet
        }
    }

    fun startStream(url: String, width: Int, height: Int, bitrate: Int, fps: Int): String? {
        val cam = camera ?: return "Camera system is not initialized"
        if (cam.isStreaming) return null

        // Enforce deterministic buffer-based timestamps for frame-perfect AV sync.
        // Must be called before prepareVideo/prepareAudio per RootEncoder docs.
        cam.setTimestampMode(TimestampMode.BUFFER, TimestampMode.BUFFER)

        // Prepare video (H.264 Baseline/Main)
        val videoPrepared: Boolean
        try {
            // Enforce 16:9 Landscape output regardless of device orientation
            val landscapeWidth = maxOf(width, height)
            val landscapeHeight = minOf(width, height)
            
            // Pass 1-second iFrameInterval (GOP keyframe) to prevent macroblock blur during fast motion
            videoPrepared = cam.prepareVideo(landscapeWidth, landscapeHeight, fps, bitrate, 1 /* iFrameInterval */, 0 /* rotation */)
            if (!videoPrepared) {
                return "Failed to prepare video encoder (unsupported resolution or bitrate)"
            }
        } catch (e: Exception) {
            return "Video encoder initialization crashed: ${e.localizedMessage}"
        }

        // Prepare audio (AAC-LC) — zero-latency configuration with exact RootEncoder API parameter order:
        // RootEncoder prepareAudio signature: (audioSource: Int, bitrate: Int, sampleRate: Int, isStereo: Boolean, echoCanceler: Boolean, noiseSuppressor: Boolean)
        // 1. Try CAMCORDER (5) for hardware-level camera mic AV sync on physical devices.
        // 2. Fall back to DEFAULT (0) if CAMCORDER is not exposed by virtual audio HAL (e.g., emulators).
        // - 128 * 1024 (128kbps AAC): High quality broadcast audio
        // - 48000 (48kHz): Matches native Android Audio HAL (zero resampling latency)
        // - isStereo = false (Mono): Eliminates stereo buffer overhead
        // - echoCanceler = false: No echo processing delay
        // - noiseSuppressor = false: CRITICAL — bypasses Android Audio HAL DSP buffer (~200ms framing delay)
        var audioPrepared = false
        try {
            audioPrepared = cam.prepareAudio(
                MediaRecorder.AudioSource.CAMCORDER, // 1st arg: CAMCORDER mic array for hardware AV sync
                128 * 1024,                          // 2nd arg: bitrate (128kbps)
                48000,                               // 3rd arg: sampleRate (48kHz)
                false,                               // 4th arg: isStereo (false)
                false,                               // 5th arg: echoCanceler (false)
                false                                // 6th arg: noiseSuppressor (false)
            )
        } catch (_: Exception) {}

        if (!audioPrepared) {
            try {
                audioPrepared = cam.prepareAudio(
                    MediaRecorder.AudioSource.DEFAULT,   // Fallback: DEFAULT audio input
                    128 * 1024,
                    48000,
                    false,
                    false,
                    false
                )
            } catch (_: Exception) {}
        }

        if (!audioPrepared) {
            return "Failed to initialize microphone or configure audio encoder. Please check if the microphone is in use."
        }
        
        try {
            // CRITICAL: Set audio state BEFORE starting the stream.
            // This ensures audio packets are included from the very first frame,
            // eliminating the initial audio delay/gap that occurred when audio
            // was enabled after the stream had already started.
            if (isAudioEnabled) {
                cam.enableAudio()
            } else {
                cam.disableAudio()
            }

            cam.startStream(url)
            isStreaming = true
            currentUrl = url
            updateOrientation()
            return null
        } catch (e: Exception) {
            return "Failed to start connection stream: ${e.localizedMessage}"
        }
    }

    fun stopStream() {
        camera?.stopStream()
        isStreaming = false
        currentUrl = null
    }

    override fun onDestroy() {
        orientationListener?.disable()
        orientationListener = null
        releaseCamera()
        releaseLocks()
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SrtStream::WakeLock").apply {
                acquire(10 * 60 * 1000L /* 10 minutes fallback */)
            }
            
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifiLock = wifiManager.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "SrtStream::WifiLock").apply {
                acquire()
            }
        } catch (e: Exception) {
            // Silently catch lock exceptions
        }
    }

    private fun releaseLocks() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
            wakeLock = null
            
            if (wifiLock?.isHeld == true) {
                wifiLock?.release()
            }
            wifiLock = null
        } catch (e: Exception) {
            // Silently catch lock exceptions
        }
    }
}
