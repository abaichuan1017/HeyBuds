import AppKit
import SwiftUI
import QuartzCore
import HeyBudsBluetooth
import HeyBudsProtocol

struct OutputVolumeView:View {
    let route:BluetoothAudioRoute?
    let service:SystemAudio.VolumeService
    @ViewState private var sample:(route:BluetoothAudioRoute,level:SystemAudio.Level)?
    var body:some View {
        HStack(spacing:10) {
            Image(systemName:"speaker.wave.2").accessibilityHidden(true)
            if let route, let sample, route == sample.route {
                let level=sample.level
                Slider(value:Binding(get:{ Double(level.value) },set:{ value in
                    self.sample=service.set(Float(value),route).map { (route,$0) }
                }),in:0...1).disabled(!level.writable)
                    .accessibilityLabel(L("耳机音量","Headphone volume"))
                Text(level.value,format:.percent.precision(.fractionLength(0)))
                    .monospacedDigit().frame(minWidth:34,alignment:.trailing)
            } else {
                Text(L("系统音量不可用","System volume unavailable")).foregroundStyle(.secondary)
                Spacer()
            }
        }.font(.system(size:12))
        .task(id:route) {
            sample=nil
            guard let route else { return }
            for await _ in service.changes(route) {
                guard !Task.isCancelled else { return }
                sample=service.level(route).map { (route,$0) }
            }
        }
    }
}

struct ConnectionTipView:View {
    private static let contentSize=NSSize(width:336,height:164)
    // Keep the antialiased material edge inside the transparent window bounds.
    static let size=NSSize(width:340,height:168)
    @Bindable var app:AppModel
    let device:DeviceCandidate?
    var preview=false
    var disconnected=false
    let onOpen:() -> Void
    let onClose:() -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var name:String {
        guard let device else { return "HeyBuds" }
        return app.candidates.first(where:{$0.id == device.id})?.name ?? device.name
    }
    private var deviceModel:DeviceModel? {
        guard let device else { return nil }
        if device.id == app.selectedID { return app.model }
        return device.model(in:app.catalog)
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
    private func unassignedReading(_ id:UInt8) -> BatteryReading? {
        guard connected,app.ready,device?.id == app.selectedID,
              let value=app.state.unassignedBatteries[id],Date().timeIntervalSince(value.updatedAt) < 120 else { return nil }
        return value
    }
    private var missingBattery:Bool { reading(.left) == nil && reading(.right) == nil && unassignedReading(1) == nil && unassignedReading(2) == nil }
    private var statusText:String {
        if disconnected { return L("已断开","Disconnected") }
        if preview && !connected { return L("连接提示预览","Connection preview") }
        if device?.systemAudioOnly == true { return L("已连接","Connected") }
        if missingBattery {
            return app.connecting ? L("已连接 · 正在读取电量…","Connected · Reading battery…") : L("已连接 · 等待电量","Connected · Waiting for battery")
        }
        return L("已连接","Connected")
    }
    private var header:some View {
        HStack(spacing:10) {
            Image(systemName:device?.systemAudioOnly == true ? "headphones" : EarbudIcon.pair).font(.system(size:28)).frame(width:44,height:36)
            VStack(alignment:.leading,spacing:4) {
                Text(name).font(.system(size:14,weight:.semibold)).lineLimit(1).truncationMode(.middle)
                HStack(spacing:5) {
                    Circle().fill(connected ? Color.green : .secondary).frame(width:5,height:5)
                    Text(statusText).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength:0)
        }.padding(.trailing,28)
    }
    private var batteryRow:some View {
        HStack(alignment:.top,spacing:8) {
            if deviceModel?.unassignedEarbudBatteries == true {
                ForEach([UInt8(1),2],id:\.self) { id in
                    BatteryCell(title:L("耳机电量 ","Earbud battery ")+String(id),symbol:"earbuds",reading:unassignedReading(id),placement:nil,t500:false,compact:true).frame(width:88)
                }
            } else {
            BatteryCell(title:deviceModel?.singleBattery == true ? L("耳机","Headphones") : L("左耳","Left"),symbol:deviceModel?.singleBattery == true ? "headphones" : "airpods.pro.left",sideLabel:deviceModel?.singleBattery == true ? nil : "L",reading:reading(.left),placement:placement(.left),t500:deviceModel?.isT500 == true,compact:true).frame(width:88)
            if deviceModel?.singleBattery != true {
            BatteryCell(title:L("右耳","Right"),symbol:"airpods.pro.right",sideLabel:"R",reading:reading(.right),placement:placement(.right),t500:deviceModel?.isT500 == true,compact:true).frame(width:88)
            }
            }
            if deviceModel?.singleBattery != true,let enclosure=reading(.enclosure) {
                BatteryCell(title:L("充电盒","Case"),symbol:EarbudIcon.enclosure,reading:enclosure,placement:nil,t500:false,compact:true).frame(width:88)
            }
        }
    }
    var body:some View {
        content
            .background {
                if reduceTransparency { Color(nsColor:.windowBackgroundColor) }
                else { ConnectionTipMaterial() }
            }
            .clipShape(RoundedRectangle(cornerRadius:24,style:.continuous))
            .padding(2)
            .font(.system(size:13,weight:.regular))
            .preferredColorScheme(app.appearance == "dark" ? .dark : app.appearance == "light" ? .light : nil)
    }
    private var content:some View {
        ZStack(alignment:.topTrailing) {
            if device?.systemAudioOnly == true || disconnected {
                VStack(alignment:.leading,spacing:14) {
                    Button(action:onOpen) { header.contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel(name + ", " + statusText)
                        .accessibilityHint(L("打开控制面板","Open control panel"))
                    if !disconnected, connected, let device {
                        OutputVolumeView(route:app.candidates.first(where:{$0.id == device.id})?.audioRoute,service:app.volume)
                    }
                }.padding(.horizontal,16).padding(.vertical,14)
                    .frame(width:Self.contentSize.width,height:compactHeight,alignment:disconnected ? .leading : .topLeading)
            } else {
                Button(action:onOpen) {
                    VStack(spacing:12) {
                        header
                        batteryRow
                    }.padding(.horizontal,16).padding(.vertical,14)
                        .frame(width:Self.contentSize.width,height:Self.contentSize.height,alignment:.top)
                        .contentShape(RoundedRectangle(cornerRadius:24))
                }.buttonStyle(.plain)
                    .accessibilityLabel(name+(preview && !connected ? L("，连接提示预览",", connection preview") : L("，已连接。打开控制面板",", connected. Open controls")))
                    .accessibilityValue(L("左耳：","Left: ")+(reading(.left).map { "\($0.percent)%" } ?? L("未知","unknown"))+L("，右耳：",", right: ")+(reading(.right).map { "\($0.percent)%" } ?? L("未知","unknown")))
            }
            Button(action:onClose) {
                Image(systemName:"xmark").font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
                    .frame(width:22,height:22).background(.quaternary.opacity(0.55),in:Circle())
                    .frame(width:28,height:28).contentShape(Circle())
            }.buttonStyle(.plain).padding(.top,18).padding(.trailing,12)
                .help(L("关闭连接提示","Dismiss connection pop-up"))
                .accessibilityLabel(L("关闭连接提示","Dismiss connection pop-up"))
        }
    }
    private var compactHeight:CGFloat { Self.size(for:device,disconnected:disconnected).height-4 }
    static func size(for device:DeviceCandidate?,disconnected:Bool) -> NSSize {
        NSSize(width:size.width,height:disconnected ? 78 : device?.systemAudioOnly == true ? 110 : size.height)
    }
}

private struct ConnectionTipMaterial:NSViewRepresentable {
    func makeNSView(context:Context) -> NSVisualEffectView {
        let view=NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view:NSVisualEffectView,context:Context) {
        view.appearance=NSAppearance(named:context.environment.colorScheme == .dark ? .darkAqua : .aqua)
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
    private(set) var disconnected=false
    private(set) var presentationCount=0
    var onDismiss:(() -> Void)?
    var isShown:Bool { panel?.isVisible == true }

    func show(app:AppModel,device:DeviceCandidate?,preview:Bool,disconnected:Bool=false,anchor:NSRect?,onOpen:@escaping () -> Void) {
        dismiss(animated:false,notify:false)
        presentationCount += 1
        self.deviceID=device?.id; self.preview=preview; self.disconnected=disconnected
        let size=ConnectionTipView.size(for:device,disconnected:disconnected)
        let panel=ConnectionNotificationPanel(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.title="HeyBuds · Connection"; panel.isReleasedWhenClosed=false
        panel.level = .statusBar; panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=true
        panel.appearance=app.appearance == "dark" ? NSAppearance(named:.darkAqua) : app.appearance == "light" ? NSAppearance(named:.aqua) : nil
        panel.hidesOnDeactivate=false; panel.isFloatingPanel=true
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        panel.contentView=NSHostingView(rootView:ConnectionTipView(app:app,device:device,preview:preview,disconnected:disconnected,onOpen:onOpen,onClose:{ [weak self] in self?.dismiss() }))
        let screen=anchor.flatMap { point in NSScreen.screens.first(where:{$0.frame.contains(NSPoint(x:point.midX,y:point.midY))}) } ?? NSScreen.main
        let visible=screen?.visibleFrame ?? NSRect(x:0,y:0,width:1280,height:800)
        let x=min(max((anchor?.midX ?? visible.maxX-size.width/2-12)-size.width/2,visible.minX+12),visible.maxX-size.width-12)
        let y=max(visible.minY+12,(anchor?.minY ?? visible.maxY)-size.height-12)
        let scale=screen?.backingScaleFactor ?? 1
        let origin=NSPoint(x:(x*scale).rounded()/scale,y:(y*scale).rounded()/scale)
        let target=NSRect(origin:origin,size:size)
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
            if disconnected || device?.systemAudioOnly == true {
                try? await Task.sleep(for:.seconds(disconnected ? 4 : 8))
                if !Task.isCancelled { self?.dismiss() }
                return
            }
            let start=Date()
            let hasBattery:() -> Bool = { [weak app] in
                guard let app, app.ready, app.selectedID == device?.id else { return false }
                return app.state.batteries[.left] != nil || app.state.batteries[.right] != nil || !app.state.unassignedBatteries.isEmpty
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
