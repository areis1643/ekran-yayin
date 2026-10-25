import ReplayKit
import SwiftUI

@main
struct EkranApp: App {
    var body: some Scene {
        WindowGroup { AnaEkran() }
    }
}

/// Sistemin yayın seçicisi; listede doğrudan bizim eklentimizi gösterir.
struct YayinDugmesi: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 96, height: 96))
        // İmzalayıcı ana kimliğe takım kimliği ekleyebiliyor; eklenti kimliğini çalışma anında türet.
        v.preferredExtension = (Bundle.main.bundleIdentifier ?? "") + ".EkranYayin"
        v.showsMicrophoneButton = false
        return v
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

struct AnaEkran: View {
    var body: some View {
        VStack(spacing: 28) {
            Text("Ekran yayını").font(.largeTitle.bold())
            YayinDugmesi().frame(width: 96, height: 96)
            Text("Düğmeye bas, \"Yayını Başlat\" de.\niPad'de Ekran simgesini aç.\n\nAdres: http://172.20.10.1:8888")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
