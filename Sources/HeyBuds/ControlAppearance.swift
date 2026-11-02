import SwiftUI
import AppKit

private struct LiquidGlassKey:EnvironmentKey {
    static var defaultValue:Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

extension EnvironmentValues {
    // Previews and rendering checks can also exercise the older system style.
    var heyBudsLiquidGlass:Bool {
        get { self[LiquidGlassKey.self] }
        set { self[LiquidGlassKey.self]=newValue }
    }
}

private struct CompatibleButtonStyle:ViewModifier {
    let prominent:Bool
    @Environment(\.heyBudsLiquidGlass) private var liquidGlass

    @ViewBuilder func body(content:Content) -> some View {
        if #available(macOS 26.0, *), liquidGlass {
            if prominent { content.buttonStyle(.glassProminent) }
            else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        }
    }
}

extension View {
    func compatibleButtonStyle(prominent:Bool=false) -> some View {
        modifier(CompatibleButtonStyle(prominent:prominent))
    }
}

struct CompatibleGlassContainer<Content:View>:View {
    let spacing:CGFloat
    @ViewBuilder var content:() -> Content
    @Environment(\.heyBudsLiquidGlass) private var liquidGlass

    @ViewBuilder var body:some View {
        if #available(macOS 26.0, *), liquidGlass {
            GlassEffectContainer(spacing:spacing,content:content)
        } else {
            content()
        }
    }
}

struct ListeningSurface<S:Shape>:ViewModifier {
    let selected:Bool
    let shape:S
    private let transparencyOverride:Bool?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.heyBudsLiquidGlass) private var liquidGlass

    init(selected:Bool,shape:S,reduceTransparency:Bool?=nil) {
        self.selected=selected; self.shape=shape; self.transparencyOverride=reduceTransparency
    }

    @ViewBuilder func body(content:Content) -> some View {
        if transparencyOverride ?? reduceTransparency {
            content.background(selected ? Color.accentColor : Color(nsColor:.controlBackgroundColor),in:shape)
        } else if #available(macOS 26.0, *), liquidGlass {
            content.glassEffect(selected ? .regular.tint(.accentColor).interactive() : .regular.interactive(),in:shape)
        } else {
            content.background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial),in:shape)
        }
    }
}
