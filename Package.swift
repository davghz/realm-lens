// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RealmLens",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "realm-lens", targets: ["realm-lens"]),
        .library(name: "RealmLensCore", targets: ["RealmLensCore"]),
        .executable(name: "RealmLens", targets: ["RealmLens"]),
    ],
    dependencies: [
        // GUI-only. RealmLensCore and the headless reader stay dependency-free so the
        // qualified reader artifact (baf8cb77) is unaffected by anything here.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        // Pure data layer: no SwiftUI, no AppKit. Fully testable headlessly.
        .target(name: "RealmLensCore",
                linkerSettings: [.linkedLibrary("sqlite3")]),
        // Headless CLI that dumps the reader's model as JSON. This exists so the app's
        // brain can be validated against fixtures without building or launching the GUI.
        .executableTarget(name: "realm-lens", dependencies: ["RealmLensCore"],
                          linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "RealmLens",
                          dependencies: ["RealmLensCore",
                                         .product(name: "SwiftTerm", package: "SwiftTerm")],
                          linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "RealmLensCoreTests", dependencies: ["RealmLensCore"]),
        .testTarget(name: "RealmLensTerminalTests", dependencies: ["RealmLens"]),
    ],
    swiftLanguageModes: [.v5]
)
