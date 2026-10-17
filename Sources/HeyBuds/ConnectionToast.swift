import AppKit
import SwiftUI
import QuartzCore
import HeyBudsBluetooth
import HeyBudsProtocol

struct ConnectionTipView:View {
    static let size=NSSize(width:336,height:208)
    @Bindable var app:AppModel
    let device:DeviceCandidate?
    var preview=false
    let onOpen:() -> Void
    let onClose:() -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var name:String {
        guard let device else { return "HeyBuds" }
        return device.id == app.selectedID ? app.title : device.name
    }
    private var deviceModel:DeviceModel? {
        guard let device else { return nil }
        if device.id == app.selectedID { return app.model }
        return app.catalog.model(productID:nil,name:device.name)
    }
    private var connected:Bool { device.map { d in app.knownConnectedDevices.contains(where:{$0.id == d.id}) } ?? false }
    private func reading(_ slot:BatterySlot) -> BatteryReading? {
        guard connected, app.ready, device?.id == app.selectedID,
              let value=app.state.batteries[slot], Date().timeIntervalSince(value.updatedAt) < 120 else { return nil }
        return value
    }
    private func placement(_ slot:BatterySlot) -> UInt8? {
        guard connected, app.ready, device?.id == app.selectedID else { return nil }
        return app.state.placement[slot]
    }
    private var missingBattery:Bool { reading(.left) == nil && reading(.right) == nil }
    private var header:some View {
        HStack(spacing:12) {
            Image(systemName:EarbudIcon.pair).font(.system(size:32)).frame(width:54,height:44)
            VStack(alignment:.leading,spacing:4) {
                Text(name).font(.system(size:14,weight:.semibold)).lineLimit(1).truncationMode(.middle)
                HStack(spacing:5) {
                    Circle().fill(connected ? Color.green : .secondary).frame(width:5,height:5)
                    Text(preview && !connected ? L("连接提示预览","Connection preview") : L("已连接","Connected"))
                        .font(.system(size:11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength:18)
        }
    }
    private var batteryRow:some View {
        HStack(alignment:.top,spacing:8) {
            BatteryCell(title:deviceModel?.singleBattery == true ? L("耳机","Headphones") : L("左耳","Left"),symbol:deviceModel?.singleBattery == true ? "headphones" : "airpods.pro.left",sideLabel:deviceModel?.singleBattery == true ? nil : "L",reading:reading(.left),placement:placement(.left),t500:deviceModel?.isT500 == true,compact:true)
            if deviceModel?.singleBattery != true {
            BatteryCell(title:L("右耳","Right"),symbol:"airpods.pro.right",sideLabel:"R",reading:reading(.right),placement:placement(.right),t500:deviceModel?.isT500 == true,compact:true)
            }
            if deviceModel?.singleBattery != true,let enclosure=reading(.enclosure) {
                BatteryCell(title:L("充电盒","Case"),symbol:EarbudIcon.enclosure,reading:enclosure,placement:nil,t500:false,compact:true)
            }
        }
    }
    @ViewBuilder var body:some View {
        if reduceTransparency {
            content.background(Color(nsColor:.windowBackgroundColor),in:RoundedRectangle(cornerRadius:28))
        } else {
            // System Liquid Glass owns the material, highlights and interaction.
            content.glassEffect(.regular.interactive(),in:.rect(cornerRadius:28))
        }
    }
    private var content:some View {
        ZStack(alignment:.topTrailing) {
            Button(action:onOpen) {
                VStack(spacing:14) {
                    header
                    batteryRow
                    if missingBattery {
                        Text(app.connecting ? L("正在读取耳机电量…","Reading battery levels…") : L("电量暂未上报","Battery not yet reported"))
                            .font(.system(size:10)).foregroundStyle(.secondary)
                    }
                }.padding(18).frame(width:Self.size.width,height:Self.size.height)
                    .contentShape(RoundedRectangle(cornerRadius:28))
            }.buttonStyle(.plain)
                .accessibilityLabel(name+(preview && !connected ? L("，连接提示预览",", connection preview") : L("，已连接。打开控制面板",", connected. Open controls")))
                .accessibilityValue(L("左耳：","Left: ")+(reading(.left).map { "\($0.percent)%" } ?? L("未知","unknown"))+L("，右耳：",", right: ")+(reading(.right).map { "\($0.percent)%" } ?? L("未知","unknown")))
            Button(action:onClose) {
                Image(systemName:"xmark").font(.system(size:9,weight:.semibold)).foregroundStyle(.secondary).frame(width:24,height:24)
            }.buttonStyle(.plain).padding(7).accessibilityLabel(L("关闭连接提示","Dismiss connection pop-up"))
        }
        .preferredColorScheme(app.appearance == "dark" ? .dark : app.appearance == "light" ? .light : nil)
    }
}

struct ConnectionTipPreviewView:View {
    @Bindable var app:AppModel
    var body:some View { ConnectionTipView(app:app,device:app.candidate,preview:true,onOpen:{},onClose:{}) }
}

private final class ConnectionNotificationPanel:NSPanel {
    override var canBecomeKey:Bool { false }
    override var canBecomeMain:Bool { false }
}

@MainActor final class ConnectionToastController {
    private var panel:ConnectionNotificationPanel?
    private var dismissal:Task<Void,Never>?
    private(set) var deviceID:String?
    private(set) var preview=false
    private(set) var presentationCount=0
    var onDismiss:(() -> Void)?
    var isShown:Bool { panel?.isVisible == true }

    func show(app:AppModel,device:DeviceCandidate?,preview:Bool,anchor:NSRect?,onOpen:@escaping () -> Void) {
        dismiss(animated:false,notify:false)
        presentationCount += 1
        self.deviceID=device?.id; self.preview=preview
        let size=ConnectionTipView.size
        let panel=ConnectionNotificationPanel(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.title="HeyBuds · Connection"; panel.isReleasedWhenClosed=false
        panel.level = .statusBar; panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=true
        panel.hidesOnDeactivate=false; panel.isFloatingPanel=true
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        panel.contentView=NSHostingView(rootView:ConnectionTipView(app:app,device:device,preview:preview,onOpen:onOpen,onClose:{ [weak self] in self?.dismiss() }))
        let screen=anchor.flatMap { point in NSScreen.screens.first(where:{$0.frame.contains(NSPoint(x:point.midX,y:point.midY))}) } ?? NSScreen.main
        let visible=screen?.visibleFrame ?? NSRect(x:0,y:0,width:1280,height:800)
        let x=min(max((anchor?.midX ?? visible.maxX-size.width/2-12)-size.width/2,visible.minX+12),visible.maxX-size.width-12)
        let y=max(visible.minY+12,(anchor?.minY ?? visible.maxY)-size.height-12)
        let target=NSRect(origin:NSPoint(x:x,y:y),size:size)
        let reduceMotion=NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(reduceMotion ? target : target.offsetBy(dx:0,dy:6),display:false)
        panel.alphaValue=reduceMotion ? 1 : 0
        self.panel=panel; panel.orderFrontRegardless()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration=0.25; context.timingFunction=CAMediaTimingFunction(name:.easeOut)
                panel.animator().alphaValue=1; panel.animator().setFrame(target,display:true)
            }
        }
        dismissal=Task { [weak self,weak app] in
            let start=Date()
            let hasBattery:() -> Bool = { [weak app] in
                guard let app, app.ready, app.selectedID == device?.id else { return false }
                return app.state.batteries[.left] != nil || app.state.batteries[.right] != nil
            }
            var received=hasBattery()
            var end=start.addingTimeInterval(received ? 5 : 8)
            while Date() < end {
                try? await Task.sleep(for:.milliseconds(200))
                guard !Task.isCancelled else { return }
                if !received, hasBattery() {
                    received=true
                    end=min(start.addingTimeInterval(10),max(start.addingTimeInterval(5),Date().addingTimeInterval(3)))
                }
            }
            self?.dismiss()
        }
    }
    func dismiss(animated:Bool=true,notify:Bool=true) {
        dismissal?.cancel(); dismissal=nil
        guard let panel else { return }
        self.panel=nil; deviceID=nil
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration=0.2; panel.animator().alphaValue=0
            },completionHandler:{ panel.orderOut(nil) })
        } else { panel.orderOut(nil) }
        if notify { onDismiss?() }
    }
    func snapshot(to url:URL) {
        guard let view=panel?.contentView, let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
        view.layoutSubtreeIfNeeded(); view.cacheDisplay(in:view.bounds,to:bitmap)
        if let png=bitmap.representation(using:.png,properties:[:]) { try? png.write(to:url,options:.atomic) }
    }
}
