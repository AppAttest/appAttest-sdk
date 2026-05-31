require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name             = 'AppAttestReactNative'
  s.version          = package['version']
  s.summary          = package['description']
  s.homepage         = 'https://github.com/AppAttest/appAttest-sdk'
  s.license          = 'MIT'
  s.author           = { 'AppAttest' => 'support@appattest.dev' }
  s.source           = {
    :git => 'https://github.com/AppAttest/appAttest-sdk.git',
    :tag => "v#{s.version}"
  }

  s.platforms = { :ios => '17.0' }
  s.swift_versions = ['5.9']

  s.source_files = '**/*.{swift,m,mm,h}'

  # Depend on the Swift SDK's Objective-C facade. The facade transitively
  # pulls in `AppAttest` (the pure Swift module).
  s.dependency 'AppAttestObjC', "= #{s.version}"

  # React Native core — this is the standard pattern from @react-native/
  # official modules. `install_modules_dependencies` is exposed by RN's
  # podspec helpers and ensures new-arch / TurboModule deps are wired.
  if respond_to?(:install_modules_dependencies, true)
    install_modules_dependencies(s)
  else
    s.dependency 'React-Core'
  end
end
