import Foundation
import os.log

public class HTTPProxySocket: ProxySocket {
    enum HTTPProxyReadStatus: CustomStringConvertible {
        case invalid,
        readingFirstHeader,
        pendingFirstHeader,
        readingHeader,
        readingContent,
        stopped
        
        var description: String {
            switch self {
            case .invalid:
                return "invalid"
            case .readingFirstHeader:
                return "reading first header"
            case .pendingFirstHeader:
                return "waiting to send first header"
            case .readingHeader:
                return "reading header (forwarding)"
            case .readingContent:
                return "reading content (forwarding)"
            case .stopped:
                return "stopped"
            }
        }
    }
    
    enum HTTPProxyWriteStatus: CustomStringConvertible {
        case invalid,
        sendingConnectResponse,
        forwarding,
        stopped
        
        var description: String {
            switch self {
            case .invalid:
                return "invalid"
            case .sendingConnectResponse:
                return "sending response header for CONNECT"
            case .forwarding:
                return "waiting to begin forwarding data"
            case .stopped:
                return "stopped"
            }
        }
    }
    /// The remote host to connect to.
    public var destinationHost: String!
    
    /// The remote port to connect to.
    public var destinationPort: Int!
    
    private var currentHeader: HTTPHeader!
    
    private let scanner: HTTPStreamScanner = HTTPStreamScanner()
    
    private var readStatus: HTTPProxyReadStatus = .invalid
    private var writeStatus: HTTPProxyWriteStatus = .invalid
    
    public var isConnectCommand = false
    
    public var readStatusDescription: String {
        return readStatus.description
    }
    
    public var writeStatusDescription: String {
        return writeStatus.description
    }

    private var logRequestLine: String?
    private var logRequestUserAgent: String?
    private var logStartTime: Date?
    private var isHTTPMessage = false
    private var responseData: Data?

    /**
     Begin reading and processing data from the socket.
     */
    override public func openSocket() {
        super.openSocket()
        
        guard !isCancelled else {
            return
        }

        logStartTime = Date()
        readStatus = .readingFirstHeader
        socket.readDataTo(data: Utils.HTTPData.DoubleCRLF)
    }
    
    override public func readData() {
        guard !isCancelled else {
            return
        }
        
        // Return the first header we read when the socket was opened if the proxy command is not CONNECT.
        if readStatus == .pendingFirstHeader {
            delegate?.didRead(data: currentHeader.toData(), from: self)
            readStatus = .readingContent
            return
        }
        
        switch scanner.nextAction {
        case .readContent(let length):
            readStatus = .readingContent
            if length > 0 {
                socket.readDataTo(length: length)
            } else {
                socket.readData()
            }
        case .readHeader:
            readStatus = .readingHeader
            socket.readDataTo(data: Utils.HTTPData.DoubleCRLF)
        case .stop:
            readStatus = .stopped
            disconnect()
        }
        
    }
    
    // swiftlint:disable function_body_length
    // swiftlint:disable cyclomatic_complexity
    /**
     The socket did read some data.
     
     - parameter data:    The data read from the socket.
     - parameter from:    The socket where the data is read from.
     */
    override public func didRead(data: Data, from: RawTCPSocketProtocol) {
        super.didRead(data: data, from: from)
        
        let result: HTTPStreamScanner.Result
        do {
            result = try scanner.input(data)
        } catch let error {
            disconnect(becauseOf: error)
            return
        }
        
        switch (readStatus, result) {
        case (.readingFirstHeader, .header(let header)):
            currentHeader = header
            currentHeader.removeProxyHeader()
            currentHeader.rewriteToRelativePath()
            
            destinationHost = currentHeader.host
            destinationPort = currentHeader.port
            isConnectCommand = currentHeader.isConnect
            
            if !isConnectCommand {
                readStatus = .pendingFirstHeader
            } else {
                readStatus = .readingContent
            }

            let headerString = String(data: data, encoding: .utf8)!
            let headerComponents = headerString.components(separatedBy: "\r\n")
            logRequestLine = headerComponents.first
            for headerField in headerComponents {
                if headerField.hasPrefix("User-Agent:") {
                    logRequestUserAgent = String(headerField.suffix(headerField.count - "User-Agent:".count))
                }
            }

            session = ConnectSession(host: destinationHost!, port: destinationPort!)
            observer?.signal(.receivedRequest(session!, on: self))
            delegate?.didReceive(session: session!, from: self)
        case (.readingHeader, .header(let header)):
            currentHeader = header
            currentHeader.removeProxyHeader()
            currentHeader.rewriteToRelativePath()
            
            delegate?.didRead(data: currentHeader.toData(), from: self)
        case (.readingContent, .content(let content)):
            delegate?.didRead(data: content, from: self)
        default:
            return
        }
    }
    
    /**
     The socket did send some data.
     
     - parameter data:    The data which have been sent to remote (acknowledged). Note this may not be available since the data may be released to save memory.
     - parameter by:    The socket where the data is sent out.
     */
    override public func didWrite(data: Data?, by: RawTCPSocketProtocol) {
        super.didWrite(data: data, by: by)
        
        switch writeStatus {
        case .sendingConnectResponse:
            writeStatus = .forwarding
            observer?.signal(.readyForForward(self))
            delegate?.didBecomeReadyToForwardWith(socket: self)
        default:
            delegate?.didWrite(data: data, by: self)
        }
    }


    private let responseHeaderBodyDelimiter = "\r\n\r\n"
    private let headerFieldsDelimiter = "\r\n"

    override public func didDisconnectWith(socket: RawTCPSocketProtocol) {
        super.didDisconnectWith(socket: socket)

        guard let data = self.responseData, let responseStr = String(data:data, encoding: .ascii) else {
            return
        }

        let responseComponents = responseStr.components(separatedBy: responseHeaderBodyDelimiter)

        let responseHeaderComponents = responseComponents.first!.components(separatedBy: headerFieldsDelimiter)
        guard responseHeaderComponents.count >= 1 else {
            return
        }

        let body = responseComponents.count <= 1 ? "" : responseComponents[1...responseComponents.count - 1].joined(separator:responseHeaderBodyDelimiter)

        let statusLine = responseHeaderComponents.first!

        let statusLineComponents = responseStr.components(separatedBy: " ")
        if statusLine.count > 0, statusLineComponents.count >= 3, Int(statusLineComponents[1]) != nil {
            let responseStatusCode = statusLineComponents[1]

            var headerFields = [String: String]()
            if responseHeaderComponents.count > 1 {
                headerFields = parseHeaderFields(Array(responseHeaderComponents[1...responseHeaderComponents.count - 1]))
            }

            let now = Date()
            let timestamp = now.description
            let requestLine = self.logRequestLine == nil ? "-" : self.logRequestLine!
            let requestUserAgent = self.logRequestUserAgent == nil ? "-" : self.logRequestUserAgent!
            let contentType = headerFields["CONTENT-TYPE"] == nil ? "-" : headerFields["CONTENT-TYPE"]!
            let referer = headerFields["REFERER"] == nil ? "-" : headerFields["REFERER"]!
            let xdsid = headerFields["X-DSID"] == nil ? "-" : headerFields["X-DSID"]!
            let xappleclientapp = headerFields["X-APPLE-CLIENT-APPLICATION"] == nil ? "-" : headerFields["X-APPLE-CLIENT-APPLICATION"]!
            let duration = Int(now.timeIntervalSince(self.logStartTime == nil ? now : self.logStartTime!))
            let bodyLength = body.count

            os_log(">>>>>>>>>>>>>\t%{public}@\t%{public}@\t%{public}@\t%{public}lu\t%{public}@\t%{public}@\t%{public}@\t%{public}@\t%{public}@\t%{public}@\t%{public}@",
                   timestamp,
                   requestLine,
                   responseStatusCode,
                   bodyLength,
                   requestUserAgent,
                   xdsid,
                   xappleclientapp,
                   referer,
                   contentType,
                   String(data.count),
                   String(duration))
            writeToProxyLog("\(timestamp)\t\(requestLine)\t\(responseStatusCode)\t\(bodyLength)\t\(requestUserAgent)\t\(xdsid)\t\(xappleclientapp)\t\(referer)\t\(contentType)\t\(data.count)\t\(duration)")
        }
    }

    override public func write(data: Data) {
        super.write(data: data)

        if isHTTPMessage {
            responseData?.append(data)
        } else {
            guard let _ = String(data:data, encoding: .ascii) else {
                return
            }

            isHTTPMessage = true
            responseData = data
        }
    }
    
    /**
     Response to the `AdapterSocket` on the other side of the `Tunnel` which has succefully connected to the remote server.
     
     - parameter adapter: The `AdapterSocket`.
     */
    public override func respondTo(adapter: AdapterSocket) {
        super.respondTo(adapter: adapter)
        
        guard !isCancelled else {
            return
        }
        
        if isConnectCommand {
            writeStatus = .sendingConnectResponse
            write(data: Utils.HTTPData.ConnectSuccessResponse)
        } else {
            writeStatus = .forwarding
            observer?.signal(.readyForForward(self))
            delegate?.didBecomeReadyToForwardWith(socket: self)
        }
    }

    private func parseHeaderFields(_ headers: [String])->[String: String] {
        var headerFields = [String: String]()
        for header in headers {
            let fields = header.components(separatedBy: ";")

            for field in fields {
                var fieldComponents = field.components(separatedBy: ":")

                if fieldComponents.count >= 2 {
                    let name = fieldComponents.first!.uppercased().trimmingCharacters(in: .whitespaces)
                    let value = fieldComponents[1].trimmingCharacters(in: .whitespaces)
                    headerFields[name] = value
                }
            }
        }

        return headerFields
    }

    private func writeToProxyLog(_ log: String) {
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.nielsen.emm.SimpleTunnel") else {
            os_log("Can't get group container")
            return
        }

        let fileURL = groupURL.appendingPathComponent("emm_vpn_proxy.log")

        do {
            let fileHandle = try FileHandle(forWritingTo: fileURL)
            fileHandle.seekToEndOfFile()
            fileHandle.write(log.data(using: .utf8)!)
        } catch {
            do {
                try log.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch let err {
                os_log("Failed to create emm_vpn_proxy.log: %@", err.localizedDescription)
            }
        }
    }
}
