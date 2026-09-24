/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 *
 * Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 *
 * PeanutButter patch: do NOT System.loadLibrary("mpv") in a static initializer.
 * Loading mpv before Flutter's first frame leaves the window at NO_SURFACE on
 * Android TV x86 emulators. Native libs are loaded on a background thread via
 * MethodChannel before first playback so the UI thread never ANRs.
 */
package com.alexmercerind.media_kit_libs_android_video;

import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import androidx.annotation.NonNull;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

import com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper;

/** MediaKitLibsAndroidVideoPlugin */
public class MediaKitLibsAndroidVideoPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private static final AtomicBoolean nativeLoaded = new AtomicBoolean(false);
    private static final ExecutorService loadExecutor =
            Executors.newSingleThreadExecutor(r -> {
                Thread t = new Thread(r, "media-kit-mpv-load");
                t.setPriority(Thread.NORM_PRIORITY - 1);
                return t;
            });

    private MethodChannel channel;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    /** Load libmpv off the UI thread. Safe to call repeatedly. */
    public static void loadNativeLibraries(Runnable onDone) {
        if (nativeLoaded.get()) {
            if (onDone != null) onDone.run();
            return;
        }
        loadExecutor.execute(() -> {
            try {
                if (!nativeLoaded.get()) {
                    System.loadLibrary("mpv");
                    nativeLoaded.set(true);
                    Log.i("media_kit", "libmpv loaded (background).");
                }
            } catch (Throwable e) {
                Log.e("media_kit", "libmpv load failed", e);
            } finally {
                if (onDone != null) onDone.run();
            }
        });
    }

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding flutterPluginBinding) {
        Log.i("media_kit", "package:media_kit_libs_android_video attached (mpv deferred).");
        try {
            MediaKitAndroidHelper.setApplicationContextJava(flutterPluginBinding.getApplicationContext());
            Log.i("media_kit", "Saved application context.");
        } catch (Throwable e) {
            e.printStackTrace();
        }
        channel = new MethodChannel(
                flutterPluginBinding.getBinaryMessenger(),
                "com.alexmercerind.media_kit_libs_android_video");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        if ("loadNativeLibraries".equals(call.method)) {
            loadNativeLibraries(() -> mainHandler.post(() -> result.success(nativeLoaded.get())));
            return;
        }
        if ("isNativeLoaded".equals(call.method)) {
            result.success(nativeLoaded.get());
            return;
        }
        result.notImplemented();
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (channel != null) {
            channel.setMethodCallHandler(null);
            channel = null;
        }
        Log.i("media_kit", "package:media_kit_libs_android_video detached.");
    }
}
