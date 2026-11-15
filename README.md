# TailTrace

SwiftUI and PencilKit iPad research prototype for tracing microscopy tails across image frames and exporting calibrated centerline coordinates as CSV.

## Build
Open TailTrace.xcodeproj in Xcode. Select your own development team under Signing & Capabilities, then build for an iPad running iPadOS 17 or later. No third-party dependencies.

## Use
Import TIFF, PNG or JPEG images, choose a tail color, trace with Apple Pencil, navigate frames, and export CSV. Calibration defaults to 2.91 pixels/µm and spacing to 5 µm; use the actual calibration of your images. Appearance controls and reversible smoothing preserve raw PencilKit data.

## Validation status
Signed device builds and standalone geometry tests have passed. Full end-to-end CSV, persistence, smoothing accuracy and biological validation remain incomplete. Colors are manual identity assignments, not proof of biological continuity. Smoothing changes measurements. Project save/open controls were removed from the simplified UI; export before replacing a stack.

## Geometry checks
```sh
swiftc Sources/Geometry.swift Tests/main.swift -o /tmp/tailtrace-tests
/tmp/tailtrace-tests
```

Original research images, signing details, device identifiers, build logs, and user-specific Xcode state are not included.
