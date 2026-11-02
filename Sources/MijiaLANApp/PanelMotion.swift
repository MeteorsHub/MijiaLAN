import QuartzCore
import SwiftUI

/// One motion language for page navigation and the menu-bar panel itself.
enum PanelMotion {
    static let duration: TimeInterval = 0.24
    static let animation = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
    static var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    }
}

private struct PanelPresentedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var panelPresented: Bool {
        get { self[PanelPresentedKey.self] }
        set { self[PanelPresentedKey.self] = newValue }
    }
}
