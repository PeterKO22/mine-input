import Foundation

/// 一键熔断开关（FR4 / §8.2）——全局标志，开启时一切采集立即停：
/// 日志保留、不新增。状态持久在 store 的 meta 表（key=breaker），跨进程生效；
/// 采集 API 在写入前检查（InteractionStore.insert 亦兜底拒绝）。
public final class CircuitBreaker {
    private let store: InteractionStore
    private let lock = NSLock()
    private var cached: Bool

    public init(store: InteractionStore) {
        self.store = store
        self.cached = store.isBreakerTripped
    }

    /// 熔断状态：true = 采集已停。
    public var isTripped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// 一键熔断：立即生效（后续一切入库被拒）。
    public func trip() {
        lock.lock()
        cached = true
        lock.unlock()
        store.metaSet("breaker", "1")
    }

    /// 解除熔断（显式操作才恢复采集）。
    public func reset() {
        lock.lock()
        cached = false
        lock.unlock()
        store.metaSet("breaker", "0")
    }

    /// 从持久层重新读取（多进程场景同步用）。
    public func refresh() {
        let v = store.isBreakerTripped
        lock.lock()
        cached = v
        lock.unlock()
    }
}
