// Turns the renders from `--render-windows` and `--render-snapshots` into the images in docs/images: resized, with
// rounded corners and a 2 px edge, in sRGB and with no metadata. Run through `make readme-images`.
//
//   swift Scripts/readme-images.swift <windows-dir> <snapshots-dir> <output-dir>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: readme-images.swift <windows-dir> <snapshots-dir> <output-dir>\n".utf8))
    exit(2)
}
let windows = URL(fileURLWithPath: arguments[1])
let snapshots = URL(fileURLWithPath: arguments[2])
let output = URL(fileURLWithPath: arguments[3])
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func load(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write(Data("missing render: \(url.path)\n".utf8))
        exit(1)
    }
    return image
}

func save(_ image: CGImage, _ name: String) {
    let url = output.appending(path: name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(url.path)") }
    print("wrote \(url.path)")
}

func context(width: Int, height: Int) -> CGContext {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    return context
}

/// Draws `image` into `rect` of `context`, clipped to rounded corners, with the README's edge on top.
func drawFramed(_ image: CGImage, in rect: CGRect, radius: CGFloat, dark: Bool, context: CGContext) {
    let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.draw(image, in: rect)
    context.restoreGState()
    let inset = rect.insetBy(dx: 1, dy: 1)
    context.addPath(CGPath(roundedRect: inset, cornerWidth: radius - 1, cornerHeight: radius - 1, transform: nil))
    context.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.16) : CGColor(gray: 0, alpha: 0.16))
    context.setLineWidth(2)
    context.strokePath()
}

func framed(_ image: CGImage, width: Int, radius: CGFloat, dark: Bool) -> CGImage {
    let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
    let canvas = context(width: width, height: height)
    drawFramed(image, in: CGRect(x: 0, y: 0, width: width, height: height), radius: radius, dark: dark, context: canvas)
    return canvas.makeImage()!
}

/// The row, counted from the top, of the gap between two cards nearest the middle of a full-height popover render.
/// A gap row matches the background at the image's left edge across the whole card width.
func cardGap(in image: CGImage) -> (row: Int, background: CGColor) {
    let width = image.width, height = image.height
    let canvas = context(width: width, height: height)
    canvas.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = canvas.data!.bindMemory(to: UInt8.self, capacity: canvas.bytesPerRow * height)
    func pixel(_ x: Int, _ row: Int) -> (Int, Int, Int) {
        let offset = row * canvas.bytesPerRow + x * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }
    func isGap(_ row: Int) -> Bool {
        let background = pixel(4, row)
        return stride(from: 30, to: width - 30, by: 2).allSatisfy { x in
            let p = pixel(x, row)
            return abs(p.0 - background.0) + abs(p.1 - background.1) + abs(p.2 - background.2) <= 6
        }
    }
    let gaps = (height / 4..<height * 3 / 4).filter(isGap)
    guard !gaps.isEmpty else { fatalError("no gap between cards in the full popover render") }
    // The middle of each run of gap rows, then the one closest to half the height.
    var runs: [[Int]] = []
    for row in gaps {
        if let last = runs.last?.last, last == row - 1 { runs[runs.count - 1].append(row) } else { runs.append([row]) }
    }
    let row = runs.map { $0[$0.count / 2] }.min { abs($0 - height / 2) < abs($1 - height / 2) }!
    let (r, g, b) = pixel(4, row)
    return (row, CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
}

/// `image` with `top` and `bottom` rows of `color` added, so a card cut out of a taller render clears the corners.
func padded(_ image: CGImage, top: Int, bottom: Int, color: CGColor) -> CGImage {
    let canvas = context(width: image.width, height: image.height + top + bottom)
    canvas.setFillColor(color)
    canvas.fill(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
    canvas.draw(image, in: CGRect(x: 0, y: bottom, width: image.width, height: image.height))
    return canvas.makeImage()!
}

/// Every card of the full-height popover in two columns side by side, split at the card gap nearest the middle.
func twoColumns(_ image: CGImage, radius: CGFloat, dark: Bool) -> CGImage {
    let (split, background) = cardGap(in: image)
    let pad = 16
    let top = padded(image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: split))!, top: 0, bottom: pad, color: background)
    let bottom = padded(
        image.cropping(to: CGRect(x: 0, y: split, width: image.width, height: image.height - split))!, top: pad, bottom: 0, color: background
    )
    let gutter = 40
    let width = image.width * 2 + gutter, height = max(top.height, bottom.height)
    let canvas = context(width: width, height: height)
    drawFramed(top, in: CGRect(x: 0, y: height - top.height, width: top.width, height: top.height), radius: radius, dark: dark, context: canvas)
    drawFramed(
        bottom, in: CGRect(x: image.width + gutter, y: height - bottom.height, width: bottom.width, height: bottom.height),
        radius: radius, dark: dark, context: canvas
    )
    return canvas.makeImage()!
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for theme in ["light", "dark"] {
    let dark = theme == "dark"
    for screen in ["popover", "popover-spend-limit", "popover-api-value"] {
        save(framed(load(windows.appending(path: "\(screen)-\(theme).png")), width: 720, radius: 24, dark: dark), "\(screen)-\(theme).png")
    }
    save(twoColumns(load(snapshots.appending(path: "popover-full-\(theme).png")), radius: 24, dark: dark), "popover-providers-\(theme).png")
    save(framed(load(windows.appending(path: "dashboard-all-default-\(theme).png")), width: 1720, radius: 22, dark: dark), "dashboard-\(theme).png")
    save(
        framed(load(windows.appending(path: "settings-account-claude-work-\(theme).png")), width: 1360, radius: 22, dark: dark),
        "settings-account-\(theme).png"
    )
}
