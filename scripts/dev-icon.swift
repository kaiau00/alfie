// Recolour Moe's icon for the development build.
//
// Moe Dev must be recognisable across the room, not by reading a title.
// On 2026-09-03 someone spent twenty minutes looking at a months-old build
// wondering what had happened to their Mac, because the only thing telling
// it apart from their own Moe was a version string inside the bundle. A
// name is read; an icon is seen. Chrome Canary is gold and Firefox Nightly
// is blue for exactly this reason.
//
// Derived from the real icon rather than committed as a second .icns, so
// the two can never drift apart and there is no artwork to maintain twice.
//
//   swift scripts/dev-icon.swift <in.png> <out.png>
//
// Hue-rotated most of the way round the wheel and pushed up in saturation:
// far enough that no glance confuses the two, close enough that it is still
// recognisably Moe. `sips` cannot do this — it re-encodes without touching
// colour — which is worth saying because reaching for it is the obvious
// mistake and it fails silently, producing an identical icon.

import CoreImage
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: dev-icon.swift <in.png> <out.png>\n".utf8))
    exit(2)
}

guard let input = CIImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write(Data("cannot read \(args[1])\n".utf8))
    exit(1)
}

// 2.4 radians ≈ 137°, which takes Moe's blue into a warm orange-gold.
let hue = CIFilter(name: "CIHueAdjust", parameters: [
    kCIInputImageKey: input, "inputAngle": 2.4,
])
guard let hued = hue?.outputImage else { exit(1) }

let vivid = CIFilter(name: "CIColorControls", parameters: [
    kCIInputImageKey: hued, "inputSaturation": 1.35, "inputBrightness": 0.02,
])
guard let out = vivid?.outputImage else { exit(1) }

let ctx = CIContext(options: [.useSoftwareRenderer: true])
guard let png = ctx.pngRepresentation(of: out, format: .RGBA8,
                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: args[2]))
} catch {
    FileHandle.standardError.write(Data("cannot write \(args[2]): \(error)\n".utf8))
    exit(1)
}
