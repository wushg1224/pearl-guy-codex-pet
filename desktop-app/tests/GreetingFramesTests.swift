import ImageIO
import UniformTypeIdentifiers

func loadImage(_ path: String) -> CGImage {
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(source, 0, nil)!
}

func pixels(_ image: CGImage) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
    result.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return result
}

let sheet = loadImage(CommandLine.arguments[1])
let artwork = loadImage(CommandLine.arguments[2])
let preview = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
var greeting: [CGImage] = []
var inkCounts: [Int] = []
for state in PetState.allCases where state != .hug {
    for index in 0..<state.frameCount {
        let sprite = sheet.cropping(to: CGRect(x: index * 192, y: state.rawValue * 208,
                                             width: 192, height: 208))!
        let image = GreetingFrames.render(sprite, state: state, frame: index, artwork: artwork)
        precondition(image.width == 192 && image.height == 277, "Every state needs the same padded canvas")
        let bottom = image.cropping(to: CGRect(x: 0, y: 69, width: 192, height: 208))!
        let original = pixels(sprite), rendered = pixels(bottom)
        precondition(zip(original, rendered).allSatisfy { abs(Int($0) - Int($1)) <= 2 },
                     "Original character pixels and foot position must survive compositing")
        let top = image.cropping(to: CGRect(x: 0, y: 0, width: 192, height: 69))!
        let topPixels = pixels(top)
        let count = stride(from: 3, to: topPixels.count, by: 4).filter { topPixels[$0] > 0 }.count
        if state != .waving || index == 0 {
            precondition(count == 0, "Other states and the first greeting frame must have no bubble")
        }
        if state == .waving {
            greeting.append(image)
            inkCounts.append(count)
            let data = pixels(image)
            for x in 0..<192 { precondition(data[x * 4 + 3] == 0, "Bubble must fit below the top edge") }
            for y in 0..<277 {
                precondition(data[(y * 192) * 4 + 3] == 0 && data[(y * 192 + 191) * 4 + 3] == 0,
                             "Artwork must fit inside the frame sides")
            }
        }
        precondition(GreetingFrames.render(sprite, state: state, frame: index, artwork: nil) === sprite,
                     "Missing artwork must keep the original sprites usable")
    }
}
precondition(inkCounts[2] > inkCounts[1] && inkCounts[1] > inkCounts[3] && inkCounts[3] > 0,
             "Bubble must pop in, grow, and shrink across the greeting")
let large = CGContext(data: nil, width: 384, height: 416, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
large.interpolationQuality = .none
large.draw(sheet.cropping(to: CGRect(x: 384, y: 624, width: 192, height: 208))!,
           in: CGRect(x: 0, y: 0, width: 384, height: 416))
let largeFrame = GreetingFrames.render(large.makeImage()!, state: .waving, frame: 2, artwork: artwork)
precondition(largeFrame.width == 384 && largeFrame.height == 555, "Scaled atlases must keep proportional padding")
let wrongArtwork = artwork.cropping(to: CGRect(x: 0, y: 0, width: 100, height: 100))!
precondition(GreetingFrames.render(greeting[0], state: .waving, frame: 2, artwork: wrongArtwork) === greeting[0],
             "Unexpected artwork dimensions must fall back safely")

let strip = CGContext(data: nil, width: 768, height: 277, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
for (index, image) in greeting.enumerated() {
    strip.draw(image, in: CGRect(x: index * 192, y: 0, width: 192, height: 277))
}
let png = CGImageDestinationCreateWithURL(preview.appendingPathComponent("waving-hi.png") as CFURL,
                                         UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(png, strip.makeImage()!, nil)
precondition(CGImageDestinationFinalize(png), "PNG export must succeed")
let gif = CGImageDestinationCreateWithURL(preview.appendingPathComponent("gifs/waving.gif") as CFURL,
                                         UTType.gif.identifier as CFString, greeting.count, nil)!
CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for (index, image) in greeting.enumerated() {
    CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary:
        [kCGImagePropertyGIFDelayTime: PetState.waving.durations[index]]] as CFDictionary)
}
precondition(CGImageDestinationFinalize(gif), "GIF export must succeed")
print("PASS: original pixels, all nine states, four bubble stages, transparent bounds, missing/invalid artwork, 2x atlas, PNG/GIF exports")
