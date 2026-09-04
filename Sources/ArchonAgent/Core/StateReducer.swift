import Foundation

/// Protocol defining a state reducer function that merges a partial update into the parent state.
public protocol StateReducer<State, Update>: Sendable {
    associatedtype State: AgentState
    associatedtype Update: Sendable

    /// Applies a partial update to the existing state in-place.
    func reduce(state: inout State, update: Update)
}

/// A closure-based reducer implementation for maximum flexibility.
public struct AnyReducer<State: AgentState, Update: Sendable>: StateReducer {
    private let reducerClosure: @Sendable (inout State, Update) -> Void

    public init(_ reduce: @escaping @Sendable (inout State, Update) -> Void) {
        self.reducerClosure = reduce
    }

    public func reduce(state: inout State, update: Update) {
        reducerClosure(&state, update)
    }
}

/// Standard Reducer: Appends items of type `Element` to a collection key path.
public struct AppendReducer<State: AgentState, Element: Sendable>: StateReducer, @unchecked Sendable {
    public typealias Update = [Element]
    private let keyPath: WritableKeyPath<State, [Element]>

    public init(keyPath: WritableKeyPath<State, [Element]>) {
        self.keyPath = keyPath
    }

    public func reduce(state: inout State, update: [Element]) {
        state[keyPath: keyPath].append(contentsOf: update)
    }
}

/// Standard Reducer: Overwrites the target field with the new value.
public struct OverwriteReducer<State: AgentState, Value: Sendable>: StateReducer, @unchecked Sendable {
    public typealias Update = Value
    private let keyPath: WritableKeyPath<State, Value>

    public init(keyPath: WritableKeyPath<State, Value>) {
        self.keyPath = keyPath
    }

    public func reduce(state: inout State, update: Value) {
        state[keyPath: keyPath] = update
    }
}

/// Standard Reducer: Merges a dictionary of key-values into an existing dictionary field.
public struct MergeDictionaryReducer<State: AgentState, Key: Hashable & Sendable, Value: Sendable>: StateReducer, @unchecked Sendable {
    public typealias Update = [Key: Value]
    private let keyPath: WritableKeyPath<State, [Key: Value]>

    public init(keyPath: WritableKeyPath<State, [Key: Value]>) {
        self.keyPath = keyPath
    }

    public func reduce(state: inout State, update: [Key: Value]) {
        state[keyPath: keyPath].merge(update) { _, new in new }
    }
}

/// Standard Reducer: Sums or increments a numeric value.
public struct NumericAddReducer<State: AgentState, Value: Numeric & Sendable>: StateReducer, @unchecked Sendable {
    public typealias Update = Value
    private let keyPath: WritableKeyPath<State, Value>

    public init(keyPath: WritableKeyPath<State, Value>) {
        self.keyPath = keyPath
    }

    public func reduce(state: inout State, update: Value) {
        state[keyPath: keyPath] += update
    }
}
