import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.os.Looper;
import android.os.Build;
import android.content.res.Configuration;
import android.os.UserHandle;
import android.util.Base64;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

public final class AppMetadata {
    private static final int ICON_SIZE = 48;

    public static void main(String[] args) throws Exception {
        Context context = packageContext(Integer.parseInt(args[0]));
        PackageManager packages = context.getPackageManager();
        Map<String, String> launchers = launcherComponents(packages);
        Set<String> cached = new HashSet<>(Arrays.asList(args).subList(1, args.length));
        Configuration configuration = context.getResources().getConfiguration();
        String environment = Build.FINGERPRINT + "\n" + configuration.getLocales().toLanguageTags()
            + "\n" + configuration.densityDpi + "\n" + configuration.uiMode;
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        for (PackageInfo info : packages.getInstalledPackages(0)) {
            ApplicationInfo app = info.applicationInfo;
            if (app == null) continue;
            String stamp = metadataStamp(digest, environment, info, app);
            boolean hit = cached.contains(stamp);
            boolean cacheable = true;
            String label = "";
            String icon = "";
            if (!hit) {
                try {
                    CharSequence text = app.loadLabel(packages);
                    if (text != null) {
                        label = encodeText(text.toString());
                    }
                } catch (RuntimeException ignored) {
                    cacheable = false;
                }
                if (app.icon != 0) {
                    try {
                        icon = encodeIcon(app.loadIcon(packages));
                        cacheable &= !icon.isEmpty();
                    } catch (RuntimeException ignored) {
                        cacheable = false;
                    }
                }
            }
            System.out.println(app.packageName + "\t" + label + "\t" + icon + "\t"
                + encodeText(info.versionName) + "\t" + apkSize(app) + "\t"
                + launchers.getOrDefault(app.packageName, "") + "\t" + stamp + "\t"
                + (hit ? "hit" : cacheable ? "fresh" : "retry") + "\t"
                + info.firstInstallTime + "\t" + info.lastUpdateTime + "\t"
                + versionCode(info) + "\t" + app.minSdkVersion + "\t" + app.targetSdkVersion + "\t"
                + (app.sourceDir == null ? "" : Integer.toString(app.splitSourceDirs == null ? 0 : app.splitSourceDirs.length)));
        }
    }

    @SuppressWarnings("deprecation")
    private static long versionCode(PackageInfo info) {
        return Build.VERSION.SDK_INT >= 28 ? info.getLongVersionCode() : info.versionCode;
    }

    private static String metadataStamp(MessageDigest digest, String environment, PackageInfo info, ApplicationInfo app) {
        String stamp = environment + "\n" + app.packageName + "\n" + versionCode(info) + "\n"
            + info.firstInstallTime + "\n" + info.lastUpdateTime + "\n" + app.sourceDir + "\n"
            + Arrays.toString(app.splitSourceDirs) + "\n" + app.icon + "\n" + app.labelRes;
        byte[] hash = digest.digest(stamp.getBytes(StandardCharsets.UTF_8));
        return Base64.encodeToString(hash, 0, 16, Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
    }

    private static Map<String, String> launcherComponents(PackageManager packages) {
        Map<String, String> result = new HashMap<>();
        Intent launcher = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        for (ResolveInfo match : packages.queryIntentActivities(launcher, 0)) {
            if (match.activityInfo == null || !match.activityInfo.exported) continue;
            ComponentName component = new ComponentName(match.activityInfo.packageName, match.activityInfo.name);
            result.putIfAbsent(component.getPackageName(), component.flattenToShortString());
        }
        return result;
    }

    private static String apkSize(ApplicationInfo app) {
        if (app.sourceDir == null) return "";
        long total = new File(app.sourceDir).length();
        if (total <= 0) return "";
        if (app.splitSourceDirs != null) {
            for (String split : app.splitSourceDirs) {
                long size = new File(split).length();
                if (size <= 0 || total > Long.MAX_VALUE - size) return "";
                total += size;
            }
        }
        return Long.toString(total);
    }

    private static String encodeText(String text) {
        if (text == null) return "";
        return Base64.encodeToString(text.substring(0, Math.min(text.length(), 512))
            .getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP);
    }

    @SuppressWarnings("deprecation")
    private static Context packageContext(int user) throws Exception {
        // ADB starts this as a short-lived shell process without an Android application context.
        Looper.prepareMainLooper();
        Class<?> activityThread = Class.forName("android.app.ActivityThread");
        Constructor<?> constructor = activityThread.getDeclaredConstructor();
        constructor.setAccessible(true);
        Object thread = constructor.newInstance();
        Field current = activityThread.getDeclaredField("sCurrentActivityThread");
        current.setAccessible(true);
        current.set(null, thread);
        Context context = (Context) activityThread.getMethod("getSystemContext").invoke(thread);
        UserHandle handle = (UserHandle) UserHandle.class.getMethod("of", int.class).invoke(null, user);
        return (Context) Context.class.getMethod("createContextAsUser", UserHandle.class, int.class)
            .invoke(context, handle, 0);
    }

    private static String encodeIcon(Drawable icon) {
        if (icon == null) return "";
        Bitmap bitmap = Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888);
        try {
            int width = Math.max(1, icon.getIntrinsicWidth());
            int height = Math.max(1, icon.getIntrinsicHeight());
            float scale = (float) ICON_SIZE / Math.max(width, height);
            int drawWidth = Math.max(1, Math.round(width * scale));
            int drawHeight = Math.max(1, Math.round(height * scale));
            int left = (ICON_SIZE - drawWidth) / 2;
            int top = (ICON_SIZE - drawHeight) / 2;
            icon.setBounds(left, top, left + drawWidth, top + drawHeight);
            icon.draw(new Canvas(bitmap));
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            return bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
                ? Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP) : "";
        } finally {
            bitmap.recycle();
        }
    }
}
