// swift-tools-version:5.9
// ClayCoreStub — placeholder for the real ClayCore package
// (https://github.com/CyberdyneCorp/ClayCore). Exposes the clay.h C ABI
// with canned implementations so the app shell can be built and tested
// before the engine lands. Swap this local package for the tag-pinned
// ClayCore dependency once its C ABI is published (see tasks.md 2.8).
import PackageDescription

let package = Package(
    name: "ClayCoreStub",
    products: [
        .library(name: "ClayCoreC", targets: ["ClayCoreC"])
    ],
    targets: [
        .target(name: "ClayCoreC")
    ]
)
