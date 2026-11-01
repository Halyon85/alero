// swift-tools-version:5.10
import PackageDescription

// Alero: utilidades para la Mac en la barra de menú y en el notch. Sin dependencias de Swift: el adaptador de música
// (Vendor/mediaremote-adapter) se compila aparte con cmake desde `compilar.sh` y viaja dentro de la app.
let package = Package(
    name: "Alero",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Alero",
            path: "Sources/Alero",
            swiftSettings: [.unsafeFlags(["-Osize"])],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("EventKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Speech"),
            ]
        ),
        // Pruebas de las piezas sin pantalla ni permisos (reglas, cálculos y modelos de cada función): `swift test`.
        .testTarget(
            name: "AleroTests",
            dependencies: ["Alero"],
            path: "Tests/AleroTests"
        ),
    ]
)
