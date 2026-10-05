// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentPad",
    defaultLocalization: "en",
    platforms: [
        // .v14 floor — `@Observable` macro requires Sonoma+. Dropping further
        // would mean reverting all session models to ObservableObject + @Published.
        // AgentPad: 14.5, as released (LSMinimumSystemVersion).
        .macOS("14.5")
    ],
    dependencies: [
        // AgentPad: in-app updates ("Install and Relaunch"), verified with an
        // EdDSA key and a Developer ID signature. Pinned: updates are deliberate.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        // AgentPad: the server mode's local cache and run journal (SQLite,
        // docs/agentpad/CHAT-PLAN.md C4). MIT. Pinned like the others.
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        // Thin executable: main.swift only. Everything else lives in AgentPadKit so
        // tests can `@testable import` it (SPM doesn't allow importing executables).
        .executableTarget(
            name: "AgentPad",
            dependencies: ["AgentPadKit"],
            path: "Sources/AgentPad",
            // AgentPad: Sparkle.framework lives in Contents/Frameworks of the
            // app bundle (scripts/build-app.sh).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // Tiny stand-alone CLI invoked from Claude Code / Codex hooks. Reads
        // $AGENTPAD_SURFACE_ID from env, opens the unix socket the running app
        // owns, writes one JSON line, exits. Doesn't link AgentPadKit on purpose
        // — keeps the binary fast and dependency-free.
        .executableTarget(
            name: "AgentPadHook",
            dependencies: ["AgentPadHookKit"],
            path: "Sources/AgentPadHook"
        ),
        // User-facing control CLI (`agentpad-cli`): open tabs / run commands /
        // resume conversations / list / focus / close / status over the same
        // unix socket, but request-response instead of fire-and-forget.
        // Separate from AgentPadHook on purpose — hook argv is positional
        // (`agentpad-hook <agent> <event>`) and a custom agent id could collide
        // with a verb. Doesn't link AgentPadKit for the same reason AgentPadHook
        // doesn't: the binary must stay small and AppKit-free. The target
        // IS the shipped binary name so one name holds across dev builds,
        // the bundle, and the Application Support mirror (nobody imports an
        // executable, so the mangled module name never surfaces).
        .executableTarget(
            name: "agentpad-cli",
            dependencies: ["AgentPadHookKit"],
            path: "Sources/AgentPadCLI"
        ),
        // Payload builders + stdin parsing extracted out of `main.swift` so
        // they're unit-testable without spawning a subprocess. Foundation /
        // Darwin only — must not depend on AgentPadKit (would bloat the CLI).
        .target(
            name: "AgentPadHookKit",
            path: "Sources/AgentPadHookKit"
        ),
        .target(
            name: "AgentPadKit",
            dependencies: [
                "GhosttyKit",
                // CLI wire types (AgentPadCLIRequest/Response) — compiled into
                // both ends so the protocol can't drift. One-way dependency;
                // AgentPadHookKit stays Foundation/Darwin-only.
                "AgentPadHookKit",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/AgentPadKit",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                // libghostty bundles C++ deps (glslang, spirv-cross, imgui)
                // and uses Metal for rendering; link the system frameworks.
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                // Text Input Services — libghostty uses TIS to read the active
                // keyboard layout. Pulled in implicitly by SwiftTerm before;
                // now declared directly.
                .linkedFramework("Carbon"),
            ]
        ),
        .binaryTarget(
            name: "GhosttyKit",
            // Run scripts/setup-libghostty.sh to populate this; not committed.
            path: "Vendor/GhosttyKit.xcframework"
        ),
        .testTarget(
            name: "AgentPadKitTests",
            // AgentPadHookKit is listed so socket integration tests can drive
            // HookServer with the real CLI transport client.
            dependencies: ["AgentPadKit", "AgentPadHookKit"],
            path: "Tests/AgentPadKitTests",
            // AgentPad: the server's API samples, read from disk by the
            // chat tests (scripts/sync-chat-fixtures.sh).
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "AgentPadHookKitTests",
            dependencies: ["AgentPadHookKit"],
            path: "Tests/AgentPadHookKitTests"
        ),
    ]
)
