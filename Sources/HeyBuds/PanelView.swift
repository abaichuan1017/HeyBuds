import SwiftUI
import AppKit
import HeyBudsProtocol
import HeyBudsBluetooth

typealias ViewState<Value> = SwiftUI.State<Value>

private enum Page: Hashable { case home,hosts,device,advanced,settings }
private struct Card: ViewModifier {
    var verticalPadding:CGFloat=12
    func body(content:Content) -> some View {
        content.padding(.horizontal,12).padding(.vertical,verticalPadding).frame(maxWidth:.infinity,alignment:.leading)
            .background(.quaternary.opacity(0.45),in:RoundedRectangle(cornerRadius:16))
    }
}
extension View { fileprivate func card(verticalPadding:CGFloat=12) -> some View { modifier(Card(verticalPadding:verticalPadding)) } }

// The same SF Symbols used by the MIT-licensed Realme menu bar controller.
enum EarbudIcon {
    static let pair="airpods.pro"
    static let enclosure="airpods.pro.chargingcase.wireless.fill"
}

private struct ListeningSurface<S:Shape>:ViewModifier {
    let selected:Bool
    let shape:S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content:Content) -> some View {
        if reduceTransparency {
            content.background(selected ? Color.accentColor : Color(nsColor:.controlBackgroundColor),in:shape)
        } else {
            content.glassEffect(selected ? .regular.tint(.accentColor).interactive() : .regular.interactive(),in:shape)
        }
    }
}

struct PanelView: View {
    @Bindable var app:AppModel
    var onHeightChange:((CGFloat) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    // A type alias selects the native State property wrapper rather than SDK 27 macros.
    @ViewState<Page> private var page = .home
    @ViewState<CGFloat> private var contentHeight=300
    @ViewState<CustomEQEntry?> private var editEQ:CustomEQEntry? = nil
    @ViewState<Bool> private var findConfirmation=false
    private var maxHeight:CGFloat { max(280,(NSScreen.main?.visibleFrame.height ?? 800)-100) }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                if page == .home { header; home }
                else { navigationHeader; pageContent }
                messages
                footer
            }
            .padding(16)
            .frame(maxWidth:.infinity,alignment:.leading)
            .fixedSize(horizontal:false,vertical:true)
            .onGeometryChange(for:CGFloat.self) { geometry in geometry.size.height } action: { height in
                guard height.isFinite, height > 0 else { return }
                let measured=ceil(height)
                guard abs(contentHeight-measured) > 0.5 else { return }
                var transaction=Transaction(animation:nil)
                transaction.disablesAnimations=true
                withTransaction(transaction) {
                    contentHeight=measured
                    onHeightChange?(min(measured,maxHeight))
                }
            }
        }
        .scrollIndicators(.never)
        .frame(width:360,height:min(contentHeight,maxHeight))
        .background(reduceTransparency ? Color(nsColor:.windowBackgroundColor) : Color.clear)
        .preferredColorScheme(app.appearance == "dark" ? .dark : app.appearance == "light" ? .light : nil)
        // Keep page replacement immediate to avoid flashing newly inserted switches.
        .animation(reduceMotion ? nil : .smooth(duration:0.25),value:app.ready)
        .sheet(item:$editEQ) { entry in EQEditor(app:app,entry:entry) { editEQ=nil } }
        .alert(L("查找耳机","Find earbuds"),isPresented:$findConfirmation) {
            Button(L("开始响铃","Start ringing")) { app.perform { try await $0.find(true) } }
            Button(L("取消","Cancel"),role:.cancel) { }
        } message: { Text(L("请先摘下耳机。可随时点“停止响铃”结束。","Remove the earbuds first. Use Stop ringing to end the sound.")) }
        .font(.system(size:13))
        .onChange(of:app.selectedID) { _,_ in page = .home }
        .onChange(of:app.state.placement) { _,placement in
            let worn:[UInt8]=app.model?.isT500 == true ? [3] : [3,7]
            if placement.values.contains(where:{worn.contains($0)}) { app.noiseControlHint=nil }
        }
    }
    private var header:some View {
        HStack(spacing:10) {
            Image(systemName:EarbudIcon.pair).font(.system(size:24)).foregroundStyle(.primary)
                .frame(width:36,height:40)
            HStack(spacing:6) {
                Circle().fill(app.bluetoothConnected ? Color.green : Color.yellow)
                    .frame(width:5,height:5).accessibilityHidden(true)
                Menu {
                    ForEach(app.candidates) { candidate in
                        Button { app.select(candidate.id) } label: {
                            if app.selectedID == candidate.id { Label(candidate.name,systemImage:"checkmark") }
                            else { Text(candidate.name) }
                        }
                    }
                    Divider()
                    Button(L("重新查找设备","Refresh devices")) { Task { await app.rescan() } }
                    Button(L("蓝牙设置…","Bluetooth Settings…")) { app.bluetoothSettings() }
                } label: {
                    Text(app.bluetoothConnected ? app.title : L("未连接","Not connected"))
                        .font(.system(size:14,weight:.semibold)).lineLimit(1).truncationMode(.tail)
                }
                .menuStyle(.borderlessButton).menuIndicator(.visible)
                .accessibilityLabel(L("选择设备","Select device"))
                .accessibilityValue(app.bluetoothConnected ? L("已连接 · ","Connected · ")+app.title : L("未连接","Not connected"))
                .help(L("选择已配对的耳机","Select paired earbuds"))
            }
            Spacer(minLength:0)
            ZStack {
                if app.connecting || app.operationBusy { ProgressView().controlSize(.small) }
            }.frame(width:16,height:16)
            Button {
                if app.ready || app.connecting { app.disconnect() } else { app.connect() }
            } label: { Image(systemName:"power").font(.system(size:14,weight:.medium)).frame(width:28,height:28) }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .help(app.ready ? L("断开耳机","Disconnect earbuds") : L("连接耳机","Connect earbuds"))
            .accessibilityLabel(app.ready ? L("断开耳机","Disconnect earbuds") : L("连接耳机","Connect earbuds"))
        }
    }
    @ViewBuilder private var home:some View {
        if app.ready {
            HStack(alignment:.top,spacing:8) {
                BatteryCell(title:app.model?.singleBattery == true ? L("耳机","Headphones") : L("左耳","Left"),symbol:app.model?.singleBattery == true ? "headphones" : "airpods.pro.left",sideLabel:app.model?.singleBattery == true ? nil : "L",reading:app.state.batteries[.left],placement:app.state.placement[.left],t500:app.model?.isT500 == true)
                if app.model?.singleBattery != true {
                BatteryCell(title:L("右耳","Right"),symbol:"airpods.pro.right",sideLabel:"R",reading:app.state.batteries[.right],placement:app.state.placement[.right],t500:app.model?.isT500 == true)
                BatteryCell(title:L("充电盒","Case"),symbol:EarbudIcon.enclosure,reading:app.state.batteries[.enclosure],placement:nil,t500:false)
                }
            }.padding(.vertical,6)
            if app.model?.noiseOptions.isEmpty == false { noiseCard }
            if app.session?.canQuery(Command.hosts) == true || app.features.contains(where:{$0.key == "dual"}) {
                navRow(L("多设备连接","Connected devices"),symbol:"laptopcomputer.and.iphone",target:.hosts).card()
            }
            navRow(L("高级功能","Advanced features"),symbol:"slider.horizontal.3",target:.advanced).card()
        } else {
            VStack(alignment:.leading,spacing:12) {
                Text(L("你的耳机，随手可控。","Your earbuds, a click away."))
                    .font(.system(size:18,weight:.semibold))
                HStack {
                    Button(L("蓝牙设置","Bluetooth Settings")) { app.bluetoothSettings() }
                    Spacer()
                    Button(L("连接","Connect")) { app.connect() }.buttonStyle(.glassProminent).disabled(app.connecting || app.candidates.isEmpty)
                }
            }.card()
        }
    }
    private var noiseCard:some View {
        noiseModeButtons.card().accessibilityElement(children:.contain)
            .accessibilityLabel(L("降噪控制","Noise control"))
    }
    private var noiseModeButtons:some View {
        let options=app.model?.noiseOptions ?? []
        let hasStrengths=options.filter { $0.mode.group == .anc }.count > 1
        let groups:[NoiseMode]=[.off,.anc,.transparency,.adaptive].filter { group in options.contains { $0.mode.group == group } }
        return GlassEffectContainer(spacing:8) {
            HStack(spacing:0) {
                ForEach(groups,id:\.self) { group in
                    let active=app.state.noise?.group == group
                    Button {
                        let target=options.first(where:{$0.mode == app.state.noise && $0.mode.group == group})?.mode
                            ?? options.first(where:{$0.mode == .smart && group == .anc})?.mode
                            ?? options.first(where:{$0.mode.group == group})!.mode
                        app.perform(noiseControl:true) { try await $0.setNoise(target) }
                    } label: {
                        VStack(spacing:8) {
                            Image(systemName:noiseSymbol(group)).font(.system(size:22))
                                .foregroundStyle(active ? Color.white : Color.primary)
                                .frame(width:54,height:54)
                                .modifier(ListeningSurface(selected:active,shape:Circle()))
                                .animation(reduceMotion ? nil : .easeOut(duration:0.18),value:active)
                            Text(noiseLabel(group)).font(.system(size:11,weight:active ? .medium : .regular))
                                .foregroundStyle(active ? .primary : .secondary)
                                .lineLimit(1).minimumScaleFactor(0.8).frame(height:16)
                                .opacity(group == .anc && active && hasStrengths ? 0 : 1)
                        }.frame(maxWidth:.infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .disabled(!app.canWrite(Command.setNoise,reading:app.model?.isT500 == true ? nil : Command.noise))
                        .help(group == .off ? L("关闭降噪与通透，音频保持正常播放。","Turns off noise cancellation and transparency. Audio continues playing.") : noiseLabel(group))
                        .accessibilityLabel(group == .off ? L("关闭降噪","Noise control off") : noiseLabel(group))
                        .accessibilityAddTraits(active ? .isSelected : [])
                        .overlay(alignment:.bottom) {
                            if group == .anc { noiseStrengthMenu }
                        }
                }
            }
        }
    }
    private var noiseStrengthMenu:some View {
        let levels=(app.model?.noiseOptions ?? []).filter { $0.mode.group == .anc }
        let visible=app.state.noise?.group == .anc && levels.count > 1
        return NoiseStrengthMenu(options:levels,selection:app.state.noise,
            enabled:visible && app.canWrite(Command.setNoise,reading:app.model?.isT500 == true ? nil : Command.noise)) { mode in
                app.perform(noiseControl:true) { try await $0.setNoise(mode) }
            }.frame(maxWidth:.infinity).frame(height:16)
            .opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
            .disabled(!visible || !app.canWrite(Command.setNoise,reading:app.model?.isT500 == true ? nil : Command.noise))
            .accessibilityLabel(L("降噪强度","ANC strength"))
            .accessibilityValue(noiseLabel(app.state.noise ?? .smart))
    }
    private var footerHintText:String? {
        if page == .home {
            if let hint=app.noiseControlHint { return hint }
            if app.ready, app.model?.noiseOptions.isEmpty == false, app.state.noise == nil {
                return L("等待耳机报告当前模式","Waiting for the current mode")
            }
        }
        return app.notice
    }
    @ViewBuilder private var eqPicker:some View {
        if app.model?.presets.isEmpty == false || !app.state.customEQ.isEmpty {
            HStack(spacing:9) {
                Image(systemName:"music.note.list").frame(width:18).foregroundStyle(.secondary)
                Text(L("均衡器","Equalizer")).fixedSize()
                Spacer(minLength:12)
                Menu {
                    ForEach(app.presets) { p in eqChoice(p.id,name:app.language == "en" ? p.english : p.chinese) }
                    if !app.presets.isEmpty, !app.state.customEQ.isEmpty { Divider() }
                    ForEach(app.state.customEQ) { p in eqChoice(p.id,name:p.name) }
                } label: {
                    HStack(spacing:6) {
                        Text(selectedEQName).lineLimit(1).truncationMode(.tail)
                        Image(systemName:"chevron.up.chevron.down").font(.system(size:9,weight:.semibold))
                    }.foregroundStyle(.secondary)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(maxWidth:148,alignment:.trailing).fixedSize(horizontal:false,vertical:true)
                    .accessibilityLabel(L("均衡器","Equalizer"))
                    .accessibilityValue(selectedEQName)
                    .disabled(!app.canWrite(Command.setEQ,reading:Command.equalizer))
            }.padding(.vertical,6).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private var selectedEQName:String {
        guard let id=app.state.eq else { return L("未知","Unknown") }
        if let preset=app.presets.first(where:{$0.id == id}) { return app.language == "en" ? preset.english : preset.chinese }
        if let preset=app.state.customEQ.first(where:{$0.id == id}) { return preset.name }
        return L("预设 ","Preset ")+String(id)
    }
    private func eqChoice(_ id:UInt8,name:String) -> some View {
        Button { app.perform { try await $0.setEQ(id) } } label: {
            if app.state.eq == id { Label(name,systemImage:"checkmark") }
            else { Text(name) }
        }
    }
    private var spatialControls:some View {
        VStack(alignment:.leading,spacing:9) {
            Text(L("空间音频","Spatial audio")).fontWeight(.semibold)
            ForEach(app.model?.spatialModes ?? [],id:\.self) { mode in
                Button { app.perform { try await $0.setSpatial(mode) } } label: {
                    HStack(spacing:10) {
                        Image(systemName:mode == 0 ? "headphones" : mode == 1 ? "hifispeaker.2" : "person.crop.circle.badge.waveform")
                            .frame(width:22)
                        Text(spatialLabel(mode)); Spacer()
                        if app.state.spatial == mode { Image(systemName:"checkmark").fontWeight(.semibold).foregroundStyle(.tint) }
                    }.padding(.vertical,4).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!app.canWrite(Command.setSpatial,reading:Command.spatial))
            }
        }.padding(.vertical,6)
    }
    private var navigationHeader:some View {
        PanelNavigationHeader(title:pageTitle) { page = page == .device ? .settings : .home }
    }
    private var pageTitle:String {
        switch page {
        case .home:return "HeyBuds"
        case .hosts:return L("多设备连接","Connected devices")
        case .device:return L("设备信息","Device info")
        case .advanced:return L("高级功能","Advanced features")
        case .settings:return L("设置","Settings")
        }
    }
    @ViewBuilder private var pageContent:some View {
        switch page {
        case .hosts: hostsPage
        case .device: devicePage
        case .advanced: advancedPage
        case .settings: settingsPage
        case .home: EmptyView()
        }
    }
    private var canAdjustEQ:Bool {
        (!app.presets.isEmpty || !app.state.customEQ.isEmpty) && app.session?.canWrite(Command.setEQ,reading:Command.equalizer) == true
    }
    private var canCustomizeEQ:Bool {
        app.model?.customEQFrequencies.isEmpty == false && app.session?.canWrite(Command.setCustomEQ,reading:Command.customEQ) == true
    }
    private var canAdjustBass:Bool { app.state.bass != nil && app.session?.canWrite(Command.setBass,reading:Command.bass) == true }
    private var canAdjustSpatial:Bool { app.supportsSpatialAudio && app.session?.canWrite(Command.setSpatial,reading:Command.spatial) == true }
    private var canAdjustGameSound:Bool {
        app.model?.gameTypes.isEmpty == false && app.state.gameSound != nil && app.session?.canWrite(Command.setGameSound,reading:Command.gameSound) == true
    }
    private var gameFeature:FeatureDefinition? {
        guard let feature=app.session?.gameFeature, app.session?.canSetFeature(feature) == true else { return nil }
        return feature
    }
    private func availableFeature(_ key:String) -> FeatureDefinition? {
        app.features.first { $0.key == key && app.session?.canSetFeature($0) == true }
    }
    private var configurableGestures:[GestureEntry] {
        guard app.session?.canWrite(Command.setGestures,reading:Command.gestures) == true else { return [] }
        return app.state.gestures.filter { $0.mode == 1 && (app.session?.gestureActions($0).count ?? 0) > 1 }
    }
    private var canFind:Bool { app.model?.function["findDevice"].enabled == true && app.session?.canWrite(Command.find) == true }
    private var hasSoundControls:Bool {
        canAdjustEQ || canCustomizeEQ || canAdjustBass || canAdjustSpatial || availableFeature("spatialSound") != nil || availableFeature("voice") != nil
    }
    private var hasGameControls:Bool { gameFeature != nil || canAdjustGameSound }
    private var hasEarbudControls:Bool { availableFeature("wear") != nil || !configurableGestures.isEmpty || canFind }
    private var assistanceFeatures:[FeatureDefinition] { ["hearing","hearingProtection","posture"].compactMap(availableFeature) }
    @ViewBuilder private var soundControls:some View {
        if canAdjustEQ { eqPicker }
        if canCustomizeEQ {
            if canAdjustEQ { Divider() }
            VStack(alignment:.leading,spacing:8) {
                ForEach(app.state.customEQ) { entry in
                    HStack {
                        Text(entry.name); Spacer()
                        Button(L("编辑","Edit")) { editEQ=entry }
                    }
                }
                Button { editEQ=CustomEQEntry(name:"HeyBuds",minimum:app.model!.customEQMinimum,maximum:app.model!.customEQMaximum,frequencies:app.model!.customEQFrequencies,gains:Array(repeating:0,count:app.model!.customEQFrequencies.count)) } label: {
                    Label(L("新建自定义 EQ","Create custom EQ"),systemImage:"plus")
                }.disabled(app.operationBusy || app.state.customEQ.count >= (app.model?.customEQMax ?? 0))
            }.padding(.vertical,8)
        }
        if canAdjustBass, let bass=app.state.bass {
            if canAdjustEQ || canCustomizeEQ { Divider() }
            VStack(alignment:.leading,spacing:8) {
                HStack { Text(L("低音引擎","Bass engine")); Spacer(); Text(String(bass.current)).monospacedDigit() }
                BassSlider(app:app,state:bass)
            }.padding(.vertical,8)
        }
        if canAdjustSpatial || availableFeature("spatialSound") != nil {
            if canAdjustEQ || canCustomizeEQ || canAdjustBass { Divider() }
            if canAdjustSpatial { spatialControls }
            else if let feature=availableFeature("spatialSound") {
                featureToggle(feature,title:L("空间音效","Spatial sound"),detail:nil,symbol:"waveform.path")
            }
        }
        if let voice=availableFeature("voice") {
            if canAdjustEQ || canCustomizeEQ || canAdjustBass || canAdjustSpatial || availableFeature("spatialSound") != nil { Divider() }
            featureToggle(voice,title:featureLabel(voice.key),detail:nil,symbol:"person.wave.2")
        }
    }
    @ViewBuilder private var gameControls:some View {
        if let game=gameFeature {
            featureToggle(game,title:L("游戏模式","Game mode"),detail:nil,symbol:"gamecontroller")
        }
        if canAdjustGameSound {
            if gameFeature != nil { Divider() }
            HStack(spacing:9) {
                Image(systemName:"waveform").frame(width:18).foregroundStyle(.secondary)
                Text(L("游戏音效","Game sound"))
                Spacer(minLength:12)
                Picker(L("游戏音效","Game sound"),selection:Binding(get:{app.state.gameSound.map(Int.init) ?? -1},set:{ value in
                    if let mode=UInt8(exactly:value) { app.perform { try await $0.setGameSound(mode) } }
                })) {
                    Text(L("关闭","Off")).tag(0)
                    ForEach(app.model?.gameTypes ?? [],id:\.self) { Text(L("音效 ","Effect ")+String($0)).tag(Int($0)) }
                }.labelsHidden().fixedSize().disabled(app.operationBusy)
            }.padding(.vertical,6).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    @ViewBuilder private var earbudControls:some View {
        if let wear=availableFeature("wear") {
            featureToggle(wear,title:L("佩戴检测","In-ear detection"),detail:nil,symbol:"ear")
        }
        ForEach(configurableGestures) { entry in
            if availableFeature("wear") != nil || entry.id != configurableGestures.first?.id { Divider() }
            HStack(spacing:10) {
                Text((entry.side == 1 ? L("左耳 · ","Left · ") : L("右耳 · ","Right · "))+gestureLabel(entry.gesture))
                Spacer(minLength:8)
                Picker(L("操作","Action"),selection:Binding(get:{entry.action},set:{ value in app.perform { try await $0.setGesture(entry,action:value) } })) {
                    ForEach(Array(Set((app.session?.gestureActions(entry) ?? [])+[entry.action])).sorted(),id:\.self) { Text(actionLabel($0)).tag($0) }
                }.labelsHidden().frame(maxWidth:138).disabled(app.operationBusy)
                    .accessibilityLabel((entry.side == 1 ? L("左耳 · ","Left · ") : L("右耳 · ","Right · "))+gestureLabel(entry.gesture))
            }.padding(.vertical,6)
        }
        if canFind {
            if availableFeature("wear") != nil || !configurableGestures.isEmpty { Divider() }
            HStack {
                Button(L("查找耳机","Find earbuds")) { findConfirmation=true }
                Spacer()
                Button(L("停止响铃","Stop ringing")) { app.perform { try await $0.find(false) } }
            }.padding(.vertical,8).disabled(app.operationBusy)
        }
    }
    private var hostsPage:some View {
        VStack(alignment:.leading,spacing:12) {
            if !app.ready { offlineNote }
            if let feature=app.features.first(where:{$0.key == "dual"}) { featureToggle(feature,title:L("双设备连接","Dual connection"),detail:L("同时连接两台设备","Connect to two hosts")).card() }
            ForEach(app.state.hosts) { host in
                VStack(alignment:.leading,spacing:8) {
                    HStack {
                        Image(systemName:host.current ? "laptopcomputer" : "laptopcomputer.and.iphone")
                        Text(host.name.isEmpty ? L("未命名设备","Unnamed device") : host.name).fontWeight(.medium)
                        Spacer()
                        if host.current { Text(L("当前","Current")).font(.caption).foregroundStyle(.secondary) }
                    }
                    HStack {
                        Text(host.connected ? L("已连接","Connected") : host.connection == 1 ? L("已配对","Paired") : host.connection == 0 ? L("未连接","Disconnected") : L("状态未知","Unknown status"))
                            .font(.caption).foregroundStyle(.secondary)
                        if host.audioActive { Label(L("播放中","Playing"),systemImage:"waveform").font(.caption).foregroundStyle(.secondary) }
                        if host.preferred || (app.state.automaticPriority == false && app.state.priorityAddress == host.address) {
                            Text(L("优先设备","Priority device")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !host.current {
                            Button(host.connected ? L("断开","Disconnect") : L("连接","Connect")) { app.perform { try await $0.operateHost(host.connected ? .disconnect : .connect,host:host) } }
                                .disabled(app.operationBusy || app.session?.canOperateHost(host.connected ? .disconnect : .connect,host:host) != true)
                                .help(L("连接或断开所选设备。","Connect or disconnect the selected host."))
                        }
                    }
                }.card()
            }
            if app.state.hosts.isEmpty { Text(L("耳机尚未报告连接设备列表。","No connected-host list has been reported.")).foregroundStyle(.secondary) }
            if app.model?.hostOperationAvailable("setPriorityDevice",firmware:app.state.firmwareRevision) == true {
                settingsGroup(L("连接策略","Connection strategy")) {
                    if app.session?.canQuery(Command.priority) == true || app.state.observedQueries.contains(Command.hosts) && app.model?.family == .huawei {
                        HStack {
                            Text(L("优先连接","Preferred host")); Spacer()
                            Picker(L("优先连接","Preferred host"),selection:Binding(get:{prioritySelection},set:{ selection in
                                if selection == "auto" { app.perform { try await $0.operateHost(.automatic) } }
                                else if let host=app.state.hosts.first(where:{$0.id == selection}) {
                                    app.perform { try await $0.operateHost(.priority,host:host) }
                                }
                            })) {
                                if prioritySelection == "unknown" { Text(L("尚未上报","Not reported")).tag("unknown") }
                                if app.session?.canOperateHost(.automatic) == true { Text(L("自动选择","Automatic")).tag("auto") }
                                ForEach(app.state.hosts.filter(\.connected)) { host in
                                    Text(host.name.isEmpty ? L("未命名设备","Unnamed device") : host.name).tag(host.id)
                                }
                            }.labelsHidden().frame(maxWidth:156)
                                .disabled(app.operationBusy || (app.session?.canOperateHost(.automatic) != true && !app.state.hosts.contains { app.session?.canOperateHost(.priority,host:$0) == true }))
                        }.padding(.vertical,6)
                    } else {
                        Text(L("此耳机当前未开放连接优先级设置。","Connection priority is not currently available from these earbuds."))
                            .font(.system(size:11)).foregroundStyle(.secondary).padding(.vertical,6)
                    }
                }
            }
        }
    }
    private var prioritySelection:String {
        if app.state.automaticPriority == true { return "auto" }
        if app.state.automaticPriority != true,
           let host=app.state.hosts.first(where:{$0.connected && $0.address == app.state.priorityAddress}) { return host.id }
        return "unknown"
    }
    private var devicePage:some View {
        VStack(alignment:.leading,spacing:12) {
            if !app.ready { offlineNote }
            VStack(spacing:10) {
                infoRow(L("型号","Model"),app.model?.name ?? L("未知","Unknown"))
                infoRow(L("产品 ID","Product ID"),app.state.productID ?? "—")
                infoRow(L("固件","Firmware"),app.state.firmware ?? "—")
                infoRow(L("编解码器","Codec"),app.state.codec ?? "—")
                infoRow(L("控制连接","Control transport"),app.transportLabel.isEmpty ? "—" : app.transportLabel)
            }.card()
        }
    }
    private var advancedPage:some View {
        VStack(alignment:.leading,spacing:16) {
            if !app.ready { offlineNote }
            if hasSoundControls {
                settingsGroup(L("声音与音效","Sound & audio")) { soundControls }
            }
            if hasGameControls {
                settingsGroup(L("游戏","Gaming")) { gameControls }
            }
            if hasEarbudControls {
                settingsGroup(L("佩戴与操作","Wearing & controls")) { earbudControls }
            }
            if !assistanceFeatures.isEmpty {
                settingsGroup(L("辅助与健康","Assistance & health")) {
                    ForEach(assistanceFeatures) { feature in
                        if feature.id != assistanceFeatures.first?.id { Divider() }
                        featureToggle(feature,title:featureLabel(feature.key),detail:nil)
                    }
                }
            }
            if let feature=availableFeature("longBattery") {
                settingsGroup(L("电源","Power")) {
                    featureToggle(feature,title:featureLabel(feature.key),detail:nil)
                }
            }
            if app.ready, !hasSoundControls, !hasGameControls, !hasEarbudControls, assistanceFeatures.isEmpty, availableFeature("longBattery") == nil {
                Text(L("耳机尚未报告其他可用功能。","No additional features have been reported by the earbuds."))
                    .foregroundStyle(.secondary)
            }
        }
    }
    private var settingsPage:some View {
        VStack(alignment:.leading,spacing:12) {
            settingsGroup(L("常规","General")) {
                settingPicker(L("语言","Language"),selection:Binding(get:{app.language == "en" ? "en" : "zh"},set:{app.language=$0}),choices:[
                    .init("zh","简体中文"),.init("en","English")
                ])
                Divider()
                settingPicker(L("外观","Appearance"),selection:Binding(get:{["light","dark"].contains(app.appearance) ? app.appearance : "system"},set:{app.appearance=$0}),choices:[
                    .init("system",L("跟随系统","System")),.init("light",L("浅色","Light")),.init("dark",L("深色","Dark"))
                ])
                Divider()
                settingToggle(L("菜单栏显示电量","Battery in menu bar"),isOn:$app.menuBattery)
                Divider()
                settingToggle(L("后台运行","Background mode"),helpText:L("未连接已识别耳机时隐藏图标，重新打开 HeyBuds 可进入设置。","Hide the icon when no recognized earbuds are connected. Reopen HeyBuds to access settings."),isOn:$app.backgroundMode)
                Divider()
                settingToggle(L("断线自动重连","Reconnect automatically"),isOn:$app.autoReconnect)
                Divider()
                settingToggle(L("登录时启动","Launch at login"),isOn:Binding(get:{app.launchAtLogin},set:app.setLogin))
            }.onAppear { app.refreshLoginStatus() }
            settingsGroup(L("提醒","Notifications")) {
                settingToggle(L("连接提示","Connection pop-up"),isOn:$app.connectionTips)
                Divider()
                settingAction(L("预览连接提示","Preview connection pop-up"),symbol:"play.circle") { app.onPreviewConnectionTip?() }
                Divider()
                settingToggle(L("低电量提醒","Low battery notifications"),isOn:Binding(get:{app.notifyLow},set:app.setNotifications))
                Divider()
                settingPicker(L("提醒阈值","Alert threshold"),selection:$app.lowThreshold,
                    choices:Array(Set([10,15,20,25,30,app.lowThreshold])).sorted().map { .init($0,"\($0)%") })
                    .disabled(!app.notifyLow)
            }
            settingsGroup(L("设备","Device")) {
                settingAction(L("设备信息","Device info"),symbol:"chevron.right") { page = .device }
                Divider()
                settingPicker(L("设备型号","Device model"),helpText:L("仅在自动识别错误时手动指定。功能仍需耳机响应确认。","Override only if automatic identification is incorrect. Features still require device responses."),isDisabled:app.candidate == nil || app.operationBusy,
                    selection:Binding(get:{app.overrideID.flatMap { id in app.catalog.models.contains(where:{$0.id == id}) ? id : nil } ?? "auto"},set:{app.overrideID=$0 == "auto" ? nil : $0}),
                    choices:[.init("auto",L("自动识别","Automatic"))]+app.catalog.models.sorted(by:{$0.name < $1.name}).map { .init($0.id,$0.name) })
            }
            UpdatesSection(app:app)
        }
    }
    private func settingsGroup<Content:View>(_ title:String,@ViewBuilder content:() -> Content) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary).padding(.horizontal,12)
            VStack(alignment:.leading,spacing:0,content:content).card(verticalPadding:6)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func settingRow<Control:View>(_ title:String,helpText:String? = nil,@ViewBuilder control:() -> Control) -> some View {
        HStack(spacing:12) {
            SettingsLabel(title:title,helpText:helpText)
            Spacer(minLength:0)
            control()
        }.frame(maxWidth:.infinity,minHeight:30,alignment:.leading)
    }
    private func settingPicker<Value:Hashable>(_ title:String,helpText:String? = nil,isDisabled:Bool = false,selection:Binding<Value>,choices:[SettingsChoice<Value>]) -> some View {
        settingRow(title,helpText:helpText) {
            SettingsMenu(title:title,choices:choices,selection:selection,enabled:!isDisabled).frame(width:132)
        }
    }
    private func settingToggle(_ title:String,helpText:String? = nil,isOn:Binding<Bool>) -> some View {
        settingRow(title,helpText:helpText) {
            Toggle(title,isOn:isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize()
        }
    }
    private func settingAction(_ title:String,symbol:String,action:@escaping () -> Void) -> some View {
        SettingsActionRow(title:title,symbol:symbol,action:action)
    }
    @ViewBuilder private var messages:some View {
        if let error=app.error {
            HStack(alignment:.top,spacing:7) {
                Image(systemName:"exclamationmark.circle").foregroundStyle(.orange)
                Text(error).font(.caption).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(.orange.opacity(0.08),in:RoundedRectangle(cornerRadius:10))
        }
        if page == .settings, let notice=app.notice {
            Text(notice).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal:false,vertical:true)
        }
    }
    @ViewBuilder private var footer:some View {
        if page == .settings {
            SettingsFooter(app:app)
        } else {
            standardFooter
        }
    }
    private var standardFooter:some View {
        HStack(spacing:14) {
            Button { page = .settings } label: {
                Image(systemName:"gearshape").font(.system(size:12))
                    .frame(width:16,height:22).contentShape(Rectangle())
            }
                .help(L("设置","Settings")).accessibilityLabel(L("设置","Settings"))
            if app.ready {
                Button { app.performRefresh() } label: {
                    Image(systemName:"arrow.clockwise").font(.system(size:11))
                        .frame(width:16,height:22).contentShape(Rectangle())
                }
                    .disabled(app.operationBusy).help(L("刷新状态","Refresh state")).accessibilityLabel(L("刷新状态","Refresh state"))
            }
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: {
                Text(L("退出","Quit")).font(.system(size:11))
                    .frame(minWidth:28,minHeight:22).contentShape(Rectangle())
            }
        }.frame(height:30)
            .overlay(alignment:.center) {
                // Reuse the space between the footer controls without affecting layout.
                Text(footerHintText ?? " ")
                    .font(.system(size:10.5)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85)
                    .frame(width:196,height:30)
                    .opacity(footerHintText == nil ? 0 : 1)
                    .accessibilityHidden(footerHintText == nil).allowsHitTesting(false)
                    .animation(reduceMotion ? nil : .easeOut(duration:0.15),value:footerHintText != nil)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).padding(.top,3)
    }
    private var offlineNote:some View { Text(L("控制通道未连接。","Control channel is disconnected.")).foregroundStyle(.secondary) }
    private func navRow(_ title:String,symbol:String,target:Page) -> some View {
        Button { page=target } label: {
            HStack(spacing:9) { Image(systemName:symbol).frame(width:18); Text(title); Spacer(); Image(systemName:"chevron.right").font(.system(size:10,weight:.semibold)).foregroundStyle(.tertiary) }
                .padding(.vertical,4).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func featureToggle(_ feature:FeatureDefinition,title:String,detail:String?,symbol:String? = nil) -> some View {
        HStack(spacing:9) {
            if let symbol { Image(systemName:symbol).frame(width:18).foregroundStyle(.secondary) }
            SettingsLabel(title:title,helpText:detail)
            Spacer(minLength:12)
            if app.state.switches[feature.switchID] != nil {
                Toggle(title,isOn:Binding(get:{app.state.switches[feature.switchID] ?? false},set:{ enabled in app.perform { try await $0.setFeature(feature,enabled:enabled) } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize()
                    .disabled(app.operationBusy || app.session?.canSetFeature(feature) != true)
                    .help(app.session?.canSetFeature(feature) == true ? title : L("耳机尚未开放此设置。","This setting is not currently available from the earbuds."))
                    .accessibilityValue(app.state.switches[feature.switchID] == true ? L("开启","On") : L("关闭","Off"))
            } else {
                Text(L("未上报","Not reported")).font(.system(size:10)).foregroundStyle(.secondary)
                    .frame(width:44,height:20)
            }
        }.padding(.vertical,5).frame(maxWidth:.infinity,alignment:.leading)
    }
    private func infoRow(_ name:String,_ value:String) -> some View {
        HStack(alignment:.top) { Text(name).foregroundStyle(.secondary); Spacer(minLength:10); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }
    }
}

struct PanelNavigationHeader:View {
    let title:String
    let onBack:() -> Void
    var body:some View {
        HStack(spacing:10) {
            Button(action:onBack) {
                Image(systemName:"chevron.left").font(.system(size:12,weight:.semibold)).frame(width:24,height:24)
            }.buttonStyle(.glass).buttonBorderShape(.circle)
                .help(L("返回","Back")).accessibilityLabel(L("返回","Back"))
            Text(title).font(.system(size:16,weight:.semibold))
            Spacer(minLength:0)
        }
    }
}

struct SettingsHelpText:View {
    let title:String, text:String
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title).font(.system(size:13,weight:.semibold))
            Text(text).font(.system(size:12)).fixedSize(horizontal:false,vertical:true)
        }.frame(width:240,alignment:.leading).padding(14)
    }
}

struct SettingsLabel:View {
    let title:String
    var helpText:String? = nil
    @ViewState<Bool> private var showingHelp=false
    var body:some View {
        HStack(spacing:4) {
            Text(title).font(.system(size:13,weight:.regular)).fixedSize(horizontal:false,vertical:true)
            if let helpText {
                Button { showingHelp.toggle() } label: {
                    Image(systemName:"info.circle").font(.system(size:11)).foregroundStyle(.secondary).frame(width:18,height:22)
                }.buttonStyle(.plain).help(helpText)
                    .accessibilityLabel(title+L("说明"," information"))
                    .accessibilityHint(L("显示此设置的说明。","Show information about this setting."))
                    .popover(isPresented:$showingHelp,arrowEdge:.top) { SettingsHelpText(title:title,text:helpText) }
            }
        }.layoutPriority(1)
    }
}

struct SettingsActionRow:View {
    let title:String, symbol:String
    var detail:String?=nil
    let action:() -> Void
    var body:some View {
        Button(action:action) {
            HStack(spacing:12) {
                Text(title).font(.system(size:13,weight:.regular)).fixedSize(horizontal:false,vertical:true).layoutPriority(1)
                Spacer(minLength:0)
                if let detail { Text(detail).font(.system(size:13,weight:.regular)).foregroundStyle(.secondary).monospacedDigit() }
                Image(systemName:symbol).font(.system(size:11,weight:.medium)).foregroundStyle(.secondary).frame(width:16)
            }.frame(maxWidth:.infinity,minHeight:30,alignment:.leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct UpdatesSection:View {
    @Bindable var app:AppModel
    @ViewState private var showingDonation=false
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            Text(L("关于","About")).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary).padding(.horizontal,12)
            VStack(spacing:8) {
                SettingsActionRow(title:L("检查更新…","Check for updates…"),symbol:"arrow.down.circle",detail:AppIdentity.version) {
                    app.updater.checkForUpdates()
                }.disabled(!app.updater.canCheckForUpdates).card(verticalPadding:6)
                Button { showingDonation=true } label: {
                    HStack(spacing:8) {
                        Image(systemName:"cup.and.saucer").frame(width:18)
                        Text(L("请作者喝杯咖啡","Buy the developer a coffee"))
                        Spacer(minLength:0)
                        Image(systemName:"chevron.right").font(.system(size:11,weight:.medium)).foregroundStyle(.secondary)
                    }.frame(minHeight:30).contentShape(Rectangle())
                }.buttonStyle(.plain).card(verticalPadding:6)
                    .popover(isPresented:$showingDonation,arrowEdge:.bottom) { DonationView() }
            }
        }
    }
}

struct SettingsFooter:View {
    @Bindable var app:AppModel
    @ViewState private var showingLicense=false
    private static let githubImage:NSImage = {
        let image=NSImage(contentsOf:Bundle.module.url(forResource:"GitHub",withExtension:"pdf")!)!
        image.isTemplate=true
        return image
    }()
    var body:some View {
        HStack(spacing:10) {
            VStack(alignment:.leading,spacing:1) {
                Text(AppIdentity.name).font(.system(size:13,weight:.semibold)).foregroundStyle(.primary)
                Button { showingLicense=true } label: {
                    Text("GPL-3.0-or-later").font(.system(size:9)).foregroundStyle(.secondary)
                }.help(L("开源许可与第三方声明","License and third-party notices"))
                    .popover(isPresented:$showingLicense) { LicenseInfo() }
            }.fixedSize()
            Spacer(minLength:0)
            if app.ready {
                Button { app.performRefresh() } label: {
                    Image(systemName:"arrow.clockwise").font(.system(size:11)).frame(width:24,height:28)
                }.disabled(app.operationBusy).help(L("刷新状态","Refresh state")).accessibilityLabel(L("刷新状态","Refresh state"))
            }
            Button { NSWorkspace.shared.open(AppIdentity.projectURL) } label: {
                Image(nsImage:Self.githubImage).resizable().scaledToFit().frame(width:16,height:16).frame(width:24,height:28)
            }.help(L("GitHub 项目","GitHub project")).accessibilityLabel(L("在 GitHub 查看 HeyBuds","View HeyBuds on GitHub"))
            Button { app.exportDiagnostics() } label: {
                Image(systemName:"stethoscope").font(.system(size:13)).frame(width:24,height:28)
            }.help(L("导出诊断…","Export diagnostics…")).accessibilityLabel(L("导出诊断","Export diagnostics"))
            Button { NSApplication.shared.terminate(nil) } label: {
                Text(L("退出","Quit")).font(.system(size:11)).frame(minWidth:28,minHeight:28)
            }
        }.buttonStyle(.plain).foregroundStyle(.secondary).frame(height:32).padding(.top,3)
    }
}

private struct LicenseInfo:View {
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text(L("开源许可","Open-source license")).font(.headline)
            Text(L("HeyBuds 代码采用 GPL-3.0-or-later。包含的第三方组件及其版权归属见第三方声明，组合发行适用 GPL 第 3 版。软件不提供担保；你可以按许可证条款复制、修改与再分发。","HeyBuds code is licensed under GPL-3.0-or-later. See the third-party notices for component copyrights; the combined distribution is under GPL version 3. This software comes without warranty. You may copy, modify and redistribute it under the license terms."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack {
                Button(L("完整许可","Full license")) { openNotice("LICENSE") }
                Button(L("第三方声明","Third-party notices")) { openNotice("THIRD_PARTY_NOTICES.md") }
            }.controlSize(.small)
        }.padding(16).frame(width:290)
    }
    private func openNotice(_ name:String) {
        let local=Bundle.main.resourceURL?.appendingPathComponent(name)
        let url=local.flatMap { FileManager.default.fileExists(atPath:$0.path) ? $0 : nil }
            ?? AppIdentity.projectURL.appendingPathComponent("blob/main/"+name)
        NSWorkspace.shared.open(url)
    }
}

struct DonationView:View {
    @ViewState private var selection:DonationOption
    private static let codes:[URL:CGImage]=Dictionary(uniqueKeysWithValues:DonationOption.options.compactMap { option in
        option.makeQRCode().map { (option.codeURL,$0) }
    })
    init(selection:DonationOption=DonationOption.options[1]) {
        _selection=State(initialValue:selection)
    }
    var body:some View {
        VStack(spacing:12) {
            Text(L("请作者喝杯咖啡","Buy the developer a coffee")).font(.headline)
                .frame(maxWidth:.infinity,alignment:.leading)
            HStack(spacing:5) {
                ForEach(DonationOption.options) { option in
                    Button { selection=option } label: {
                        Text(option.label).font(.system(size:12,weight:.medium)).monospacedDigit()
                            .fixedSize().frame(maxWidth:.infinity,minHeight:28).padding(.horizontal,5)
                    }.buttonStyle(.plain)
                        .background(selection == option ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:8))
                        .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(selection == option ? Color.accentColor : .clear,lineWidth:1))
                        .accessibilityAddTraits(selection == option ? [.isSelected] : [])
                }
            }
            if let image=Self.codes[selection.codeURL] {
                Image(image,scale:1,label:Text(L("支付宝收款码，","Alipay payment QR code, ")+selection.label))
                    .interpolation(.none).resizable().scaledToFit()
                    .frame(width:222,height:222).background(.white)
            } else {
                ContentUnavailableView(L("收款码暂不可用","Payment code unavailable"),systemImage:"qrcode")
                    .frame(height:222)
            }
            VStack(spacing:4) {
                Text(selection.label).font(.system(size:16,weight:.semibold)).monospacedDigit()
                Text(L("请使用支付宝扫一扫","Scan with the Alipay app"))
                    .font(.callout).foregroundStyle(.secondary)
                if selection.amount == nil {
                    Text(L("扫码后输入想支持的金额","Enter your preferred amount after scanning"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(16).frame(width:300)
    }
}

// Shared by the main panel and the connection card, with one caption baseline.
struct BatteryCell:View {
    let title:String, symbol:String
    var sideLabel:String?=nil
    let reading:BatteryReading?
    let placement:UInt8?
    let t500:Bool
    var compact=false
    private var placementText:String? { placement.flatMap { wearLabel($0,t500:t500) } }
    private var caption:String { sideLabel == nil ? title : placementText ?? "—" }
    var body:some View {
        VStack(spacing:compact ? 5 : 6) {
            ZStack {
                Circle().stroke(.quaternary,lineWidth:compact ? 2.5 : 3)
                if let reading { Circle().trim(from:0,to:CGFloat(reading.percent)/100).stroke(reading.charging ? Color.green : .accentColor,style:StrokeStyle(lineWidth:compact ? 2.5 : 3,lineCap:.round)).rotationEffect(.degrees(-90)) }
                VStack(spacing:2) {
                    Image(systemName:symbol).font(.system(size:compact ? 14 : 18))
                        .frame(height:compact ? 16 : 20)
                    if let sideLabel {
                        Text(sideLabel).font(.system(size:compact ? 9 : 10,weight:.medium))
                            .foregroundStyle(.secondary)
                    }
                }.foregroundStyle(reading == nil ? .secondary : .primary)
            }.frame(width:compact ? 44 : 54,height:compact ? 44 : 54)
            HStack(spacing:3) {
                if reading?.charging == true { Image(systemName:"bolt.fill").font(.system(size:9)).foregroundStyle(.green) }
                Text(reading.map { "\($0.percent)%" } ?? "—").font(.system(size:compact ? 12 : 13,weight:.semibold)).monospacedDigit()
            }.frame(height:compact ? 18 : 20)
            Text(caption).font(.system(size:10)).foregroundStyle(.secondary)
                .lineLimit(1).frame(height:14)
        }.frame(maxWidth:.infinity)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(title)
            .accessibilityValue((reading.map { "\($0.percent)%" } ?? L("电量未知","Battery unknown"))
                + (reading?.charging == true ? L("，充电中",", charging") : "")
                + (placementText.map { "，"+$0 } ?? ""))
    }
}
private func wearLabel(_ value:UInt8,t500:Bool) -> String? {
    if t500 { return value == 0 ? L("已入盒","In case") : value == 3 ? L("使用中","In use") : nil }
    switch value { case 1,5:return L("未佩戴","Not worn"); case 3,7:return L("已佩戴","Worn"); case 4:return L("已入盒","In case"); default:return nil }
}
private struct BassSlider:View {
    @Bindable var app:AppModel
    let state:BassState
    @ViewState<Double> private var value=0
    var body:some View {
        Slider(value:$value,in:Double(state.minimum)...max(Double(state.minimum)+1,Double(state.maximum)),step:1) { editing in
            if !editing { let requested=UInt8(value); app.perform { try await $0.setBass(requested) } }
        }.onAppear { value=Double(state.current) }.onChange(of:state.current) { _,v in value=Double(v) }
            .disabled(!app.canWrite(Command.setBass,reading:Command.bass) || state.minimum == state.maximum)
    }
}
private struct EQEditor:View {
    @Bindable var app:AppModel
    let entry:CustomEQEntry
    let dismiss:() -> Void
    @ViewState<String> private var name:String
    @ViewState<[Double]> private var gains:[Double]
    init(app:AppModel,entry:CustomEQEntry,dismiss:@escaping () -> Void) {
        self.app=app; self.entry=entry; self.dismiss=dismiss
        _name=State(initialValue:entry.name); _gains=State(initialValue:entry.gains.map(Double.init))
    }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text(L("自定义均衡器","Custom equalizer")).font(.headline)
            VStack(alignment:.leading,spacing:6) {
                SettingsLabel(title:L("预设名称","Preset name"),helpText:L("名称仅支持中文、英文字母和数字。","Use Chinese characters, letters and numbers for names."))
                TextField(L("预设名称","Preset name"),text:$name).labelsHidden()
            }
            ScrollView {
                VStack(spacing:10) {
                    ForEach(entry.frequencies.indices,id:\.self) { i in
                        HStack(spacing:8) {
                            Text("\(entry.frequencies[i]) Hz").font(.caption).frame(width:58,alignment:.leading)
                            Slider(value:$gains[i],in:Double(entry.minimum)...max(Double(entry.minimum)+1,Double(entry.maximum)),step:1)
                                .disabled(entry.minimum == entry.maximum || app.operationBusy)
                            Text(String(format:"%+.0f",gains[i])).font(.caption.monospacedDigit()).frame(width:26)
                        }
                    }
                }
            }.frame(maxHeight:320)
            if let error=app.error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true) }
            HStack {
                Button(L("取消","Cancel"),action:dismiss); Spacer()
                if app.operationBusy { ProgressView().controlSize(.small) }
                Button(L("保存到耳机","Save to earbuds")) {
                    var saved=entry; saved.name=name; saved.gains=gains.map { Int8($0.rounded()) }
                    app.perform { session in let result=try await session.saveEQ(saved); dismiss(); return result }
                }.buttonStyle(.glassProminent).disabled(!FeatureCodec.validEQName(name) || app.operationBusy)
            }
        }.padding(20).frame(width:350)
    }
}
func noiseLabel(_ mode:NoiseMode) -> String {
    switch mode {
    case .off:return L("关闭","Off"); case .transparency:return L("通透","Transparency"); case .anc:return L("降噪","ANC")
    case .smart:return L("智能","Smart"); case .deep:return L("深度","High"); case .medium:return L("中度","Medium")
    case .light:return L("轻度","Low"); case .adaptive:return L("自适应","Adaptive")
    }
}
func noiseSymbol(_ mode:NoiseMode) -> String { [.off:"circle.dashed",.anc:"waveform",.transparency:"ear",.adaptive:"sparkles"][mode] ?? "waveform" }
func spatialLabel(_ mode:UInt8) -> String { mode == 0 ? L("关闭","Off") : mode == 1 ? L("固定空间音频","Fixed spatial audio") : L("头部追踪","Head tracking") }
func featureLabel(_ key:String) -> String {
    switch key {
    case "voice":return L("人声增强","Voice enhancement")
    case "hearingProtection":return L("听力保护","Hearing protection")
    case "hearing":return L("听力增强","Hearing enhancement")
    case "longBattery":return L("长续航模式","Long battery mode")
    case "posture":return L("颈椎健康提醒","Posture reminders")
    case "spatialSound":return L("空间音效","Spatial sound")
    default:return key
    }
}
func gestureLabel(_ value:UInt8) -> String { [1:L("单击","Single press"),2:L("双击","Double press"),3:L("三击","Triple press"),4:L("长按","Hold"),5:L("滑动","Swipe")][Int(value)] ?? L("手势 ","Gesture ")+String(value) }
func actionLabel(_ value:UInt8) -> String { [0:L("无","None"),1:L("播放／暂停","Play / pause"),3:L("语音助手","Voice assistant"),5:L("上一首","Previous track"),6:L("下一首","Next track"),7:L("音量","Volume"),10:L("切换歌曲","Skip track"),17:L("游戏模式","Game mode")][Int(value)] ?? L("操作 ","Action ")+String(value) }
