import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            Tab("Live", systemImage: "gauge") {
                Text("Live View")
            }
            Tab("Runs", systemImage: "list.bullet") {
                Text("Runs List")
            }
        }
        .preferredColorScheme(.dark)
    }
}
