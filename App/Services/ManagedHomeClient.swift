import Foundation
import OSLog
import ServiceManagement
@preconcurrency import XPC

actor ManagedHomeClient {
    private let log = Logger.service("home-xpc")
    private let identifier: String
    private let service: SMAppService
    private let machService: String
    private var connection: xpc_connection_t?
    private var generation = 0
    private var ready = false

    init?(identifier: String) {
        guard let host = Bundle.main.bundleIdentifier else { return nil }
        self.identifier = identifier
        service = .agent(plistName: ManagedHome.agentPlist(for: host))
        machService = ManagedHome.machService(for: host)
    }

    var isActivated: Bool { ready }

    func activate() async throws {
        guard !ready else { return }
        let started = generation
        _ = try await call(ManagedHome.readyTool, [:], readOnly: true)
        guard started == generation else { return }
        ready = true
    }

    func stop() {
        generation += 1
        disconnect()
        let status = service.status
        if status == .enabled || status == .requiresApproval {
            do { try service.unregister() } catch {
                log.error("Could not unregister the HomeKit helper: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func disconnect() {
        ready = false
        if let connection {
            xpc_connection_cancel(connection)
            self.connection = nil
        }
    }

    func call(_ tool: String, _ arguments: [String: Value], readOnly: Bool) async throws -> Value {
        let started = generation
        let current = try connect()
        do {
            return try await send(tool, arguments, over: current)
        } catch is ConnectionLost {
            if connection === current { disconnect() }
            guard readOnly else {
                throw HomeError(
                    "The HomeKit connection was lost. The write may have completed. Inspect the home before retrying."
                )
            }
            guard generation == started else { throw CancellationError() }
            try Task.checkCancellation()
            let replacement = try connect()
            do {
                return try await send(tool, arguments, over: replacement)
            } catch is ConnectionLost {
                if connection === replacement { disconnect() }
                throw ConnectionLost()
            }
        }
    }

    private func connect() throws -> xpc_connection_t {
        let preferences = UserDefaults.standard
        guard preferences.bool(forKey: HomeService.enabledKey), preferences.object(forKey: "isEnabled") as? Bool ?? true
        else { throw HomeError("Home is disabled in iMCP.") }
        if let connection { return connection }
        let requirement = try ManagedHome.peerRequirement(identifier: identifier)
        let approval = HomeError(
            "Allow iMCP's HomeKit service in System Settings → General → Login Items & Extensions, then try again."
        )
        if service.status == .requiresApproval { throw approval }
        if service.status != .enabled {
            do { try service.register() } catch {
                if service.status == .requiresApproval { throw approval }
                throw error
            }
        }
        if service.status == .requiresApproval { throw approval }
        let new = xpc_connection_create_mach_service(machService, nil, 0)
        guard xpc_connection_set_peer_code_signing_requirement(new, requirement) == 0 else {
            xpc_connection_cancel(new)
            throw HomeError("Could not establish trust for the bundled HomeKit service.")
        }
        xpc_connection_set_event_handler(new) { [weak self] event in
            if xpc_equal(event, XPC_ERROR_CONNECTION_INVALID) || xpc_equal(event, XPC_ERROR_CONNECTION_INTERRUPTED) {
                Task { await self?.connectionEnded(new) }
            }
        }
        xpc_connection_resume(new)
        connection = new
        return new
    }

    private func connectionEnded(_ ended: xpc_connection_t) {
        if connection === ended { disconnect() }
    }

    private struct ConnectionLost: LocalizedError {
        var errorDescription: String? { "The bundled HomeKit service stopped responding." }
    }

    private func send(_ tool: String, _ arguments: [String: Value], over connection: xpc_connection_t) async throws
        -> Value
    {
        let request = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(request, ManagedHome.toolKey, tool)
        ManagedHome.setData(try JSONEncoder().encode(arguments), in: request, key: ManagedHome.argumentsKey)
        return try await withCheckedThrowingContinuation { continuation in
            xpc_connection_send_message_with_reply(connection, request, nil) { reply in
                guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
                    continuation.resume(throwing: ConnectionLost())
                    return
                }
                if let error = xpc_dictionary_get_string(reply, ManagedHome.errorKey) {
                    continuation.resume(throwing: HomeError(String(cString: error)))
                } else {
                    do {
                        guard let data = ManagedHome.data(in: reply, key: ManagedHome.valueKey) else {
                            throw HomeError("The bundled HomeKit service gave an invalid response.")
                        }
                        continuation.resume(returning: try JSONDecoder().decode(Value.self, from: data))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
