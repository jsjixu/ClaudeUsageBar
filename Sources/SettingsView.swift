import SwiftUI

struct SettingsView: View {
    @State private var cdpHost: String = UserDefaults.standard.string(forKey: "cdp_host") ?? ""
    @State private var cdpPortString: String = {
        let p = UserDefaults.standard.integer(forKey: "cdp_port")
        return p > 0 ? "\(p)" : ""
    }()
    @State private var saved = false
    let onSave: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.accentColor)
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }

            Divider()

            Text("Chrome CDP Connection")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Host")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("127.0.0.1", text: $cdpHost)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Port")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("9222", text: $cdpPortString)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 72)
                }
            }

            Text("Leave blank for defaults (127.0.0.1:9222).\nFor remote access, enter the host running Chrome CDP\n(e.g. Surge Ponte address or LAN IP).")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                if saved {
                    Label("Saved!", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                        .transition(.opacity)
                }
                Button("Save & Reconnect") {
                    let hostVal = cdpHost.trimmingCharacters(in: .whitespacesAndNewlines)
                    let portVal = Int(cdpPortString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

                    UserDefaults.standard.set(hostVal, forKey: "cdp_host")
                    UserDefaults.standard.set(portVal, forKey: "cdp_port")

                    withAnimation { saved = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { saved = false }
                    }
                    onSave()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
