import SwiftUI

/// Radial menu opened by Pencil Pro squeeze (or pencil long-press): the six
/// most recent tools/actions arranged around the anchor point, right under
/// the hand. Tap outside dismisses.
struct RadialMenu: View {
    let anchor: CGPoint
    let actions: [RadialAction]
    let perform: (RadialAction) -> Void
    let dismiss: () -> Void

    private let radius: CGFloat = 86

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                let angle = Angle(degrees: -90 + Double(index) * 360 / Double(max(actions.count, 1)))
                Button {
                    perform(action)
                } label: {
                    Text(action.title)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .frame(width: 62, height: 62)
                        .background(.regularMaterial, in: Circle())
                        .shadow(radius: 4, y: 2)
                }
                .position(
                    x: anchor.x + cos(angle.radians) * radius,
                    y: anchor.y + sin(angle.radians) * radius
                )
            }

            Circle()
                .fill(.orange)
                .frame(width: 9, height: 9)
                .position(anchor)
        }
        .transition(.opacity)
    }
}
