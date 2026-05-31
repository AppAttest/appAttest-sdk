require 'yaml'

pubspec = YAML.load_file(File.join(__dir__, '..', 'pubspec.yaml'))

Pod::Spec.new do |s|
  # Pod name MUST equal the Dart package name — Flutter's auto-link
  # expects `<package>.podspec` with matching `s.name`. On a case-
  # insensitive filesystem (macOS APFS default), `appattest.framework`
  # collides with the core `AppAttest.framework`. Consumers' Podfiles
  # should use static linkage (`use_frameworks! :linkage => :static`)
  # to avoid the collision — that's standard Flutter practice for
  # plugins that depend on native Swift packages.
  s.name             = 'appattest_flutter'
  s.version          = pubspec['version']
  s.summary          = pubspec['description']
  s.homepage         = pubspec['homepage']
  # The actual LICENSE file is at the monorepo root, but CocoaPods
  # resolves paths from `.symlinks/plugins/<pkg>/ios/` when the plugin
  # is consumed via Flutter autolink, and `../../../LICENSE` doesn't
  # resolve from there. Declaring the license type is sufficient for
  # both `pod lib lint` and `pod trunk push`; pub.dev separately
  # derives license info from the LICENSE file at the package root.
  s.license          = { :type => 'MIT' }
  s.author           = { 'AppAttest' => 'support@appattest.dev' }
  s.source           = { :path => '.' }

  s.platform = :ios, '17.0'
  s.swift_versions = ['5.9']

  s.source_files = 'Classes/**/*'

  # Pure Swift plugin — Pigeon generates typed Swift glue that calls
  # directly into the AppAttest module. No ObjC facade needed.
  s.dependency 'AppAttest', "= #{s.version}"
  s.dependency 'Flutter'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
