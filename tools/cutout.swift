import Vision
import CoreImage
import Foundation

// usage: swift cutout.swift input.jpg output.png [maxHeight]
let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: cutout input output [maxHeight]")
    exit(1)
}
let inURL  = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let maxH: CGFloat = args.count > 3 ? CGFloat(Double(args[3]) ?? 1600) : 1600
let erodeR: Double = args.count > 4 ? (Double(args[4]) ?? 2.5) : 2.5

guard var image = CIImage(contentsOf: inURL, options: [.applyOrientationProperty: true]) else {
    print("cannot load \(inURL.path)")
    exit(1)
}

let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(ciImage: image)
try handler.perform([request])
guard let result = request.results?.first, !result.allInstances.isEmpty else {
    print("no foreground found")
    exit(2)
}
let maskPB = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
var mask = CIImage(cvPixelBuffer: maskPB)

// маска может прийти в другом масштабе — растянем до кадра
let sx = image.extent.width / mask.extent.width
let sy = image.extent.height / mask.extent.height
if abs(sx - 1) > 0.001 || abs(sy - 1) > 0.001 {
    mask = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
}

// сначала даунскейлим кадр и маску до целевого размера,
// чтобы обработка краёв не зависела от исходного разрешения
func downscale(_ img: CIImage, to height: CGFloat) -> CIImage {
    guard img.extent.height > height else { return img }
    let k = height / img.extent.height
    let f = CIFilter(name: "CILanczosScaleTransform")!
    f.setValue(img, forKey: kCIInputImageKey)
    f.setValue(k, forKey: kCIInputScaleKey)
    f.setValue(1.0, forKey: kCIInputAspectRatioKey)
    return f.outputImage!
}
image = downscale(image, to: maxH)
mask  = downscale(mask,  to: maxH)

// ужесточаем мягкую маску: 0.3→0, 0.8→1
let poly = CIFilter(name: "CIColorPolynomial")!
poly.setValue(mask, forKey: kCIInputImageKey)
let coeff = CIVector(x: -0.6, y: 2.0, z: 0, w: 0)
poly.setValue(coeff, forKey: "inputRedCoefficients")
poly.setValue(coeff, forKey: "inputGreenCoefficients")
poly.setValue(coeff, forKey: "inputBlueCoefficients")
poly.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputAlphaCoefficients")
let clamp = CIFilter(name: "CIColorClamp")!
clamp.setValue(poly.outputImage!, forKey: kCIInputImageKey)
mask = clamp.outputImage!

// съедаем кромку фона: эрозия + лёгкое размытие для мягкого края
let erode = CIFilter(name: "CIMorphologyMinimum")!
erode.setValue(mask, forKey: kCIInputImageKey)
erode.setValue(erodeR, forKey: kCIInputRadiusKey)
mask = erode.outputImage!
let soften = CIFilter(name: "CIGaussianBlur")!
soften.setValue(mask, forKey: kCIInputImageKey)
soften.setValue(1.2, forKey: kCIInputRadiusKey)
mask = soften.outputImage!.cropped(to: image.extent)

let blend = CIFilter(name: "CIBlendWithMask")!
blend.setValue(image, forKey: kCIInputImageKey)
blend.setValue(CIImage(color: .clear).cropped(to: image.extent), forKey: kCIInputBackgroundImageKey)
blend.setValue(mask, forKey: kCIInputMaskImageKey)
var out = blend.outputImage!

let ctx = CIContext()

// обрезка по непрозрачному содержимому (+ отступ)
if let cg = ctx.createCGImage(out, from: out.extent),
   let data = cg.dataProvider?.data {
    let ptr = CFDataGetBytePtr(data)!
    let w = cg.width, h = cg.height
    let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w {
            if ptr[y * bpr + x * bpp + 3] > 16 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    if maxX >= minX {
        let pad = 12
        let cx0 = max(0, minX - pad), cy0 = max(0, minY - pad)
        let cx1 = min(w - 1, maxX + pad), cy1 = min(h - 1, maxY + pad)
        // CoreImage: origin снизу слева, CGImage-скан — сверху
        let rect = CGRect(x: CGFloat(cx0),
                          y: out.extent.height - CGFloat(cy1 + 1),
                          width: CGFloat(cx1 - cx0 + 1),
                          height: CGFloat(cy1 - cy0 + 1))
        out = out.cropped(to: rect.offsetBy(dx: out.extent.origin.x, dy: out.extent.origin.y))
        out = out.transformed(by: CGAffineTransform(translationX: -out.extent.origin.x,
                                                    y: -out.extent.origin.y))
    }
}
try ctx.writePNGRepresentation(of: out, to: outURL, format: .RGBA8,
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
print("ok \(Int(out.extent.width))x\(Int(out.extent.height)) -> \(outURL.lastPathComponent)")
