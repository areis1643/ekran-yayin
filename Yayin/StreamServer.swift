import Foundation
import Network
import os

private let log = Logger(subsystem: "tr.niladsp.ekran", category: "stream")

/// TCP 8889: H.264 kareleri ve PCM sesi bağlı tüm istemcilere yayınlar.
final class StreamServer {
    private final class Client {
        let connection: NWConnection
        var pending = 0

        init(_ connection: NWConnection) {
            self.connection = connection
        }
    }

    private let port: UInt16
    private let queue = DispatchQueue(label: "ekran.stream")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    var onNewClient: (() -> Void)?

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        queue.sync {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port),
                  let newListener = try? NWListener(using: parameters, on: nwPort) else {
                log.error("stream dinleyicisi kurulamadi")
                return
            }
            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            newListener.stateUpdateHandler = { state in
                log.notice("stream dinleyici: \(String(describing: state), privacy: .public)")
            }
            newListener.start(queue: queue)
            listener = newListener
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for client in clients.values {
                client.connection.stateUpdateHandler = nil
                client.connection.cancel()
            }
            clients.removeAll()
        }
    }

    /// Paket başlığını ekleyip tüm istemcilere yollar.
    func send(type: UInt8, payload: Data) {
        queue.async { [weak self] in
            self?.sendLocked(type: type, payload: payload)
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        clients[ObjectIdentifier(client)] = client

        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .failed, .cancelled:
                self.queue.async { self.remove(client) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveLoop(client)
        onNewClient?()
    }

    private func receiveLoop(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak client] _, _, isComplete, error in
            guard let self, let client else { return }
            self.queue.async {
                if error != nil || isComplete {
                    self.remove(client)
                } else {
                    self.receiveLoop(client)
                }
            }
        }
    }

    private func remove(_ client: Client) {
        guard clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
        log.notice("stream istemci ayrildi; kalan \(self.clients.count)")
    }

    private func sendLocked(type: UInt8, payload: Data) {
        guard !clients.isEmpty else { return }

        let isVideo = type == 0x46 // 'F'
        let isAudio = type == 0x41 // 'A'
        let isKeyframe = isVideo && payload.first == 1

        var packet = Data(capacity: payload.count + 5)
        packet.append(type)
        let length = UInt32(payload.count)
        packet.append(UInt8((length >> 24) & 0xFF))
        packet.append(UInt8((length >> 16) & 0xFF))
        packet.append(UInt8((length >> 8) & 0xFF))
        packet.append(UInt8(length & 0xFF))
        packet.append(payload)

        for client in clients.values {
            if isVideo && !isKeyframe && client.pending > 8 { continue }
            if isAudio && client.pending > 30 { continue }

            client.pending += 1
            client.connection.send(content: packet, completion: .contentProcessed { [weak self, weak client] error in
                guard let self, let client else { return }
                self.queue.async {
                    client.pending = max(0, client.pending - 1)
                    if error != nil {
                        self.remove(client)
                    }
                }
            })
        }
    }
}
