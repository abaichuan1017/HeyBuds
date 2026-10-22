// swift-tools-version: 6.4
import PackageDescription
import Foundation

// CLT 27 contains Swift Testing, but SwiftPM does not discover its nested macro plugin.
// Locate it without requiring a full Xcode installation or altering system settings.
let developerRoots = [ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
                      "/Library/Developer/CommandLineTools", "/Applications/Xcode.app/Contents/Developer"].compactMap { $0 }
let testingPlugin = developerRoots.flatMap { root in
    [root+"/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib",
     root+"/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"]
}.first { FileManager.default.fileExists(atPath:$0) }
let testingFrameworks = developerRoots.map { $0+"/Library/Developer/Frameworks" }.first {
    FileManager.default.fileExists(atPath:$0+"/Testing.framework")
}
let testSettings:[SwiftSetting] = (testingPlugin.map { [.unsafeFlags(["-load-plugin-library",$0])] } ?? [])
    + (testingFrameworks.map { [.unsafeFlags(["-F",$0])] } ?? [])
let testLinker:[LinkerSetting] = testingFrameworks.map { [.unsafeFlags(["-F",$0,"-Xlinker","-rpath","-Xlinker",$0])] } ?? []

let package = Package(
    name: "HeyBuds",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "HeyBuds", targets: ["HeyBuds"]),
               .executable(name: "heybuds-probe", targets: ["HeyBudsProbe"])],
    targets: [
        .target(name: "HeyBudsProtocol", resources: [.process("Resources")]),
        .target(name: "HeyBudsBluetooth", dependencies: ["HeyBudsProtocol"],
                linkerSettings: [.linkedFramework("IOBluetooth"), .linkedFramework("CoreBluetooth")]),
        .executableTarget(name: "HeyBuds", dependencies: ["HeyBudsProtocol", "HeyBudsBluetooth"]),
        .executableTarget(name: "HeyBudsProbe", dependencies: ["HeyBudsProtocol", "HeyBudsBluetooth"]),
        .testTarget(name: "HeyBudsProtocolTests", dependencies: ["HeyBudsProtocol"],swiftSettings:testSettings,linkerSettings:testLinker),
        .testTarget(name: "HeyBudsBluetoothTests", dependencies: ["HeyBudsBluetooth", "HeyBudsProtocol"],swiftSettings:testSettings,linkerSettings:testLinker),
        .testTarget(name: "HeyBudsTests", dependencies: ["HeyBuds"],swiftSettings:testSettings,linkerSettings:testLinker)
    ],
    swiftLanguageModes: [.v5]
)
