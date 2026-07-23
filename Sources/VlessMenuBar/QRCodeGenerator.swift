import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

enum QRCodeGenerator {
    /// 把一段文本生成二维码图片。scale 控制放大倍数——CIQRCodeGenerator 原生
    /// 输出的图一般只有几十像素见方，不放大的话在屏幕上会糊成一团。
    static func generate(from string: String, scale: CGFloat = 10) -> NSImage? {
        guard let data = string.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M" // L/M/Q/H，M 是纠错能力和信息密度比较均衡的常用档位

        guard let outputImage = filter.outputImage else { return nil }

        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaledImage = outputImage.transformed(by: transform)

        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}
