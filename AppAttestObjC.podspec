Pod::Spec.new do |s|
  s.name             = 'AppAttestObjC'
  s.version          = '0.3.0'
  s.summary          = 'Objective-C-friendly wrapper for AppAttest, for bridge writers and ObjC consumers.'
  s.description      = <<~DESC
    AppAttestObjC is a thin `@objc`-friendly facade over `AppAttest`.
    It translates the typed Swift API into NSError + completion handlers
    + primitive enums, making it consumable from Objective-C, React
    Native, Flutter, and Capacitor bridges. Native Swift consumers
    should target `AppAttest` directly — this pod is intentionally
    lossy.
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

  s.source_files = 'Sources/AppAttestObjC/**/*.swift'

  s.dependency 'AppAttest', "= #{s.version}"

  s.frameworks = 'Foundation'
end
