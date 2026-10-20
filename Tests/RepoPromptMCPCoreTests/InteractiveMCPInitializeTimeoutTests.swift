import Darwin
import Foundation
import MCP
import os
@testable import RepoPromptMCPCore
import XCTest

final class InteractiveMCPInitializeTimeoutTests: XCTestCase {
    func testInitializationTimeoutDisconnectsAdoptedSocketAndUnblocksConnect() async throws {
        let pair = try makeSocketPair()
        defer { Darwin.close(pair[1]) }
        let transport = try BootstrapSocketMCPTransport(connectedFD: pair[0])
        try await transport.connect()
        let client = Client(name: "rpce-cli-timeout-test", version: "1.0")
        let timeoutDisconnected = OSAllocatedUnfairLock(initialState: false)
        let started = Date()

        do {
            _ = try await InteractiveMCPClientSession.debugAwaitInitialization(
                timeoutNanoseconds: 50_000_000,
                timeoutSleep: { try await Task.sleep(nanoseconds: $0) },
                onTimeout: {
                    timeoutDisconnected.withLock { $0 = true }
                    await transport.disconnect()
                }
            ) {
                try await client.connect(transport: transport)
            }
            XCTFail("Initialize must not succeed when the peer never answers")
        } catch let error as InteractiveSessionError {
            guard case .bootstrapResponseTimeout = error else {
                return XCTFail("Expected bootstrapResponseTimeout, got \(error)")
            }
        }

        XCTAssertTrue(timeoutDisconnected.withLock { $0 })
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "Timeout must not wait on a cancelled connect that still owns the FD")
        try waitForPeerShutdown(pair[1])
        await transport.disconnect()
    }

    func testInitializationSuccessDoesNotInvokeTimeoutTeardown() async throws {
        let timeoutTeardowns = OSAllocatedUnfairLock(initialState: 0)
        let result = try await InteractiveMCPClientSession.debugAwaitInitialization(
            timeoutNanoseconds: 1_000_000_000,
            timeoutSleep: { try await Task.sleep(nanoseconds: $0) },
            onTimeout: { timeoutTeardowns.withLock { $0 += 1 } }
        ) {
            Initialize.Result(
                protocolVersion: Version.latest,
                capabilities: .init(),
                serverInfo: .init(name: "RepoPrompt", version: "test")
            )
        }
        XCTAssertEqual(result.serverInfo.name, "RepoPrompt")
        XCTAssertEqual(timeoutTeardowns.withLock { $0 }, 0)
    }

    private func makeSocketPair() throws -> [Int32] {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return descriptors
    }

    private func waitForPeerShutdown(_ descriptor: Int32) throws {
        let deadline = Date().addingTimeInterval(5)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var descriptorPoll = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(deadline.timeIntervalSinceNow * 1000)
            guard poll(&descriptorPoll, 1, max(1, remaining)) > 0 else { continue }
            let bytesRead = Darwin.read(descriptor, &buffer, buffer.count)
            if bytesRead == 0 { return }
            if bytesRead < 0, errno == EAGAIN || errno == EINTR { continue }
            guard bytesRead > 0 else {
                XCTFail("Peer read failed after initialize timeout: errno \(errno)")
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
        XCTFail("Transport did not shut down after initialize timeout")
        throw POSIXError(.ETIMEDOUT)
    }
}
