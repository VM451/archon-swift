import Testing
import Foundation
@testable import ArchonAgent

struct ReducerState: AgentState {
    var items: [String] = []
    var totalScore: Double = 0.0
    var metadata: [String: String] = [:]
}

@Suite("State Reducer Tests")
struct StateReducerTests {

    @Test("AppendReducer appends list items correctly")
    func testAppendReducer() {
        let reducer = AppendReducer<ReducerState, String>(keyPath: \.items)
        var state = ReducerState(items: ["A"])
        reducer.reduce(state: &state, update: ["B", "C"])

        #expect(state.items == ["A", "B", "C"])
    }

    @Test("OverwriteReducer replaces field value")
    func testOverwriteReducer() {
        let reducer = OverwriteReducer<ReducerState, Double>(keyPath: \.totalScore)
        var state = ReducerState(totalScore: 10.0)
        reducer.reduce(state: &state, update: 99.5)

        #expect(state.totalScore == 99.5)
    }

    @Test("MergeDictionaryReducer merges keys")
    func testMergeDictionaryReducer() {
        let reducer = MergeDictionaryReducer<ReducerState, String, String>(keyPath: \.metadata)
        var state = ReducerState(metadata: ["env": "prod", "version": "1.0"])
        reducer.reduce(state: &state, update: ["version": "2.0", "region": "us-east"])

        #expect(state.metadata["env"] == "prod")
        #expect(state.metadata["version"] == "2.0")
        #expect(state.metadata["region"] == "us-east")
    }

    @Test("NumericAddReducer sums values correctly")
    func testNumericAddReducer() {
        let reducer = NumericAddReducer<ReducerState, Double>(keyPath: \.totalScore)
        var state = ReducerState(totalScore: 10.0)
        reducer.reduce(state: &state, update: 15.5)

        #expect(state.totalScore == 25.5)
    }
}
