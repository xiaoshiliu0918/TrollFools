//
//  TempHome.swift
//  TrollFools
//
//  Minimal temp-injection launcher:
//  permanent plugin stash + one-tap game launch with auto inject & auto restore.
//

import SwiftUI
import UIKit
import CoreServices
import UniformTypeIdentifiers

// MARK: - Alert item (iOS 14 compatible)

struct TempAlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Game Targets

struct GameTarget {
    let buttonTitle: String
    let emoji: String
    /// keywords matched against plugin file names in the stash
    let pluginKeywords: [String]
    /// keywords matched against installed app display names
    let appNameKeywords: [String]
    /// optional hard-coded bundle identifier (checked first)
    let fixedBundleID: String?

    static let wzry = GameTarget(
        buttonTitle: "启动王者荣耀",
        emoji: "👑",
        pluginKeywords: ["王者", "王者荣耀", "wzry", "smoba"],
        appNameKeywords: ["王者", "smoba"],
        fixedBundleID: "com.tencent.smoba"
    )

    static let dnf = GameTarget(
        buttonTitle: "启动地下城与勇士",
        emoji: "⚔️",
        pluginKeywords: ["地下城", "dnf", "DNF"],
        appNameKeywords: ["地下城", "dnf", "DNF"],
        fixedBundleID: nil
    )
}

// MARK: - Stash

final class StashManager {
    static let shared = StashManager()

    static var stashRootURL: URL {
        // 必须解析符号链接：iOS 上 /var 是 /private/var 的软链，
        // 目录枚举器返回的是 /private/var/... 形态；若根仍是 /var/...，
        // "根前缀剔除"会错位，把绝对路径后缀（如 "ts/插件导入"、"s/Stash"）
        // 当成相对路径 → 双向同步产生嵌套污染。
        URL(fileURLWithPath: "/var/mobile/Library/TrollFools/Stash")
            .resolvingSymlinksInPath()
    }

    /// 导入结果：新导入 / 覆盖更新 / 同名同大小跳过。
    enum ImportOutcome {
        case imported
        case updated
        case skipped
    }

    // MARK: 双向镜像快照
    // 「插件导入」文件夹 ⇄ 暂存箱 双向同步的状态依据：
    /// iOS 文件 App 复制重名文件时会自动生成 "Name (2).ext" / "Name(2).ext"。
    /// 把这类名字折叠回 "Name.ext"，避免同一插件因重复复制产生多个副本。
    static func normalizedPluginName(_ rawName: String) -> String {
        let nsName = rawName as NSString
        let ext = nsName.pathExtension
        let base = nsName.deletingPathExtension
        if let range = base.range(of: #"\s*\(\d+\)\s*$"#, options: .regularExpression) {
            let stripped = String(base[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty {
                return ext.isEmpty ? stripped : "\(stripped).\(ext)"
            }
        }
        return rawName
    }

    static func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
    }

    func ensureStash() {
        try? FileManager.default.createDirectory(
            at: Self.stashRootURL, withIntermediateDirectories: true
        )
    }

    /// All plugin files currently in the stash (dylib / framework / bundle).
    func listPlugins() -> [URL] {
        ensureStash()
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: Self.stashRootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return urls
            .filter { $0.lastPathComponent != ".DS_Store" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Import one file into the stash (dedup version).
    /// - 同名且同大小的文件已在暂存箱 → .skipped（不覆盖、不重复导入）
    /// - 同名但内容不同 → 覆盖更新 → .updated
    /// - 新文件 → .imported
    /// - "Name(2).ext" 这类文件 App 复制副本名会被折叠回 "Name.ext"
    @discardableResult
    func importPluginDedup(from src: URL) throws -> (name: String, outcome: ImportOutcome) {
        ensureStash()
        let fm = FileManager.default
        let name = Self.normalizedPluginName(src.lastPathComponent)
        let dst = Self.stashRootURL.appendingPathComponent(name)

        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        let srcSize = Self.fileSize(of: src)

        // 暂存箱已有同名且同大小的文件：跳过
        if fm.fileExists(atPath: dst.path), srcSize >= 0 {
            let dstSize = Self.fileSize(of: dst)
            if dstSize == srcSize {
                return (name, .skipped)
            }
        }

        let hadExisting = fm.fileExists(atPath: dst.path)
        if hadExisting {
            try? fm.removeItem(at: dst)
        }

        var reasons: [String] = []

        // Strategy 1: direct copy
        if !fm.fileExists(atPath: dst.path) {
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                reasons.append("copy:\(error.localizedDescription)")
            }
        }

        // Strategy 2: byte-level read then write
        if !fm.fileExists(atPath: dst.path) {
            do {
                let data = try Data(contentsOf: src)
                if data.isEmpty {
                    reasons.append("read:文件内容为空")
                } else {
                    try data.write(to: dst, options: .atomic)
                }
            } catch {
                reasons.append("read:\(error.localizedDescription)")
            }
        }

        // Verify
        guard fm.fileExists(atPath: dst.path) else {
            throw NSError(
                domain: "StashImport", code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "所有方式均失败（\(reasons.joined(separator: "；"))）。源路径：\(src.path)"]
            )
        }

        // 成功导入，保持镜像状态一致（无墓碑机制，删除由双向同步处理）
        return (name, hadExisting ? .updated : .imported)
    }

    /// Import one file into the stash. Returns the stored file name.
    /// (兼容旧调用点；内部走去重逻辑)
    @discardableResult
    func importPlugin(from src: URL) throws -> String {
        try importPluginDedup(from: src).name
    }

    /// 从暂存箱删除插件。
    /// 「插件导入」文件夹里的同名文件由双向同步负责删除。
    /// 从暂存箱删除插件。暂存箱是「插件导入」文件夹的单向镜像，
    /// 因此同时删除文件夹里的对应文件（同相对路径），否则下次同步又会被收回来。
    func removePlugin(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        let root = Self.stashRootURL.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(root) else { return }
        let rel = String(path.dropFirst(root.count))
        let mirror = ImportEngine.importFolderURL.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: mirror.path) {
            try? FileManager.default.removeItem(at: mirror)
        }
    }

    // MARK: 深度列举（支持子文件夹分类）

    /// 暂存箱/导入文件夹内的一项（文件或目录），relPath 相对根目录，
    /// 例如 "DNF.dylib"、"王者荣耀/DNF.dylib"。
    struct DeepItem {
        let relPath: String
        let url: URL
        let isDirectory: Bool
    }

    /// 递归列举目录下所有文件与子目录（跳过点文件），按相对路径排序。
    func listDeep(at root: URL? = nil) -> [DeepItem] {
        let rootURL = (root ?? Self.stashRootURL).resolvingSymlinksInPath()
        ensureStash()
        let fm = FileManager.default
        let rootPath = rootURL.path
        var result: [DeepItem] = []
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }
            var path = url.path
            if !path.hasPrefix(rootPath + "/") {
                path = url.resolvingSymlinksInPath().path
            }
            guard path.hasPrefix(rootPath + "/") else {
                enumerator.skipDescendants()
                continue
            }
            let rel = String(path.dropFirst(rootPath.count + 1))
            if rel.isEmpty { continue }
            let isDir = ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
            result.append(DeepItem(relPath: rel, url: url, isDirectory: isDir))
        }
        result.sort { $0.relPath.localizedStandardCompare($1.relPath) == .orderedAscending }
        return result
    }

    /// 只列出「插件条目」：dylib/zip/deb 文件与 .framework/.bundle 目录。
    /// 插件 bundle（.framework/.bundle）内部的文件不单独列出；
    /// 分类子文件夹（非插件目录）本身也不是条目。
    func listPluginItems(at root: URL? = nil) -> [DeepItem] {
        listDeep(at: root).filter { item in
            if item.isDirectory {
                let ext = (item.url.lastPathComponent as NSString).pathExtension.lowercased()
                return Self.pluginBundleExtensions.contains(ext)
            }
            // 文件：扩展名须为插件类型，且不在插件 bundle 内部
            let ext = (item.url.lastPathComponent as NSString).pathExtension.lowercased()
            guard Self.pluginFileExtensions.contains(ext) else { return false }
            let ancestors = item.relPath.split(separator: "/").dropLast().map(String.init)
            return !ancestors.contains {
                Self.pluginBundleExtensions.contains((($0 as NSString).pathExtension.lowercased()))
            }
        }
    }

    /// 某插件文件所属的分类名（暂存箱根下的第一级子文件夹名；根目录文件 = 未分类）。
    static func category(ofPluginAt url: URL) -> String {
        let root = stashRootURL.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(root) else { return "未分类" }
        let rel = String(path.dropFirst(root.count))
        let parts = rel.split(separator: "/")
        return parts.count > 1 ? String(parts[0]) : "未分类"
    }

    // MARK: 插件类型判定
    // 只有这些类型会被当作插件：dylib / framework / bundle / zip / deb。
    // 分类子文件夹仅用于归类，其内部仍只收上述类型；
    // 其他任意文件（txt/png 等）不参与同步、不进暂存箱。

    static let pluginFileExtensions: Set<String> = ["dylib", "zip", "deb"]
    static let pluginBundleExtensions: Set<String> = ["framework", "bundle"]

    /// 判断一个相对路径是否为插件（或插件 bundle 内部的组成部分）。
    /// - 顶层/任意层级文件：扩展名为 dylib/zip/deb
    /// - .framework / .bundle 目录本身及其内部所有内容
    static func isPluginPath(_ rel: String) -> Bool {
        let parts = rel.split(separator: "/").map(String.init)
        guard let last = parts.last else { return false }
        // 位于插件 bundle 内部 → 属于插件的一部分
        if parts.count > 1 {
            let ancestors = parts.dropLast()
            if ancestors.contains(where: {
                pluginBundleExtensions.contains((($0 as NSString).pathExtension.lowercased()))
            }) {
                return true
            }
        }
        let ext = (last as NSString).pathExtension.lowercased()
        return pluginFileExtensions.contains(ext) || pluginBundleExtensions.contains(ext)
    }

    /// Plugins whose file name (only the file itself, not its category
    /// folder path) contains any of the keywords.
    /// 分类文件夹仅用于视觉归类，不参与一键启动匹配；匹配只看插件文件名。
    func plugins(matching keywords: [String]) -> [URL] {
        listPluginItems().filter { item in
            let name = item.url.lastPathComponent.lowercased()
            return keywords.contains { name.contains($0.lowercased()) }
        }.map { $0.url }
    }
}

// MARK: - Import Engine (multi-channel, always visible on screen)

final class ImportEngine: ObservableObject {

    static let shared = ImportEngine()

    /// On-screen log lines, newest last. Rendered in the UI so results are
    /// always visible even if system alerts fail to present.
    @Published var logs: [String] = []
    @Published var notice: TempAlertItem?

    private func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    func log(_ line: String) {
        DispatchQueue.main.async {
            self.logs.append("[\(self.stamp())] \(line)")
            if self.logs.count > 40 {
                self.logs.removeFirst(self.logs.count - 40)
            }
        }
    }

    /// Import a batch of files. Safe to call from anywhere.
    func importURLs(_ urls: [URL], source: String, showAlert: Bool = true) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var ok: [String] = []
            var skipped: [String] = []
            var failures: [String] = []
            let fm = FileManager.default
            for url in urls {
                do {
                    // 一切以「插件导入」文件夹为准：外部导入（共享接收等）
                    // 先落进导入文件夹，再由单向同步收进暂存箱
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let name = StashManager.normalizedPluginName(url.lastPathComponent)
                    let dst = Self.importFolderURL.appendingPathComponent(name)
                    if fm.fileExists(atPath: dst.path) {
                        let oldSize = StashManager.fileSize(of: dst)
                        let newSize = StashManager.fileSize(of: url)
                        if oldSize >= 0, oldSize == newSize {
                            skipped.append(name)
                            continue
                        }
                        try? fm.removeItem(at: dst)
                    }
                    try fm.copyItem(at: url, to: dst)
                    ok.append(name)
                } catch {
                    failures.append("\(url.lastPathComponent)\n\(error.localizedDescription)")
                }
            }
            if !ok.isEmpty || !skipped.isEmpty {
                self.syncImportFolder()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                for name in ok {
                    self.log("✅ \(source)：已导入 \(name)")
                }
                for name in skipped {
                    self.log("♻️ \(source)：\(name) 已在暂存箱，跳过")
                }
                for failure in failures {
                    self.log("❌ \(source)：\(failure)")
                }
                if showAlert {
                    if !failures.isEmpty {
                        self.notice = TempAlertItem(title: "导入失败", message: failures.joined(separator: "\n\n"))
                    } else if !ok.isEmpty {
                        var msg = ok.joined(separator: ", ")
                        if !skipped.isEmpty {
                            msg += "\n\n已存在跳过：\(skipped.joined(separator: ", "))"
                        }
                        self.notice = TempAlertItem(title: "已添加插件", message: msg)
                    } else if !skipped.isEmpty {
                        self.notice = TempAlertItem(title: "插件已存在", message: skipped.joined(separator: ", "))
                    }
                }
            }
        }
    }

    /// The user-visible import folder inside our own Documents, exposed via
    /// UIFileSharingEnabled so it shows up in the Files app
    /// (固定路径：/var/mobile/Documents/插件导入).
    static var importFolderURL: URL {
        // 用户明确要求：导入文件夹固定为 /var/mobile/Documents/插件导入。
        // TrollStore 环境下 app 以 mobile 身份运行，可直接读写该全局目录；
        // 用户在文件 App / Filza 里往这里放插件、建分类文件夹，app 据此双向同步。
        // 若该位置不可写（非 TrollStore 安装），退回应用沙盒 Documents/插件导入。
        let fm = FileManager.default
        let preferred = URL(fileURLWithPath: "/var/mobile/Documents/插件导入", isDirectory: true)
            .resolvingSymlinksInPath()
        try? fm.createDirectory(at: preferred, withIntermediateDirectories: true)
        if fm.isWritableFile(atPath: preferred.path) {
            return preferred
        }
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("插件导入", isDirectory: true)
            .resolvingSymlinksInPath()
    }

    static func ensureImportFolder() {
        try? FileManager.default.createDirectory(
            at: importFolderURL, withIntermediateDirectories: true
        )
    }

    /// 「插件导入」文件夹 → 暂存箱 **单向**镜像同步（递归，支持子文件夹分类）。
    /// ★ 一切以 /var/mobile/Documents/插件导入 为准：
    ///   - 文件夹里有 → 暂存箱必须有（内容不同以文件夹覆盖）
    ///   - 文件夹里没有 → 暂存箱删除（app 内的内容绝不回灌进文件夹）
    ///   - 文件夹里的分类目录 → 暂存箱同步创建（空分类也建）
    /// - 只同步插件类型（dylib/zip/deb 文件与 .framework/.bundle 目录）
    /// - 文件 App 复制副本 "DNF(2).dylib" 自动并入正本 "DNF.dylib"（按目录内处理）
    /// - force = true（手动按钮）：忽略大小比对，全部重新复制一遍
    func syncImportFolder(force: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            Self.ensureImportFolder()
            StashManager.shared.ensureStash()

            let folderURL = Self.importFolderURL
            let stashURL = StashManager.stashRootURL

            // 递归扫描一侧：返回 relPath → URL 的文件表 + 目录集合。
            // 双保险：枚举器返回的路径若与根前缀对不上（符号链接解析差异），
            // 先尝试标准化对齐；仍对不上则连同子树整体跳过，绝不生成碎片相对路径。
            func scan(_ root: URL, otherRoot: URL) -> (files: [String: URL], dirs: Set<String>) {
                var files: [String: URL] = [:]
                var dirs = Set<String>()
                let rootPath = root.resolvingSymlinksInPath().path
                let otherPath = otherRoot.resolvingSymlinksInPath().path
                guard let enumerator = fm.enumerator(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey]
                ) else { return (files, dirs) }
                for case let url as URL in enumerator {
                    let name = url.lastPathComponent
                    if name.hasPrefix(".") {
                        enumerator.skipDescendants()
                        continue
                    }
                    var path = url.path
                    if !path.hasPrefix(rootPath + "/") {
                        path = url.resolvingSymlinksInPath().path
                    }
                    guard path.hasPrefix(rootPath + "/") else {
                        enumerator.skipDescendants() // 路径形态对不上：整棵子树跳过
                        continue
                    }
                    if path.hasPrefix(otherPath + "/") {
                        enumerator.skipDescendants() // 对端根嵌套在本端内：整体跳过，防止互拷
                        continue
                    }
                    let rel = String(path.dropFirst(rootPath.count + 1))
                    if rel.isEmpty { continue }
                    let isDir = ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
                    if isDir { dirs.insert(rel) } else { files[rel] = url }
                }
                return (files, dirs)
            }

            var folderScan = scan(folderURL, otherRoot: stashURL)
            var stashScan = scan(stashURL, otherRoot: folderURL)

            // ── Step A-：清理历史版本遗留的"相对路径碎片"污染 ──
            // 症状：目录里出现 "ts/插件导入/…"、"s/Stash/…" 这类嵌套
            // （绝对路径后缀被当成相对路径复制）。凡相对路径里含系统目录名
            // 组件（插件导入/Documents/Library/TrollFools/Stash/…）即视为污染，
            // 两侧一并删除；随后清空同步快照并重新扫描（快照为空只做补齐，不误删）。
            let pollutionNames: Set<String> = [
                "插件导入", "Documents", "Library", "TrollFools",
                "Stash", "private", "var", "mobile",
            ]
            func isPolluted(_ rel: String) -> Bool {
                rel.split(separator: "/").contains { pollutionNames.contains(String($0)) }
            }
            var cleanedCount = 0
            for (rootURL, scanResult) in [(folderURL, folderScan), (stashURL, stashScan)] {
                var removedPrefixes: [String] = []
                for rel in Set(scanResult.files.keys).union(scanResult.dirs).sorted() {
                    guard isPolluted(rel),
                          !removedPrefixes.contains(where: { rel.hasPrefix($0 + "/") }) else { continue }
                    try? fm.removeItem(at: rootURL.appendingPathComponent(rel))
                    removedPrefixes.append(rel)
                    cleanedCount += 1
                }
            }
            if cleanedCount > 0 {
                self.log("🧹 已清理路径污染残留 \(cleanedCount) 项（历史版本相对路径错位导致）")
                // 重新扫描，保证后续步骤基于干净状态
                folderScan = scan(folderURL, otherRoot: stashURL)
                stashScan = scan(stashURL, otherRoot: folderURL)
            }

            var folderFiles = folderScan.files
            let folderDirs = folderScan.dirs
            var stashFiles = stashScan.files
            let stashDirs = stashScan.dirs

            // ── Step A0：类型过滤——只有插件类型（dylib/zip/deb 文件与
            // .framework/.bundle 目录及其内部）参与同步。
            // 用户放在导入文件夹里的其他文件（笔记/图片等）保持原样，不进暂存箱。
            folderFiles = folderFiles.filter { StashManager.isPluginPath($0.key) }
            stashFiles = stashFiles.filter { StashManager.isPluginPath($0.key) }

            // 暂存箱里不应该有非插件文件（可能是历史版本同步进去的残留），清掉
            for (rel, url) in stashScan.files where !StashManager.isPluginPath(rel) {
                try? fm.removeItem(at: url)
                self.log("🧹 已清理暂存箱内的非插件文件 \(rel)")
            }

            // ── Step A：每个目录内做文件 App 复制副本规范化（DNF(2).dylib → DNF.dylib）──
            let folderByParent = Dictionary(grouping: folderFiles.keys) {
                ($0 as NSString).deletingLastPathComponent
            }
            for (parent, paths) in folderByParent {
                for path in paths.sorted() {
                    let raw = (path as NSString).lastPathComponent
                    let norm = StashManager.normalizedPluginName(raw)
                    guard norm != raw else { continue }
                    let normRel = parent.isEmpty ? norm : parent + "/" + norm
                    if let twinURL = folderFiles[normRel] {
                        // 正本存在：大小相同 → 副本是重复复制产生的，删除
                        let s1 = StashManager.fileSize(of: folderFiles[path]!)
                        let s2 = StashManager.fileSize(of: twinURL)
                        if s1 >= 0, s1 == s2 {
                            try? fm.removeItem(at: folderFiles[path]!)
                            folderFiles.removeValue(forKey: path)
                            self.log("♻️ 已合并重复副本 \(path) → \(normRel)")
                        }
                        // 大小不同 → 视为不同版本，保留原名当独立插件
                    } else {
                        // 没有正本：直接改名为正本名
                        let dstURL = folderURL.appendingPathComponent(normRel)
                        try? fm.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if (try? fm.moveItem(at: folderFiles[path]!, to: dstURL)) != nil {
                            folderFiles.removeValue(forKey: path)
                            folderFiles[normRel] = dstURL
                        }
                    }
                }
            }

            // ── Step B：单向镜像——一切以「插件导入」文件夹为准 ──
            var imported: [String] = []
            var updated: [String] = []
            var removed: [String] = []

            for rel in folderFiles.keys.sorted() {
                let src = folderFiles[rel]!
                let dst = stashURL.appendingPathComponent(rel)
                let existing = stashFiles[rel]
                let needCopy: Bool
                if let s = existing {
                    let fs = StashManager.fileSize(of: src)
                    let ss = StashManager.fileSize(of: s)
                    needCopy = force || fs < 0 || fs != ss
                } else {
                    needCopy = true
                }
                guard needCopy else { continue }
                do {
                    try? fm.createDirectory(
                        at: dst.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
                    try fm.copyItem(at: src, to: dst)
                    if existing == nil { imported.append(rel) } else { updated.append(rel) }
                } catch {
                    self.log("❌ 同步：\(rel) \(error.localizedDescription)")
                }
            }

            // 暂存箱里多出来的文件 = 文件夹里已不存在 → 删除（以文件夹为准，不回灌）
            for rel in stashFiles.keys where folderFiles[rel] == nil {
                try? fm.removeItem(at: stashURL.appendingPathComponent(rel))
                removed.append(rel)
            }

            // 目录对齐：文件夹里的目录 → 暂存箱同步创建（空分类也建）；
            // 暂存箱多出来的目录（含残留空分类）→ 删除
            for rel in folderDirs.sorted() {
                let dst = stashURL.appendingPathComponent(rel, isDirectory: true)
                if !fm.fileExists(atPath: dst.path) {
                    try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
                }
            }
            for rel in stashDirs.sorted() where !folderDirs.contains(rel) {
                // 其内容已在上一步按文件级清空，这里移除目录本身
                try? fm.removeItem(at: stashURL.appendingPathComponent(rel, isDirectory: true))
            }

            if !imported.isEmpty || !updated.isEmpty || !removed.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if !imported.isEmpty {
                        self.log("✅ 同步：已导入 \(imported.joined(separator: ", "))")
                    }
                    if !updated.isEmpty {
                        self.log("🔄 同步：已更新 \(updated.joined(separator: ", "))")
                    }
                    if !removed.isEmpty {
                        self.log("🗑 同步：已移除 \(removed.joined(separator: ", "))")
                    }
                    if !imported.isEmpty || !updated.isEmpty {
                        let names = (imported + updated).joined(separator: ", ")
                        self.notice = TempAlertItem(title: "同步完成", message: names)
                    }
                }
            }
        }
    }
}

// MARK: - Process kill helper

private func killRunningApp(bid: String) {
    guard let proxy = LSApplicationProxy(forIdentifier: bid),
          let bundleURL = proxy.bundleURL()
    else { return }
    guard let info = CFBundleCopyInfoDictionaryForURL(bundleURL as CFURL) as? [String: Any],
          let execName = info["CFBundleExecutable"] as? String
    else { return }
    // p_comm is truncated to 15 chars
    let comm = String(execName.prefix(15))
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return }
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
    guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return }
    let count = size / MemoryLayout<kinfo_proc>.stride
    for index in 0..<count {
        let name = withUnsafeBytes(of: procs[index].kp_proc.p_comm) { rawBuffer -> String in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return ""
            }
            return String(cString: base)
        }
        if name == comm {
            kill(procs[index].kp_proc.p_pid, SIGKILL)
        }
    }
}

// MARK: - Injector orchestration

final class GameInjector: ObservableObject {

    static let shared = GameInjector()

    @Published var isWorking = false
    @Published var statusText: String = ""

    /// Resolve target app: fixed bid first, then display-name match.
    private func resolveApp(_ target: GameTarget) -> (bid: String, url: URL)? {
        if let bid = target.fixedBundleID,
           let proxy = LSApplicationProxy(forIdentifier: bid),
           let url = proxy.bundleURL() {
            return (bid, url)
        }
        let installed = LSApplicationWorkspace.default().allApplications() ?? []
        for kw in target.appNameKeywords {
            if let hit = installed.first(where: { proxy in
                (proxy.localizedName() ?? "").contains(kw) && proxy.bundleURL() != nil
            }) {
                guard let bid = hit.applicationIdentifier(), let url = hit.bundleURL() else { continue }
                return (bid, url)
            }
        }
        return nil
    }

    /// 通用临时注入：对任意 App 注入指定插件列表，然后跳转。
    /// - Parameters:
    ///   - appName: 用于日志与提示的显示名。
    ///   - bid: 目标 App 的 bundle identifier。
    ///   - bundleURL: 目标 App 的 bundle URL。
    ///   - plugins: 要注入的插件文件列表。
    func injectAndLaunch(appName: String, bid: String, bundleURL: URL, plugins: [URL]) {
        guard !isWorking else { return }
        isWorking = true
        statusText = "正在处理…"
        let engine = ImportEngine.shared
        engine.log("🚀 \(appName)：开始处理")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let names = plugins.map { $0.lastPathComponent }.joined(separator: ", ")
            engine.log("🩺 目标 App：\(bid)")
            engine.log("💉 注入 \(plugins.count) 个插件：\(names)…")

            DispatchQueue.main.async { self.statusText = "正在加载 \(plugins.count) 个插件…" }

            // 1. kill the app if running (inject requires it not running)
            killRunningApp(bid: bid)
            Thread.sleep(forTimeInterval: 0.5)

            // 2. inject (non-persistent)
            do {
                let injector = try InjectorV3(bundleURL, loggerType: .os)
                try injector.inject(plugins, shouldPersist: false)
                engine.log("✅ 注入完成")

                // 3. record session + spawn detached watchdog
                let manager = TempInjectManager.shared
                try manager.writeState(bid: bid, assetURLs: plugins)
                try manager.spawnWatchdog(bid: bid)
                engine.log("🐕 看门狗已启动（退出后自动还原）")

                // 4. jump to the app
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let launched = manager.launchApp(bid: bid)
                    engine.log(launched ? "📲 跳转指令已发送" : "⚠️ 跳转指令发送失败，请手动打开")
                    if !launched {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            let retry = manager.launchApp(bid: bid)
                            engine.log(retry ? "📲 重试跳转成功" : "❌ 重试跳转仍失败，请手动打开")
                        }
                    }
                }
                self.finish(success: "插件已加载，正在打开 \(appName)。退出后插件自动移除。")
            } catch {
                engine.log("❌ 注入失败：\(error.localizedDescription)")
                self.finish(alertOnly: "加载失败：\(error.localizedDescription)")
            }
        }
    }

    func injectAndLaunch(_ target: GameTarget, stash: StashManager = .shared) {
        guard !isWorking else { return }
        isWorking = true
        statusText = "正在处理…"
        let engine = ImportEngine.shared
        engine.log("🚀 \(target.buttonTitle)：开始处理")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 1. resolve app
            guard let targetApp = self.resolveApp(target) else {
                engine.log("❌ 未找到已安装的目标 App")
                self.finish(alertOnly: "未找到「\(target.buttonTitle.replacingOccurrences(of: "启动", with: ""))」对应的已安装 App，请确认游戏已安装。")
                return
            }
            let bid = targetApp.bid
            let bundleURL = targetApp.url
            engine.log("🩺 目标 App：\(bid)")

            // 2. resolve plugins
            let plugins = stash.plugins(matching: target.pluginKeywords)
            guard !plugins.isEmpty else {
                engine.log("❌ 暂存箱无匹配插件（关键词：\(target.pluginKeywords.joined(separator: "/"))）")
                self.finish(alertOnly: "暂存箱中没有匹配「\(target.buttonTitle.replacingOccurrences(of: "启动", with: ""))」的插件。\n请先把对应的 dylib 放入暂存箱（文件名需包含“\(target.appNameKeywords.first ?? "")”）再试。")
                return
            }
            let names = plugins.map { $0.lastPathComponent }.joined(separator: ", ")
            engine.log("💉 匹配到 \(plugins.count) 个插件：\(names)，开始注入…")

            DispatchQueue.main.async { self.statusText = "正在加载 \(plugins.count) 个插件…" }

            // 3. kill the game if running (inject requires it not running)
            killRunningApp(bid: bid)
            Thread.sleep(forTimeInterval: 0.5)

            // 4. inject (non-persistent)
            do {
                let injector = try InjectorV3(bundleURL, loggerType: .os)
                try injector.inject(plugins, shouldPersist: false)
                engine.log("✅ 注入完成")

                // 5. record session + spawn detached watchdog
                let manager = TempInjectManager.shared
                try manager.writeState(bid: bid, assetURLs: plugins)
                try manager.spawnWatchdog(bid: bid)
                engine.log("🐕 看门狗已启动（退出游戏后自动还原）")

                // 6. jump to the game
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let launched = manager.launchApp(bid: bid)
                    engine.log(launched ? "📲 跳转指令已发送" : "⚠️ 跳转指令发送失败，请手动打开游戏")
                    if !launched {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            let retry = manager.launchApp(bid: bid)
                            engine.log(retry ? "📲 重试跳转成功" : "❌ 重试跳转仍失败，请手动打开游戏")
                        }
                    }
                }
                self.finish(success: "插件已加载，正在打开游戏。退出游戏后插件自动移除。")
            } catch {
                engine.log("❌ 注入失败：\(error.localizedDescription)")
                self.finish(alertOnly: "加载失败：\(error.localizedDescription)")
            }
        }
    }

    private func finish(alertOnly message: String) {
        DispatchQueue.main.async {
            self.isWorking = false
            self.statusText = ""
            ImportEngine.shared.notice = TempAlertItem(title: "提示", message: message)
        }
    }

    private func finish(success message: String) {
        DispatchQueue.main.async {
            self.isWorking = false
            self.statusText = ""
            ImportEngine.shared.notice = TempAlertItem(title: "完成", message: message)
        }
    }
}

// MARK: - Liquid Glass (极简白玻璃 · 深色/浅色自适应)

/// 极简玻璃材质卡片：深色模式叠暗色玻璃，浅色模式叠通透白玻璃，
/// 带斜向高光模拟 iOS 26 液态玻璃的折射质感。
/// iOS 15+ 用 ultraThinMaterial 高斯模糊，iOS 14 退化为纯半透明。
private struct LiquidGlassCard: ViewModifier {

    var cornerRadius: CGFloat = 22
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        if #available(iOS 15.0, *) {
            content
                .background(
                    ZStack {
                        // 主玻璃层：半透明 + 高斯模糊
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill((isDark ? Color.black : Color.white).opacity(isDark ? 0.42 : 0.55))
                            .background(.ultraThinMaterial)
                        // 斜向高光：模拟玻璃边缘的折射反光
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        (isDark ? Color.white : Color.white).opacity(isDark ? 0.16 : 0.8),
                                        Color.clear,
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        // 描边
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                (isDark ? Color.white : Color.white).opacity(isDark ? 0.14 : 0.9),
                                lineWidth: 0.8
                            )
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            // iOS 14：无 Material，退化为纯半透明 + 高光 + 描边
            content
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill((isDark ? Color.black : Color.white).opacity(isDark ? 0.55 : 0.72))
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color.white.opacity(isDark ? 0.12 : 0.9),
                                        Color.clear,
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                Color.white.opacity(isDark ? 0.12 : 0.9),
                                lineWidth: 0.8
                            )
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

private extension View {
    func liquidGlass(cornerRadius: CGFloat = 22) -> some View {
        modifier(LiquidGlassCard(cornerRadius: cornerRadius))
    }
}

/// 玻璃页面上使用的一节标题（深色小字）
private struct GlassSectionTitle: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.footnote)
            .fontWeight(.medium)
            .foregroundColor(
                colorScheme == .dark ? Color.white.opacity(0.55) : Color.black.opacity(0.5)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
            .padding(.top, 18)
            .padding(.bottom, 8)
    }
}

// MARK: - Target Selection (跨 Tab 共享已选目标应用)

/// 跨 Tab 共享的「当前已选目标应用」状态。
final class TargetSelection: ObservableObject {
    static let shared = TargetSelection()

    @Published var selectedApp: App?

    private init() {}
}

// MARK: - 收藏置顶 (收藏的 App 自动排最前)

/// 收藏的 App（bundle id）集合，用 UserDefaults 持久化。
/// 收藏的应用在「应用」列表中自动置顶，方便快速找到常用目标。
final class FavoriteApps: ObservableObject {

    static let shared = FavoriteApps()

    private static let defaultsKey = "shiliu.favoriteApps"

    @Published private(set) var bundleIDs: Set<String>

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        bundleIDs = Set(stored)
    }

    func isFavorite(_ bid: String) -> Bool {
        bundleIDs.contains(bid)
    }

    func toggle(_ bid: String) {
        if bundleIDs.contains(bid) {
            bundleIDs.remove(bid)
        } else {
            bundleIDs.insert(bid)
        }
        UserDefaults.standard.set(Array(bundleIDs), forKey: Self.defaultsKey)
    }
}

// MARK: - 液态玻璃背景（共享）

/// 液态玻璃背景：浅色暖粉+淡蓝径向渐变，深色近黑+暗色光晕，制造「玻璃后有东西在流动」的液态感。
private struct LiquidGlassBackground: View {

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if colorScheme == .dark {
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(red: 0.08, green: 0.08, blue: 0.11),
                            Color(red: 0.05, green: 0.05, blue: 0.08),
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    RadialGradient(
                        gradient: Gradient(colors: [Color(red: 1.0, green: 0.55, blue: 0.35).opacity(0.30), .clear]),
                        center: UnitPoint(x: 0.15, y: 0.05),
                        startRadius: 0,
                        endRadius: geo.size.width * 0.9
                    )
                    RadialGradient(
                        gradient: Gradient(colors: [Color(red: 0.35, green: 0.50, blue: 1.0).opacity(0.25), .clear]),
                        center: UnitPoint(x: 0.9, y: 0.85),
                        startRadius: 0,
                        endRadius: geo.size.width * 0.9
                    )
                } else {
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(red: 0.96, green: 0.95, blue: 0.97),
                            Color(red: 0.91, green: 0.90, blue: 0.94),
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    RadialGradient(
                        gradient: Gradient(colors: [Color(red: 1.0, green: 0.72, blue: 0.60).opacity(0.55), .clear]),
                        center: UnitPoint(x: 0.15, y: 0.05),
                        startRadius: 0,
                        endRadius: geo.size.width * 0.9
                    )
                    RadialGradient(
                        gradient: Gradient(colors: [Color(red: 0.55, green: 0.70, blue: 1.0).opacity(0.45), .clear]),
                        center: UnitPoint(x: 0.9, y: 0.85),
                        startRadius: 0,
                        endRadius: geo.size.width * 0.9
                    )
                }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Home View (底部三栏：应用 / 注入 / 暂存箱)

struct TempHomeView: View {

    @StateObject private var injector = GameInjector.shared
    @ObservedObject private var engine = ImportEngine.shared
    @State private var selectedTab = 0

    var body: some View {
        NavigationView {
            TabView(selection: $selectedTab) {
                // 首项：应用（选择目标进程）
                AppTabView()
                    .tabItem {
                        Label("应用", systemImage: "square.grid.2x2.fill")
                    }
                    .tag(0)

                // 中间项：注入（选插件并注入）
                InjectTabView()
                    .tabItem {
                        Label("注入", systemImage: "syringe.fill")
                    }
                    .tag(1)

                // 第三项：暂存箱
                StashTabView()
                    .tabItem {
                        Label("暂存箱", systemImage: "shippingbox.fill")
                    }
                    .tag(2)
            }
            .accentColor(.orange)
            .onAppear {
                Self.configureTabBarAppearance()
                // cleanupOrphans may synchronously run a full restore via the
                // CLI; keep it off the main thread to avoid blocking the UI.
                DispatchQueue.global(qos: .utility).async {
                    TempInjectManager.shared.cleanupOrphans()
                }
                ImportEngine.shared.syncImportFolder()
            }
            .onOpenURL { url in
                // Receive files shared in from Files app / WeChat "open in" etc.
                ImportEngine.shared.log("📩 收到共享文件：\(url.lastPathComponent)")
                ImportEngine.shared.importURLs([url], source: "共享")
            }
            .alert(item: $engine.notice) { item in
                Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("好")))
            }
        }
        .navigationViewStyle(.stack)
    }

    /// 底部 Tab 栏：iOS 原生 dock 式磨砂效果（systemChromeMaterial），无顶部分割线。
    private static func configureTabBarAppearance() {
        if #available(iOS 15.0, *) {
            let appearance = UITabBarAppearance()
            // 系统原生磨砂背景（与 dock 同材质）
            appearance.configureWithDefaultBackground()
            // 去掉顶部分割线，更贴近 dock 观感
            appearance.shadowColor = .clear
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
        // iOS 14：TabView 默认自带系统磨砂，无需额外配置
    }

    // MARK: 首项 · 应用

    struct AppTabView: View {

        @StateObject private var appList = AppListModel()
        @StateObject private var targetSelection = TargetSelection.shared
        @StateObject private var favorites = FavoriteApps.shared
        @State private var searchText = ""
        @Environment(\.colorScheme) private var colorScheme

        private var filteredApps: [App] {
            let apps = appList.activeScopeApps.values.flatMap { $0 }
            let filtered = searchText.isEmpty
                ? apps
                : apps.filter {
                    $0.name.localizedCaseInsensitiveContains(searchText)
                        || $0.bid.localizedCaseInsensitiveContains(searchText)
                }
            // 收藏的排最前，其余按名称稳定排序
            // （Dictionary.values 顺序不稳定，且 Swift sort 非稳定，必须给出确定性的平局规则）
            return filtered.sorted { a, b in
                let aFav = favorites.isFavorite(a.bid)
                let bFav = favorites.isFavorite(b.bid)
                if aFav != bFav { return aFav }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }

        var body: some View {
            NavigationView {
                ZStack {
                    LiquidGlassBackground()

                    VStack(spacing: 0) {
                        // 搜索栏（始终显示，不受列表状态影响）
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField("搜索 App 名称或 bundle id", text: $searchText)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            if !searchText.isEmpty {
                                Button {
                                    searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(12)
                        .background(
                            (colorScheme == .dark ? Color.black : Color.white).opacity(colorScheme == .dark ? 0.4 : 0.7)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                        ScrollView {
                            if filteredApps.isEmpty {
                                // 空态：区分「搜索无结果」和「确实没有可注入 App」
                                VStack(spacing: 8) {
                                    if !searchText.isEmpty {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 28))
                                            .foregroundColor(.secondary.opacity(0.6))
                                        Text("没有找到「\(searchText)」相关的 App")
                                            .font(.body)
                                            .foregroundColor(.secondary)
                                        Text("换个关键词试试，或点搜索框右侧 ✕ 清空搜索。")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 40)
                                    } else {
                                        Text("没有可注入的 App")
                                            .font(.body)
                                            .foregroundColor(.secondary)
                                        Text("请确认 App 已安装，且为可注入类型（App Store / 巨魔商店应用）。")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 40)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 80)
                            } else {
                                LazyVStack(spacing: 0) {
                                    ForEach(filteredApps, id: \.bid) { app in
                                        let isSelected = targetSelection.selectedApp?.bid == app.bid
                                        let isFav = favorites.isFavorite(app.bid)
                                        HStack(spacing: 12) {
                                            // 点主体选为目标应用
                                            Button {
                                                targetSelection.selectedApp = app
                                            } label: {
                                                HStack(spacing: 12) {
                                                    Image(uiImage: app.icon ?? UIImage())
                                                        .resizable()
                                                        .frame(width: 40, height: 40)
                                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                                    VStack(alignment: .leading, spacing: 2) {
                                                        HStack(spacing: 4) {
                                                            Text(app.name)
                                                                .font(.body)
                                                                .fontWeight(.medium)
                                                                .foregroundColor(.primary)
                                                                .lineLimit(1)
                                                            if isFav {
                                                                Image(systemName: "star.fill")
                                                                    .font(.system(size: 12))
                                                                    .foregroundColor(.orange)
                                                            }
                                                        }
                                                        Text(app.bid)
                                                            .font(.caption)
                                                            .foregroundColor(.secondary)
                                                            .lineLimit(1)
                                                    }
                                                    Spacer()
                                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                        .font(.system(size: 22))
                                                        .foregroundColor(isSelected ? .orange : .secondary.opacity(0.4))
                                                }
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(PlainButtonStyle())

                                            // 收藏/取消收藏星标按钮
                                            Button {
                                                favorites.toggle(app.bid)
                                            } label: {
                                                Image(systemName: isFav ? "star.fill" : "star")
                                                    .font(.system(size: 20))
                                                    .foregroundColor(isFav ? .orange : .secondary.opacity(0.45))
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                        }
                                        .padding(14)
                                        .liquidGlass()
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                        }
                    }
                }
                .navigationBarTitleDisplayMode(.large)
                .navigationTitle("应用")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        if let app = targetSelection.selectedApp {
                            Text("已选：\(app.name)")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationViewStyle(.stack)
        }
    }

    // MARK: 中间项 · 注入

    struct InjectTabView: View {

        @StateObject private var injector = GameInjector.shared
        @StateObject private var targetSelection = TargetSelection.shared
        @ObservedObject private var engine = ImportEngine.shared
        @State private var plugins: [URL] = []
        @State private var groups: [(category: String, items: [StashManager.DeepItem])] = []
        @State private var collapsed: Set<String> = []
        @State private var selected: Set<String> = []

        var body: some View {
            NavigationView {
                ZStack {
                    LiquidGlassBackground()

                    ScrollView {
                        VStack(spacing: 0) {
                            // 已选目标应用
                            GlassSectionTitle(text: "目标应用")

                            if let app = targetSelection.selectedApp {
                                HStack(spacing: 12) {
                                    Image(uiImage: app.icon ?? UIImage())
                                        .resizable()
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(app.name)
                                            .font(.body)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Text(app.bid)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundColor(.orange)
                                }
                                .padding(16)
                                .liquidGlass()
                            } else {
                                HStack(spacing: 12) {
                                    Image(systemName: "square.grid.2x2")
                                        .font(.system(size: 20))
                                        .foregroundColor(.secondary)
                                    Text("尚未选择目标应用，请先到「应用」页选择")
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(16)
                                .liquidGlass()
                            }

                            // 选择插件
                            HStack(alignment: .bottom) {
                                GlassSectionTitle(text: "选择要注入的插件（可多选）")
                                Spacer()
                                if !plugins.isEmpty {
                                    Button(selected.count == plugins.count ? "清空" : "全选") {
                                        if selected.count == plugins.count {
                                            selected.removeAll()
                                        } else {
                                            selected = Set(plugins.map { $0.absoluteString })
                                        }
                                    }
                                    .font(.footnote)
                                    .foregroundColor(.orange)
                                    .padding(.bottom, 8)
                                    .padding(.trailing, 10)
                                }
                            }

                            if plugins.isEmpty {
                                HStack(spacing: 12) {
                                    Image(systemName: "shippingbox")
                                        .font(.system(size: 20))
                                        .foregroundColor(.secondary)
                                    Text("暂存箱暂无插件，请先到「暂存箱」页导入")
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(16)
                                .liquidGlass()
                            } else {
                                // 按分类分组展示，与暂存箱一致；点分组标题展开/收起
                                VStack(spacing: 12) {
                                    ForEach(groups, id: \.category) { group in
                                        VStack(spacing: 0) {
                                            // 分组标题（可点折叠）
                                            Button {
                                                toggleCollapsed(group.category)
                                            } label: {
                                                HStack(spacing: 10) {
                                                    Image(systemName: collapsed.contains(group.category) ? "chevron.right" : "chevron.down")
                                                        .font(.caption.weight(.semibold))
                                                        .foregroundColor(.secondary)
                                                        .frame(width: 14)
                                                    Image(systemName: "folder.fill")
                                                        .font(.caption)
                                                        .foregroundColor(.orange)
                                                    Text(group.category)
                                                        .font(.subheadline)
                                                        .fontWeight(.semibold)
                                                        .foregroundColor(.primary)
                                                    Spacer()
                                                    Text("\(group.items.count) 个")
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                }
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 12)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(PlainButtonStyle())

                                            if !collapsed.contains(group.category) {
                                                ForEach(Array(group.items.enumerated()), id: \.element.relPath) { index, item in
                                                    let url = item.url
                                                    let isSelected = selected.contains(url.absoluteString)
                                                    Button {
                                                        if isSelected {
                                                            selected.remove(url.absoluteString)
                                                        } else {
                                                            selected.insert(url.absoluteString)
                                                        }
                                                    } label: {
                                                        HStack(spacing: 12) {
                                                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                                .font(.system(size: 22))
                                                                .foregroundColor(isSelected ? .orange : .secondary.opacity(0.5))
                                                            Image(systemName: "shippingbox.fill")
                                                                .font(.system(size: 16))
                                                                .foregroundColor(.orange)
                                                            VStack(alignment: .leading, spacing: 2) {
                                                                Text(url.lastPathComponent)
                                                                    .font(.body)
                                                                    .fontWeight(.medium)
                                                                    .foregroundColor(.primary)
                                                                    .lineLimit(1)
                                                                Text(url.pathExtension.uppercased())
                                                                    .font(.caption2)
                                                                    .foregroundColor(.secondary)
                                                            }
                                                            Spacer()
                                                        }
                                                        .padding(14)
                                                    }
                                                    .buttonStyle(PlainButtonStyle())
                                                    if index < group.items.count - 1 {
                                                        Divider()
                                                            .padding(.leading, 16)
                                                    }
                                                }
                                            }
                                        }
                                        .liquidGlass()
                                    }
                                }
                            }

                            // 注入按钮
                            Button {
                                startInjection()
                            } label: {
                                HStack {
                                    Spacer()
                                    if injector.isWorking {
                                        ProgressView()
                                            .padding(.trailing, 8)
                                    }
                                    Text(injectButtonTitle)
                                        .font(.body)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.white)
                                    Spacer()
                                }
                                .padding(.vertical, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(canInject ? Color.orange : Color.gray.opacity(0.4))
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(!canInject)
                            .padding(.top, 20)

                            // 运行日志
                            if !engine.logs.isEmpty {
                                GlassSectionTitle(text: "运行日志")

                                VStack(spacing: 0) {
                                    ForEach(Array(engine.logs.suffix(6).enumerated()), id: \.offset) { index, line in
                                        HStack(alignment: .top, spacing: 10) {
                                            Text(line)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(3)
                                                .multilineTextAlignment(.leading)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        if index < min(engine.logs.count, 6) - 1 {
                                            Divider()
                                                .padding(.leading, 16)
                                        }
                                    }
                                }
                                .liquidGlass()
                            }

                            Text("石榴动态注入 v1.0 · 基于 TrollFools")
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.7))
                                .frame(maxWidth: .infinity)
                                .padding(.top, 24)
                                .padding(.bottom, 24)
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .navigationBarTitleDisplayMode(.large)
                .navigationTitle("注入")
                .onAppear {
                    reloadPlugins()
                }
            }
            .navigationViewStyle(.stack)
        }

        // MARK: - 插件分组

        private static let collapsedKey = "shiliu.injectCollapsed"

        private func loadCollapsed() {
            let arr = UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? []
            collapsed = Set(arr)
        }

        private func toggleCollapsed(_ category: String) {
            if collapsed.contains(category) {
                collapsed.remove(category)
            } else {
                collapsed.insert(category)
            }
            UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedKey)
        }

        /// 刷新插件列表：按分类分组（与暂存箱一致），同时维护全选用的扁平数组。
        private func reloadPlugins() {
            loadCollapsed()
            let items = StashManager.shared.listPluginItems()
            plugins = items.map { $0.url }

            var byCategory: [String: [StashManager.DeepItem]] = [:]
            for item in items {
                let category = StashManager.category(ofPluginAt: item.url)
                byCategory[category, default: []].append(item)
            }
            groups = byCategory
                .sorted { lhs, rhs in
                    if (lhs.key == "未分类") != (rhs.key == "未分类") {
                        return rhs.key == "未分类" // 未分类永远排最后
                    }
                    return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
                }
                .map { (category: $0.key, items: $0.value) }
        }

        private var canInject: Bool {
            targetSelection.selectedApp != nil && !selected.isEmpty && !injector.isWorking
        }

        /// 注入按钮标题：根据当前状态动态变化。
        private var injectButtonTitle: String {
            if injector.isWorking {
                return injector.statusText
            }
            if targetSelection.selectedApp == nil {
                return "请先选择目标应用"
            }
            if selected.isEmpty {
                return "请选择要注入的插件"
            }
            return selected.count == 1 ? "注入并启动（1 个插件）" : "注入并启动（\(selected.count) 个插件）"
        }

        private func startInjection() {
            guard let app = targetSelection.selectedApp else { return }
            let urls = plugins.filter { selected.contains($0.absoluteString) }
            guard !urls.isEmpty else { return }
            let engine = ImportEngine.shared
            engine.log("⚡️ 临时注入：\(app.name) ← \(urls.count) 个插件")
            engine.log("   - \(urls.map { $0.lastPathComponent }.joined(separator: "\n   - "))")
            injector.injectAndLaunch(
                appName: app.name,
                bid: app.bid,
                bundleURL: app.url,
                plugins: urls
            )
        }
    }

    // MARK: 第三项 · 暂存箱

    struct StashTabView: View {

        var body: some View {
            NavigationView {
                StashView()
            }
            .navigationViewStyle(.stack)
        }
    }
}

// MARK: - Stash Page (permanent storage)

struct StashView: View {

    @ObservedObject private var engine = ImportEngine.shared
    @State private var groups: [(category: String, items: [StashManager.DeepItem])] = []
    @State private var collapsed: Set<String> = []
    @State private var isCreateCategoryPresented = false
    @State private var newCategoryName = ""

    private let stash = StashManager.shared

    var body: some View {
        List {
            Section(
                header: Text("暂存箱 = 「插件导入」文件夹的实时镜像"),
                footer: Text("同步目录：/var/mobile/Documents/插件导入（唯一权威）。app 每次刷新都按该目录镜像：文件夹里有什么，这里就显示什么；文件夹里删了，这里跟着删；文件夹里更新了，这里跟着更新。app 内的任何内容都不会被回灌进文件夹。点分组标题可展开/收起。在 app 内删除插件会同时删掉文件夹里的对应文件。只有 dylib / framework / bundle / zip / deb 会被当作插件；重复副本（如 DNF(2).dylib）自动并入 DNF.dylib。")
            ) {
                if groups.isEmpty {
                    Text("暂无插件。把 dylib / framework / zip / deb 放进「插件导入」文件夹即可自动同步到这里。")
                        .foregroundColor(.secondary)
                        .font(.footnote)
                } else {
                    ForEach(groups, id: \.category) { group in
                        Section(
                            header: Button {
                                toggleCollapsed(group.category)
                            } label: {
                                HStack {
                                    Image(systemName: collapsed.contains(group.category) ? "chevron.right" : "chevron.down")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundColor(.secondary)
                                        .frame(width: 14)
                                    Image(systemName: "folder.fill")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                    Text(group.category)
                                        .font(.footnote)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Text("\(group.items.count) 个")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        ) {
                            if !collapsed.contains(group.category) {
                                ForEach(group.items, id: \.relPath) { item in
                                    HStack {
                                        Image(systemName: "shippingbox.fill")
                                            .foregroundColor(.orange)
                                        Text(item.url.lastPathComponent)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                    }
                                }
                                .onDelete { indexSet in
                                    for index in indexSet {
                                        stash.removePlugin(group.items[index].url)
                                    }
                                    reload()
                                }
                            }
                        }
                    }
                }
            }

            Section(header: Text("导入")) {
                Button {
                    ImportEngine.shared.syncImportFolder(force: true)
                } label: {
                    Label("立即同步（以插件导入文件夹为准）", systemImage: "arrow.triangle.2.circlepath")
                }

                Button {
                    isCreateCategoryPresented = true
                } label: {
                    Label("新建分类文件夹", systemImage: "folder.badge.plus")
                }
            }

            if !engine.logs.isEmpty {
                Section(header: Text("导入日志")) {
                    ForEach(engine.logs.suffix(10), id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("暂存箱")
        .onAppear {
            loadCollapsed()
            reload()
            ImportEngine.shared.syncImportFolder()
        }
        .onChange(of: engine.logs.count) { _ in
            reload()
        }
        .alert(item: $engine.notice) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("好")))
        }
        .sheet(isPresented: $isCreateCategoryPresented) {
            NavigationView {
                Form {
                    Section(footer: Text("分类文件夹会在 /var/mobile/Documents/插件导入 目录下创建（暂存箱同步出现），之后把对应 dylib 拖进该文件夹即可自动归类。")) {
                        TextField("分类名称（如：王者荣耀）", text: $newCategoryName)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Button {
                            let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !name.isEmpty, name != ".", name != "..", !name.contains("/") {
                                let folderURL = ImportEngine.importFolderURL
                                    .appendingPathComponent(name, isDirectory: true)
                                try? FileManager.default.createDirectory(
                                    at: folderURL, withIntermediateDirectories: true
                                )
                                ImportEngine.shared.log("📁 已创建分类：\(name)")
                                ImportEngine.shared.syncImportFolder()
                                reload()
                            }
                            newCategoryName = ""
                            isCreateCategoryPresented = false
                        } label: {
                            Text("创建")
                                .fontWeight(.semibold)
                        }
                    }
                }
                .navigationTitle("新建分类")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            newCategoryName = ""
                            isCreateCategoryPresented = false
                        }
                    }
                }
            }
            .navigationViewStyle(.stack)
        }
    }

    // MARK: - Reload

    private static let collapsedKey = "shiliu.stashCollapsed"

    private func loadCollapsed() {
        let arr = UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? []
        collapsed = Set(arr)
    }

    private func toggleCollapsed(_ category: String) {
        if collapsed.contains(category) {
            collapsed.remove(category)
        } else {
            collapsed.insert(category)
        }
        UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedKey)
    }

    private func reload() {
        // 按分类分组：子文件夹名 = 分类名；根目录插件 = 未分类；空分类也显示。
        // 只把插件类型（dylib/zip/deb 文件与 .framework/.bundle 目录）当条目，
        // 插件 bundle 内部的文件不单独成行。
        let deep = stash.listDeep()
        var byCategory: [String: [StashManager.DeepItem]] = [:]
        var topLevelDirs = Set<String>()
        for item in deep {
            let ext = (item.url.lastPathComponent as NSString).pathExtension.lowercased()
            if item.isDirectory {
                if StashManager.pluginBundleExtensions.contains(ext) {
                    // .framework / .bundle 目录本身就是插件
                    let category = StashManager.category(ofPluginAt: item.url)
                    byCategory[category, default: []].append(item)
                } else if !item.relPath.contains("/") {
                    topLevelDirs.insert(item.relPath) // 顶层分类文件夹（可能为空）
                }
                continue
            }
            // 文件：仅插件扩展名，且不在插件 bundle 内部
            guard StashManager.pluginFileExtensions.contains(ext) else { continue }
            let ancestors = item.relPath.split(separator: "/").dropLast().map(String.init)
            guard !ancestors.contains(where: {
                StashManager.pluginBundleExtensions.contains((($0 as NSString).pathExtension.lowercased()))
            }) else { continue }
            let category = StashManager.category(ofPluginAt: item.url)
            byCategory[category, default: []].append(item)
        }
        for dir in topLevelDirs where byCategory[dir] == nil {
            byCategory[dir] = [] // 空分类也展示
        }
        groups = byCategory
            .sorted { lhs, rhs in
                if (lhs.key == "未分类") != (rhs.key == "未分类") {
                    return rhs.key == "未分类" // 未分类永远排最后
                }
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            .map { (category: $0.key, items: $0.value) }
    }
}
