import Foundation
import Ontology
import OSLog
import Synchronization
@preconcurrency import XPC

enum ManagedHomeServer {
    private static let log = Logger.service("home-xpc")
    private static let peers = Mutex(0)
    @MainActor private static var connection: xpc_connection_t?

    @MainActor
    static func start() {
        guard let host = Bundle.main.object(forInfoDictionaryKey: ManagedHome.hostKey) as? String,
            let requirement = try? ManagedHome.peerRequirement(identifier: host)
        else {
            log.error("Cannot identify the signed host of the bundled HomeKit service.")
            exit(EXIT_FAILURE)
        }
        let listener = xpc_connection_create_mach_service(
            ManagedHome.machService(for: host),
            nil,
            UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
        )
        guard xpc_connection_set_peer_code_signing_requirement(listener, requirement) == 0 else {
            log.error("Cannot establish trust for the bundled HomeKit service.")
            exit(EXIT_FAILURE)
        }
        xpc_connection_set_event_handler(listener) { peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            guard xpc_connection_set_peer_code_signing_requirement(peer, requirement) == 0 else {
                xpc_connection_cancel(peer)
                return
            }
            peers.withLock { $0 += 1 }
            let session = ManagedHomeSession()
            xpc_connection_set_event_handler(peer) { message in
                if xpc_equal(message, XPC_ERROR_CONNECTION_INVALID) {
                    // launchd will start a fresh helper when iMCP next opens a connection.
                    let isIdle = peers.withLock { count in
                        count -= 1
                        return count == 0
                    }
                    if isIdle {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            peers.withLock { if $0 == 0 { exit(EXIT_SUCCESS) } }
                        }
                    }
                    return
                }
                guard xpc_get_type(message) == XPC_TYPE_DICTIONARY,
                    let reply = xpc_dictionary_create_reply(message)
                else { return }
                let name = xpc_dictionary_get_string(message, ManagedHome.toolKey).map { String(cString: $0) }
                let data = ManagedHome.data(in: message, key: ManagedHome.argumentsKey)
                Task {
                    do {
                        let value = try await session.call(name, arguments: data)
                        ManagedHome.setData(value, in: reply, key: ManagedHome.valueKey)
                    } catch {
                        xpc_dictionary_set_string(reply, ManagedHome.errorKey, homeErrorMessage(error))
                    }
                    xpc_connection_send_message(peer, reply)
                }
            }
            xpc_connection_resume(peer)
        }
        connection = listener
        xpc_connection_resume(listener)
    }
}

private actor ManagedHomeSession {
    private let backendTask = Task { @MainActor in HomeKitBackend() }

    func call(_ name: String?, arguments: Data?) async throws -> Data {
        let backend = await backendTask.value
        if name == ManagedHome.readyTool {
            try await backend.store.ensureLoaded()
            return Data("null".utf8)
        }
        guard let name, let arguments,
            let tool = HomeKitService(backend: backend).tools.first(where: { $0.name == name })
        else { throw HomeError("Unsupported Home tool.") }
        let input = try JSONDecoder().decode([String: Value].self, from: arguments)
        try HomeInput.validate(input, schema: tool.inputSchema)
        let value = try await tool.callAsFunction(input)
        let encoder = JSONEncoder()
        encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] = TimeZone.current
        return try encoder.encode(value)
    }
}
