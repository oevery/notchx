import SwiftUI
import AppKit

struct ConnectivityExpandedView: View {
    @ObservedObject private var bluetooth = BluetoothManager.shared
    @ObservedObject private var wifi = WiFiManager.shared

    @EnvironmentObject var appState: AppState
    @Environment(\.islandPresentationState) private var presentationState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            primaryStatus
            if (presentationState ?? appState.currentState) == .fullExpanded {
                HStack {
                    Button(L10n.text("Bluetooth Settings")) { PermissionsManager.shared.openBluetoothSettings(fromIsland: appState) }
                    Button(L10n.text("Wi-Fi Settings")) { openWiFiSettings() }
                }.controlSize(.small)
            }

            // Connected devices list (full expanded)
            if (presentationState ?? appState.currentState) == .fullExpanded && (!bluetooth.connectedDevices.isEmpty || wifi.isConnected) {
                Divider().background(.white.opacity(0.2))

                ForEach(bluetooth.connectedDevices) { device in
                    HStack(spacing: 8) {
                        Image(systemName: device.deviceType.iconName)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 20)

                        Text(device.name)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.8))

                        Spacer()
                        Text(device.batteryLevel.map { L10n.format("Battery %d%%", $0) } ?? L10n.text("Battery unavailable"))
                            .font(.caption).foregroundStyle(.secondary)

                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                    }
                }

                // WiFi info
                if wifi.isConnected {
                    let ssid = wifi.ssid ?? L10n.text("Wi-Fi network")
                    HStack(spacing: 8) {
                        Image(systemName: wifi.signalIconName)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 20)

                        Text(ssid)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.8))

                        Spacer()
                    }
                }
            }
        }
        .contextMenu {
            Button(L10n.text("Bluetooth Settings")) { PermissionsManager.shared.openBluetoothSettings(fromIsland: appState) }
            Button(L10n.text("Wi-Fi Settings")) { openWiFiSettings() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: (presentationState ?? appState.currentState) == .fullExpanded ? .topLeading : .center)
    }

    private func openWiFiSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") { appState.openExternalURL(url, for: .connectivity) }
    }

    @ViewBuilder
    private var primaryStatus: some View {
        if let device = bluetooth.lastConnectedDevice {
            statusRow(
                icon: device.deviceType.iconName,
                status: "Connected",
                statusColor: .green,
                title: device.name,
                detail: device.batteryLevel.map { L10n.format("Battery %d%%", $0) }
            )
        } else if let disconnectedName = bluetooth.lastDisconnectedDeviceName {
            statusRow(
                icon: "link.badge.plus",
                status: "Disconnected",
                statusColor: .red,
                title: disconnectedName,
                detail: L10n.text("Bluetooth device")
            )
        } else if wifi.isConnected {
            statusRow(
                icon: wifi.signalIconName,
                status: "Wi-Fi Connected",
                statusColor: .blue,
                title: wifi.ssid ?? L10n.text("Wi-Fi network"),
                detail: wifi.signalDescription
            )
        } else {
            statusRow(
                icon: "wifi.slash",
                status: "Offline",
                statusColor: .white.opacity(0.45),
                title: L10n.text("No active connection"),
                detail: bluetooth.connectedDevices.isEmpty ? L10n.text("Wi-Fi and Bluetooth are idle") : L10n.format("%d Bluetooth devices connected", bluetooth.connectedDevices.count)
            )
        }
    }

    private func statusRow(
        icon: String,
        status: String,
        statusColor: Color,
        title: String,
        detail: String?
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(.white)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(status))
                    .font(.system(size: 10))
                    .foregroundColor(statusColor)

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }

            Spacer()
        }
    }
}
