import Foundation

struct ForumThread: Codable, Equatable {
    let title: String
    let category: String
    let root: ForumFloor?
    let replies: [ForumFloor]
    let pages: [ForumPageLink]
    let page: Int
    let replyRestriction: String?
}

/// Resolve missing/deleted/filtered floors without sending the reader back to the title.
enum ForumReadingDestination {
    static func replies(in thread: ForumThread, authorOnly: Bool) -> [ForumFloor] {
        guard authorOnly else { return thread.replies }
        return thread.replies.filter { $0.isAuthor || (thread.root != nil && $0.author == thread.root?.author) }
    }

    static func anchor(in thread: ForumThread, preferred: String?, fragment: String?, authorOnly: Bool) -> String {
        let replies = replies(in: thread, authorOnly: authorOnly)
        let fallback = thread.page == 1 ? "thread-title" : "thread-discussion"
        let requested = preferred ?? fragment.map { "floor-" + ($0.hasPrefix("comment-") ? String($0.dropFirst(8)) : $0) }
        guard let requested else { return fallback }
        if ["thread-title", "thread-discussion"].contains(requested) { return requested }
        if requested == "floor-0", thread.root != nil { return requested }
        if replies.contains(where: { $0.readerID == requested }) { return requested }
        guard requested.hasPrefix("floor-"), let number = Int(requested.dropFirst(6)), number >= 0 else { return fallback }
        let candidates = replies.compactMap { item -> (Int, String)? in
            guard let floor = Int(item.id), floor >= 0 else { return nil }
            return (floor, item.readerID)
        }
        return candidates.min { left, right in
            let leftDistance = abs(left.0 - number)
            let rightDistance = abs(right.0 - number)
            return leftDistance == rightDistance ? left.0 < right.0 : leftDistance < rightDistance
        }?.1 ?? fallback
    }
}

struct ForumFloor: Codable, Identifiable, Equatable {
    let id: String
    let author: String
    let authorID: Int?
    let isAuthor: Bool
    let avatar: URL?
    let tags: [String]?
    let date: String
    let dateLabel: String
    let blocks: [ForumBlock]
    var signature: String? = nil
    var likes: Int? = nil
    var chicken: Int? = nil
    var dislikes: Int? = nil
    var upvoted: Bool? = nil
    var gaveChicken: Bool? = nil
    var downvoted: Bool? = nil

    var readerID: String { "floor-\(id)" }

    func reaction(_ kind: ForumReactionKind) -> (count: Int?, selected: Bool) {
        switch kind {
        case .upvote: (likes, upvoted == true)
        case .chicken: (chicken, gaveChicken == true)
        case .dislike: (dislikes, downvoted == true)
        }
    }
}

struct ForumPageLink: Codable, Identifiable, Equatable {
    let number: Int
    let url: URL
    var id: Int { number }
}

struct ForumBlock: Codable, Equatable {
    let kind: String
    let text: String
    let url: URL?
    let tabs: [ForumBlockTab]?
    let rows: [[String]]?
    let terminal: [[ForumTerminalSpan]]?
    var imageSize: ForumImageDimensions? = nil
    var items: [ForumListItem]? = nil
    /// Optional and bounded DOM hint, never source code or a highlighter name
    /// to execute. Old snapshots without this key retain plain-code rendering.
    var language: String? = nil

    var hasTerminal: Bool {
        kind == "terminal" || kind == "terminalUnavailable" ||
            (items ?? []).contains { $0.blocks.contains { $0.hasTerminal } } ||
            (tabs ?? []).contains { $0.blocks.contains { $0.hasTerminal } }
    }
}

struct ForumListItem: Codable, Equatable {
    let marker: String
    let blocks: [ForumBlock]
}

/// Optional DOM metadata reserves a first-load image's height. It is only a
/// hint; decoded dimensions and the image cache always take precedence.
struct ForumImageDimensions: Codable, Equatable {
    let width: Double
    let height: Double

    var validatedSize: CGSize? {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 100_000, height <= 100_000, width * height <= 1_000_000_000 else { return nil }
        return CGSize(width: width, height: height)
    }
}

struct ForumTerminalSpan: Codable, Equatable {
    let text: String
    let foreground: String?
    let background: String?
    let bold: Bool
}

struct ForumBlockTab: Codable, Equatable {
    let label: String
    let blocks: [ForumBlock]
}

struct ForumReplyResponse: Codable {
    let success: Bool
    let redirect: String?
    let redirectHash: String?
    let message: String?

    func destination(from source: URL, floorsPerPage: Int? = nil) -> URL? {
        guard success, let topicID = Forum.topicID(source) else { return nil }
        let target: URL
        if let redirect, !redirect.isEmpty {
            guard let url = URL(string: redirect, relativeTo: source)?.absoluteURL,
                  Forum.topicID(url) == topicID else { return nil }
            target = url
        } else if let floor, let floorsPerPage, floorsPerPage > 0 {
            let page = floor == 0 ? 1 : (floor - 1) / floorsPerPage + 1
            target = Forum.home.appendingPathComponent("post-\(topicID)-\(page)")
        } else { return nil }
        guard var components = URLComponents(url: target, resolvingAgainstBaseURL: false) else { return nil }
        if let redirectHash, !redirectHash.isEmpty {
            let anchor = redirectHash.hasPrefix("#") ? String(redirectHash.dropFirst()) : redirectHash
            guard anchor.range(of: #"^(?:comment-)?[0-9]+$"#, options: .regularExpression) != nil else { return target }
            components.fragment = anchor
        }
        return components.url
    }

    private var floor: Int? {
        guard let redirectHash else { return nil }
        let hash = redirectHash.hasPrefix("#") ? String(redirectHash.dropFirst()) : redirectHash
        let raw = hash.hasPrefix("comment-") ? String(hash.dropFirst("comment-".count)) : hash
        guard let number = Int(raw), number >= 0 else { return nil }
        return number
    }
}

enum ForumPageError: LocalizedError {
    case verification, signInRequired, missing, changed, timedOut, network

    var errorDescription: String? {
        switch self {
        case .verification: "请先在 NodeSeek 窗口中完成站点验证，再回到这里阅读。"
        case .signInRequired: "请登录 NodeSeek 后查看这篇帖子。"
        case .missing: "NodeSeek 没有返回这篇帖子，可能已删除或当前账号无权查看。"
        case .changed: "暂时无法读取这篇帖子的正文。你可以重试，或打开原帖查看。"
        case .timedOut: "加载超时。请检查网络后重试。"
        case .network: "暂时无法连接 NodeSeek。请检查网络后重试。"
        }
    }
}

enum ForumPageScript {
    // NodeSeek's enhancement can replace the original code block with an empty
    // xterm viewport before the terminal has drawn. Keep the original in this
    // WebKit content world so inactive tabs and offscreen rows still have data.
    private static let terminalSource = #"""
    const ansiReport = (text, hint = false) => /[\x1b]\[[0-9;:]*m|\u009b[0-9;:]*m/.test(text) ||
        ((hint || /硬件质量体检报告|IP质量体检报告|HardwareQuality|IpQuality|NodeQuality|融合怪|ecs\.sh/i.test(text)) &&
            (text.match(/\[[0-9;:]{1,24}m/g) || []).length >= 3);
    const explicitANSI = code => Boolean(code.matches?.('code.language-ansi'));
    const terminalCodeText = node => {
        if (node.nodeType === Node.TEXT_NODE) return node.textContent || '';
        if (node.nodeType !== Node.ELEMENT_NODE) return '';
        const encoded = node.getAttribute('data-ansicode');
        if (encoded !== null && /^\d{1,3}$/.test(encoded)) {
            const value = Number(encoded);
            if (value < 32 || value === 127) return String.fromCharCode(value);
        }
        return [...node.childNodes].map(terminalCodeText).join('');
    };
    """#

    // This small page-world DTO carries only already-delivered Markdown for
    // visible floors that contain a terminal. The reader's isolated world cannot
    // access __config__, and must not receive account metadata from that object.
    static let terminalMarkdown = #"""
    const path = /^\/post-(\d+)-(\d+)\/?$/.exec(location.pathname);
    if (location.protocol !== 'https:' || !['www.nodeseek.com', 'nodeseek.com'].includes(location.host) ||
        !path || typeof expectedURL !== 'string') return null;
    let expected;
    try { expected = new URL(expectedURL); } catch { return null; }
    if (expected.origin !== location.origin || expected.pathname !== location.pathname ||
        expected.search !== location.search || expected.username || expected.password) return null;
    const postID = Number(path[1]), page = Number(path[2]);
    if (!Number.isSafeInteger(postID) || postID <= 0 || !Number.isSafeInteger(page) || page <= 0) return null;
    const data = window.__config__?.postData;
    if (Number(data?.postId) !== postID || !Array.isArray(data?.comments) || data.comments.length > 1000) return null;
    const main = document.querySelector('#nsk-body-left');
    if (!main) return null;
    const requested = typeof onlyFloor === 'string' ? onlyFloor : null;
    if (requested === null || (requested !== '' && (!/^(0|[1-9]\d*)$/.test(requested) ||
        !Number.isSafeInteger(Number(requested))))) return null;
    const items = [...main.querySelectorAll('.nsk-post-wrapper .content-item[id="0"], .comments > .content-item[id]')];
    const counts = new Map();
    for (const item of items) counts.set(item.id, (counts.get(item.id) || 0) + 1);
    const visibleContent = content => {
        for (let node = content; node; node = node.parentElement) {
            if (node.matches('[hidden], [aria-hidden="true"]')) return false;
            const style = getComputedStyle(node);
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            if (node === main) return true;
        }
        return false;
    };
    const floors = new Set(items.filter(item => {
        if (!/^(0|[1-9]\d*)$/.test(item.id) || counts.get(item.id) !== 1 || (requested && item.id !== requested) ||
            item.matches('[hidden], [aria-hidden="true"]')) return false;
        const content = item.querySelector(':scope > .post-content');
        return visibleContent(content) && Boolean(content.querySelector('.terminal-container, .xterm'));
    }).map(item => item.id));
    if (!floors.size) return null;
    const seen = new Set(), duplicates = new Set(), comments = [];
    let length = 0;
    for (const item of data.comments) {
        const floorIndex = item?.floorIndex;
        if (!Number.isSafeInteger(floorIndex) || floorIndex < 0 || !floors.has(String(floorIndex))) continue;
        if (seen.has(floorIndex)) duplicates.add(floorIndex);
        seen.add(floorIndex);
        if (typeof item.markdown !== 'string' || item.markdown.length > 512 * 1024) continue;
        length += item.markdown.length;
        if (length > 2 * 1024 * 1024 || comments.length >= 100) return null;
        comments.push({floorIndex, markdown:item.markdown});
    }
    return JSON.stringify({postID, page, comments:comments.filter(item => !duplicates.has(item.floorIndex))});
    """#

    // Pure helpers are shared with regression fixtures. Parsing all fences,
    // including ordinary code, prevents an example containing an ANSI fence
    // from being mistaken for another rendered report.
    static let terminalMarkdownHelpers = #"""
    const terminalMarkdownText = markdown => {
        if (typeof markdown !== 'string' || markdown.length > 512 * 1024) return null;
        const reports = [];
        let fence = null, body = [];
        for (const line of markdown.replace(/\r\n?/g, '\n').split('\n')) {
            if (fence) {
                const closing = /^ {0,3}(`{3,}|~{3,})[\t ]*$/.exec(line);
                if (closing && closing[1][0] === fence.mark && closing[1].length >= fence.length) {
                    if (fence.ansi) {
                        const text = body.join('\n');
                        if (!text.trim() || reports.length >= 64) return null;
                        reports.push(text);
                    }
                    fence = null;
                    body = [];
                } else if (fence.ansi) body.push(line);
                continue;
            }
            const opening = /^ {0,3}(`{3,}|~{3,})([^\n]*)$/.exec(line);
            if (!opening || (opening[1][0] === '`' && opening[2].includes('`'))) continue;
            fence = {mark:opening[1][0], length:opening[1].length, ansi:/^ansi[\t ]*$/i.test(opening[2].trim())};
        }
        return fence?.ansi ? null : reports;
    };
    const terminalMarkdownSources = (value, postID, page) => {
        const sources = new Map();
        if (typeof value !== 'string' || value.length > 4 * 1024 * 1024) return sources;
        let payload;
        try { payload = JSON.parse(value); } catch { return sources; }
        if (!Number.isSafeInteger(postID) || postID <= 0 || !Number.isSafeInteger(page) || page <= 0 ||
            payload?.postID !== postID || payload?.page !== page || !Array.isArray(payload.comments) ||
            payload.comments.length > 100) return sources;
        const seen = new Set(), duplicates = new Set();
        let length = 0;
        for (const item of payload.comments) {
            const floor = item?.floorIndex;
            if (!Number.isSafeInteger(floor) || floor < 0) continue;
            if (seen.has(floor)) duplicates.add(floor);
            seen.add(floor);
            if (typeof item.markdown !== 'string') continue;
            length += item.markdown.length;
            if (length > 2 * 1024 * 1024) return new Map();
            const reports = terminalMarkdownText(item.markdown);
            if (reports?.length) sources.set(String(floor), reports);
        }
        for (const floor of duplicates) sources.delete(String(floor));
        return sources;
    };
    """#

    static let captureTerminals = terminalSource + #"""
    ;(() => {
        if (!/^\/post-\d+-\d+\/?$/.test(location.pathname)) return;
        const panes = new WeakMap();
        const captured = new WeakMap();
        const collect = (pre, parent) => {
            if (!parent) return;
            const pane = parent.closest('.nsk-magic-tab-body, .post-content');
            if (!pane) return;
            const code = pre.querySelector('code') || pre;
            const text = terminalCodeText(code);
            const hint = /ansi|terminal|xterm/i.test(pre.className + ' ' + code.className) ||
                Boolean(pane.matches('.nsk-magic-tab-body') && /基本信息|IP质量/i.test(pane.previousElementSibling?.textContent ?? ''));
            if (!text.trim() || (!explicitANSI(code) && !ansiReport(text, hint))) return;
            const existing = captured.get(pre);
            if (existing) { existing.text = text; return; }
            const record = {pre, parent, text};
            captured.set(pre, record);
            const source = panes.get(pane) ?? [];
            source.push(record);
            panes.set(pane, source);
        };
        const scan = node => {
            if (node.nodeType !== Node.ELEMENT_NODE) return;
            if (node.matches('pre')) collect(node, node.parentElement);
            else for (const pre of node.querySelectorAll('pre')) collect(pre, pre.parentElement);
        };
        const observer = new MutationObserver(records => {
            for (const change of records) {
                if (change.target.nodeType === Node.TEXT_NODE) {
                    const pre = change.target.parentElement?.closest('pre');
                    if (pre) collect(pre, pre.parentElement);
                    continue;
                }
                if (change.target.nodeType !== Node.ELEMENT_NODE) continue;
                if (change.target.matches('pre')) collect(change.target, change.target.parentElement);
                else if (change.target.matches('pre code')) collect(change.target.closest('pre'), change.target.closest('pre').parentElement);
                for (const removed of change.removedNodes) {
                    if (removed.nodeType === Node.ELEMENT_NODE && removed.matches('pre')) collect(removed, change.target);
                }
                for (const added of change.addedNodes) scan(added);
            }
        });
        observer.observe(document, {childList:true, characterData:true, subtree:true});
        document.addEventListener('DOMContentLoaded', () => scan(document.documentElement), {once:true, capture:true});
        globalThis.__seekDeskTerminalSources = panes;
        setTimeout(() => observer.disconnect(), 12000);
    })();
    """#

    static let extract = #"""
    const allowed = new Set(['www.nodeseek.com', 'nodeseek.com']);
    const safeURL = (value, media = false) => {
        if (!value) return null;
        try {
            const url = new URL(value, location.href);
            if (url.username || url.password) return null;
            if (media ? url.protocol !== 'https:' : !['https:', 'http:'].includes(url.protocol)) return null;
            return url.href;
        } catch { return null; }
    };
    const plain = node => (node?.innerText || node?.textContent || '').trim();
    const excluded = node => node.matches('script,style,noscript,template,[hidden],[aria-hidden="true"]') ||
        getComputedStyle(node).display === 'none' || getComputedStyle(node).visibility === 'hidden';
    const main = document.querySelector('#nsk-body-left');
    const visibleFloor = item => {
        for (let node = item; node; node = node.parentElement) {
            if (excluded(node)) return false;
            if (node === main) return true;
        }
        return false;
    };
    const rootCandidate = main?.querySelector('.nsk-post-wrapper .content-item[id="0"]');
    const root = rootCandidate && visibleFloor(rootCandidate) ? rootCandidate : null;
    const title = main?.querySelector('h1 .post-title-link');
    const current = /^\/post-(\d+)-(\d+)\/?$/.exec(location.pathname);
    const page = Number(current?.[2]) || 1;
    if (!title || (!root && (page === 1 || !main.querySelector('.comment-container')))) {
        return JSON.stringify({ error: 'missing' });
    }
    const requested = typeof onlyFloor === 'string' ? onlyFloor : null;
    if (requested === null || (requested !== '' && (!/^(0|[1-9]\d*)$/.test(requested) ||
        !Number.isSafeInteger(Number(requested))))) return JSON.stringify({error:'missing'});
    const commentItems = [...main.querySelectorAll('.comments > .content-item[id]')]
        .filter(item => /^(0|[1-9]\d*)$/.test(item.id) && Number.isSafeInteger(Number(item.id)) && visibleFloor(item));
    const selected = requested ? [root, ...commentItems].filter(item => item?.id === requested) : [];
    if (requested && selected.length !== 1) return JSON.stringify({error:'missing'});
    const relevant = requested ? selected[0] : main;
    const firstFloor = requested ? selected[0] : root || commentItems[0];
    for (let attempt = 0; firstFloor && !firstFloor.querySelector(':scope > .comment-menu [title="点赞"]') && attempt < 8; attempt++) {
        await new Promise(resolve => setTimeout(resolve, 80));
    }
    \#(terminalSource)
    \#(terminalMarkdownHelpers)
    const renderedSelector = '.terminal-container, .xterm';
    const terminalRoot = node => node.matches(renderedSelector) && !node.parentElement?.closest(renderedSelector);
    const inactiveTerminalPane = node => node.matches('.nsk-magic-tab-body:not(.is-active)') &&
        !node.matches('[hidden], [aria-hidden="true"]') && getComputedStyle(node).visibility !== 'hidden';
    const terminalVisible = node => {
        for (let ancestor = node; ancestor; ancestor = ancestor.parentElement) {
            if (excluded(ancestor) && !inactiveTerminalPane(ancestor)) return false;
            if (ancestor === main) return true;
        }
        return false;
    };
    const sourceReports = terminalMarkdownSources(typeof terminalSources === 'string' ? terminalSources : '', Number(current?.[1]), page);
    const visibleFloors = [root, ...commentItems].filter(Boolean);
    let terminalSlots = new WeakMap();
    const markdownText = node => {
        if (!terminalRoot(node) || !terminalVisible(node)) return null;
        const content = node.closest('.post-content');
        const item = content?.parentElement;
        if (!item || !visibleFloors.includes(item) || (requested && item.id !== requested) ||
            visibleFloors.filter(floor => floor.id === item.id).length !== 1) return null;
        let visible = false;
        for (let ancestor = content; ancestor; ancestor = ancestor.parentElement) {
            if (excluded(ancestor)) return null;
            if (ancestor === main) { visible = true; break; }
        }
        if (!visible) return null;
        const reports = sourceReports.get(item.id);
        if (!reports) return null;
        // The site converts only its first ANSI blocks. Count remaining PREs
        // alongside converted roots so a mixed page cannot shift the pairing.
        let slots = terminalSlots.get(content);
        if (!slots) {
            slots = [...content.querySelectorAll('.terminal-container, .xterm, pre')].filter(candidate =>
                candidate.closest('.post-content') === content &&
                (terminalRoot(candidate) || (candidate.tagName === 'PRE' && !candidate.closest(renderedSelector) &&
                    explicitANSI(candidate.querySelector('code') || candidate))));
            terminalSlots.set(content, slots);
        }
        if (slots.length !== reports.length) return null;
        const index = slots.indexOf(node);
        return index < 0 ? null : reports[index];
    };
    const rootsIn = scope => [...scope.querySelectorAll(renderedSelector)]
        .filter(node => terminalRoot(node) && node.closest('.nsk-magic-tab-body, .post-content') === scope);
    const capturedText = node => {
        const scope = node.closest('.nsk-magic-tab-body, .post-content');
        const all = globalThis.__seekDeskTerminalSources?.get(scope);
        const records = all?.filter(x => !x.pre.isConnected);
        if (!records?.length) return null;
        const related = records.filter(x => x.parent.contains(node));
        if (related.length === 1 && rootsIn(scope).filter(root => related[0].parent.contains(root)).length === 1) return related[0].text;
        const roots = rootsIn(scope);
        if (roots.length !== records.length) return null;
        return records[roots.indexOf(node)]?.text ?? null;
    };
    const drawnRows = node => {
        const rows = node.querySelector('.xterm-rows');
        return rows?.textContent.trim() ? rows : null;
    };
    const incomplete = () => [...(relevant?.querySelectorAll('.post-content :is(.terminal-container, .xterm)') || [])]
        .some(node => terminalRoot(node) && terminalVisible(node) && !markdownText(node) && !capturedText(node) && !drawnRows(node));
    // Only wait for a report that is actually present but not painted yet.
    for (let attempt = 0; attempt < 25 && incomplete(); attempt++) {
        await new Promise(resolve => setTimeout(resolve, 80));
        // The site may replace another PRE while drawing. Reuse only within
        // one synchronous pass; never retain a slot order across a DOM wait.
        terminalSlots = new WeakMap();
    }
    const escape = text => text.replace(/[\\`*_~\[\]<>&.:]/g, '\\$&');
    const imageSize = (node, url) => {
        // data-src can still point at a different resource than the loaded
        // placeholder. Never attach that placeholder's dimensions to it.
        const loadedURL = safeURL(node.currentSrc || node.src, true);
        const width = node.naturalWidth, height = node.naturalHeight;
        const valid = (width, height) => Number.isFinite(width) && Number.isFinite(height) &&
            width > 0 && height > 0 && width <= 100000 && height <= 100000 && width * height <= 1000000000;
        if (node.complete && loadedURL === url && valid(width, height)) return {width, height};
        // A lazy image may not be downloaded yet, but explicit HTML dimensions
        // already describe its aspect ratio. Ignore CSS/layout sizes, percentages
        // and data-src placeholders, which may describe a different resource.
        if (loadedURL !== url || safeURL(node.getAttribute?.('src'), true) !== url) return null;
        const declared = name => {
            const value = node.getAttribute?.(name)?.trim() || '';
            return /^\d+(?:\.\d+)?$/.test(value) ? Number(value) : NaN;
        };
        const declaredWidth = declared('width'), declaredHeight = declared('height');
        return valid(declaredWidth, declaredHeight) ? {width:declaredWidth, height:declaredHeight} : null;
    };
    const codeLanguage = (code, pre) => {
        for (const element of code === pre ? [code] : [code, pre]) {
            for (const name of element.classList ?? []) {
                const match = /^(?:language-|lang-)([a-z0-9][a-z0-9_+#.-]{0,31})$/i.exec(name);
                if (match) return match[1].toLowerCase();
            }
            const hint = element.getAttribute('data-language') || element.getAttribute('data-lang') || '';
            if (/^[a-z0-9][a-z0-9_+#.-]{0,31}$/i.test(hint)) return hint.toLowerCase();
        }
        return null;
    };
    const collect = (article, output, quote = false, skip = null) => {
        let buffer = '';
        const append = (kind, text, url = null) => output.push({ kind, text, url });
        const flush = (kind = quote ? 'quote' : 'text') => {
            if (buffer.trim()) append(kind, buffer.trim());
            buffer = '';
        };
        const inline = node => {
            if (node.nodeType === Node.TEXT_NODE) return escape(node.textContent.replace(/\s+/g, ' '));
            if (node.nodeType !== Node.ELEMENT_NODE || excluded(node)) return '';
            const tag = node.tagName;
            if (tag === 'BR') return '\n';
            if (tag === 'IMG') {
                flush();
                const url = safeURL(node.getAttribute('data-src') || node.getAttribute('src'), true);
                if (url) output.push({kind:node.classList.contains('sticker') ? 'sticker' : 'image',
                    text:node.alt || '帖子图片', url, imageSize:imageSize(node, url)});
                else if (node.alt) append('text', escape(node.alt));
                return '';
            }
            let value = '';
            for (const child of node.childNodes) {
                if (child.nodeType === Node.ELEMENT_NODE && (child.tagName === 'IMG' || child.querySelector('img'))) {
                    buffer += value;
                    value = '';
                }
                value += inline(child);
            }
            if (!value.trim()) return value;
            const trimmed = value.trim();
            let decorated = trimmed;
            if (tag === 'A') {
                const url = safeURL(node.getAttribute('href'));
                if (url) decorated = `[${trimmed}](<${url.replace(/&/g, '&amp;').replace(/[<>]/g, v => encodeURIComponent(v))}>)`;
            } else if (tag === 'STRONG' || tag === 'B') decorated = `**${trimmed}**`;
            else if (tag === 'EM' || tag === 'I') decorated = `*${trimmed}*`;
            else if (tag === 'S' || tag === 'DEL') decorated = `~~${trimmed}~~`;
            else if (tag === 'CODE' && !trimmed.includes('`')) decorated = '`' + plain(node) + '`';
            return value.replace(trimmed, () => decorated);
        };
        const appendInline = node => {
            const value = inline(node);
            buffer += value;
        };
        const walk = node => {
            if (node.nodeType === Node.TEXT_NODE) { appendInline(node); return; }
            if (node.nodeType !== Node.ELEMENT_NODE) return;
            if (terminalRoot(node)) {
                if (!terminalVisible(node)) return;
                flush();
                const raw = markdownText(node) || capturedText(node);
                if (raw) { append('terminal', raw); return; }
                const terminal = drawnRows(node);
                if (!terminal) { append('terminalUnavailable', ''); return; }
                const lines = [...terminal.children].map(row => {
                    const spans = [...row.querySelectorAll(':scope > span')];
                    if (!spans.length) return [{text:row.textContent, bold:false}];
                    return spans.map(span => {
                        const style = getComputedStyle(span);
                        const background = style.backgroundColor;
                        const declared = span.style.color || ([...span.classList].some(name => name.startsWith('xterm-fg-')) ? style.color : null);
                        return {text:span.textContent, foreground:declared,
                            background:background === 'rgba(0, 0, 0, 0)' ? null : background,
                            bold:span.classList.contains('xterm-bold')};
                    });
                });
                if (lines.length) output.push({kind:'terminal', text:'', terminal:lines});
                return;
            }
            if (excluded(node) && !inactiveTerminalPane(node)) return;
            if (node.matches('.nsk-magic-tabs')) {
                flush();
                const tabs = [];
                for (const label of node.children) {
                    if (!label.matches('.nsk-magic-tab-title')) continue;
                    const pane = label.nextElementSibling;
                    if (!pane?.matches('.nsk-magic-tab-body')) continue;
                    if (excluded(pane) && !inactiveTerminalPane(pane)) continue;
                    const blocks = [];
                    collect(pane, blocks);
                    tabs.push({label:plain(label), blocks});
                }
                if (tabs.length) output.push({kind:'tabs', text:'', tabs});
                return;
            }
            switch (node.tagName) {
                case 'PRE': {
                    flush();
                    const code = node.querySelector('code') || node;
                    const text = terminalCodeText(code).replace(/\n$/, '');
                    const pane = node.closest('.nsk-magic-tab-body');
                    const hint = /ansi|terminal|xterm/i.test(node.className + ' ' + code.className) ||
                        /基本信息|IP质量/i.test(pane?.previousElementSibling?.textContent ?? '');
                    const isTerminal = explicitANSI(code) || ansiReport(text, hint);
                    if (isTerminal) {
                        if (terminalVisible(node)) append('terminal', text);
                    } else {
                        output.push({kind:'code', text, language:codeLanguage(code, node)});
                    }
                    break;
                }
                case 'BLOCKQUOTE': flush(); collect(node, output, true); break;
                case 'TABLE': {
                    flush();
                    const caption = plain(node.querySelector('caption'));
                    if (caption) append('text', escape(caption));
                    const rows = [...node.rows].map(row => [...row.cells].map(cell => plain(cell)));
                    if (rows.length) output.push({kind:'table', text:'', rows});
                    break;
                }
                case 'HR': flush(); append('rule', ''); break;
                case 'UL': case 'OL': {
                    flush();
                    const children = [...node.children].filter(item =>
                        item.tagName === 'LI' && getComputedStyle(item).display !== 'none');
                    const integer = value => {
                        const raw = value?.trim() ?? '';
                        const number = /^[+-]?\d+$/.test(raw) ? Number(raw) : NaN;
                        return Number.isSafeInteger(number) ? number : null;
                    };
                    const ordered = node.tagName === 'OL';
                    const step = ordered && node.hasAttribute('reversed') ? -1 : 1;
                    let counter = integer(node.getAttribute('start')) ?? (step < 0 ? children.length : 1);
                    const items = [];
                    for (const item of children) {
                        if (ordered) counter = integer(item.getAttribute('value')) ?? counter;
                        if (!excluded(item)) {
                            const blocks = [];
                            collect(item, blocks, quote);
                            items.push({marker:ordered ? `${counter}.` : '•', blocks});
                        }
                        counter += step;
                    }
                    if (items.length) output.push({kind:'list', text:'', items});
                    break;
                }
                case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6':
                    flush(); appendInline(node); flush('heading'); break;
                case 'DETAILS': {
                    flush();
                    const summary = node.querySelector(':scope > summary');
                    const blocks = [];
                    collect(node, blocks, quote, summary);
                    output.push({kind:'disclosure', text:plain(summary) || '展开内容', tabs:[{label:'', blocks}]});
                    break;
                }
                case 'P': case 'DIV': case 'SECTION': case 'SUMMARY':
                    flush(); for (const child of node.childNodes) walk(child); flush(); break;
                default: appendInline(node);
            }
        };
        if (article) for (const child of article.childNodes) if (child !== skip) walk(child);
        flush();
    };
    const signatureText = blocks => blocks.map(block => {
        if (block.kind === 'text') return block.text;
        if (block.kind !== 'list') return '';
        return block.items.map(item => {
            const text = signatureText(item.blocks);
            const indent = ' '.repeat(item.marker.length + 1);
            return item.marker + (text ? ' ' + text.replace(/\n/g, '\n' + indent) : '');
        }).join('\n');
    }).filter(Boolean).join('\n');
    const floor = item => {
        const meta = item.querySelector(':scope > .nsk-content-meta-info');
        const avatar = meta?.querySelector('.avatar-wrapper img');
        const time = meta?.querySelector('time');
        const blocks = [];
        collect(item.querySelector(':scope > .post-content'), blocks);
        const warning = item.querySelector(':scope > .topic-warning');
        if (warning && !excluded(warning) && plain(warning)) blocks.push({kind:'notice', text:plain(warning),url:null});
        const author = meta?.querySelector('.author-name');
        const authorID = Number(author?.getAttribute('href')?.match(/^\/space\/(\d+)$/)?.[1]) || null;
        const tags = [...(meta?.querySelectorAll('.author-info .role-tag:not(.is-poster)') || [])].map(plain).filter(Boolean);
        const avatarURL = safeURL(avatar?.getAttribute('data-src'), true) || safeURL(avatar?.getAttribute('src'), true) ||
            (authorID ? safeURL(`/avatar/${authorID}.png`, true) : null);
        const menu = item.querySelector(':scope > .comment-menu');
        const reaction = title => menu?.querySelector('[title="' + title + '"]');
        const count = title => {
            const value = plain(reaction(title));
            return /^\d+$/.test(value) ? Number(value) : null;
        };
        const signature = [];
        collect(item.querySelector(':scope > .signature, :scope > .user-signature'), signature);
        return { id:item.id, author:plain(author), authorID, tags, isAuthor:item.id === '0' || Boolean(meta?.querySelector('.is-poster')), avatar:avatarURL,
                 date:time?.getAttribute('title') || '', dateLabel:plain(time), blocks,
                 signature:signatureText(signature) || null,
                 likes:count('点赞'), chicken:count('加鸡腿'), dislikes:count('反对'),
                 upvoted:reaction('点赞')?.classList.contains('clicked') ?? null,
                 gaveChicken:reaction('加鸡腿')?.classList.contains('clicked') ?? null,
                 downvoted:reaction('反对')?.classList.contains('clicked') ?? null };
    };
    const postId = current?.[1];
    const pages = new Map();
    for (const link of main.querySelectorAll('[aria-label="pagination"] a[href], .pagination a[href]')) {
        const url = safeURL(link.getAttribute('href'));
        if (!url) continue;
        const parsed = new URL(url);
        const route = /^\/post-(\d+)-(\d+)\/?$/.exec(parsed.pathname);
        if (!route || route[1] !== postId || parsed.protocol !== 'https:' || !allowed.has(parsed.hostname)) continue;
        const number = Number(route[2]);
        pages.set(number, {number, url});
    }
    const badges = [...title.closest('h1').querySelectorAll('span')].map(plain);
    const restriction = badges.find(text => /^(只读|已锁定|禁止回复)$/.test(text));
    const category = root?.querySelector('.content-category a')?.getAttribute('href')?.split('/').pop() || '';
    return JSON.stringify({title:plain(title) || document.title, category, root:root && (!requested || requested === '0') ? floor(root) : null,
        replies:commentItems.filter(item => !requested || item.id === requested).map(floor),
        pages:[...pages.values()].sort((a,b)=>a.number-b.number),page,replyRestriction:restriction || null});
    """#

    static let reply = #"""
    const route = /^\/post-(\d+)-\d+\/?$/.exec(location.pathname);
    if (location.protocol !== 'https:' || !['www.nodeseek.com','nodeseek.com'].includes(location.host) ||
        !route || Number(route[1]) !== postId || !document.querySelector('.nsk-post-wrapper .post-title-link')) {
        return JSON.stringify({ kind:'unavailable' });
    }
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    const requestID = Array.from(crypto.getRandomValues(new Uint8Array(16)), value => alphabet[value % alphabet.length]).join('');
    try {
        const result = await fetch('/api/content/new-comment', {
            method: 'POST', credentials: 'same-origin', redirect: 'error', signal: AbortSignal.timeout(20000),
            headers: {'Content-Type':'application/json', 'csrf-token':requestID},
            body: JSON.stringify({postId, content, mode:'new-comment'})
        });
        if (result.headers.get('cf-mitigated') === 'challenge') return JSON.stringify({kind:'verification'});
        if (result.status === 401) return JSON.stringify({kind:'signIn'});
        const data = await result.json().catch(() => null);
        if (typeof data?.success === 'boolean') return JSON.stringify({kind:'response', response:{
            success:result.ok && data.success,
            redirect:typeof data.redirect === 'string' ? data.redirect : null,
            redirectHash:typeof data.redirectHash === 'string' || typeof data.redirectHash === 'number' ? String(data.redirectHash) : null,
            message:typeof data.message === 'string' ? data.message : null
        }});
        if (result.status === 403) return JSON.stringify({kind:'forbidden'});
        return JSON.stringify({kind:'unknown'});
    } catch { return JSON.stringify({kind:'unknown'}); }
    """#
}

enum ForumTerminalANSI {
    // Clipboard and exported Markdown can contain either the control byte or its printed form.
    private static let sgr = try! NSRegularExpression(pattern: #"(?:(?:\x1b|\\(?:x1b|u001b|033))?\[|\x{009B})([0-9;:]*)m"#, options: .caseInsensitive)
    private static let colors: [String] = [
        "rgb(31,35,42)", "rgb(224,108,117)", "rgb(152,195,121)", "rgb(229,192,123)",
        "rgb(97,175,239)", "rgb(198,120,221)", "rgb(86,182,194)", "rgb(229,232,237)",
        "rgb(123,133,148)", "rgb(255,126,133)", "rgb(181,229,140)", "rgb(255,219,149)",
        "rgb(129,195,255)", "rgb(223,155,246)", "rgb(114,220,232)", "rgb(251,252,255)"
    ]

    static func lines(_ input: String) -> [[ForumTerminalSpan]] {
        // Swift treats CRLF as one Character. Normalize it before splitting so
        // a Windows line ending cannot become a printable control or overwrite.
        let normalized = input.utf8.contains(13) ? input.replacingOccurrences(of: "\r\n", with: "\n") : input
        var style = Style()
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            let source = line as NSString
            var cursor = 0
            var output: [ForumTerminalSpan] = []
            for match in sgr.matches(in: line, range: NSRange(location: 0, length: source.length)) {
                if match.range.location > cursor {
                    output.append(style.span(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
                }
                let args = match.range(at: 1)
                let fields = source.substring(with: args).split(separator: ";", omittingEmptySubsequences: false)
                let parameters = fields.flatMap { field -> [Int] in
                    guard field.contains(":") else { return [Int(field) ?? 0] }
                    let parts = field.split(separator: ":", omittingEmptySubsequences: false)
                    if parts.count >= 5, parts[1] == "2" {
                        return Array(parts.prefix(2) + parts.suffix(3)).map { Int($0) ?? 0 }
                    }
                    return parts.map { Int($0) ?? 0 }
                }
                style.apply(parameters.isEmpty ? [0] : parameters)
                cursor = NSMaxRange(match.range)
            }
            if cursor < source.length { output.append(style.span(source.substring(from: cursor))) }
            // Ordinary reports retain the existing span-only path. A cell grid
            // is needed only when the input actually changes the inline cursor.
            return line.utf8.contains(where: { $0 == 8 || $0 == 9 || $0 == 13 }) ? composedLine(output) : output
        }
    }

    /// A bounded static-report model: BS moves one column, CR returns to column
    /// zero, and HT advances to an eight-column stop. LF starts another line.
    /// It intentionally does not emulate arbitrary CSI cursor motion, erase,
    /// scrolling or terminal modes. Ambiguous-width characters use one column;
    /// CJK/fullwidth and emoji presentation use two. A partial overwrite clears
    /// the whole old wide glyph, filling the untouched half with the new style.
    private static func composedLine(_ spans: [ForumTerminalSpan]) -> [ForumTerminalSpan] {
        struct Cell {
            var text: String
            let style: Style
            let width: Int // zero is the continuation of a two-column glyph
        }
        let text = spans.map(\.text).joined()
        guard !text.isEmpty else { return [] }
        var cells: [Cell] = []
        var column = 0
        var spanIndex = 0
        var spanEnd = spans[0].text.utf8.count
        var offset = 0

        func glyphStart(at index: Int) -> Int {
            cells[index].width == 0 && index > 0 ? index - 1 : index
        }

        for character in text {
            while offset >= spanEnd && spanIndex + 1 < spans.count {
                spanIndex += 1
                spanEnd += spans[spanIndex].text.utf8.count
            }
            let source = spans[spanIndex]
            let style = Style(foreground: source.foreground, background: source.background, bold: source.bold)
            let glyph = String(character)
            offset += glyph.utf8.count
            switch character {
            case "\u{0008}": column = max(0, column - 1); continue
            case "\r": column = 0; continue
            case "\t": column += 8 - column % 8; continue
            default: break
            }

            let width = columnWidth(character)
            if width == 0 {
                // A mark separated from its base by a cursor control may only
                // attach to an existing preceding cell, never form a new column.
                if column > 0 && column <= cells.count {
                    let start = glyphStart(at: column - 1)
                    cells[start].text.append(character)
                }
                continue
            }
            let blank = Cell(text: " ", style: style, width: 1)
            while cells.count < column + width { cells.append(blank) }
            for target in column..<(column + width) {
                let start = glyphStart(at: target)
                if cells[start].width == 2 {
                    cells[start] = blank
                    cells[start + 1] = blank
                }
            }
            cells[column] = Cell(text: glyph, style: style, width: width)
            if width == 2 { cells[column + 1] = Cell(text: "", style: style, width: 0) }
            column += width
        }

        var result: [ForumTerminalSpan] = []
        var activeStyle: Style?
        var buffer = ""
        for cell in cells where cell.width > 0 {
            if activeStyle != cell.style {
                if let activeStyle, !buffer.isEmpty { result.append(activeStyle.span(buffer)) }
                activeStyle = cell.style
                buffer = ""
            }
            buffer += cell.text
        }
        if let activeStyle, !buffer.isEmpty { result.append(activeStyle.span(buffer)) }
        return result
    }

    private static func columnWidth(_ character: Character) -> Int {
        let scalars = Array(character.unicodeScalars)
        let visible = scalars.filter {
            switch $0.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark, .format: false
            default: true
            }
        }
        if visible.isEmpty { return 0 }
        // Whole-string graphemes are used after SGR removal, so combining text
        // and emoji ZWJ sequences remain intact even across style boundaries.
        let textPresentation = scalars.contains { $0.value == 0xFE0E }
        if !textPresentation && (scalars.contains { $0.properties.isEmojiPresentation } ||
            (scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 } &&
                scalars.contains { $0.properties.isEmoji })) { return 2 }
        if visible.contains(where: { scalar in
            switch scalar.value {
            case 0x1100...0x115F, 0x2329...0x232A, 0x2E80...0x303E, 0x3040...0xA4CF,
                 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F,
                 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD: true
            default: false
            }
        }) { return 2 }
        return 1
    }

    private struct Style: Equatable {
        var foreground: String?
        var background: String?
        var bold = false

        func span(_ text: String) -> ForumTerminalSpan {
            ForumTerminalSpan(text: text, foreground: foreground, background: background, bold: bold)
        }

        mutating func apply(_ parameters: [Int]) {
            var index = 0
            while index < parameters.count {
                let code = parameters[index]
                switch code {
                case 0: self = Style()
                case 1: bold = true
                case 22: bold = false
                case 30...37: foreground = colors[code - 30]
                case 39: foreground = nil
                case 40...47: background = colors[code - 40]
                case 49: background = nil
                case 90...97: foreground = colors[code - 82]
                case 100...107: background = colors[code - 92]
                case 38, 48:
                    if index + 2 < parameters.count && parameters[index + 1] == 5 {
                        let color = Self.indexedColor(parameters[index + 2])
                        if code == 38 { foreground = color } else { background = color }
                        index += 2
                    } else if index + 4 < parameters.count && parameters[index + 1] == 2 {
                        let rgb = parameters[(index + 2)...(index + 4)].map { min(255, max(0, $0)) }
                        let color = "rgb(\(rgb[0]),\(rgb[1]),\(rgb[2]))"
                        if code == 38 { foreground = color } else { background = color }
                        index += 4
                    }
                default: break
                }
                index += 1
            }
        }

        private static func indexedColor(_ index: Int) -> String? {
            if colors.indices.contains(index) { return colors[index] }
            if (16...231).contains(index) {
                let cube = index - 16
                let scale = [0, 95, 135, 175, 215, 255]
                return "rgb(\(scale[cube / 36]),\(scale[(cube / 6) % 6]),\(scale[cube % 6]))"
            }
            if (232...255).contains(index) {
                let value = 8 + (index - 232) * 10
                return "rgb(\(value),\(value),\(value))"
            }
            return nil
        }
    }
}
