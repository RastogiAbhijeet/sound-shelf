// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SoundShelf",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SoundShelf", targets: ["SoundShelf"])],
    targets: [.executableTarget(name: "SoundShelf")]
)
