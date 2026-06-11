require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  # Pod name derived by Capacitor's CLI from the npm package name
  # `@appattest/capacitor` → `AppattestCapacitor`. Keeping this exact
  # casing keeps Capacitor's autolinking happy (it auto-writes
  # `pod 'AppattestCapacitor'` into the example's Podfile).
  #
  # Framework name (lowercased) is `appattestcapacitor`, distinct from
  # `appattest` (core SDK) and `appattestobjc` (wrapper). No case-
  # insensitive-filesystem collision.
  s.name             = 'AppattestCapacitor'
  s.version          = package['version']
  s.summary          = package['description']
  s.homepage         = 'https://github.com/AppAttest/appAttest-sdk'
  s.license          = { :type => 'MIT' }
  s.author           = { 'AppAttest' => 'support@appattest.dev' }
  s.source           = {
    :git => 'https://github.com/AppAttest/appAttest-sdk.git',
    :tag => "v#{s.version}"
  }

  s.ios.deployment_target = '17.0'
  s.swift_versions = ['5.9']

  s.source_files = 'ios/Plugin/**/*.{swift,h,m}'

  # Depend on the @objc-friendly facade over the Swift SDK. Same pattern
  # as @appattest/react-native. Capacitor requires @objc plugin APIs,
  # and AppAttestObjC already provides completion-handler-style methods
  # we can delegate to directly.
  s.dependency 'AppAttestObjC', "= #{s.version}"
  s.dependency 'Capacitor'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
