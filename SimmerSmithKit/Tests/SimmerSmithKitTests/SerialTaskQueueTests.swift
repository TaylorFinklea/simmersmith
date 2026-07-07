import Testing
import Foundation
@testable import SimmerSmithKit

// simmersmith-0gf — SerialTaskQueue: strict FIFO, no interleaving, visibility across ops,
// and continuation after an op that returns early.

@MainActor
@Test("enqueue runs operations in strict FIFO order")
func serialTaskQueueFIFOOrder() async {
    let queue = SerialTaskQueue()
    var order: [Int] = []

    let task1 = queue.enqueue {
        try? await Task.sleep(nanoseconds: 10_000_000)
        order.append(1)
    }
    let task2 = queue.enqueue {
        order.append(2)
    }
    let task3 = queue.enqueue {
        order.append(3)
    }

    await task1.value
    await task2.value
    await task3.value

    #expect(order == [1, 2, 3])
}

@MainActor
@Test("a suspended op blocks the next op from starting until it finishes")
func serialTaskQueueNoInterleaving() async {
    let queue = SerialTaskQueue()
    var op1Finished = false
    var op2StartedAfterOp1Finished = false

    let task1 = queue.enqueue {
        try? await Task.sleep(nanoseconds: 50_000_000)
        op1Finished = true
    }
    let task2 = queue.enqueue {
        op2StartedAfterOp1Finished = op1Finished
    }

    await task1.value
    await task2.value

    #expect(op1Finished)
    #expect(op2StartedAfterOp1Finished)
}

@MainActor
@Test("a later-enqueued op observes state written by an earlier in-flight op")
func serialTaskQueueVisibilityAcrossOps() async {
    let queue = SerialTaskQueue()
    var sharedState = 0
    var observedByOp2: Int?

    let task1 = queue.enqueue {
        try? await Task.sleep(nanoseconds: 20_000_000)
        sharedState = 42
    }
    // Enqueued while op1 is still mid-flight.
    let task2 = queue.enqueue {
        observedByOp2 = sharedState
    }

    await task1.value
    await task2.value

    #expect(observedByOp2 == 42)
}

@MainActor
@Test("the chain continues after an op that returns early")
func serialTaskQueueContinuesAfterEarlyReturn() async {
    let queue = SerialTaskQueue()
    var order: [Int] = []

    let task1 = queue.enqueue {
        order.append(1)
        return // early return
    }
    let task2 = queue.enqueue {
        order.append(2)
    }

    await task1.value
    await task2.value

    #expect(order == [1, 2])
}
