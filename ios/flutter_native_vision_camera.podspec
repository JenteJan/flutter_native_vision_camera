#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_native_vision_camera.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_native_vision_camera'
  s.version          = '0.0.5'
  s.summary          = 'High-performance Flutter FFI camera plugin with zero-copy preview and real-time frame access.'
  s.description      = <<-DESC
A high-performance camera plugin for Flutter built on AVFoundation (iOS) and CameraX (Android),
providing zero-copy preview textures, integrated barcode/QR scanning, and low-latency native
frame access via FFI for real-time on-device vision.
                       DESC
  s.homepage         = 'https://github.com/JenteJan/flutter_native_vision_camera'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Jente Jan de Waart' => 'jentedewaart@gmail.com' }

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains a forwarder C file that relatively imports
  # `../src/*` so that the C sources can be shared among all target platforms.
  s.source           = { :http => 'https://github.com/JenteJan/flutter_native_vision_camera' }
  s.source_files = 'Classes/**/*.{h,c,cpp,m,swift}'
  s.public_header_files = 'Classes/**/*.h'
  s.resource_bundles = { 'flutter_native_vision_camera_privacy' => ['Resources/PrivacyInfo.xcprivacy'] }
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  s.frameworks = 'AVFoundation', 'CoreMedia', 'CoreVideo', 'CoreImage', 'Vision', 'UIKit'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/../src"'
  }
  s.swift_version = '5.0'
end
