import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket

final class WebSocketServer {
    private var group: EventLoopGroup?
    private var channel: Channel?

    /// Every open page, not just the newest. Tracking one channel meant a second
    /// tab silently displaced the first, and commands went to a tab whose mic was
    /// never granted — the page looked connected while dictation returned
    /// "not-allowed" from the wrong tab.
    private var wsChannels: [ObjectIdentifier: Channel] = [:]

    /// Tabs that reported a denied microphone. Kept so their failures do not
    /// surface as errors while another tab is recording fine.
    private var deniedChannels: Set<ObjectIdentifier> = []

    let port: Int

    var onTranscript: ((TranscriptEvent) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?

    var isConnected: Bool { !wsChannels.isEmpty }

    init(port: Int = 9876) {
        self.port = port
    }

    func start() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let htmlData = loadHTML()

        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, head in
                guard head.uri == "/ws" else {
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { [weak self] channel, _ in
                guard let self else { return channel.eventLoop.makeSucceededVoidFuture() }
                let id = ObjectIdentifier(channel)
                let handler = WebSocketHandler(
                    onEvent: { [weak self] ev in
                        self?.route(ev, from: id)
                    },
                    onClose: { [weak self] in
                        guard let self else { return }
                        self.wsChannels.removeValue(forKey: id)
                        self.deniedChannels.remove(id)
                        let connected = self.isConnected
                        DispatchQueue.main.async { self.onConnectionChanged?(connected) }
                    }
                )
                self.wsChannels[id] = channel
                Log.write("ws: tab connected (\(self.wsChannels.count) open)")
                DispatchQueue.main.async { self.onConnectionChanged?(true) }
                return channel.pipeline.addHandler(handler)
            }
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let httpHandler = HTTPHandler(htmlData: htmlData)
                let config: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { ctx in
                        ctx.pipeline.removeHandler(httpHandler, promise: nil)
                    }
                )
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: config
                ).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }

        channel = try bootstrap.bind(host: "127.0.0.1", port: port).wait()
        print("ChromeSTT server running on http://127.0.0.1:\(port)")
    }

    func stop() {
        channel?.close(promise: nil)
        try? group?.syncShutdownGracefully()
    }

    func sendStart(lang: String) {
        deniedChannels.removeAll()
        broadcast(#"{"cmd":"start","lang":"\#(lang)"}"#)
    }

    func sendStop() {
        broadcast(#"{"cmd":"stop"}"#)
    }

    /// Commands go to every open page. Only the one whose microphone is granted
    /// will actually record; the rest report back that they were denied.
    private func broadcast(_ text: String) {
        for ch in wsChannels.values where ch.isActive {
            ch.eventLoop.execute {
                var buffer = ch.allocator.buffer(capacity: text.utf8.count)
                buffer.writeString(text)
                let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
                ch.writeAndFlush(frame, promise: nil)
            }
        }
    }

    /// Suppresses noise from tabs that cannot record, so one stale tab does not
    /// abort a session another tab is handling fine.
    private func route(_ event: TranscriptEvent, from id: ObjectIdentifier) {
        if event.kind == .error, event.text == "not-allowed" {
            deniedChannels.insert(id)
            Log.write("ws: tab denied mic (\(deniedChannels.count)/\(wsChannels.count) denied)")
            // Only surface the failure once no tab is left that could record.
            guard deniedChannels.count >= wsChannels.count else { return }
        }
        if deniedChannels.contains(id), event.kind != .error {
            return
        }
        DispatchQueue.main.async { self.onTranscript?(event) }
    }

    private func loadHTML() -> Data {
        Data(EmbeddedHTML.sttHTML.utf8)
    }
}

struct TranscriptEvent {
    enum Kind { case partial, final, ended, error }
    let kind: Kind
    let text: String
}

// MARK: - HTTP Handler

private final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let htmlData: Data

    init(htmlData: Data) { self.htmlData = htmlData }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        guard case .head(let head) = part else { return }

        if head.uri == "/" || head.uri == "/index.html" {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/html; charset=utf-8")
            headers.add(name: "Content-Length", value: "\(htmlData.count)")
            let respHead = HTTPResponseHead(version: head.version, status: .ok, headers: headers)
            context.write(wrapOutboundOut(.head(respHead)), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: htmlData.count)
            buffer.writeBytes(htmlData)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        } else {
            let respHead = HTTPResponseHead(version: head.version, status: .notFound)
            context.write(wrapOutboundOut(.head(respHead)), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

// MARK: - WebSocket Handler

private final class WebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    let onEvent: (TranscriptEvent) -> Void
    let onClose: () -> Void

    init(onEvent: @escaping (TranscriptEvent) -> Void, onClose: @escaping () -> Void) {
        self.onEvent = onEvent
        self.onClose = onClose
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .text:
            var data = frame.unmaskedData
            guard let text = data.readString(length: data.readableBytes),
                  let jsonData = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let type = json["type"] as? String else { return }

            let transcript = json["text"] as? String ?? ""

            switch type {
            case "partial": onEvent(TranscriptEvent(kind: .partial, text: transcript))
            case "final":   onEvent(TranscriptEvent(kind: .final, text: transcript))
            case "ended":   onEvent(TranscriptEvent(kind: .ended, text: ""))
            case "error":   onEvent(TranscriptEvent(kind: .error, text: json["error"] as? String ?? "unknown"))
            default: break
            }

        case .connectionClose:
            let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: context.channel.allocator.buffer(capacity: 0))
            context.writeAndFlush(wrapOutboundOut(closeFrame)).whenComplete { _ in
                context.close(promise: nil)
            }

        case .ping:
            let pongFrame = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pongFrame), promise: nil)

        default: break
        }
    }
}
