import Foundation
import os.log
import SwiftScanner

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
    private var responseData = Data()
    private var fullResponseLength = 0
    private var isResponseCompleted = false
    private var selfAddressStr: String!
//    private let responseParser = HTTPParser(type: .Response)

    /**
     Begin reading and processing data from the socket.
     */
    override public func openSocket() {
        super.openSocket()
        
        guard !isCancelled else {
            return
        }

        logStartTime = Date()
        selfAddressStr = String(describing: Unmanaged.passUnretained(self).toOpaque())

//        responseParser.onMessageComplete { parser in
//            self.parseResponseData()
//            return 0
//        }
//
//        responseParser.onBody { parser, ptr, len in
//            print("\(String(cString: ptr))")
//            return 0
//        }

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
                    logRequestUserAgent = String(headerField.suffix(headerField.count - "User-Agent:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            os_log(">>>>>>>>>>>>>\t%{public}@\t[START]\t%{public}@", selfAddressStr, logRequestLine!)
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

    override public func write(data: Data) {
        super.write(data: data)

        fullResponseLength += data.count

        // save only first chunk of response data that contains status line and headers
        // as response data takes a lot of memory and very slow to append
        if self.responseData.count == 0 {
            self.responseData = data
        }
    }

    override public func didDisconnectWith(socket: RawTCPSocketProtocol) {
        super.didDisconnectWith(socket: socket)
        if !isResponseCompleted {
            self.parseResponseData(forceComplete: true)
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

    private let messageDelimiter = "\r\n"
    private let messageDelimiterLen = 2 // define constants as Swift treats \r\n as one character and return messageDelimiter.count as 1

    private func parseResponseData(forceComplete: Bool = false) {
        guard let responseStr = String(data:self.responseData, encoding: .ascii) else {
            return
        }

        let scanner = StringScanner(responseStr)
        var statusLineSaved = "-"
        var headerFields = [String: String]()

        do {
            if let statusLine = try scanner.scan(upTo: messageDelimiter) {
                statusLineSaved = statusLine
                try scanner.skip(length: messageDelimiterLen) // skip \r\n after status line

                // Detecting message length according to RFC2616 Section 4.4 Message Length
                if scanner.match(messageDelimiter) { // terminated response
                    if  scanner.remainder == messageDelimiter { // terminated response
                        logResponse(responseStatusCode: parseStatusLine(statusLine), headers: headerFields, bodyLength: 0)
                    } else {
                        // Body w/o headers. It is possible for CONNECT requests.
                        // We will have to read it until the connection is closed as no other way to detect the end of request body
                    }
                } else { // read headers
                    if let headers = try scanner.scan(upTo: messageDelimiter + messageDelimiter) {
                        try scanner.skip(length: 2 * messageDelimiterLen) // skip \r\n\r\n after headers to go to body
                        headerFields = parseHeaderFields(headers.components(separatedBy: messageDelimiter))

                        if scanner.isAtEnd {
                            // no body
                            logResponse(responseStatusCode: parseStatusLine(statusLine), headers: headerFields, bodyLength: 0)
                        } else {
                            if let transferEncoding = headerFields["TRANSFER-ENCODING"], transferEncoding != "identity" {
                                // chunked specified
                                if scanner.remainder.hasSuffix(messageDelimiter + messageDelimiter) {
                                    // final chunk received
                                    let bodyLength = fullResponseLength - scanner.position.encodedOffset
                                    logResponse(responseStatusCode: parseStatusLine(statusLine), headers: headerFields, bodyLength: bodyLength)
                                } else {
                                    os_log(">>>>>>>>>>>>>\t%{public}@\t[CHUNK]\n%{public}@", selfAddressStr, responseStr)
                                }
                            } else if let contentLengthStr = headerFields["CONTENT-LENGTH"] {
                                let contentLength = Int(contentLengthStr)
                                let bodyLength = fullResponseLength - scanner.position.encodedOffset

                                if contentLength == nil || contentLength != bodyLength {
                                    os_log(">>>>>>>>>>>>>\t%{public}@\t[WARN] Content-length %{public}@ seems incorrect for body, maybe it's chunked data:\n%{public}@", selfAddressStr, contentLengthStr, scanner.remainder)
                                } else {
                                    logResponse(responseStatusCode: parseStatusLine(statusLine), headers: headerFields, bodyLength: bodyLength)
                                }
                            } else {
                                // chunked unspecified
                                if scanner.remainder.hasSuffix(messageDelimiter + messageDelimiter) {
                                    // final chunk received
                                    let body = scanner.remainder.data(using: .ascii)!
                                    logResponse(responseStatusCode: parseStatusLine(statusLine), headers: headerFields, bodyLength: body.count)
                                } else {
                                    os_log(">>>>>>>>>>>>>\t%{public}@\t[CHUNK]\n%{public}@", selfAddressStr, responseStr)
                                }
                            }
                        }
                    }
                }

                if forceComplete && !isResponseCompleted {
                    logResponse(responseStatusCode: parseStatusLine(statusLine), headers: headerFields, bodyLength: scanner.remainder.count)
                }

            }

        } catch let error as StringScannerError {
            os_log(">>>>>>>>>>>>>\t%{public}@\t[ERR] Parser error: %{public}@", selfAddressStr, error.localizedDescription)
            if error == .eof {
                logResponse(responseStatusCode: parseStatusLine(statusLineSaved), headers: headerFields, bodyLength: 0)
            }
        } catch let error {
            os_log(">>>>>>>>>>>>>\t%{public}@\t[ERR] Parser error: %{public}@", selfAddressStr, error.localizedDescription)
        }
    }

    private func parseStatusLine(_ statusLine: String) -> Int {
        var responseStatusCode = -1
        let statusLineComponents = statusLine.components(separatedBy: " ")

        if statusLine.count > 0, statusLineComponents.count >= 3, let statusCode = Int(statusLineComponents[1]) {
            responseStatusCode = statusCode
        }

        return responseStatusCode
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

    private func logResponse(responseStatusCode: Int, headers: [String: String], bodyLength: Int) {
        isResponseCompleted = true

        let now = Date()
        let timestamp = now.description
        let requestLine = self.logRequestLine == nil ? "-" : self.logRequestLine!
        let requestUserAgent = self.logRequestUserAgent == nil ? "-" : self.logRequestUserAgent!
        let contentType = headers["CONTENT-TYPE"] == nil ? "-" : headers["CONTENT-TYPE"]!
        let referer = headers["REFERER"] == nil ? "-" : headers["REFERER"]!
        let xdsid = headers["X-DSID"] == nil ? "-" : headers["X-DSID"]!
        let xappleclientapp = headers["X-APPLE-CLIENT-APPLICATION"] == nil ? "-" : headers["X-APPLE-CLIENT-APPLICATION"]!
        let duration = Int(now.timeIntervalSince(self.logStartTime == nil ? now : self.logStartTime!))

        os_log(">>>>>>>>>>>>>\t%{public}@\t[END]\t%{public}@\t%{public}@\t%{public}lu\t%{public}lu\t%{public}@\t%{public}@\t%{public}@\t%{public}@\t%{public}@\t%{public}lu\t%{public}lu",
               selfAddressStr,
               timestamp,
               requestLine,
               responseStatusCode,
               bodyLength,
               requestUserAgent,
               xdsid,
               xappleclientapp,
               referer,
               contentType,
               fullResponseLength,
               duration)
        writeToProxyLog("\(timestamp)\t\(requestLine)\t\(responseStatusCode)\t\(bodyLength)\t\(requestUserAgent)\t\(xdsid)\t\(xappleclientapp)\t\(referer)\t\(contentType)\t\(fullResponseLength)\t\(duration)\n")
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
