import SwiftUI
import UIKit

final class CanvasView: UIView {
    private let doc: CanvasDocument
    private let baseLayer = CALayer()
    private let strokeLayer = CALayer()

    init(doc: CanvasDocument) {
        self.doc = doc
        super.init(frame: CGRect(x: 0, y: 0, width: doc.width, height: doc.height))
        isMultipleTouchEnabled = true
        backgroundColor = UIColor(patternImage: CanvasView.checkerboard())
        for layer in [baseLayer, strokeLayer] {
            layer.frame = bounds
            layer.contentsGravity = .resize
            layer.magnificationFilter = .nearest
            layer.minificationFilter = .linear
            self.layer.addSublayer(layer)
        }
        doc.attach(base: baseLayer, stroke: strokeLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func checkerboard() -> UIImage {
        let s: CGFloat = 12
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: s * 2, height: s * 2))
        return renderer.image { context in
            UIColor(white: 0.88, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: s * 2, height: s * 2))
            UIColor(white: 0.72, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: s, height: s))
            context.fill(CGRect(x: s, y: s, width: s, height: s))
        }
    }

    private func isSingleTouch(_ event: UIEvent?) -> Bool {
        (event?.allTouches?.count ?? 1) <= 1
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isSingleTouch(event), let touch = touches.first else {
            doc.cancelOperation()
            return
        }
        doc.begin(at: touch.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isSingleTouch(event), let touch = touches.first else {
            doc.cancelOperation()
            return
        }
        doc.move(to: touch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        doc.end(at: touch.location(in: self))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        doc.cancelOperation()
    }
}

final class CanvasScrollView: UIScrollView, UIScrollViewDelegate {
    private let canvas: CanvasView
    private var fitted = false

    init(doc: CanvasDocument) {
        canvas = CanvasView(doc: doc)
        super.init(frame: .zero)
        delegate = self
        addSubview(canvas)
        contentSize = canvas.bounds.size
        maximumZoomScale = 40
        bouncesZoom = true
        delaysContentTouches = false
        panGestureRecognizer.minimumNumberOfTouches = 2
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .clear
        doc.fitHandler = { [weak self] in
            guard let self else { return }
            self.setZoomScale(self.minimumZoomScale, animated: true)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        canvas
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let fit = min(bounds.width / canvas.bounds.width, bounds.height / canvas.bounds.height)
        minimumZoomScale = fit
        if !fitted {
            fitted = true
            zoomScale = fit
        }
        centerContent()
    }

    private func centerContent() {
        let size = canvas.frame.size
        let x = max(0, (bounds.width - size.width) / 2)
        let y = max(0, (bounds.height - size.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }
}

struct CanvasRepresentable: UIViewRepresentable {
    let doc: CanvasDocument

    func makeUIView(context: Context) -> CanvasScrollView {
        CanvasScrollView(doc: doc)
    }

    func updateUIView(_ uiView: CanvasScrollView, context: Context) {}
}
