Pod::Spec.new do |s|
  s.name             = 'AppAttest'
  s.version          = '0.2.0'
  s.summary          = 'Zero-config Swift SDK for AppAttest — App-Attest-gated secret delivery for iOS and macOS.'
  s.description      = <<~DESC
    AppAttest delivers API keys and app secrets to your iOS and macOS binary,
    gated on Apple's App Attest so only a real build of your real app can read
    them. Zero config. One call to register, one call to sync, Keychain reads
    from there. Release builds always run real attestation.
  DESC
  s.homepage         = 'https://github.com/AppAttest/appAttest-sdk'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'AppAttest' => 'support@appattest.dev' }
  s.source           = {
    :git => 'https://github.com/AppAttest/appAttest-sdk.git',
    :tag => "v#{s.version}"
  }

  s.swift_versions = ['5.9']
  s.ios.deployment_target     = '17.0'
  s.osx.deployment_target     = '14.0'
  s.tvos.deployment_target    = '17.0'
  s.watchos.deployment_target = '10.0'

  s.source_files = 'Sources/AppAttest/**/*.swift'
  # DocC catalog is excluded — CocoaPods doesn't need it at build time.
  s.exclude_files = 'Sources/AppAttest/Documentation.docc/**/*'

  # Bridge writers' pods (RN / Flutter / Capacitor iOS shims) will add a
  # companion AppAttestObjC.podspec in Phase 3 and depend on this one.

  s.frameworks = 'Foundation', 'Security'
  s.ios.frameworks = 'DeviceCheck', 'UIKit'
  s.osx.frameworks = 'DeviceCheck'
  s.tvos.frameworks = 'DeviceCheck', 'UIKit'
  s.watchos.frameworks = 'DeviceCheck'
end
