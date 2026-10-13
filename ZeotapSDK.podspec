Pod::Spec.new do |s|
  s.name             = 'ZeotapSDK'
  s.version          = File.read(File.join(__dir__, 'VERSION')).strip
  s.summary          = 'Zeotap / SignalSmith event collection SDK for iOS.'
  s.description      = <<-DESC
    The iOS counterpart of the SignalSmith browser SDK: same event model, consent model (opt-in gating,
    IAB TCF v2 via the TCF-for-Apps IABTCF_* defaults, persisted decisions), on-device PII hashing and
    wire format, proven identical by a shared conformance suite — plus a durable offline queue, flush on
    background, device/app context and app-lifecycle events.
  DESC
  s.homepage         = 'https://github.com/zeotap/zeotap-pulse-ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Zeotap' => 'engineering@zeotap.com' }
  # The PUBLIC repository generated from this monorepo on release (scripts/sdk-export,
  # increment 358) — trunk validates the pod by cloning this tag, and SPM consumers
  # resolve the same tag, so both channels install the exact tree the export gated.
  s.source           = { :git => 'https://github.com/zeotap/zeotap-pulse-ios.git', :tag => "v#{s.version}" }
  s.swift_versions   = ['5.9']
  s.platforms        = { :ios => '14.0' }
  s.default_subspecs = 'Core'

  s.subspec 'Core' do |core|
    core.source_files = 'Sources/ZeotapSDK/**/*.swift'
    core.resource_bundles = { 'ZeotapSDK' => ['Sources/ZeotapSDK/PrivacyInfo.xcprivacy'] }
    core.frameworks = 'Foundation', 'Network'
    core.libraries = 'sqlite3'
  end

  s.subspec 'AdSupport' do |ad|
    ad.dependency 'ZeotapSDK/Core'
    ad.source_files = 'Sources/ZeotapSDKAdSupport/**/*.swift'
    ad.resource_bundles = { 'ZeotapSDKAdSupport' => ['Sources/ZeotapSDKAdSupport/PrivacyInfo.xcprivacy'] }
    ad.weak_frameworks = 'AdSupport', 'AppTrackingTransparency'
  end

  s.subspec 'ObjC' do |objc|
    objc.dependency 'ZeotapSDK/Core'
    objc.source_files = 'Sources/ZeotapSDKObjC/**/*.swift'
  end
end
