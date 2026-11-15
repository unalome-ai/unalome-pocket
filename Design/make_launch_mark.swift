import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Renders the launch-screen mark (UnalomeMark's proportions, transparent background) at
// 1x, 2x and 3x. Usage: swift make_launch_mark.swift <output-folder>
// The launch screen centres it on #06050a (the LaunchBackground colour).
let pointHeight: CGFloat = 96
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: space,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
        ])!
}

for scale in [1, 2, 3] {
    // As in UnalomeMark: height = 2.94 R; triangle 0.51 R tall, 0.57 R wide; ring stroke 0.46 R.
    let height = pointHeight * CGFloat(scale)
    let R = height / 2.94
    let width = Int((2 * R).rounded(.up))
    let ctx = CGContext(
        data: nil, width: width, height: Int(height), bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: height)
    ctx.scaleBy(x: 1, y: -1)
    let midX = CGFloat(width) / 2

    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: midX, y: 0))
    triangle.addLine(to: CGPoint(x: midX + 0.285 * R, y: 0.51 * R))
    triangle.addLine(to: CGPoint(x: midX - 0.285 * R, y: 0.51 * R))
    triangle.closeSubpath()
    ctx.saveGState()
    ctx.addPath(triangle)
    ctx.clip()
    let brand = CGGradient(
        colorsSpace: space, colors: [color(0x34D399), color(0x2DD4BF), color(0x22D3EE)] as CFArray,
        locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(
        brand, start: CGPoint(x: midX - 0.285 * R, y: 0), end: CGPoint(x: midX + 0.285 * R, y: 0.51 * R),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    let stroke = 0.46 * R
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(stroke)
    ctx.strokeEllipse(in: CGRect(x: midX - R + stroke / 2, y: 0.94 * R + stroke / 2, width: 2 * R - stroke, height: 2 * R - stroke))

    let output = folder.appending(path: "LaunchMark@\(scale)x.png")
    let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(output.path)") }
}
