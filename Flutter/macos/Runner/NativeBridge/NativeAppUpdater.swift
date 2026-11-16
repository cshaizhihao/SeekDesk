import AppKit
import Sparkle

@MainActor
final class NativeAppUpdater: NSObject, SPUUpdaterDelegate {
    private let driver: InstallDriver
    private var updater: SPUUpdater?
    private(set) var startupError: Error?

    init(bundle: Bundle = .main, beforeRelaunch: @escaping (@escaping (Bool) -> Void) -> Void) {
        driver = InstallDriver(hostBundle: bundle, delegate: nil)
        driver.beforeRelaunch = beforeRelaunch
        super.init()
        let engine = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
        do {
            try engine.start()
            updater = engine
        } catch {
            startupError = error
        }
    }

    var canCheck: Bool {
        updater?.canCheckForUpdates == true &&
            updater?.sessionInProgress == false &&
            !DeskProxyNetwork.shared.requiresProxy
    }

    func check(install: Bool = false) {
        guard canCheck else { return }
        driver.install = install
        updater?.checkForUpdates()
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if DeskProxyNetwork.shared.requiresProxy {
            throw NativeBridgeError(code: "update_proxy", message: "请先关闭 SeekDesk 专用代理，再重试应用内更新。")
        }
    }

    private final class InstallDriver: SPUStandardUserDriver {
        var install = false
        var beforeRelaunch: (@escaping (Bool) -> Void) -> Void = { $0(false) }

        override func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState,
                                      reply: @escaping (SPUUserUpdateChoice) -> Void) {
            if install, !item.isInformationOnlyUpdate {
                reply(.install)
            } else {
                super.showUpdateFound(with: item, state: state, reply: reply)
            }
        }

        override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
            guard install else {
                super.showReady(toInstallAndRelaunch: reply)
                return
            }
            beforeRelaunch { saved in
                reply(saved ? .install : .skip)
            }
        }
    }
}
