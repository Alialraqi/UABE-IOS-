import SwiftUI
import UIKit
import CoreGraphics

enum PaintTool: String, CaseIterable, Identifiable {
    case brush, eraser, line, rectangle, ellipse, fill, picker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brush: return "Brush"
        case .eraser: return "Eraser"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .fill: return "Fill"
        case .picker: return "Picker"
        }
    }

    var symbol: String {
        switch self {
        case .brush: return "paintbrush.pointed.fill"
        case .eraser: return "eraser.fill"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .fill: return "drop.fill"
        case .picker: return "eyedropper"
        }
    }

    var isShape: Bool { self == .line || self == .rectangle || self == .ellipse }
}

private struct PatchStep {
    let rect: CGRect
    let image: CGImage
}

final class CanvasDocument: ObservableObject {
    let width: Int
    let height: Int

    @Published var tool: PaintTool = .brush {
        didSet { if tool != .picker { lastDrawingTool = tool } }
    }
    @Published var color: Color = .red
    @Published var size: Double = 16
    @Published var opacity: Double = 1
    @Published var filled = false
    @Published var tolerance: Double = 24
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isDirty = false

    var fitHandler: (() -> Void)?

    private let original: CGImage
    private let ctx: CGContext
    private let strokeCtx: CGContext
    private weak var baseLayer: CALayer?
    private weak var strokeLayer: CALayer?

    private var undoStack: [PatchStep] = []
    private var redoStack: [PatchStep] = []
    private var opBase: CGImage?
    private var dirty = CGRect.null
    private var active = false
    private var startPoint = CGPoint.zero
    private var prevPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var lastDrawingTool: PaintTool = .brush

    var maxSize: Double { Double(max(32, max(width, height) / 6)) }

    private var fullRect: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    init(image: UIImage) {
        var cg = image.cgImage
        if cg == nil {
            let renderer = UIGraphicsImageRenderer(size: image.size)
            cg = renderer.image { _ in image.draw(at: .zero) }.cgImage
        }
        let source = cg ?? CanvasDocument.blankImage()
        original = source
        width = source.width
        height = source.height
        ctx = CanvasDocument.makeContext(source.width, source.height)
        strokeCtx = CanvasDocument.makeContext(source.width, source.height)
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.copy)
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        ctx.setBlendMode(.normal)
        size = Double(max(4, max(source.width, source.height) / 64))
    }

    private static func makeContext(_ w: Int, _ h: Int) -> CGContext {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        if let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                             space: space, bitmapInfo: info) {
            return c
        }
        return CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: info)!
    }

    private static func blankImage() -> CGImage {
        makeContext(1, 1).makeImage()!
    }

    func attach(base: CALayer, stroke: CALayer) {
        baseLayer = base
        strokeLayer = stroke
        refreshBase()
    }

    private func flip(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: CGFloat(height) - p.y)
    }

    private func ctxRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: CGFloat(height) - r.maxY, width: r.width, height: r.height)
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), CGFloat(width)), y: min(max(p.y, 0), CGFloat(height)))
    }

    private func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private func mark(_ r: CGRect) {
        dirty = dirty.isNull ? r : dirty.union(r)
    }

    private var drawColor: CGColor { UIColor(color).cgColor }

    func refreshBase() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseLayer?.contents = ctx.makeImage()
        CATransaction.commit()
    }

    private func showStroke() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokeLayer?.contents = strokeCtx.makeImage()
        strokeLayer?.opacity = Float(opacity)
        CATransaction.commit()
    }

    private func clearStroke() {
        strokeCtx.clear(fullRect)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokeLayer?.contents = nil
        CATransaction.commit()
    }

    private func deepCopy() -> CGImage? {
        guard let image = ctx.makeImage() else { return nil }
        let copy = CanvasDocument.makeContext(width, height)
        copy.setBlendMode(.copy)
        copy.draw(image, in: fullRect)
        return copy.makeImage()
    }

    private func copyRegion(_ image: CGImage, _ rect: CGRect) -> CGImage? {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !r.isNull, r.width >= 1, r.height >= 1, let cropped = image.cropping(to: r) else { return nil }
        let c = CanvasDocument.makeContext(cropped.width, cropped.height)
        c.interpolationQuality = .none
        c.setBlendMode(.copy)
        c.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return c.makeImage()
    }

    private func beginOp(deep: Bool = false) {
        opBase = deep ? deepCopy() : ctx.makeImage()
        dirty = .null
    }

    private func endOp() {
        defer {
            opBase = nil
            dirty = .null
        }
        guard let base = opBase, !dirty.isNull else { return }
        let r = dirty.integral.intersection(fullRect)
        guard !r.isNull, r.width >= 1, r.height >= 1, let patch = copyRegion(base, r) else { return }
        undoStack.append(PatchStep(rect: r, image: patch))
        redoStack.removeAll()
        trimUndo()
        isDirty = true
        updateFlags()
    }

    private func trimUndo() {
        var bytes = undoStack.reduce(0) { $0 + $1.image.width * $1.image.height * 4 }
        while bytes > 256 * 1024 * 1024, undoStack.count > 1 {
            let removed = undoStack.removeFirst()
            bytes -= removed.image.width * removed.image.height * 4
        }
    }

    private func updateFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func restore(_ image: CGImage) {
        ctx.saveGState()
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: fullRect)
        ctx.restoreGState()
    }

    private func applyPatch(_ step: PatchStep) -> PatchStep? {
        guard let current = ctx.makeImage(), let after = copyRegion(current, step.rect) else { return nil }
        ctx.saveGState()
        ctx.setBlendMode(.copy)
        ctx.draw(step.image, in: ctxRect(step.rect))
        ctx.restoreGState()
        refreshBase()
        return PatchStep(rect: step.rect, image: after)
    }

    func undo() {
        guard !active, let step = undoStack.popLast() else { return }
        if let reverse = applyPatch(step) { redoStack.append(reverse) }
        isDirty = true
        updateFlags()
    }

    func redo() {
        guard !active, let step = redoStack.popLast() else { return }
        if let reverse = applyPatch(step) { undoStack.append(reverse) }
        isDirty = true
        updateFlags()
    }

    func begin(at point: CGPoint) {
        guard !active else { return }
        let p = clamp(point)
        if tool == .picker {
            pickColor(at: p)
            return
        }
        if tool == .fill {
            beginOp(deep: true)
            floodFill(at: p)
            endOp()
            refreshBase()
            return
        }
        active = true
        startPoint = p
        prevPoint = p
        lastPoint = p
        beginOp()
        switch tool {
        case .brush:
            dot(at: p, into: strokeCtx, erase: false)
            showStroke()
        case .eraser:
            dot(at: p, into: ctx, erase: true)
            refreshBase()
        default:
            break
        }
    }

    func move(to point: CGPoint) {
        guard active else { return }
        let p = tool.isShape ? clamp(point) : point
        switch tool {
        case .brush:
            segment(to: p, into: strokeCtx, erase: false, final: false)
            showStroke()
        case .eraser:
            segment(to: p, into: ctx, erase: true, final: false)
            refreshBase()
        case .line, .rectangle, .ellipse:
            previewShape(to: p)
        default:
            break
        }
    }

    func end(at point: CGPoint) {
        guard active else { return }
        let p = tool.isShape ? clamp(point) : point
        switch tool {
        case .brush:
            segment(to: p, into: strokeCtx, erase: false, final: true)
            mergeStroke()
        case .eraser:
            segment(to: p, into: ctx, erase: true, final: true)
            refreshBase()
        case .line, .rectangle, .ellipse:
            previewShape(to: p)
        default:
            break
        }
        active = false
        endOp()
    }

    func cancelOperation() {
        guard active else { return }
        active = false
        if tool != .brush, let base = opBase { restore(base) }
        clearStroke()
        opBase = nil
        dirty = .null
        refreshBase()
    }

    private func dot(at p: CGPoint, into target: CGContext, erase: Bool) {
        let r = CGFloat(size) / 2
        let top = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        target.saveGState()
        if erase {
            target.setBlendMode(.clear)
        } else {
            target.setFillColor(opaqueColor())
        }
        target.fillEllipse(in: ctxRect(top))
        target.restoreGState()
        mark(top.insetBy(dx: -2, dy: -2))
    }

    private func opaqueColor() -> CGColor {
        UIColor(color).withAlphaComponent(1).cgColor
    }

    private func segment(to p: CGPoint, into target: CGContext, erase: Bool, final: Bool) {
        let start = mid(prevPoint, lastPoint)
        let stop = final ? p : mid(lastPoint, p)
        target.saveGState()
        if erase {
            target.setBlendMode(.clear)
        } else {
            target.setStrokeColor(opaqueColor())
        }
        target.setLineWidth(CGFloat(size))
        target.setLineCap(.round)
        target.setLineJoin(.round)
        target.beginPath()
        target.move(to: flip(start))
        target.addQuadCurve(to: flip(stop), control: flip(lastPoint))
        target.strokePath()
        target.restoreGState()
        let minX = min(start.x, stop.x, lastPoint.x), maxX = max(start.x, stop.x, lastPoint.x)
        let minY = min(start.y, stop.y, lastPoint.y), maxY = max(start.y, stop.y, lastPoint.y)
        let pad = CGFloat(size) / 2 + 2
        mark(CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2))
        prevPoint = lastPoint
        lastPoint = p
    }

    private func mergeStroke() {
        if let image = strokeCtx.makeImage() {
            ctx.saveGState()
            ctx.setAlpha(CGFloat(opacity))
            ctx.draw(image, in: fullRect)
            ctx.restoreGState()
        }
        clearStroke()
        refreshBase()
    }

    private func previewShape(to p: CGPoint) {
        guard let base = opBase else { return }
        restore(base)
        let a = startPoint
        let top = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(a.x - p.x), height: abs(a.y - p.y))
        let rect = ctxRect(top)
        ctx.saveGState()
        ctx.setAlpha(CGFloat(opacity))
        ctx.setStrokeColor(drawColor)
        ctx.setFillColor(drawColor)
        ctx.setLineWidth(CGFloat(size))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch tool {
        case .line:
            ctx.beginPath()
            ctx.move(to: flip(a))
            ctx.addLine(to: flip(p))
            ctx.strokePath()
        case .rectangle:
            if filled { ctx.fill(rect) } else { ctx.stroke(rect) }
        case .ellipse:
            if filled { ctx.fillEllipse(in: rect) } else { ctx.strokeEllipse(in: rect) }
        default:
            break
        }
        ctx.restoreGState()
        mark(top.insetBy(dx: -CGFloat(size) - 2, dy: -CGFloat(size) - 2))
        refreshBase()
    }

    private func pixel(_ px: UnsafeMutablePointer<UInt8>, _ bpr: Int, _ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
        let i = y * bpr + x * 4
        return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]), Int(px[i + 3]))
    }

    private func pickColor(at p: CGPoint) {
        guard let raw = ctx.data else { return }
        let px = raw.assumingMemoryBound(to: UInt8.self)
        let x = min(max(Int(p.x), 0), width - 1)
        let y = min(max(Int(p.y), 0), height - 1)
        let (r, g, b, a) = pixel(px, ctx.bytesPerRow, x, y)
        guard a > 0 else {
            color = .white
            tool = lastDrawingTool
            return
        }
        let scale = 255.0 / Double(a)
        color = Color(.sRGB,
                      red: min(1, Double(r) * scale / 255),
                      green: min(1, Double(g) * scale / 255),
                      blue: min(1, Double(b) * scale / 255),
                      opacity: 1)
        tool = lastDrawingTool
        Haptics.tap()
    }

    private func floodFill(at p: CGPoint) {
        guard let raw = ctx.data else { return }
        let px = raw.assumingMemoryBound(to: UInt8.self)
        let bpr = ctx.bytesPerRow
        let w = width, h = height
        let sx = min(max(Int(p.x), 0), w - 1)
        let sy = min(max(Int(p.y), 0), h - 1)
        let (tr, tg, tb, ta) = pixel(px, bpr, sx, sy)
        let tol = Int(tolerance)

        let ui = UIColor(color)
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        ui.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        let alpha = CGFloat(opacity)
        let pr = UInt8(max(0, min(255, (fr * alpha * 255).rounded())))
        let pg = UInt8(max(0, min(255, (fg * alpha * 255).rounded())))
        let pb = UInt8(max(0, min(255, (fb * alpha * 255).rounded())))
        let pa = UInt8(max(0, min(255, (alpha * 255).rounded())))

        func matches(_ x: Int, _ y: Int) -> Bool {
            let i = y * bpr + x * 4
            return abs(Int(px[i]) - tr) <= tol && abs(Int(px[i + 1]) - tg) <= tol
                && abs(Int(px[i + 2]) - tb) <= tol && abs(Int(px[i + 3]) - ta) <= tol
        }

        var visited = [Bool](repeating: false, count: w * h)
        var stack: [(Int, Int)] = [(sx, sy)]
        var minX = sx, maxX = sx, minY = sy, maxY = sy

        while let (x0, y) = stack.popLast() {
            if visited[y * w + x0] || !matches(x0, y) { continue }
            var xl = x0
            while xl > 0, !visited[y * w + xl - 1], matches(xl - 1, y) { xl -= 1 }
            var xr = x0
            while xr < w - 1, !visited[y * w + xr + 1], matches(xr + 1, y) { xr += 1 }
            for x in xl...xr {
                visited[y * w + x] = true
                let i = y * bpr + x * 4
                px[i] = pr
                px[i + 1] = pg
                px[i + 2] = pb
                px[i + 3] = pa
            }
            minX = min(minX, xl)
            maxX = max(maxX, xr)
            minY = min(minY, y)
            maxY = max(maxY, y)
            for ny in [y - 1, y + 1] where ny >= 0 && ny < h {
                var inRun = false
                for x in xl...xr {
                    let ok = !visited[ny * w + x] && matches(x, ny)
                    if ok && !inRun {
                        stack.append((x, ny))
                        inRun = true
                    } else if !ok {
                        inRun = false
                    }
                }
            }
        }
        mark(CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }

    private func perform(deep: Bool = false, _ body: () -> Void) {
        guard !active else { return }
        beginOp(deep: deep)
        body()
        mark(fullRect)
        endOp()
        refreshBase()
        Haptics.tap()
    }

    func flipHorizontal() {
        perform {
            guard let image = ctx.makeImage() else { return }
            ctx.saveGState()
            ctx.setBlendMode(.copy)
            ctx.translateBy(x: CGFloat(width), y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.draw(image, in: fullRect)
            ctx.restoreGState()
        }
    }

    func flipVertical() {
        perform {
            guard let image = ctx.makeImage() else { return }
            ctx.saveGState()
            ctx.setBlendMode(.copy)
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: fullRect)
            ctx.restoreGState()
        }
    }

    func invertColors() {
        perform(deep: true) {
            guard let raw = ctx.data else { return }
            let px = raw.assumingMemoryBound(to: UInt8.self)
            let bpr = ctx.bytesPerRow
            for y in 0..<height {
                var i = y * bpr
                for _ in 0..<width {
                    let a = px[i + 3]
                    px[i] = a - min(px[i], a)
                    px[i + 1] = a - min(px[i + 1], a)
                    px[i + 2] = a - min(px[i + 2], a)
                    i += 4
                }
            }
        }
    }

    func clearAll() {
        perform { ctx.clear(fullRect) }
    }

    func resetToOriginal() {
        perform { restore(original) }
    }

    func pngData() -> Data? {
        guard let image = ctx.makeImage() else { return nil }
        return UIImage(cgImage: image).pngData()
    }
}
