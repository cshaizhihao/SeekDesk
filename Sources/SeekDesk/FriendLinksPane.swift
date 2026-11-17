import AppKit
import SwiftUI

struct FriendLinksPane: View {
    let palette: DeskPalette
    let returnTitle: String
    let returnToForum: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DeskGlassGroup {
                HStack(spacing: 14) {
                    Button(action: returnToForum) { DeskLabel(returnTitle, systemImage: "chevron.left") }
                        .deskGlassButtonStyle().controlSize(.large)
                    Text("友情链接").font(.system(size: 23, weight: .bold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                }
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("感谢以下伙伴对本项目的支持，排名不分先后。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    DeskGlassGroup {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 242), spacing: 16)], spacing: 16) {
                            ForEach(Self.partners) { partner in card(partner) }
                        }
                    }
                }
                .frame(maxWidth: 990, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .background(palette.chrome)
    }

    private func card(_ partner: Partner) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 13) {
                Group {
                    if let image = partner.image {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        DeskIcon("link", size: 20).foregroundStyle(palette.accent)
                    }
                }
                .frame(width: 56, height: 56)
                .background(palette.selection, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

                Text(partner.name)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Text(partner.description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if let website = partner.website {
                    Link(destination: website) { DeskLabel("官网", systemImage: "arrow.up.right") }
                        .accessibilityLabel("\(partner.name) 官网")
                        .help(website.absoluteString)
                }
                if let telegram = partner.telegram {
                    Link(destination: telegram) {
                        DeskLabel("Telegram 群组", systemImage: "paperplane")
                    }
                    .accessibilityLabel("\(partner.name) Telegram 群组")
                    .help(telegram.absoluteString)
                }
            }
            .buttonStyle(.bordered).controlSize(.regular)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deskGlass(in: shape, solid: palette.list)
        .accessibilityElement(children: .contain)
    }

    private struct Partner: Identifiable {
        let name: String
        let description: String
        let website: URL?
        let telegram: URL?
        var id: String { name }

        var image: NSImage? {
            Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Partners")
                .flatMap { NSImage(contentsOf: $0) }
        }
    }

    private static let partners = [
        Partner(name: "Impart", description: "全球自建家宽测速，VPS与IDC、银行卡、电话卡交流与优惠。",
                website: nil, telegram: URL(string: "https://t.me/Impart_Cloud")!),
        Partner(name: "Shlii", description: "高性价比的 VPS、NAT 平台",
                website: URL(string: "https://shlii.io/")!,
                telegram: URL(string: "https://t.me/IncuShliidlb")!),
        Partner(name: "PickMyVPS", description: "自购 400+ 台热门线路 / 落地机探针站",
                website: URL(string: "https://www.pickmyvps.com/")!,
                telegram: URL(string: "https://t.me/PickMyVPS_Group")!),
        Partner(name: "CowCode", description: "下一代AI全聚合中转平台 主流模型 0.1x 起",
                website: URL(string: "https://cowcode.top/r/cshaizhihao")!,
                telegram: nil),
        Partner(name: "VPStarter", description: "VPS 详细观察与评测的工具站",
                website: URL(string: "https://vpstarter.com/")!,
                telegram: nil),
        Partner(name: "deerstack", description: "服务器实测、避坑教程和实用工具",
                website: URL(string: "https://deerstack.com/")!,
                telegram: nil),
    ]
}
