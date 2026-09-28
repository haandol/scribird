import Darwin
import Foundation
import Network

/// 사용자만 접근할 수 있는 Unix 소켓. TCP 포트나 브라우저 제어를 사용하지 않는다.
@MainActor
final class LocalControlServer {
    static var directory: URL { URL(filePath: "/tmp/scribird-control-\(getuid())", directoryHint: .isDirectory) }
    private(set) var socketPath: String?
    private var listener: NWListener?
    private var connections: [UUID: LocalControlConnection] = [:]
    private let handle: @MainActor (ControlRequest) async -> ControlResponse
    private let reportError: @MainActor (String) -> Void

    init(
        handle: @escaping @MainActor (ControlRequest) async -> ControlResponse,
        reportError: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.handle = handle
        self.reportError = reportError
    }

    func start(in directory: URL = LocalControlServer.directory) throws {
        guard listener == nil else { return }
        let path = directory.path
        if mkdir(path, 0o700) != 0, errno != EEXIST { throw POSIXError(.EACCES) }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw ControlError("MCP 소켓 폴더는 현재 사용자만 접근할 수 있어야 합니다.",
                               "The MCP socket directory must be owned by this user with permissions 0700.")
        }
        let socket = directory.appending(path: "\(getpid())-\(UUID().uuidString.prefix(8)).sock").path
        guard socket.utf8.count < 104 else { throw POSIXError(.ENAMETOOLONG) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socket)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed(let error) = state {
                    self?.reportError(error.localizedDescription)
                    self?.stop()
                }
            }
        }
        self.socketPath = socket
        self.listener = listener
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let current = Array(connections.values)
        connections.removeAll()
        current.forEach { $0.close() }
        if let socketPath { unlink(socketPath) }
        socketPath = nil
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID()
        let client = LocalControlConnection(connection: connection, handle: handle) { [weak self] in
            self?.connections.removeValue(forKey: id)
        }
        connections[id] = client
        client.start()
    }
}

@MainActor
private final class LocalControlConnection {
    private let connection: NWConnection
    private let handle: @MainActor (ControlRequest) async -> ControlResponse
    private let onClose: @MainActor () -> Void
    private var buffer = Data()
    private var deadline: Task<Void, Never>?
    private var closed = false

    init(connection: NWConnection,
         handle: @escaping @MainActor (ControlRequest) async -> ControlResponse,
         onClose: @escaping @MainActor () -> Void) {
        self.connection = connection
        self.handle = handle
        self.onClose = onClose
    }

    func start() {
        connection.start(queue: .main)
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.close()
        }
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        deadline?.cancel()
        connection.cancel()
        onClose()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let data { self.buffer.append(data) }
                guard self.buffer.count <= 65_536 else {
                    self.send(.failure(tr("요청이 너무 큽니다.", "Request exceeds 64 KiB.")))
                    return
                }
                if let newline = self.buffer.firstIndex(of: 0x0A) {
                    self.deadline?.cancel()
                    do {
                        let request = try JSONDecoder().decode(ControlRequest.self, from: self.buffer[..<newline])
                        self.send(await self.handle(request))
                    } catch { self.send(.failure(error.localizedDescription)) }
                } else if complete || error != nil { self.close() }
                else { self.receive() }
            }
        }
    }

    private func send(_ response: ControlResponse) {
        guard !closed else { return }
        let fallback = ControlResponse.failure(tr("제어 응답을 직렬화하지 못했습니다.", "Could not encode the control response."))
        guard var data = (try? JSONEncoder().encode(response)) ?? (try? JSONEncoder().encode(fallback)) else {
            close(); return
        }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close() }
        })
    }
}
