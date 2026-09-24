/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 *
 * Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 *
 * PeanutButter patch: defer native lib load until first use so Flutter can
 * attach a surface on Android TV x86 emulators.
 */
package com.alexmercerind.mediakitandroidhelper;

import android.net.Uri;
import android.content.Context;
import androidx.annotation.Keep;

@Keep
public class MediaKitAndroidHelper {
    private static boolean nativeLoaded = false;
    private static Context applicationContext = null;

    private static synchronized void ensureNativeLoaded() {
        if (nativeLoaded) return;
        System.loadLibrary("mediakitandroidhelper");
        nativeLoaded = true;
        if (applicationContext != null) {
            setApplicationContextNative(applicationContext);
        }
    }

    public static native long newGlobalObjectRef(Object obj);

    public static native void deleteGlobalObjectRef(long ref);

    public static native String copyAssetToFilesDir(String assetName);

    private static native void setApplicationContextNative(Context context);

    public static void setApplicationContextJava(Context context) {
        applicationContext = context;
        // Do not load native here — wait until a native method is actually needed.
    }

    public static native int openFileDescriptorNative(String uri);

    public static int openFileDescriptorJava(String uri) {
        try {
            final Uri object = Uri.parse(uri);
            return applicationContext.getContentResolver().openFileDescriptor(object, "r").detachFd();
        } catch (Throwable e) {
            e.printStackTrace();
            return -1;
        }
    }

    // Eager-load before MediaKit playback (optional; DynamicLibrary.open may also pull it in).
    public static void loadNative() {
        ensureNativeLoaded();
    }
}
