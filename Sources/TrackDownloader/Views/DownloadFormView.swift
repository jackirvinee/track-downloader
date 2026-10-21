import SwiftUI

struct DownloadFormView: View {
    @Binding var link: String
    @FocusState.Binding var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Paste YouTube or SoundCloud link", text: $link)
                .textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityLabel("Track link").accessibilityHint("Paste a supported link to check its source before downloading.")
            Text("Checking a valid YouTube or SoundCloud link contacts that platform. No media downloads until you choose Download.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
