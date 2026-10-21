import Foundation
import TrackDownloaderChromeCompanion

let response: NativeMessageResponse
if let payload = try? NativeMessageFrame.readPayload(from: .standardInput) {
    response = NativeMessageHost().handle(payload)
} else {
    response = NativeMessageResponse(
        version: ChromeCompanionRequest.protocolVersion,
        requestID: nil,
        status: .rejected
    )
}

if let encodedResponse = try? JSONEncoder().encode(response),
   let framedResponse = try? NativeMessageFrame.encode(encodedResponse) {
    FileHandle.standardOutput.write(framedResponse)
}
