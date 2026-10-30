require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

# The Notification Service Extension half of the SDK. Add it to the extension
# target only (see "Notification Service Extension" in the README):
#
#   target 'NotificationService' do
#     pod 'SinchPushNotificationExtension', :path => '../node_modules/@sinch/react-native-sinch-push'
#   end
#
# React-free on purpose: Foundation and UserNotifications, extension-safe APIs
# only. ios/NotificationExtension/Core is also compiled into the main
# `react-native-sinch-push` pod (which would otherwise force every host to
# declare this pod), so the report encoder and uploader exist once in source.
Pod::Spec.new do |s|
  s.name         = "SinchPushNotificationExtension"
  s.version      = package["version"]
  s.summary      = "Sinch Push Notification Service Extension support: reports pushes as delivered from the extension."
  s.homepage     = "https://github.com/sinchlabs/react-native-sinch-push"
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "13.0" }
  s.swift_version = "5.0"
  s.source       = { :git => "https://github.com/sinchlabs/react-native-sinch-push.git", :tag => "#{s.version}" }

  s.source_files = "ios/NotificationExtension/**/*.swift"

  # Extensions may not use UIApplication.shared and friends.
  # SINCH_PUSH_EXTENSION: the shared sources hold a background task around the file lock in
  # the app only; UIApplication does not exist here.
  s.pod_target_xcconfig = {
    "APPLICATION_EXTENSION_API_ONLY" => "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS" => "$(inherited) SINCH_PUSH_EXTENSION",
  }
  s.frameworks   = "Foundation", "UserNotifications"
end
