import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Renders the Unalome Pocket app icon at 1024 px. Usage: swift make_icon.swift <output.png>
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

// Work in a top-left origin, like the design.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: space,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
        ])!
}

func radial(_ center: CGPoint, _ radius: CGFloat, _ colors: [CGColor], _ stops: [CGFloat]) {
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops)!
    ctx.drawRadialGradient(
        gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
        options: [.drawsAfterEndLocation])
}

// Background: the site's base colour, lifted by two soft glows.
ctx.setFillColor(color(0x06050A))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
radial(CGPoint(x: 512, y: 640), 640, [color(0x10B981, 0.34), color(0x10B981, 0.10), color(0x10B981, 0)], [0, 0.5, 1])
radial(CGPoint(x: 820, y: 180), 520, [color(0x22D3EE, 0.16), color(0x22D3EE, 0)], [0, 1])

// The mark: triangle above a ring. Units of the ring's outer radius R.
let R: CGFloat = 200
let midX: CGFloat = 512
let gap = 0.36 * R
let triangleHeight = 0.66 * R
let top: CGFloat = 512 - (triangleHeight + gap + 2 * R) / 2 - 6
let triangleHalfWidth = 0.37 * R
let ringCenter = CGPoint(x: midX, y: top + triangleHeight + gap + R)
let stroke = 0.44 * R

// Ring, with a soft shadow so it sits on the glow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 0), blur: 60, color: color(0x2DD4BF, 0.45))
ctx.setStrokeColor(color(0xFFFFFF))
ctx.setLineWidth(stroke)
ctx.strokeEllipse(in: CGRect(
    x: ringCenter.x - R + stroke / 2, y: ringCenter.y - R + stroke / 2,
    width: 2 * R - stroke, height: 2 * R - stroke))
ctx.restoreGState()

// Triangle, filled with the brand gradient.
let triangle = CGMutablePath()
triangle.move(to: CGPoint(x: midX, y: top))
triangle.addLine(to: CGPoint(x: midX + triangleHalfWidth, y: top + triangleHeight))
triangle.addLine(to: CGPoint(x: midX - triangleHalfWidth, y: top + triangleHeight))
triangle.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 50, color: color(0x34D399, 0.8))
ctx.addPath(triangle)
ctx.setFillColor(color(0x2DD4BF))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(triangle)
ctx.clip()
let brand = CGGradient(
    colorsSpace: space, colors: [color(0x34D399), color(0x2DD4BF), color(0x22D3EE)] as CFArray,
    locations: [0, 0.5, 1])!
ctx.drawLinearGradient(
    brand,
    start: CGPoint(x: midX - triangleHalfWidth, y: top),
    end: CGPoint(x: midX + triangleHalfWidth, y: top + triangleHeight),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let image = ctx.makeImage()!
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(output.path)") }
