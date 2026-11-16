import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct StickerPicker: View {
    let palette: DeskPalette
    let insert: (ForumSticker) -> Void
    @ObservedObject private var library = StickerLibrary.shared
    @StateObject private var state = Selection()

    private final class Selection: ObservableObject {
        @Published var group = "ac"
        @Published var newName = ""
        @Published var naming = false
        @Published var error: String?
    }

    private var custom: StickerLibrary.Group? { library.groups.first { $0.id.uuidString == state.group } }
    private var items: [ForumSticker] {
        if let custom { return library.items(custom) }
        return ForumStickers.officialPacks.first { $0.id == state.group }?.items ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                DeskLabel("表情包", systemImage: "face.smiling").font(.headline)
                Spacer()
                Button {
                    state.naming.toggle()
                    state.error = nil
                } label: {
                    DeskLabel("新建分组", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(11)
            .deskGlass(in: RoundedRectangle(cornerRadius: 13), solid: palette.chrome)
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ScrollView(.horizontal) {
                        DeskGlassPicker(values: ForumStickers.officialPacks.map(\.id), selection: $state.group,
                                        tint: palette.accent, solid: palette.selection, compact: true) { id, _ in
                            Text(ForumStickers.officialPacks.first { $0.id == id }?.title ?? id)
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .scrollIndicators(.hidden).frame(height: 32)
                    if !library.groups.isEmpty {
                        DeskGlassSelectionGroup(selection: custom?.id.uuidString,
                                                solid: palette.selection, vertical: false) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 6)], alignment: .leading, spacing: 6) {
                                ForEach(library.groups) { groupButton($0.name, id: $0.id.uuidString) }
                            }
                        }
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(height: 30 + min(3, CGFloat((library.groups.count + 3) / 4)) * 36)
            .padding(7)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("表情分组")
            if state.naming {
                HStack {
                    TextField("分组名称", text: $state.newName).textFieldStyle(.roundedBorder).onSubmit(create)
                    Button("创建", action: create).deskGlassButtonStyle()
                }
            }
            if let custom {
                HStack {
                    Button("导入图片…") { importImages(into: custom.id) }.deskGlassButtonStyle()
                    Spacer()
                    Text("使用自定义表情需配置 NodeImage 密钥").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = state.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            if items.isEmpty {
                Text("此分组还没有表情。").foregroundStyle(.secondary).font(.caption)
                    .frame(maxWidth: .infinity, minHeight: 64)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 6), spacing: 5) {
                        ForEach(items) { item in
                            Button { insert(item) } label: {
                                StickerThumbnail(url: item.url)
                                    .frame(width: 68, height: 68).padding(4)
                                    .background(palette.list, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(DeskButtonStyle(compresses: true)).help(item.label).accessibilityLabel(item.label)
                            .contextMenu {
                                if let custom {
                                    Button("从分组移除", role: .destructive) {
                                        do { try library.remove(item, in: custom.id) }
                                        catch { state.error = error.localizedDescription }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .id(state.group)
                .frame(minHeight: 76, idealHeight: min(322, CGFloat((items.count + 5) / 6) * 81 + 4),
                       maxHeight: min(322, CGFloat((items.count + 5) / 6) * 81 + 4))
            }
            if custom == nil {
                Text("NodeSeek 官方表情").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(width: 512).frame(maxHeight: 640).background(palette.readerWash)
        .onChange(of: state.group) { state.error = nil }
        .task {
            do { _ = try library.checkedGroups() }
            catch { state.error = error.localizedDescription }
        }
    }

    private func groupButton(_ title: String, id: String) -> some View {
        let selected = state.group == id
        return Button { state.group = id } label: {
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 10).frame(height: 29)
                .foregroundStyle(selected ? palette.accent : .primary)
        }
        .buttonStyle(DeskButtonStyle())
        .deskGlassSelectionItem(id, selected: selected)
        .help(title).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func create() {
        do {
            state.group = try library.create(state.newName).uuidString
            state.newName = ""; state.naming = false; state.error = nil
        } catch { state.error = error.localizedDescription }
    }

    private func importImages(into group: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "导入"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                do {
                    let result = try await library.importImages(urls, to: group, authorized: { true })
                    state.error = result.skipped > 0 ? StickerLibrary.LibraryError.skipped(result.skipped).localizedDescription : nil
                } catch { state.error = error.localizedDescription }
            }
        }
    }
}

private struct StickerThumbnail: View {
    let url: URL
    @StateObject private var local = LocalImage()
    var body: some View {
        Group {
            if url.isFileURL {
                if let image = local.image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                else { DeskIcon("photo").foregroundStyle(.secondary) }
            } else {
                ForumImageView(url: url, label: "", sticker: true, thumbnail: true)
            }
        }
        .task(id: url) {
            guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            local.image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 88
            ] as CFDictionary)
        }
        .accessibilityHidden(true)
    }

    private final class LocalImage: ObservableObject { @Published var image: CGImage? }
}
