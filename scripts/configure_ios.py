"""Idempotently wire our native bridge and pinned WhisperKit into Flutter's project."""
from pathlib import Path
import plistlib

root = Path(__file__).resolve().parents[1]
project = root / "app/ios/Runner.xcodeproj/project.pbxproj"
s = project.read_text()
if "A10000000000000000000001" not in s:
    s = s.replace("/* End PBXBuildFile section */", '''\t\tA10000000000000000000001 /* NativeAiBridge.swift in Sources */ = {isa = PBXBuildFile; fileRef = A10000000000000000000002; };
\t\tA10000000000000000000003 /* WhisperKit in Frameworks */ = {isa = PBXBuildFile; productRef = A10000000000000000000004; };
/* End PBXBuildFile section */''')
    s = s.replace("/* End PBXFileReference section */", '''\t\tA10000000000000000000002 /* NativeAiBridge.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NativeAiBridge.swift; sourceTree = "<group>"; };
/* End PBXFileReference section */''')
    s = s.replace("74858FAE1ED2DC5600515810 /* AppDelegate.swift */,", "74858FAE1ED2DC5600515810 /* AppDelegate.swift */,\n\t\t\t\tA10000000000000000000002 /* NativeAiBridge.swift */,")
    s = s.replace("74858FAF1ED2DC5600515810 /* AppDelegate.swift in Sources */,", "74858FAF1ED2DC5600515810 /* AppDelegate.swift in Sources */,\n\t\t\t\tA10000000000000000000001 /* NativeAiBridge.swift in Sources */,")
    s = s.replace("78A318202AECB46A00862997 /* FlutterGeneratedPluginSwiftPackage in Frameworks */,", "78A318202AECB46A00862997 /* FlutterGeneratedPluginSwiftPackage in Frameworks */,\n\t\t\t\tA10000000000000000000003 /* WhisperKit in Frameworks */,")
    s = s.replace("packageProductDependencies = (", "packageProductDependencies = (\n\t\t\t\tA10000000000000000000004 /* WhisperKit */,")
    s = s.replace("packageReferences = (", "packageReferences = (\n\t\t\t\tA10000000000000000000005 /* WhisperKit */,")
    s = s.replace("/* Begin XCBuildConfiguration section */", '''\t\tA10000000000000000000004 /* WhisperKit */ = {isa = XCSwiftPackageProductDependency; package = A10000000000000000000005; productName = WhisperKit; };
\t\tA10000000000000000000005 /* WhisperKit */ = {isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/argmaxinc/argmax-oss-swift.git"; requirement = {kind = exactVersion; version = 1.1.0; }; };
/* Begin XCBuildConfiguration section */''')
import re
s = re.sub(r'IPHONEOS_DEPLOYMENT_TARGET = [\d.]+;', 'IPHONEOS_DEPLOYMENT_TARGET = 16.0;', s)
project.write_text(s)
plist_path = root / 'app/ios/Runner/Info.plist'
with plist_path.open('rb') as f:
    info = plistlib.load(f)
info.update({
    'CFBundleDisplayName': 'Sage',
    'NSMicrophoneUsageDescription': 'Record conversations you choose to review and remember.',
    'NSBluetoothAlwaysUsageDescription': 'Receive audio from your Limitless Pendant.',
    'NSLocalNetworkUsageDescription': 'Connect to your optional Sage backend on your own network.',
    'UIBackgroundModes': ['audio', 'bluetooth-central'],
    'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True},
})
with plist_path.open('wb') as f:
    plistlib.dump(info, f)
print('Configured iOS bridge, permissions, and WhisperKit 1.1.0')
