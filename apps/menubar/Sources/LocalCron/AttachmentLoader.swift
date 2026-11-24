import AppKit
import LocalCronKit
import UniformTypeIdentifiers

/// Turns what the user pastes or drops on the composer into attachments
/// (Attachment.swift): a picture with its bytes, any other file with its
/// path. A picture that is too large is made smaller; a pasted picture is
/// saved to a temporary file, so the chip and the post can show it.
@MainActor
enum AttachmentLoader {
    struct Failure: Error { let text: String }

    /// The files or the picture on the pasteboard, or nil when it holds
    /// text: then the paste goes on as usual.
    static func fromPasteboard(_ pb: NSPasteboard) -> [Result<Attachment, Failure>]? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(load(url:))
        }
        if pb.string(forType: .string) != nil { return nil }
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")] {
            if let data = pb.data(forType: type) { return [load(imageData: data, name: "Pasted image")] }
        }
        return nil
    }

    /// A file from the disk.
    static func load(url: URL) -> Result<Attachment, Failure> {
        let name = url.lastPathComponent
        guard let type = Attachments.mediaType(forExtension: url.pathExtension) else {
            return .success(Attachment(name: name, path: url.path))
        }
        guard let data = try? Data(contentsOf: url) else { return .failure(Failure(text: "Could not read \(name).")) }
        return fit(data, mediaType: type).map { Attachment(name: name, path: url.path, mediaType: $0.type, data: $0.data) }
    }

    /// A picture with no file: pasted, or dragged from a browser.
    static func load(imageData: Data, name: String) -> Result<Attachment, Failure> {
        var data = imageData
        var type = Attachments.mediaType(sniffing: data)
        if type == nil {
            // TIFF and other kinds Claude does not read become PNG.
            guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else {
                return .failure(Failure(text: "This picture cannot be read."))
            }
            data = png
            type = "image/png"
        }
        return fit(data, mediaType: type ?? "image/png").flatMap { fitted in
            let ext = fitted.type.split(separator: "/").last.map(String.init) ?? "png"
            let file = name + "." + (ext == "jpeg" ? "jpg" : ext)
            let url = folder.appendingPathComponent(UUID().uuidString + "-" + file)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let path = (try? fitted.data.write(to: url)) != nil ? url.path : nil
            return .success(Attachment(name: file, path: path, mediaType: fitted.type, data: fitted.data))
        }
    }

    private static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LocalCron-attachments", isDirectory: true)
    }

    /// The picture as it is when it is small enough, else a JPEG at most
    /// 2000 points on its long side.
    private static func fit(_ data: Data, mediaType: String) -> Result<(data: Data, type: String), Failure> {
        if data.count <= Attachments.maxImageBytes { return .success((data, mediaType)) }
        guard let rep = NSBitmapImageRep(data: data) else { return .failure(Failure(text: "This picture cannot be read.")) }
        let long = CGFloat(max(rep.pixelsWide, rep.pixelsHigh))
        let scale = min(1, 2000 / max(long, 1))
        let size = NSSize(width: CGFloat(rep.pixelsWide) * scale, height: CGFloat(rep.pixelsHigh) * scale)
        guard let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return .failure(Failure(text: "This picture is too large."))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        rep.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = small.representation(using: .jpeg, properties: [.compressionFactor: 0.85]),
              jpeg.count <= Attachments.maxImageBytes else {
            return .failure(Failure(text: "This picture is too large: more than 3.7 MB, even made smaller."))
        }
        return .success((jpeg, "image/jpeg"))
    }
}

extension ManagerStore {
    /// Adds what was pasted or dropped to the composer of a channel. Returns
    /// the error to show, or nil.
    @discardableResult
    func attach(_ results: [Result<Attachment, AttachmentLoader.Failure>], jobID: String?) -> String? {
        let key = Manager.key(jobID)
        var list = attachments[key] ?? []
        var errors: [String] = []
        for result in results {
            switch result {
            case let .success(item):
                if list.count >= Attachments.maxCount {
                    errors.append("A message can have at most \(Attachments.maxCount) files.")
                    break
                }
                if item.path == nil || !list.contains(where: { $0.path == item.path }) { list.append(item) }
            case let .failure(failure):
                errors.append(failure.text)
            }
        }
        attachments[key] = list
        focusRequest += 1
        return errors.isEmpty ? nil : Array(Set(errors)).sorted().joined(separator: " ")
    }

    func detach(_ id: String, jobID: String?) {
        attachments[Manager.key(jobID)]?.removeAll { $0.id == id }
    }
}
