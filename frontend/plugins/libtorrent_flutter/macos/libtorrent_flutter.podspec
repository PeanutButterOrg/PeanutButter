Pod::Spec.new do |s|
  s.name             = 'libtorrent_flutter'
  s.version          = '2.0.0'
  s.summary          = 'Flutter plugin for libtorrent with built-in streaming server.'
  s.description      = <<-DESC
  Native libtorrent 2.x bindings for Flutter with an integrated HTTP streaming server.
                       DESC
  s.homepage         = 'https://github.com/ayman708-UX/libtorrent_flutter'
  s.license          = { :type => 'GPL-3.0', :file => '../LICENSE' }
  s.author           = { 'ayman708-UX' => 'ayman@example.com' }
  s.source           = { :path => '.' }

  s.dependency 'FlutterMacOS'
  # Matches Flutter's generated Podfile platform. The dylib itself targets
  # macOS 12.0, as does the Runner (MACOSX_DEPLOYMENT_TARGET).
  s.platform = :osx, '10.15'
  s.osx.deployment_target = '10.15'
  s.swift_version = '5.0'

  # The dylib is built in-repo by tool/build_macos_native.sh (universal,
  # libtorrent + OpenSSL linked statically). Upstream's GitHub prebuilt was
  # ABI-mismatched and is no longer downloadable, so never fetch it.
  dylib = File.join(__dir__, 'liblibtorrent_flutter.dylib')
  script = File.expand_path(File.join(__dir__, '..', 'tool', 'build_macos_native.sh'))
  unless system('/bin/bash', script)
    raise "libtorrent_flutter: native build failed. Run #{script} and fix the reported error."
  end
  raise "libtorrent_flutter: #{dylib} missing after native build" unless File.exist?(dylib)

  s.vendored_libraries = 'liblibtorrent_flutter.dylib'
  s.source_files = 'Classes/**/*.swift'
end
