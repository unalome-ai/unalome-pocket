import SwiftUI

/// Geometry of the unalome: a spiral (confusion) that settles through ever smaller
/// waves into a straight line (understanding), topped by the brand's triangle.
///
/// Defined in a unit space, x and y in 0...1 with y pointing down, and fitted into
/// any rectangle by `UnalomeGeometry.transform(in:)`.
enum UnalomeGeometry {
    /// Width of the figure relative to its height.
    static let aspectRatio: CGFloat = 0.46

    private static let spiralCenter = CGPoint(x: 0.5, y: 0.80)
    private static let spiralRadius = 0.19
    private static let waveAmplitude = 0.17
    private static let wavesTopY = 0.27
    private static let lineTopY = 0.115

    /// The line from the centre of the spiral to the top of the straight stroke.
    static let linePoints: [CGPoint] = {
        var points: [CGPoint] = []

        // Spiral, winding outwards and ending at its top, heading right.
        let turns = 2.25
        let spiralSamples = 240
        for index in 0...spiralSamples {
            let u = Double(index) / Double(spiralSamples)
            let angle = -Double.pi / 2 - turns * 2 * .pi * (1 - u)
            let radius = spiralRadius * u
            points.append(CGPoint(
                x: spiralCenter.x + radius * cos(angle),
                y: spiralCenter.y + radius * sin(angle)))
        }

        // Waves stacked above the spiral, each narrower than the last. They start in the
        // spiral's direction of travel and their width falls to nothing with zero slope,
        // so the curve enters the straight line without a kink.
        let cycles = 2.5
        let waveSamples = 260
        let wavesBottomY = spiralCenter.y - spiralRadius
        for index in 1...waveSamples {
            let v = Double(index) / Double(waveSamples)
            let amplitude = waveAmplitude * (1 - v) * (1 - v)
            points.append(CGPoint(
                x: 0.5 + amplitude * sin(2 * .pi * cycles * v),
                y: wavesBottomY - (wavesBottomY - wavesTopY) * v))
        }

        points.append(CGPoint(x: 0.5, y: lineTopY))
        return points
    }()

    /// The triangle above the line, pointing up.
    static let tipPoints: [CGPoint] = [
        CGPoint(x: 0.5, y: 0.0),
        CGPoint(x: 0.546, y: 0.078),
        CGPoint(x: 0.454, y: 0.078),
    ]

    /// Maps the unit space into `rect`, centred, keeping the figure's proportions.
    static func transform(in rect: CGRect) -> CGAffineTransform {
        let side = min(rect.height, rect.width / aspectRatio)
        return CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2)
            .scaledBy(x: side, y: side)
    }
}

/// The unalome's line. Trim it to draw it progressively.
public struct UnalomeLine: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addLines(UnalomeGeometry.linePoints)
        return path.applying(UnalomeGeometry.transform(in: rect))
    }
}

/// The triangle that completes the unalome.
public struct UnalomeTip: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addLines(UnalomeGeometry.tipPoints)
        path.closeSubpath()
        return path.applying(UnalomeGeometry.transform(in: rect))
    }
}

/// The Unalome logo mark: a white ring with the gradient triangle above it.
public struct UnalomeMark: View {
    private let height: CGFloat

    public init(height: CGFloat = 28) {
        self.height = height
    }

    public var body: some View {
        // Proportions of the mark, in units of the ring's outer radius:
        // triangle 0.51 tall and 0.57 wide, a 0.43 gap, then the ring (stroke 0.46).
        let radius = height / 2.94
        Canvas { context, size in
            let midX = size.width / 2
            var triangle = Path()
            triangle.move(to: CGPoint(x: midX, y: 0))
            triangle.addLine(to: CGPoint(x: midX + 0.285 * radius, y: 0.51 * radius))
            triangle.addLine(to: CGPoint(x: midX - 0.285 * radius, y: 0.51 * radius))
            triangle.closeSubpath()
            context.fill(
                triangle,
                with: .linearGradient(
                    Gradient(colors: UnalomeGradient.colors),
                    startPoint: CGPoint(x: midX - 0.285 * radius, y: 0),
                    endPoint: CGPoint(x: midX + 0.285 * radius, y: 0.51 * radius)))

            let stroke = 0.46 * radius
            let ringRect = CGRect(
                x: midX - radius + stroke / 2,
                y: 0.94 * radius + stroke / 2,
                width: 2 * radius - stroke,
                height: 2 * radius - stroke)
            context.stroke(Path(ellipseIn: ringRect), with: .color(.white), lineWidth: stroke)
        }
        .frame(width: 2 * radius, height: height)
        .accessibilityHidden(true)
    }
}
