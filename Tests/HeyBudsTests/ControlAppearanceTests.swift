import AppKit
import SwiftUI
import Testing
@testable import HeyBuds

private struct ControlsPreview:View {
    let reduceTransparency:Bool
    var body:some View {
        VStack(spacing:16) {
            PanelNavigationHeader(title:"降噪控制 · Noise control",onBack:{})
            CompatibleGlassContainer(spacing:8) {
                HStack(spacing:20) {
                    ForEach(0..<4) { index in
                        VStack(spacing:8) {
                            Image(systemName:["power","waveform","ear","sparkles"][index])
                                .foregroundStyle(index == 1 ? Color.white : Color.primary)
                                .frame(width:54,height:54)
                                .modifier(ListeningSurface(selected:index == 1,shape:Circle(),reduceTransparency:reduceTransparency))
                            Text(["关闭","降噪","通透","自适应"][index]).font(.system(size:11))
                        }
                    }
                }
            }
            HStack {
                Button("取消 · Cancel") {}.compatibleButtonStyle()
                Button("保存 · Save") {}.compatibleButtonStyle(prominent:true)
                Button("连接 · Connect") {}.compatibleButtonStyle(prominent:true).disabled(true)
            }
        }.padding(16)
    }
}

@Test(arguments:[false,true],[false,true]) @MainActor
func compatibleControlsKeepLayoutAndLegacyContentVisible(liquidGlass:Bool,dark:Bool) throws {
    for reduceTransparency in [false,true] {
        let content=ControlsPreview(reduceTransparency:reduceTransparency)
            .environment(\.heyBudsLiquidGlass,liquidGlass)
            .environment(\.colorScheme,dark ? .dark : .light)
            .background(Color(nsColor:dark ? .black : .white))
        _=NSApplication.shared
        let hosting=NSHostingView(rootView:content)
        let size=hosting.fittingSize
        #expect(size.width >= 320 && size.width < 400)
        #expect(size.height >= 150 && size.height < 300)
        // Liquid Glass uses native compositing and cannot be checked by an
        // offscreen bitmap. Check its layout here and its appearance in a window.
        if liquidGlass { continue }
        let renderer=ImageRenderer(content:content)
        renderer.scale=2
        let bitmap=NSBitmapImageRep(cgImage:try #require(renderer.cgImage))
        // A successful bitmap allocation alone can hide an empty native view.
        var headerInk=0
        for y in stride(from:0,to:min(bitmap.pixelsHigh,120),by:4) {
            for x in stride(from:0,to:bitmap.pixelsWide,by:4) {
                if let color=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) {
                    let brightness=(color.redComponent+color.greenComponent+color.blueComponent)/3
                    if dark ? brightness > 0.3 : brightness < 0.7 { headerInk += 1 }
                }
            }
        }
        #expect(headerInk > 20)
        if let output=ProcessInfo.processInfo.environment["HEYBUDS_QA_OUTPUT"] {
            let directory=URL(fileURLWithPath:output,isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let data=try #require(bitmap.representation(using:.png,properties:[:]))
            try data.write(to:directory.appendingPathComponent("controls-\(liquidGlass ? "glass" : "macos15")-\(dark ? "dark" : "light")-\(reduceTransparency ? "opaque" : "material").png"))
        }
    }
}

@Test(arguments:[false,true]) @MainActor
func macOS15SelectedNoiseModeKeepsAnOpaqueAccent(reduceTransparency:Bool) throws {
    let accent=Color(red:0.12,green:0.4,blue:0.92)
    let content=Color.clear.frame(width:54,height:54)
        .modifier(ListeningSurface(selected:true,shape:Circle(),reduceTransparency:reduceTransparency))
        .environment(\.heyBudsLiquidGlass,false)
        .accentColor(accent)
    let renderer=ImageRenderer(content:content)
    renderer.scale=1
    let bitmap=NSBitmapImageRep(cgImage:try #require(renderer.cgImage))
    let center=try #require(bitmap.colorAt(x:27,y:27)?.usingColorSpace(.deviceRGB))
    #expect(center.alphaComponent > 0.99)
    #expect(center.blueComponent > center.greenComponent + 0.2)
    #expect(center.greenComponent > center.redComponent + 0.1)
    #expect((bitmap.colorAt(x:0,y:0)?.alphaComponent ?? 1) < 0.01)
}
