import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.fill")
                .font(.system(size: 64))
            Text("Wall-E")
                .font(.largeTitle).bold()
            Text("Build pipeline online")
                .foregroundStyle(.secondary)
            Text("Stage 1 of 5")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
