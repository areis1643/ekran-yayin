import Foundation
import Network
import os

private let log = Logger(subsystem: "tr.niladsp.ekran", category: "http")

/// En küçük HTTP sunucusu. Yollar:
///   /           iOS 9 Safari için ES5 izleme sayfası (kareleri art arda çeker)
///   /frame.jpg  son kare
///   /stream     MJPEG (multipart/x-mixed-replace), tarayıcı destekliyorsa
final class HTTPServer {
    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ekran.http")

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let l = try? NWListener(using: params, on: nwPort) else { return }
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.stateUpdateHandler = { state in log.notice("dinleyici durumu: \(String(describing: state), privacy: .public)") }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ c: NWConnection) {
        log.notice("baglanti: \(String(describing: c.endpoint), privacy: .public)")
        // Her bağlantı kendi seri kuyruğunda; uzun MJPEG akışı ötekileri bekletmesin.
        c.start(queue: DispatchQueue(label: "ekran.conn"))
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else {
                c.cancel()
                return
            }
            let path = req.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            log.notice("istek: \(path, privacy: .public)")
            if path.hasPrefix("/frame.jpg") {
                self.sendFrame(c)
            } else if path.hasPrefix("/stream") {
                self.startStream(c)
            } else {
                self.send(c, type: "text/html; charset=utf-8", body: Data(Page.html.utf8))
            }
        }
    }

    private func send(_ c: NWConnection, type: String, body: Data, status: String = "200 OK") {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        // Yanıtı yollar yollamaz cancel() etmek, istemci veriyi almadan bağlantıyı kesip
        // sayfayı yarım bırakabiliyordu (iPad'de betik hiç çalışmıyordu). Yazma yönünü
        // kapatıp istemcinin kapatmasını bekle; gelmezse birkaç saniye sonra kes.
        c.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true,
               completion: .contentProcessed { err in
            log.notice("yanit \(status, privacy: .public) \(body.count) bayt hata=\(String(describing: err), privacy: .public)")
            self.drainUntilClosed(c)
        })
    }

    private func drainUntilClosed(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] _, _, isComplete, err in
            if isComplete || err != nil {
                c.cancel()
            } else {
                self?.drainUntilClosed(c)
            }
        }
        queue.asyncAfter(deadline: .now() + 5) { c.cancel() }
    }

    private func sendFrame(_ c: NWConnection) {
        let (jpeg, _) = FrameStore.shared.get()
        if let jpeg {
            send(c, type: "image/jpeg", body: jpeg)
        } else {
            send(c, type: "text/plain", body: Data("bekleniyor".utf8), status: "503 Service Unavailable")
        }
    }

    private func startStream(_ c: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=kare\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] err in
            if err != nil { c.cancel(); return }
            self?.pushNext(c, lastSeq: -1)
        })
    }

    private func pushNext(_ c: NWConnection, lastSeq: Int) {
        let (jpeg, seq) = FrameStore.shared.get()
        guard let jpeg, seq != lastSeq else {
            queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.pushNext(c, lastSeq: lastSeq) }
            return
        }
        let part = "--kare\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n"
        c.send(content: Data(part.utf8) + jpeg + Data("\r\n".utf8), completion: .contentProcessed { [weak self] err in
            if err != nil { c.cancel(); return }
            self?.pushNext(c, lastSeq: seq)
        })
    }
}

enum Page {
    // iOS 9 Safari: object-fit yok, ok fonksiyonu yok, let yok. Boyutlandırma JS'te.
    static let html = """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black">
    <title>Ekran</title>
    <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
    #i{position:absolute;display:block}
    #d{position:fixed;top:4px;left:6px;color:#555;font:12px sans-serif}</style></head>
    <body><img id="i" alt=""><div id="d">bağlanıyor…</div><script>
    var i=document.getElementById('i'),d=document.getElementById('d'),n=0,t0=new Date().getTime();
    function fit(){var W=window.innerWidth,H=window.innerHeight,w=i.naturalWidth,h=i.naturalHeight;
      if(!w||!h)return;var s=Math.min(W/w,H/h);i.style.width=(w*s)+'px';i.style.height=(h*s)+'px';
      i.style.left=((W-w*s)/2)+'px';i.style.top=((H-h*s)/2)+'px';}
    var w=null;
    function next(){clearTimeout(w);w=setTimeout(function(){d.innerHTML='zaman aşımı, yeniden';next();},3000);
      i.src='/frame.jpg?'+new Date().getTime();}
    i.onload=function(){clearTimeout(w);fit();n++;var t=new Date().getTime(),s=(t-t0)/1000;
      if(s>=2){d.innerHTML=(n/s).toFixed(1)+' kare/sn';n=0;t0=t;}next();};
    i.onerror=function(){clearTimeout(w);d.innerHTML='yayın bekleniyor';setTimeout(next,500);};
    window.onresize=fit;d.innerHTML='istek gönderildi';next();
    </script></body></html>
    """
}
