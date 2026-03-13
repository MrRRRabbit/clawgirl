// DebugLog.swift
// Clawgirl
//
// 文件用途：全局调试日志工具，同时输出到控制台和 /tmp/clawd_tts_debug.log
// 独立文件避免被 ChatManager.swift 中的 @MainActor 推断污染

import Foundation

/// 调试日志文件写入器：封装 FileHandle，标记为 @unchecked Sendable 以允许跨隔离域访问
/// FileHandle 启动时创建，仅追加写入
final class DebugLogWriter: @unchecked Sendable {
    static let shared = DebugLogWriter()
    private let fileHandle: FileHandle?

    private init() {
        let logPath = "/tmp/clawd_tts_debug.log"
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: logPath)
    }

    func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        fileHandle?.seekToEndOfFile()
        fileHandle?.write(data)
    }
}

/// 全局调试日志函数：带时间戳输出到控制台和日志文件
/// - Parameter msg: 日志内容
nonisolated func debugLog(_ msg: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(ts)] \(msg)\n"
    print(line, terminator: "")
    DebugLogWriter.shared.write(line)
}
