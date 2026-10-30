# Consumer ProGuard rules for the Sinch Push library.
#
# In "optional" mode the library's SinchPushFirebaseMessagingService extends
# com.google.firebase.messaging.FirebaseMessagingService but the dependency is
# compileOnly, so firebase-messaging is not bundled by the library. When the
# host app also does not include firebase-messaging, the superclass reference
# must not cause R8 full-mode failures.
#
# In "required" mode firebase-messaging is on the implementation classpath, so
# these rules are harmless. They are also harmless when the host DOES ship FCM.

-dontwarn com.google.firebase.messaging.**
-dontwarn com.google.firebase.**

# Preserve the service so Android can instantiate it via the manifest entry,
# and so R8 does not strip the FirebaseMessagingService superclass reference.
-keep class com.sinchpush.SinchPushFirebaseMessagingService { *; }
-keep class com.sinchpush.FcmProvider { *; }
-keep class com.sinchpush.socket.SinchPushSocketService { *; }

# No rules for the Square Wire types in android/src/main/wire, deliberately.
#
# Wire's generated code contains no reflection at all — no Class.forName, no
# getDeclaredField, no enum valueOf by string — so nothing has to be kept for
# ProtoAdapter to find a field. The two things the generator *does* rely on are
# already covered by the ruleset AGP applies to every app build
# (com.android.tools.build:gradle's proguard-common.txt):
#
#   -keepclassmembers enum * { public static **[] values(); ... valueOf(...) }
#   -keepclassmembers class * implements android.os.Parcelable {
#       public static final ** CREATOR; }
#
# which is why `android = true` (AndroidMessage -> Parcelable) is safe without
# anything added here.
#
# The generated classes are reachable anyway: FrameCodec's tag table names every
# adapter it uses, so R8 cannot shrink them away from the code that reads them.
