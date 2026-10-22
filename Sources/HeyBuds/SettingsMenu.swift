import AppKit
import SwiftUI

struct SettingsChoice<Value:Hashable>:Equatable {
    let value:Value
    let title:String
    init(_ value:Value,_ title:String) { self.value=value; self.title=title }
}

/// A native popup whose menu contains only choices, without a section title.
struct SettingsMenu<Value:Hashable>:NSViewRepresentable {
    let title:String
    let choices:[SettingsChoice<Value>]
    @Binding var selection:Value
    var enabled=true

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context:Context) -> NSPopUpButton {
        let button=NSPopUpButton(frame:.zero,pullsDown:false)
        button.target=context.coordinator; button.action=#selector(Coordinator.choose(_:))
        button.controlSize = .small
        button.font = .systemFont(ofSize:13,weight:.regular)
        button.alignment = .center
        button.altersStateOfSelectedItem=true
        button.setContentHuggingPriority(.defaultLow,for:.horizontal)
        return button
    }
    func updateNSView(_ button:NSPopUpButton,context:Context) {
        let coordinator=context.coordinator
        if coordinator.choices != choices {
            coordinator.choices=choices
            let menu=NSMenu()
            menu.autoenablesItems=false
            menu.font = .systemFont(ofSize:13,weight:.regular)
            for (index,choice) in choices.enumerated() {
                let item=NSMenuItem(title:choice.title,action:nil,keyEquivalent:"")
                item.tag=index
                menu.addItem(item)
            }
            button.menu=menu
        }
        coordinator.onSelect={ selection=$0 }
        let selected=choices.firstIndex(where:{$0.value == selection})
        button.selectItem(at:selected ?? -1)
        button.isEnabled=enabled && context.environment.isEnabled
        button.appearance=NSAppearance(named:context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(selected.map { choices[$0].title } ?? "")
        button.toolTip=selected.map { choices[$0].title }
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSPopUpButton,context:Context) -> CGSize? {
        CGSize(width:proposal.width ?? 132,height:nsView.intrinsicContentSize.height)
    }
    final class Coordinator:NSObject {
        var choices:[SettingsChoice<Value>]=[]
        var onSelect:((Value) -> Void)?
        @objc func choose(_ button:NSPopUpButton) {
            guard button.isEnabled, let index=button.selectedItem?.tag, choices.indices.contains(index) else { return }
            onSelect?(choices[index].value)
        }
    }
}
