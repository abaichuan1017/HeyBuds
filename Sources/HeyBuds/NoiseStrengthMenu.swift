import AppKit
import SwiftUI
import HeyBudsProtocol

/// Keep the compact trigger while sizing the expanded menu independently.
/// NSMenu supplies its standard material, highlighting and keyboard navigation.
struct NoiseStrengthMenu:NSViewRepresentable {
    let options:[NoiseOption]
    let selection:NoiseMode?
    let enabled:Bool
    let onSelect:(NoiseMode) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context:Context) -> NSButton {
        let button=NSButton(title:"",target:context.coordinator,action:#selector(Coordinator.openMenu(_:)))
        button.setButtonType(.momentaryPushIn)
        button.isBordered=false
        button.controlSize = .mini
        button.font = .systemFont(ofSize:11)
        button.contentTintColor = .secondaryLabelColor
        button.alignment = .center
        button.imagePosition = .imageLeft
        button.imageHugsTitle=true
        button.image=NSImage(systemSymbolName:"chevron.up.chevron.down",accessibilityDescription:nil)?
            .withSymbolConfiguration(.init(pointSize:9,weight:.semibold))
        button.imageScaling = .scaleProportionallyDown
        button.focusRingType = .none
        button.setContentHuggingPriority(.defaultLow,for:.horizontal)
        return button
    }
    func updateNSView(_ button:NSButton,context:Context) {
        context.coordinator.options=options
        context.coordinator.selection=selection
        context.coordinator.onSelect=onSelect
        button.title=noiseLabel(selection ?? .smart)
        button.isEnabled=enabled
        button.toolTip=L("选择降噪强度","Choose ANC strength")
        button.setAccessibilityLabel(L("降噪强度","ANC strength"))
        button.setAccessibilityValue(button.title)
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSButton,context:Context) -> CGSize? {
        CGSize(width:proposal.width ?? nsView.intrinsicContentSize.width,height:16)
    }
    final class Coordinator:NSObject {
        var options:[NoiseOption]=[]
        var selection:NoiseMode?
        var onSelect:((NoiseMode) -> Void)?
        @objc func openMenu(_ button:NSButton) {
            guard button.isEnabled else { return }
            let menu=NSMenu(title:L("降噪强度","ANC strength"))
            menu.autoenablesItems=false
            menu.font = .systemFont(ofSize:14)
            menu.minimumWidth=112
            for (index,option) in options.enumerated() {
                let item=NSMenuItem(title:noiseLabel(option.mode),action:#selector(choose(_:)),keyEquivalent:"")
                item.target=self
                item.tag=index
                item.state=option.mode == selection ? .on : .off
                menu.addItem(item)
            }
            let below=button.isFlipped ? button.bounds.maxY+4 : button.bounds.minY-4
            menu.popUp(positioning:nil,at:NSPoint(x:(button.bounds.width-menu.minimumWidth)/2,y:below),in:button)
        }
        @objc private func choose(_ item:NSMenuItem) {
            guard options.indices.contains(item.tag) else { return }
            onSelect?(options[item.tag].mode)
        }
    }
}
