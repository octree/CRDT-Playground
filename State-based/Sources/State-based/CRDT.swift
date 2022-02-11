import Foundation

public struct GCounter<ReplicaID: Hashable> {
    public private(set) var counter: [ReplicaID: Int]
    public var value: Int { counter.reduce(0) { $0 + $1.value } }

    public mutating func increase(_ replicaID: ReplicaID) {
        counter[replicaID, default: 0] += 1
    }

    public func increased(_ replicaID: ReplicaID) -> GCounter<ReplicaID> {
        var counter = self.counter
        counter[replicaID, default: 0] += 1
        return .init(counter: counter)
    }

    public func merging(with another: GCounter<ReplicaID>) -> GCounter<ReplicaID> {
        .init(counter: counter.merging(another.counter, uniquingKeysWith: max))
    }
}

public extension GCounter {
    init() { counter = [:] }
}

public struct PNCounter<ReplicaID: Hashable> {
    public private(set) var increments: GCounter<ReplicaID>
    public private(set) var decrements: GCounter<ReplicaID>

    public var value: Int { increments.value - decrements.value }

    public mutating func increase(_ replicaID: ReplicaID) {
        increments.increase(replicaID)
    }

    public mutating func decrease(_ replicaID: ReplicaID) {
        decrements.increase(replicaID)
    }

    public func merging(with another: PNCounter<ReplicaID>) -> PNCounter<ReplicaID> {
        .init(increments: increments.merging(with: another.increments),
              decrements: decrements.merging(with: another.decrements))
    }
}

public extension PNCounter {
    init() {
        increments = .init()
        decrements = .init()
    }
}

public struct VClock<ReplicaID: Hashable> {
    public enum Order {
        case lessThan
        case equal
        case greaterThan
        case concurrent
    }

    public private(set) var time: GCounter<ReplicaID>

    public mutating func increase(_ replicaID: ReplicaID) {
        time.increase(replicaID)
    }

    public func increased(_ replicaID: ReplicaID) -> VClock<ReplicaID> {
        .init(time: time.increased(replicaID))
    }

    public func merging(with another: VClock<ReplicaID>) -> VClock<ReplicaID> {
        .init(time: time.merging(with: another.time))
    }

    public func compare(_ another: VClock<ReplicaID>) -> Order {
        let allKeys = Set(time.counter.keys).union(Set(another.time.counter.keys))
        return allKeys.reduce(.equal) { prev, key in
            let valA = time.counter[key] ?? 0
            let valB = another.time.counter[key] ?? 0
            if prev == .equal, valA > valB {
                return .greaterThan
            } else if prev == .equal, valA < valB {
                return .lessThan
            } else if prev == .lessThan, valA > valB {
                return .concurrent
            } else if prev == .greaterThan, valA < valB {
                return .concurrent
            } else {
                return prev
            }
        }
    }
}

public extension VClock {
    init() { time = .init() }
}

public struct LWWRegister<Value> {
    public private(set) var value: Value
    public private(set) var time: Int

    public init(value: Value) {
        self.value = value
        time = Int(Date().timeIntervalSince1970 * 1000)
    }

    public mutating func set(_ register: LWWRegister<Value>) {
        if register.time > time {
            time = register.time
            value = register.value
        }
    }

    public func merging(with another: LWWRegister<Value>) -> LWWRegister<Value> {
        time > another.time ? self : another
    }
}

public struct GSet<Element: Hashable> {
    public private(set) var value: Set<Element>

    public mutating func insert(_ element: Element) {
        value.insert(element)
    }

    public mutating func insert(contentsOf gset: GSet<Element>) {
        value.formUnion(gset.value)
    }

    public func merging(with another: GSet<Element>) -> GSet<Element> {
        .init(value: value.union(another.value))
    }
}

public extension GSet {
    init() { value = .init() }
}

public struct PSet<Element: Hashable> {
    public private(set) var additions: GSet<Element>
    public private(set) var removals: GSet<Element>

    public var value: Set<Element> { additions.value.subtracting(removals.value) }

    public mutating func insert(_ element: Element) {
        additions.insert(element)
    }

    public mutating func insert(contentsOf gset: GSet<Element>) {
        additions.insert(contentsOf: gset)
    }

    public mutating func remove(_ element: Element) {
        removals.insert(element)
    }

    public mutating func remove(contentsOf gset: GSet<Element>) {
        removals.insert(contentsOf: gset)
    }

    public func merging(with another: PSet<Element>) -> PSet<Element> {
        .init(additions: additions.merging(with: another.additions),
              removals: removals.merging(with: another.removals))
    }
}

public extension PSet {
    init() {
        additions = .init()
        removals = .init()
    }
}

extension Date {
    var vtime: Int { Int(timeIntervalSince1970 * 1000) }
}

/// Add Win Observed Set
public struct ORSet<Element: Hashable, ReplicaID: Hashable> {
    public private(set) var additions: [Element: VClock<ReplicaID>]
    public private(set) var removals: [Element: VClock<ReplicaID>]

    public var value: Set<Element> {
        additions.reduce(into: Set()) { result, v in
            guard let clockr = removals[v.key] else {
                result.insert(v.key)
                return
            }
            if v.value.compare(clockr) != .lessThan {
                result.insert(v.key)
            }
        }
    }

    public mutating func inset(_ element: Element, replicaID: ReplicaID) {
        let clock = additions[element] ?? removals[element] ?? .init()
        additions[element] = clock.increased(replicaID)
        removals[element] = nil
    }

    public mutating func remove(_ element: Element, replicaID: ReplicaID) {
        let clock = additions[element] ?? removals[element] ?? .init()
        additions[element] = nil
        removals[element] = clock.increased(replicaID)
    }

    private func merge(_ x: [Element: VClock<ReplicaID>], _ y: [Element: VClock<ReplicaID>]) -> [Element: VClock<ReplicaID>] {
        let allKeys = Set(x.keys).union(Set(y.keys))
        var result: [Element: VClock<ReplicaID>] = [:]
        for key in allKeys {
            let clockX = x[key]
            let clockY = y[key]
            if case let (.some(clockX), .some(clockY)) = (clockX, clockY) {
                result[key] = clockX.merging(with: clockY)
            } else {
                result[key] = clockX ?? clockY!
            }
        }
        return result
    }

    public func merging(with another: ORSet<Element, ReplicaID>) -> ORSet<Element, ReplicaID> {
        let allAdd = merge(additions, another.additions)
        let allRem = merge(removals, another.removals)
        var add: [Element: VClock<ReplicaID>] = allAdd
        var rem: [Element: VClock<ReplicaID>] = [:]
        for (element, clockRem) in allRem {
            if let clockAdd = add[element],
               clockAdd.compare(clockRem) == .lessThan
            {
                add[element] = nil
                rem[element] = clockRem
            }
        }
        return .init(additions: add, removals: rem)
    }
}

public extension ORSet {
    init() {
        additions = [:]
        removals = [:]
    }
}
