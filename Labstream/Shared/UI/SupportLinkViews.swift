import SwiftUI
#if os(tvOS)
import CoreImage
import CoreImage.CIFilterBuiltins
#endif

/// Privacy Policy, Support, and support-email rows for Settings ▸ About.
///
/// Apple TV has no browser or mail client, so there each row is a focusable button that opens a
/// sheet with a QR code and the address to read; the other platforms use ordinary links.
struct SupportLinkRows: View {
    #if os(tvOS)
    @State private var presented: PresentedLink?
    #endif

    var body: some View {
        #if os(tvOS)
        Group {
            linkButton(.privacy)
            linkButton(.support)
            LabeledContent("Email", value: LabstreamLinks.supportEmailAddress)
        }
        .sheet(item: $presented) { link in
            LinkQRCodeSheet(link: link)
        }
        #else
        Link(destination: LabstreamLinks.privacyPolicy) {
            Label("Privacy Policy", systemImage: "hand.raised")
        }
        Link(destination: LabstreamLinks.support) {
            Label("Support", systemImage: "questionmark.circle")
        }
        Link(destination: LabstreamLinks.supportEmail) {
            Label("Email \(LabstreamLinks.supportEmailAddress)", systemImage: "envelope")
        }
        #endif
    }

    #if os(tvOS)
    private func linkButton(_ link: PresentedLink) -> some View {
        Button {
            presented = link
        } label: {
            LabeledContent(link.title, value: LabstreamLinks.displayString(link.url))
        }
    }
    #endif
}

/// A one-line Privacy Policy · Support footer for the sign-in screen, which is shown before
/// Settings is reachable. Apple TV shows the privacy address as text instead of a link.
struct SignInSupportFooter: View {
    var body: some View {
        #if os(tvOS)
        Text("Privacy policy: \(LabstreamLinks.displayString(LabstreamLinks.privacyPolicy))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        #else
        HStack(spacing: DS.Space.sm) {
            Link("Privacy Policy", destination: LabstreamLinks.privacyPolicy)
            Text("·")
                .accessibilityHidden(true)
            Link("Support", destination: LabstreamLinks.support)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        #endif
    }
}

#if os(tvOS)
private enum PresentedLink: String, Identifiable {
    case privacy
    case support

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: "Privacy Policy"
        case .support: "Support"
        }
    }

    var url: URL {
        switch self {
        case .privacy: LabstreamLinks.privacyPolicy
        case .support: LabstreamLinks.support
        }
    }
}

private struct LinkQRCodeSheet: View {
    let link: PresentedLink

    var body: some View {
        VStack(spacing: 40) {
            Text(link.title)
                .font(.title2.bold())
            if let image = QRCodeRenderer.image(for: link.url.absoluteString) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 420, height: 420)
                    .padding(24)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .accessibilityLabel("QR code for \(link.title)")
            }
            Text(LabstreamLinks.displayString(link.url))
                .font(.headline)
            Text("Scan the code with your iPhone or iPad, or open the address on another device.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(60)
    }
}

enum QRCodeRenderer {
    /// A crisp black-on-white QR code for `text`, or nil if Core Image cannot produce one.
    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
#endif
