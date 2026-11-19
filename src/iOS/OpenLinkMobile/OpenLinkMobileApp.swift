import SwiftUI

@main
struct OpenLinkMobileApp: App {
    @StateObject private var client = LinkClient()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .preferredColorScheme(.dark)
                .onAppear { client.startBrowsing() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var client: LinkClient

    var body: some View {
        TabView {
            DashboardView().tabItem { Label("Live", systemImage: "gauge.with.dots.needle.67percent") }
            LogsView().tabItem { Label("Logs", systemImage: "waveform.path.ecg") }
            TuneView().tabItem { Label("Tune", systemImage: "tablecells") }
            ConnectView().tabItem { Label("Mac", systemImage: "laptopcomputer") }
        }
        .tint(.orange)
        .overlay(alignment: .top) {
            if let n = client.notice {
                Text(n).font(.footnote).padding(10).background(.ultraThinMaterial, in: Capsule()).padding(.top, 6)
                    .onTapGesture { client.notice = nil }
                    .task { try? await Task.sleep(for: .seconds(3)); client.notice = nil }
            }
        }
    }
}

/// Shown on tabs that need a Mac connection.
struct NotConnectedView: View {
    @EnvironmentObject var client: LinkClient
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 48)).foregroundStyle(.orange)
            Text(client.connecting ? "Connecting…" : "Not connected to your Mac").font(.title3.bold())
            Text("Open OpenLink Tuner and make sure this iPhone is on the same Wi-Fi.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !client.macs.isEmpty {
                ForEach(client.macs) { m in
                    Button { client.connect(m) } label: { Label(m.id, systemImage: "desktopcomputer") }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView("Looking for Macs…").padding(.top, 6)
            }
        }
        .padding(30)
    }
}

struct ConnectView: View {
    @EnvironmentObject var client: LinkClient
    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Mac", value: client.connectedMac ?? "—")
                    LabeledContent("Tune", value: client.hello?.tuneName ?? "none open")
                    LabeledContent("ECU", value: client.hello?.ecu ?? "—")
                    LabeledContent("Live source", value: sourceText)
                    if let d = client.hello?.sourceDetail, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
                }
                Section("Macs on this network") {
                    if client.macs.isEmpty { Text("Searching…").foregroundStyle(.secondary) }
                    ForEach(client.macs) { m in
                        Button { client.connect(m) } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                Text(m.id)
                                Spacer()
                                if client.connectedMac == m.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            }
                        }
                    }
                }
                if client.connectedMac != nil {
                    Section { Button("Disconnect", role: .destructive) { client.disconnect() } }
                }
            }
            .navigationTitle("Mac")
        }
    }
    private var sourceText: String {
        switch client.hello?.source {
        case "usb": return "Link USB"
        case nil: return "—"
        default: return "Off"
        }
    }
}
