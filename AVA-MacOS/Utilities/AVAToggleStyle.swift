import SwiftUI

/// iOS-style pill toggle — guaranteed light blue when on, gray when off.
/// Matches the AVA iOS app's toggle exactly.
struct AVAToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            toggleSwitch(isOn: configuration.isOn)
                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { configuration.isOn.toggle() } }
        }
    }

    private func toggleSwitch(isOn: Bool) -> some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.avaBrightBlue : Color.navy.opacity(0.15))
                .frame(width: 42, height: 26)

            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .frame(width: 22, height: 22)
                .padding(2)
        }
    }
}

extension ToggleStyle where Self == AVAToggleStyle {
    static var ava: AVAToggleStyle { AVAToggleStyle() }
}
