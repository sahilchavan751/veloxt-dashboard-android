package com.custom.srt_stream

import android.content.Context
import android.view.View
import com.pedro.library.view.OpenGlView
import com.pedro.encoder.utils.gl.AspectRatioMode
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugin.common.StandardMessageCodec

class SrtVideoViewFactory(private val activity: MainActivity) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val openGlView = OpenGlView(context)
        openGlView.setAspectRatioMode(AspectRatioMode.Fill)
        activity.setOpenGlView(openGlView)
        return object : PlatformView {
            override fun getView(): View {
                return openGlView
            }
            override fun dispose() {
                activity.clearOpenGlView()
            }
        }
    }
}
