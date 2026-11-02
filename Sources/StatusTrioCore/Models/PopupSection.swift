// Modified by the Status Trio Fan fork (adds the FanCtl fan section); see NOTICE.
import Foundation

enum PopupSection: String, CaseIterable, Identifiable, Sendable {
    case battery
    case network
    case vpn
    case bluetooth
    case volume
    case brightness
    case audioInput
    case inputSource
    case fan

    var id: Self { self }

    var titleKey: LocalizationKey {
        switch self {
        case .battery: .settingsPopupOrderBattery
        case .network: .settingsPopupOrderNetwork
        case .vpn: .vpnTitle
        case .bluetooth: .bluetoothTitle
        case .volume: .settingsPopupOrderVolume
        case .brightness: .settingsPopupOrderBrightness
        case .audioInput: .settingsPopupOrderAudioInput
        case .inputSource: .settingsPopupOrderInputSource
        case .fan: .settingsPopupOrderFan
        }
    }

    var systemImage: String {
        switch self {
        case .battery: SymbolFallback.name("battery.100percent", "battery.100")
        case .network: "wifi"
        case .vpn: "lock.shield"
        case .bluetooth: "antenna.radiowaves.left.and.right"
        case .volume: "speaker.wave.2"
        case .brightness: SymbolFallback.name("sun.max", "sun.max")
        case .audioInput: "mic"
        case .inputSource: "keyboard"
        case .fan: SymbolFallback.name("fan", "wind")
        }
    }
}
