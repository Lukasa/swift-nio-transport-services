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
import Foundation
import NIO
import NIOFoundationCompat
import Dispatch
import Network


/// An object that conforms to this protocol represents the substate of a channel in the
/// active state. This can be used to provide more fine-grained tracking of states
/// within the active state of a channel. Example uses include for tracking TCP half-closure
/// state in a TCP stream channel.
internal protocol ActiveChannelSubstate {
    /// Create the substate in its default initial state.
    init()
}


/// A state machine enum that tracks the state of the connection channel.
internal enum ChannelState<ActiveSubstate: ActiveChannelSubstate> {
    case idle
    case registered
    case activating
    case active(ActiveSubstate)
    case inactive

    fileprivate mutating func register() throws {
        guard case .idle = self else {
            throw NIOTSErrors.InvalidChannelStateTransition()
        }
        self = .registered
    }

    fileprivate mutating func beginActivating() throws {
        switch self {
        case .registered:
            self = .activating
        case .idle, .activating, .active, .inactive:
            throw NIOTSErrors.InvalidChannelStateTransition()
        }
    }

    fileprivate mutating func becomeActive() throws {
        guard case .activating = self else {
            throw NIOTSErrors.InvalidChannelStateTransition()
        }
        self = .active(ActiveSubstate())
    }

    fileprivate mutating func becomeInactive() throws -> ChannelState {
        let oldState = self

        switch self {
        case .idle, .registered, .activating, .active:
            self = .inactive
        case .inactive:
            // In this state we're already closed.
            throw ChannelError.alreadyClosed
        }

        return oldState
    }
}


/// The kinds of activation that a channel may support.
internal enum ActivationType {
    case connect
    case bind
}


/// A protocol for `Channel` implementations with a simple Network.framework
/// state management layer.
///
/// This protocol provides default hooks for managing state appropriately for a
/// given channel. It also provides some default implementations of `Channel` methods
/// for simple behaviours.
internal protocol StateManagedChannel: Channel, ChannelCore {
    associatedtype ActiveSubstate: ActiveChannelSubstate

    var state: ChannelState<ActiveSubstate> { get set }

    var tsEventLoop: NIOTSEventLoop { get }

    var closePromise: EventLoopPromise<Void> { get }

    var supportedActivationType: ActivationType { get }

    func beginActivating0(to: NWEndpoint, promise: EventLoopPromise<Void>?) -> Void

    func becomeActive0(promise: EventLoopPromise<Void>?) -> Void

    func alreadyConfigured0(promise: EventLoopPromise<Void>?) -> Void

    func doClose0(error: Error) -> Void

    func doHalfClose0(error: Error, promise: EventLoopPromise<Void>?) -> Void

    func readIfNeeded0() -> Void
}

extension StateManagedChannel {
    public var eventLoop: EventLoop {
        return self.tsEventLoop
    }

    /// Whether this channel is currently active.
    public var isActive: Bool {
        switch self.state {
        case .active:
            return true
        case .idle, .registered, .activating, .inactive:
            return false
        }
    }

    /// Whether this channel is currently closed. This is not necessary for the public
    /// API, it's just a convenient helper.
    internal var closed: Bool {
        switch self.state {
        case .inactive:
            return true
        case .idle, .registered, .activating, .active:
            return false
        }
    }

    public func register0(promise: EventLoopPromise<Void>?) {
        // TODO: does this need to do anything more than this?
        do {
            try self.state.register()
            try self.tsEventLoop.register(self)
            self.pipeline.fireChannelRegistered()
            promise?.succeed(result: ())
        } catch {
            promise?.fail(error: error)
            self.close0(error: error, mode: .all, promise: nil)
        }
    }

    public func registerAlreadyConfigured0(promise: EventLoopPromise<Void>?) {
        do {
            try self.state.register()
            try self.tsEventLoop.register(self)
            self.pipeline.fireChannelRegistered()
            try self.state.beginActivating()
			promise?.succeed(result: ())
        } catch {
            promise?.fail(error: error)
            self.close0(error: error, mode: .all, promise: nil)
            return
        }

        // Ok, we are registered and ready to begin activating. Tell the channel: it must
        // call becomeActive0 directly.
        self.alreadyConfigured0(promise: promise)
    }

    public func connect0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.activateWithType(type: .connect, to: NWEndpoint(fromSocketAddress: address), promise: promise)
    }

    public func connect0(to endpoint: NWEndpoint, promise: EventLoopPromise<Void>?) {
        self.activateWithType(type: .connect, to: endpoint, promise: promise)
    }

    public func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.activateWithType(type: .bind, to: NWEndpoint(fromSocketAddress: address), promise: promise)
    }

    public func bind0(to endpoint: NWEndpoint, promise: EventLoopPromise<Void>?) {
        self.activateWithType(type: .bind, to: endpoint, promise: promise)
    }

    public func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        switch mode {
        case .all:
            let oldState: ChannelState<ActiveSubstate>
            do {
                oldState = try self.state.becomeInactive()
            } catch let thrownError {
                promise?.fail(error: thrownError)
                return
            }

            self.doClose0(error: error)

            if case .active = oldState {
                self.pipeline.fireChannelInactive()
            }

            // TODO: If we want slightly more complex state management, we can actually fire this only when the
            // state transitions into .cancelled. For the moment I didn't think it was necessary.
            self.tsEventLoop.deregister(self)
            self.pipeline.fireChannelUnregistered()

            // Next we fire the promise passed to this method.
            promise?.succeed(result: ())

            // Now we schedule our final cleanup. We need to keep the channel pipeline alive for at least one more event
            // loop tick, as more work might be using it.
            self.eventLoop.execute {
                self.removeHandlers(channel: self)
                self.closePromise.succeed(result: ())
            }

        case .input:
            promise?.fail(error: ChannelError.operationUnsupported)

        case .output:
            self.doHalfClose0(error: error, promise: promise)
        }
    }

    public func becomeActive0(promise: EventLoopPromise<Void>?) {
        // Here we crash if we cannot transition our state. That's because my understanding is that we
        // should not be able to hit this.
        do {
            try self.state.becomeActive()
        } catch {
            self.close0(error: error, mode: .all, promise: promise)
            return
        }

        if let promise = promise {
            promise.succeed(result: ())
        }
        self.pipeline.fireChannelActive()
        self.readIfNeeded0()
    }

    /// A helper to handle the fact that activation is mostly common across connect and bind, and that both are
    /// not supported by a single channel type.
    private func activateWithType(type: ActivationType, to endpoint: NWEndpoint, promise: EventLoopPromise<Void>?) {
        guard type == self.supportedActivationType else {
            promise?.fail(error: ChannelError.operationUnsupported)
            return
        }

        do {
            try self.state.beginActivating()
        } catch {
            promise?.fail(error: error)
            return
        }

        self.beginActivating0(to: endpoint, promise: promise)
    }
}
