# ekran-yayin

iPhone ekranını, iPhone'un kendi hotspot'una bağlı eski iPad 2'ye (iOS 9) gösterir.
ReplayKit yayın eklentisi kareleri JPEG'e çevirip iPhone üstünde `:8888`'den verir;
iPad'de Safari `http://172.20.10.1:8888/` sayfası kareleri art arda çeker.

Neden JPEG: iOS 9 Safari'de WebRTC yok, HLS fMP4 desteklenmiyor.
Derleme GitHub Actions (macOS) üzerinde, imzasız IPA; imza ve kurulum Slayer'da plumesign + pymobiledevice3.
