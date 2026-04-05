import SwiftUI

/// Permission approval dialog — glass theme, navy text, three-option buttons.
struct ApprovalView: View {
    let request: PermissionManager.ApprovalRequest
    let onDecision: (ApprovalDecision) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.navy)

            Text("Permission")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.navy)

            Text(request.description)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.navy)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

            VStack(spacing: 6) {
                Button(action: { onDecision(.allowOnce) }) {
                    Text("Allow Once")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.navy, in: Capsule())
                }
                .buttonStyle(.plain)

                Button(action: { onDecision(.allowAlways) }) {
                    Text("Always Allow")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.navy)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)

                Button(action: { onDecision(.deny) }) {
                    Text("Deny")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.navy.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(width: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
