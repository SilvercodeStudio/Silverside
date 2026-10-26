// Renders the Rip button's pictures from an Icon Composer file, with Icon Composer's own
// renderer (ictool), so that the button has the icon's glass look:
//
//   make rip-art, or: swift App/Icon/make_rip_art.swift [App/Silverside/SilversideRipIcon.icon]
//
// writes two image sets into App/Silverside/Assets.xcassets, each light and dark:
//
// - RipArt: the whole icon.
// - RipArtFront: the same picture where only the Arm, Laser, and Disc groups and the icon's
//   rim are, transparent elsewhere. The button draws RipArt, then the level bars, then
//   RipArtFront, so that the bars pass behind the arm.
//
// A macOS icon always has an opaque background, so RipArtFront comes from two renders of
// those groups alone, one on black and one on white: where the background shows, the two
// differ, and the difference is how much shows (1 - alpha). Run this again after the icon changes.
import AppKit
import Foundation

let ictool = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
let frontGroups: Set<String> = ["Arm", "Laser", "Disc"]
/// 256 points at 2x: the button is about 120 points wide.
let points = 256

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let icon = URL(
    fileURLWithPath: CommandLine.arguments.count > 1
        ? CommandLine.arguments[1] : root.appending(path: "Silverside/SilversideRipIcon.icon").path)
let assets = root.appending(path: "Silverside/Assets.xcassets")
let work = FileManager.default.temporaryDirectory.appending(path: "rip-art-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(1)
}

/// Renders an icon file to PNG with ictool, in the Default (light) or Dark rendition.
func render(_ file: URL, rendition: String) -> CGImage {
    let output = work.appending(path: "\(file.deletingPathExtension().lastPathComponent)-\(rendition).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ictool)
    process.arguments = [
        file.path, "--export-image", "--output-file", output.path, "--platform", "macOS", "--rendition", rendition,
        "--width", "\(points)", "--height", "\(points)", "--scale", "2",
    ]
    process.standardOutput = FileHandle.nullDevice
    do { try process.run() } catch { fail("cannot run \(ictool): \(error)") }
    process.waitUntilExit()
    guard let source = CGImageSourceCreateWithURL(output as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("ictool made no image of \(file.path)") }
    return image
}

/// A copy of the icon with only the front groups, on one solid color.
func frontOnly(fill: String) -> URL {
    let copy = work.appending(path: "front-\(fill).icon")
    do {
        try FileManager.default.copyItem(at: icon, to: copy)
        let file = copy.appending(path: "icon.json")
        guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
            let groups = json["groups"] as? [[String: Any]]
        else { fail("\(icon.path) has no groups") }
        json["groups"] = groups.filter { frontGroups.contains($0["name"] as? String ?? "") }
        // The dark rendition takes only a fill made for it.
        let solid = ["solid": "srgb:\(fill),\(fill),\(fill),1"]
        json["fill-specializations"] = [["value": solid], ["appearance": "dark", "value": solid]]
        try JSONSerialization.data(withJSONObject: json).write(to: file)
    } catch {
        fail("cannot copy \(icon.path): \(error)")
    }
    return copy
}

/// RGBA bytes, premultiplied, in sRGB.
func pixels(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(
        data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
}

func write(_ bytes: [UInt8], width: Int, height: Int, to url: URL) {
    var bytes = bytes
    let context = CGContext(
        data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    guard let image = context.makeImage(),
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { fail("cannot make \(url.lastPathComponent)") }
    do { try data.write(to: url) } catch { fail("cannot write \(url.path): \(error)") }
}

func writeSet(_ name: String, light: [UInt8], dark: [UInt8], width: Int, height: Int) {
    let folder = assets.appending(path: "\(name).imageset")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    write(light, width: width, height: height, to: folder.appending(path: "\(name).png"))
    write(dark, width: width, height: height, to: folder.appending(path: "\(name)-dark.png"))
    let contents = """
        {
          "images" : [
            {
              "filename" : "\(name).png",
              "idiom" : "universal",
              "scale" : "2x"
            },
            {
              "appearances" : [
                {
                  "appearance" : "luminosity",
                  "value" : "dark"
                }
              ],
              "filename" : "\(name)-dark.png",
              "idiom" : "universal",
              "scale" : "2x"
            }
          ],
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }

        """
    try? Data(contents.utf8).write(to: folder.appending(path: "Contents.json"))
}

let onBlack = frontOnly(fill: "0")
let onWhite = frontOnly(fill: "1")
var renders = [String: (full: [UInt8], front: [UInt8])]()
var size = (width: 0, height: 0)
for rendition in ["Default", "Dark"] {
    let fullImage = render(icon, rendition: rendition)
    size = (fullImage.width, fullImage.height)
    let full = pixels(fullImage)
    let black = pixels(render(onBlack, rendition: rendition))
    let white = pixels(render(onWhite, rendition: rendition))
    var front = [UInt8](repeating: 0, count: full.count)
    for pixel in stride(from: 0, to: full.count, by: 4) {
        // Outside the icon's shape both are transparent: nothing to draw there.
        let difference = (0..<3).map { abs(Int(white[pixel + $0]) - Int(black[pixel + $0])) }.max()!
        let alpha = Double(255 - difference) / 255 * Double(full[pixel + 3]) / 255
        for channel in 0..<3 {
            // The full picture's color, premultiplied by its own alpha, then by the front's.
            let straight = full[pixel + 3] == 0 ? 0 : Double(full[pixel + channel]) / Double(full[pixel + 3])
            front[pixel + channel] = UInt8((straight * alpha * 255).rounded())
        }
        front[pixel + 3] = UInt8((alpha * 255).rounded())
    }
    renders[rendition] = (full, front)
}
writeSet("RipArt", light: renders["Default"]!.full, dark: renders["Dark"]!.full, width: size.width, height: size.height)
writeSet(
    "RipArtFront", light: renders["Default"]!.front, dark: renders["Dark"]!.front, width: size.width,
    height: size.height)
print("Wrote RipArt and RipArtFront (\(size.width) x \(size.height), light and dark) in \(assets.path)")
