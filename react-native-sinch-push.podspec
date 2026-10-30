require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-sinch-push"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = "https://github.com/sinchlabs/react-native-sinch-push"
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "13.0" }
  s.swift_version = "5.0"
  s.source       = { :git => "https://github.com/sinchlabs/react-native-sinch-push.git", :tag => "#{s.version}" }

  s.source_files = "ios/**/*.{h,m,mm,swift}"

  # The SwiftPM harness (ios/SinchPushSocketTests) lives under ios/ but is a test
  # package, not pod source. Without this the glob above would pull in its
  # Package.swift and the symlinked Sources/ tree and fail to compile.
  #
  # ios/generated is codegen output from the library's own devDependency RN
  # (gitignored, not published); inside a checkout it holds headers for a
  # different RN version and must not be compiled into the pod.
  #
  # ios/NotificationExtension/Core is shared with the SinchPushNotificationExtension
  # pod (compiled into both, so a host that does not use the extension has nothing
  # extra to declare); the extension's own entry file belongs to that pod only.
  s.exclude_files = [
    "ios/SinchPushSocketTests/**/*",
    "ios/generated/**/*",
    "ios/NotificationExtension/SinchPushNotificationExtension.swift",
  ]

  # FrameCodec and the SwiftProtobuf types in ios/SinchPushSocket/Generated/ are
  # both .swift, so this dependency is required. 1.34.1 is the version
  # buf.gen.swift.yaml generates with (buf.build/apple/swift:v1.34.1); the
  # runtime accepts anything newer within 1.x, so the lower bound is what has
  # to match and the upper bound only guards the next major.
  s.dependency "SwiftProtobuf", ">= 1.34.1", "< 2.0"

  # Pulls in React-Core and, when the new architecture is enabled, the codegen
  # artifacts (RNSinchPushSpec) plus the required Folly/C++ compiler flags.
  # This single call is what makes the module build on both architectures.
  install_modules_dependencies(s)

  # --- Sinch native SDK ---------------------------------------------------
  # Uncomment and pin the version you integrate against. The JS/native glue in
  # this package is SDK-version agnostic; wire the calls in SinchPush.swift.
  # s.dependency "SinchRTC"
end
