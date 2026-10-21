import Foundation

public enum NativeMessageFrameError: Error, Equatable {
    case invalidFrame
    case oversized
}

public enum NativeMessageFrame {
    public static func readPayload(from fileHandle: FileHandle) throws -> Data {
        let header = try readExactly(4, from: fileHandle)
        let bytes = [UInt8](header)
        let length = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        guard length <= ChromeCompanionRequest.maximumMessageBytes else {
            throw NativeMessageFrameError.oversized
        }
        return try readExactly(length, from: fileHandle)
    }

    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= ChromeCompanionRequest.maximumMessageBytes else {
            throw NativeMessageFrameError.oversized
        }
        let length = UInt32(payload.count)
        return Data([
            UInt8(length & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 24) & 0xff)
        ]) + payload
    }

    public static func decode(_ frame: Data) throws -> Data {
        guard frame.count >= 4 else {
            throw NativeMessageFrameError.invalidFrame
        }
        let bytes = [UInt8](frame.prefix(4))
        let length = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        guard length <= ChromeCompanionRequest.maximumMessageBytes else {
            throw NativeMessageFrameError.oversized
        }
        guard frame.count == length + 4 else {
            throw NativeMessageFrameError.invalidFrame
        }
        return frame.dropFirst(4)
    }

    private static func readExactly(_ count: Int, from fileHandle: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            guard
                let chunk = try fileHandle.read(upToCount: count - data.count),
                !chunk.isEmpty
            else {
                throw NativeMessageFrameError.invalidFrame
            }
            data.append(chunk)
        }
        return data
    }
}

public enum NativeMessageResponseStatus: String, Codable, Equatable {
    case queued
    case duplicate
    case full
    case rejected
}

public struct NativeMessageResponse: Codable, Equatable {
    public let version: Int
    public let requestID: String?
    public let status: NativeMessageResponseStatus

    public init(version: Int, requestID: String?, status: NativeMessageResponseStatus) {
        self.version = version
        self.requestID = requestID
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case version
        case requestID = "requestId"
        case status
    }
}

public struct NativeMessageHost {
    private let queue: ChromeCompanionQueue

    public init(queue: ChromeCompanionQueue = ChromeCompanionQueue()) {
        self.queue = queue
    }

    public func handle(_ payload: Data, now: Date = .now) -> NativeMessageResponse {
        do {
            let request = try ChromeCompanionRequest.decode(payload, now: now)
            switch try queue.enqueue(request) {
            case .duplicate:
                return NativeMessageResponse(
                    version: ChromeCompanionRequest.protocolVersion,
                    requestID: request.requestID.uuidString,
                    status: .duplicate
                )
            case .queued:
                return NativeMessageResponse(
                    version: ChromeCompanionRequest.protocolVersion,
                    requestID: request.requestID.uuidString,
                    status: .queued
                )
            }
        } catch ChromeCompanionQueueError.capacityReached {
            return NativeMessageResponse(
                version: ChromeCompanionRequest.protocolVersion,
                requestID: nil,
                status: .full
            )
        } catch {
            return NativeMessageResponse(
                version: ChromeCompanionRequest.protocolVersion,
                requestID: nil,
                status: .rejected
            )
        }
    }
}
