import AppKit
import Network

/// 监听两类"网络连接可能已经失效"的系统事件：
///   1. 系统从睡眠中唤醒（NSWorkspace.didWakeNotification）
///   2. 网络从断开恢复 / 切换了物理网络（Wi-Fi <-> 有线、换了一个 Wi-Fi 等）
///
/// 睡眠期间 vless-ws-client 进程只是被挂起，进程还"活着"，但它跟服务器之间的
/// WebSocket/TCP 连接早就被服务器或路由器清掉了；醒来后进程不会知道，界面上
/// 仍然显示"运行中"，实际却连不上，必须手动重连——这就是要解决的问题。
final class SleepWakeMonitor {
    /// 系统刚刚唤醒（此时网络通常还没恢复，调用方应自己等网络）
    var onWake: (() -> Void)?
    /// 网络从不可用恢复到可用，或者物理网络接口发生了变化
    var onNetworkChanged: (() -> Void)?

    /// 最近一次观察到的网络是否可用（主线程读写）
    private(set) var isNetworkSatisfied = true

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "VlessMenuBar.pathMonitor")
    private var lastStatus: NWPath.Status?
    private var lastInterfaces: Set<String> = []
    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.onWake?()
            }
        )

        pathMonitor.pathUpdateHandler = { [weak self] path in
            // 只关心真实物理网卡；utun（tun 模式的虚拟网卡）、回环等归类为 .other，
            // 忽略掉，避免 tun 自己创建网卡时触发误重连。
            let interfaces = Set(
                path.availableInterfaces
                    .filter { $0.type != .other }
                    .map { $0.name }
            )
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                let previousStatus = self.lastStatus
                let previousInterfaces = self.lastInterfaces
                self.lastStatus = path.status
                self.lastInterfaces = interfaces
                self.isNetworkSatisfied = satisfied

                // 第一次回调只是记录初始状态，不触发
                guard previousStatus != nil, satisfied else { return }
                let recovered = previousStatus != .satisfied
                let interfaceChanged = interfaces != previousInterfaces
                if recovered || interfaceChanged {
                    self.onNetworkChanged?()
                }
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    deinit {
        pathMonitor.cancel()
        let nc = NSWorkspace.shared.notificationCenter
        observers.forEach { nc.removeObserver($0) }
    }
}
