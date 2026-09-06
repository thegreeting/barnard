// Use of this source code is governed by a BSD-style license.

import Foundation

/// Everything the device-lab orchestrator reads comes through here.
///
/// The contract is line oriented on stdout: one JSON object per engine event,
/// plus plain `BARNARD_MACHOST_*` marker lines, and exactly one `RESULT=` line
/// as the last thing printed. stdout is set line buffered because the
/// orchestrator backgrounds this process with stdout redirected to a file,
/// where the C library would otherwise buffer 4 KiB at a time and the markers
/// would not appear until exit.
final class LabReporter {
  private let logHandle: FileHandle?

  init(logPath: String?) {
    setvbuf(stdout, nil, _IOLBF, 0)

    guard let logPath else {
      logHandle = nil
      return
    }
    let manager = FileManager.default
    if !manager.fileExists(atPath: logPath) {
      manager.createFile(atPath: logPath, contents: nil)
    }
    logHandle = FileHandle(forWritingAtPath: logPath)
    try? logHandle?.truncate(atOffset: 0)
  }

  /// Prints a JSON line for an engine event. The `--log` file receives the
  /// JSON lines only; markers and `RESULT=` stay on stdout, which is what the
  /// orchestrator greps.
  func emitJson(_ payload: [String: Any]) {
    let line = Self.encode(payload)
    print(line)
    if let logHandle, let data = (line + "\n").data(using: .utf8) {
      logHandle.write(data)
    }
  }

  func emitMarker(_ line: String) {
    print(line)
  }

  /// The last line of every run, on every exit path.
  func emitResult(_ verdict: String, _ detail: String) {
    print("RESULT=\(verdict) \(detail)")
    try? logHandle?.close()
  }

  private static func encode(_ payload: [String: Any]) -> String {
    // A non-encodable value would throw inside JSONSerialization, and losing
    // an event line is worse for the orchestrator than a degraded one.
    guard JSONSerialization.isValidJSONObject(payload),
      let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    else {
      let type = (payload["type"] as? String) ?? "unknown"
      return "{\"type\":\"\(type)\",\"encodeFailed\":true}"
    }
    return text
  }
}
