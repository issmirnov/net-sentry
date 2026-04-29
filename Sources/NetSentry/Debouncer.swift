import Foundation

public final class Debouncer<Value> {
    private let window: DispatchTimeInterval
    private let queue: DispatchQueue
    private let callback: (Value) -> Void
    private var pending: DispatchWorkItem?
    private let lock = NSLock()

    public init(window: DispatchTimeInterval, queue: DispatchQueue, callback: @escaping (Value) -> Void) {
        self.window = window
        self.queue = queue
        self.callback = callback
    }

    public func submit(_ value: Value) {
        lock.lock()
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.callback(value)
        }
        pending = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + window, execute: item)
    }

    public func cancel() {
        lock.lock()
        pending?.cancel()
        pending = nil
        lock.unlock()
    }
}
