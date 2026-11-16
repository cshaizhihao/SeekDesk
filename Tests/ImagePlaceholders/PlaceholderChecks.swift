import AppKit
import ImageIO
import JavaScriptCore

@main
enum ImagePlaceholderChecks {
    static func main() throws {
        try decoding()
        extraction()
        try projection()
        print("Passed image placeholder compatibility, DOM source matching, bounds and decoder projection checks.")
    }

    private static func decoding() throws {
        let old = try JSONDecoder().decode(ForumBlock.self, from: Data(#"{"kind":"image","text":"old","url":"https://example.invalid/image.png"}"#.utf8))
        precondition(old.imageSize == nil)
        let constructed = ForumBlock(kind: "text", text: "existing initializer", url: nil, tabs: nil, rows: nil, terminal: nil)
        precondition(constructed.imageSize == nil)
        let current = try JSONDecoder().decode(ForumBlock.self, from: Data(#"{"kind":"image","text":"long report","imageSize":{"width":1200,"height":24000}}"#.utf8))
        precondition(current.imageSize?.validatedSize == CGSize(width: 1200, height: 24000))
        for (width, height) in [(0.0, 100.0), (-1, 100), (100, 0), (100_001, 100),
                                (100, 100_001), (100_000, 100_000), (.infinity, 100), (100, .nan)] {
            precondition(ForumImageDimensions(width: width, height: height).validatedSize == nil)
        }
    }

    private static func extraction() {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in preconditionFailure(exception?.toString() ?? "JavaScript error") }
        let source = ForumPageScript.extract
        let start = source.range(of: "const imageSize = ")!.lowerBound
        let end = source.range(of: "const floor = ", range: start..<source.endIndex)!.lowerBound
        // URL resolution itself belongs to the existing safeURL routine. Here
        // the resources are absolute so the exact production matching/size
        // helper can be tested without loading a browser or issuing requests.
        context.evaluateScript("""
        const safeURL = value => value || null;
        const Node = {ELEMENT_NODE:1, TEXT_NODE:3};
        const excluded = () => false;
        const terminalRoot = () => false;
        """ + "\n" + source[start..<end])
        let result = context.evaluateScript(#"""
        (() => {
            const target = 'https://example.invalid/report.png';
            const node = {complete:true, currentSrc:target, src:target, naturalWidth:1200, naturalHeight:24000};
            const valid = value => value?.width === 1200 && value?.height === 24000;
            if (!valid(imageSize(node, target))) return false;
            if (!valid(imageSize({...node, currentSrc:''}, target))) return false;
            if (imageSize({...node, currentSrc:'https://example.invalid/placeholder.png'}, target) !== null) return false;
            if (imageSize({...node, currentSrc:'', src:'https://example.invalid/placeholder.png'}, target) !== null) return false;
            if (imageSize({...node, complete:false}, target) !== null) return false;
            for (const dimensions of [[0,100], [-1,100], [100,0], [NaN,100], [100,Infinity],
                                      [100001,100], [100,100001], [100000,100000]]) {
                if (imageSize({...node, naturalWidth:dimensions[0], naturalHeight:dimensions[1]}, target) !== null) return false;
            }
            const image = {...node, nodeType:1, tagName:'IMG', alt:'report',
                classList:{contains:() => false}, matches:() => false,
                getAttribute:name => name === 'data-src' ? target : 'https://example.invalid/placeholder.png'};
            const exportImage = image => {
                const blocks = [];
                collect({childNodes:[image]}, blocks);
                return blocks[0];
            };
            const loaded = exportImage(image);
            if (loaded.url !== target || !valid(loaded.imageSize)) return false;
            const pending = exportImage({...image, currentSrc:'https://example.invalid/placeholder.png'});
            if (pending.url !== target || pending.imageSize !== null) return false;
            const fallback = exportImage({...image, currentSrc:'', src:target,
                getAttribute:name => name === 'src' ? target : null});
            if (fallback.url !== target || !valid(fallback.imageSize)) return false;
            const declared = (width, height, src = target) => ({...node, complete:false,
                naturalWidth:0, naturalHeight:0, currentSrc:'', src,
                getAttribute:name => ({src, width, height})[name] ?? null});
            if (!valid(imageSize(declared('1200', '24000'), target))) return false;
            if (!valid(imageSize(declared(' 1200 ', '24000.0'), target))) return false;
            // Natural dimensions take precedence over author-supplied sizing.
            if (!valid(imageSize({...declared('600','400'), ...node}, target))) return false;
            for (const dimensions of [['100%', '200'], ['200px','100'], ['', '100'], ['100', null],
                                      ['0','100'], ['-1','100'], ['Infinity','100'], ['1e3','100'],
                                      ['100001','100'], ['100000','100000']]) {
                if (imageSize(declared(...dimensions), target) !== null) return false;
            }
            if (imageSize(declared('1200','24000','https://example.invalid/placeholder.png'), target) !== null) return false;
            if (imageSize({...declared('1200','24000'), currentSrc:'https://example.invalid/other.png'}, target) !== null) return false;
            return true;
        })()
        """#)
        precondition(result?.toBool() == true)
    }

    private static func projection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("seekdesk-placeholder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for size in [CGSize(width: 640, height: 360), CGSize(width: 3000, height: 1500),
                     CGSize(width: 1800, height: 15000)] {
            try autoreleasepool {
                let file = directory.appendingPathComponent("fixture.png")
                let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.setFillColor(NSColor.white.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
                let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, context.makeImage()!, nil)
                precondition(CGImageDestinationFinalize(destination))
                let decoded = try ForumImageRequest.decode(file)
                let projected = ForumImageRequest.projectedPostSize(size)
                precondition(abs(projected.width - CGFloat(decoded.image.width)) <= 1)
                precondition(abs(projected.height - CGFloat(decoded.image.height)) <= 1)
                precondition(projected.width <= 2160 && projected.width * projected.height <= 24_030_000)
            }
        }
    }
}
