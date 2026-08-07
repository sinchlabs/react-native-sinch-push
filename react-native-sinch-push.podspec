require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-sinch-push"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["repository"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "13.0" }
  s.swift_version = "5.0"
  s.source       = { :git => "https://github.com/sinchlabs/react-native-sinch-push.git", :tag => "#{s.version}" }

  s.source_files = "ios/**/*.{h,m,mm,swift}"

  # Pulls in React-Core and, when the new architecture is enabled, the codegen
  # artifacts (RNSinchPushSpec) plus the required Folly/C++ compiler flags.
  # This single call is what makes the module build on both architectures.
  install_modules_dependencies(s)

  # --- Sinch native SDK ---------------------------------------------------
  # Uncomment and pin the version you integrate against. The JS/native glue in
  # this package is SDK-version agnostic; wire the calls in SinchPush.swift.
  # s.dependency "SinchRTC"
end
