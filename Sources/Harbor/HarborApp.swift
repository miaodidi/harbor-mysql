import SwiftUI
import HarborCore

@main struct HarborApp: App {
    @NSApplicationDelegateAdaptor(HarborDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Harbor — MySQL 客户端", id: "main") {
            MainView().environmentObject(model)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear {
                    delegate.model = model
                    #if DEBUG
                    SmokeCheck.runIfRequested(model)
                    #endif
                }
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建连接…") { model.openConnectionSheet() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("新建查询") { model.newQuery() }.keyboardShortcut("n")
                Button("导出当前 SQL…") { model.exportSQL() }.keyboardShortcut("s").disabled(model.active == nil)
            }
            CommandMenu("数据库") {
                Button("执行查询") { model.runQuery() }.keyboardShortcut(.return, modifiers: .command).disabled(!model.canOperate || model.active?.table != nil)
                Button("刷新") { model.refresh() }.keyboardShortcut("r").disabled(!model.canOperate)
                Button("取消并断开") { model.cancel() }.disabled(!model.busy)
            }
        }
    }
}

@MainActor final class HarborDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        let session = model.session
        // AppKit's termination loop can suspend main-actor tasks. Close NIO off
        // that actor and deliver the reply through AppKit's run loop.
        Task.detached {
            await session.shutdown()
            RunLoop.main.perform(inModes: [.common]) {
                sender.reply(toApplicationShouldTerminate: true)
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return .terminateLater
    }
}
