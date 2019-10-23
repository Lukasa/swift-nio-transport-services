//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
// swift-tools-version:4.0
//
// swift-tools-version:4.0
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(Network)
import NIO
import Dispatch
import Network


extension CircularBuffer where Element == PendingWrite {
    internal mutating func consumeMarkedElementsAsDispatchData() -> (DispatchData, EventLoopPromise<Void>?) {
        var dispatchData = DispatchData.empty
        var promise: EventLoopPromise<Void>?

        for element in self {
            dispatchData.append(DispatchData(element.data))
            promise.cascade(to: element.promise)
        }

        self.removeAll(keepingCapacity: true)

        return (dispatchData, promise)
    }
}


extension DispatchData {
    internal init(_ buffer: ByteBuffer) {
        // Hey folks, don't try this at home: this is only safe because I know exactly
        // how ByteBuffers work. This is one of the few cases where escaping a pointer from a Swift
        // closure is acceptable.
        self = buffer.withUnsafeReadableBytesWithStorageManagement { (pointer, manager) in
            _ = manager.retain()
            return DispatchData(bytesNoCopy: pointer, deallocator: .custom(nil, { manager.release() }))
        }
    }
}


extension Optional where Wrapped == EventLoopPromise<Void> {
    mutating func cascade(to promise: EventLoopPromise<Void>?) {
        guard let newPromise = promise else {
            return
        }

        if let current = self {
            current.futureResult.cascade(to: newPromise)
        } else {
            self = newPromise
        }
    }
}

#endif
