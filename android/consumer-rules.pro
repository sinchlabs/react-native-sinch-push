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
