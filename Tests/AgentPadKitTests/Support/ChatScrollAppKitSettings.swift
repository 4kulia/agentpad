import AppKit
import AgentPadQuietTestSupport
import ObjectiveC
import XCTest

@MainActor enum ChatScrollAppKitSettings {
    private static var installed = false
    private static let responsiveSelector = #selector(getter: NSView.isCompatibleWithResponsiveScrolling)
    private static let disabledResponsive: IMP = imp_implementationWithBlock(
        { (_: AnyObject) -> Bool in false } as @convention(block) (AnyObject) -> Bool
    )

    private static func disableResponsive(_ type: AnyClass) {
        guard let meta = object_getClass(type),
              let method = class_getClassMethod(NSView.self, responsiveSelector) else {
            preconditionFailure("Responsive-scrolling control unavailable")
        }
        class_replaceMethod(meta, responsiveSelector, disabledResponsive, method_getTypeEncoding(method))
    }

    static func install() {
        precondition(APQuietIsEnabled())
        guard !installed else { return }
        installed = true
        let count = objc_getClassList(nil, 0)
        precondition(count > 0)
        let classes = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(count))
        defer { classes.deallocate() }
        let actual = objc_getClassList(AutoreleasingUnsafeMutablePointer(classes), count)
        for index in 0..<Int(min(count, actual)) {
            let candidate = classes[index]
            var ancestor: AnyClass? = candidate
            while let current = ancestor {
                if ObjectIdentifier(current) == ObjectIdentifier(NSScrollView.self) {
                    disableResponsive(candidate)
                    break
                }
                ancestor = class_getSuperclass(current)
            }
        }
        disableResponsive(NSScrollView.self)
    }

    static func apply(to host: NSView) {
        if let scroll = host as? NSScrollView {
            disableResponsive(type(of: scroll))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.verticalScrollElasticity = .none
            scroll.horizontalScrollElasticity = .none
            scroll.scrollsDynamically = true
            scroll.usesPredominantAxisScrolling = true
            scroll.allowsMagnification = false
            return
        }
        for child in host.subviews { apply(to: child) }
    }

    static func snapshot(_ scroll: NSScrollView) -> [String: Any] {
        let values: [String: Any] = [
            "responsiveScrolling": type(of: scroll).isCompatibleWithResponsiveScrolling,
            "drawsBackground": scroll.drawsBackground,
            "hasVerticalScroller": scroll.hasVerticalScroller,
            "hasHorizontalScroller": scroll.hasHorizontalScroller,
            "autohidesScrollers": scroll.autohidesScrollers,
            "scrollerStyle": scroll.scrollerStyle.rawValue,
            "verticalElasticity": scroll.verticalScrollElasticity.rawValue,
            "horizontalElasticity": scroll.horizontalScrollElasticity.rawValue,
            "scrollsDynamically": scroll.scrollsDynamically,
            "usesPredominantAxisScrolling": scroll.usesPredominantAxisScrolling,
            "allowsMagnification": scroll.allowsMagnification
        ]
        let expected: [String: Any] = [
            "responsiveScrolling": false, "drawsBackground": false,
            "hasVerticalScroller": true, "hasHorizontalScroller": false,
            "autohidesScrollers": true, "scrollerStyle": NSScroller.Style.overlay.rawValue,
            "verticalElasticity": NSScrollView.Elasticity.none.rawValue,
            "horizontalElasticity": NSScrollView.Elasticity.none.rawValue,
            "scrollsDynamically": true, "usesPredominantAxisScrolling": true,
            "allowsMagnification": false
        ]
        XCTAssertEqual(values as NSDictionary, expected as NSDictionary)
        return values
    }
}
