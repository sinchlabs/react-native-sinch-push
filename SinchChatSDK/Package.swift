// swift-tools-version:6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package.init(
    name: "SinchChatSDK",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [
        .library(name: "SinchChatSDK", targets: ["SinchChatSDK"])
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.4.0"),
        .package(url: "https://github.com/onevcat/Kingfisher.git", from: "8.9.0")
    ],
    targets: [
        .target(
                        name: "SinchChatSDK",
                        dependencies: [
                            .product(name: "GRPCCore", package: "grpc-swift-2"),
                            .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                            .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                            .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                            .product(name: "Kingfisher", package: "Kingfisher")
                        ],
                        resources: [
                            .process("record.wav")]
                    ),
        .testTarget(
            name: "SinchChatSDKTests",
            dependencies: ["SinchChatSDK"],
            path: "Tests/SinchChatSDKTests"
        )
    ],
    swiftLanguageModes: [.v6]
)

//let package = Package(
//    name: "SinchChatSDK",
//    defaultLocalization: "en",
//    platforms: [.iOS(.v17)],
//    products: [
//        // Products define the executables and libraries a package produces, and make them visible to other packages.
//        .library(
//            name: "SinchChatSDK",
//            targets: ["SinchChatSDK"])
//    ],
//    dependencies: [
//        // Dependencies declare other packages that this package depends on.
//        // .package(url: /* package url */, from: "1.0.0"),
//        .package(url: "https://github.com/grpc/grpc-swift.git", from: "2.4.0"),
//        .package(url: "https://github.com/onevcat/Kingfisher.git", from: "8.9.0")
//    ],
//    targets: [
//        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
//        // Targets can depend on other targets in this package, and on products in packages this package depends on.
//        .target(
//            name: "SinchChatSDK",
//            dependencies: [
//                .product(name: "GRPC", package: "grpc-swift"),
//                .product(name: "Kingfisher", package: "Kingfisher")
//            ],
//            resources: [
//                .process("record.wav")]
//        ),
//        .testTarget(
//            name: "SinchChatSDKTests",
//            dependencies: ["SinchChatSDK"])
//    ],
//    swiftLanguageVersions: [.v6]
//)
