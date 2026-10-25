import Network
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
        .onAppear { YerelAgIzni.iste() }
    }
}

/// iOS yerel ağ gizliliği: izin verilmeden eklentinin sunucusu hotspot arayüzünde
/// "prohibited" kalıyor, iPad bağlanamıyor. İzin penceresi ancak uygulama yerel ağa
/// paket yollayınca çıkıyor; bu yüzden hotspot alt ağına boş bir UDP paketi atılır.
enum YerelAgIzni {
    private static var baglantilar: [NWConnection] = []

    static func iste() {
        for host in ["172.20.10.2", "172.20.10.3", "192.168.1.1"] {
            let c = NWConnection(host: NWEndpoint.Host(host), port: 9, using: .udp)
            c.stateUpdateHandler = { state in
                if case .ready = state {
                    c.send(content: Data([0]), completion: .contentProcessed { _ in c.cancel() })
                }
            }
            c.start(queue: .main)
            baglantilar.append(c)
        }
    }
}
