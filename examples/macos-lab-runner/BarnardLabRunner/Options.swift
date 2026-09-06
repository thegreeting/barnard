// Use of this source code is governed by a BSD-style license.

import Foundation

/// Role the runner plays on the radio for this run.
enum LabRole: String {
  case advertise
  case scan
  case auto
}

/// Parsed command line. Every value has a default, so `run.sh` with no
/// arguments is a valid rendezvous run.
struct LabOptions {
  var eventCode: String = "BND"
  var role: LabRole = .auto
  var relayEnabled: Bool = false
  var expectPeers: Int = 1
  var timeoutSeconds: Double = 120
  var logPath: String?

  static let usage = """
    usage: BarnardLabRunner [options]
      --event-code <code>        event code to join (default: BND)
      --role advertise|scan|auto radio role (default: auto)
      --relay on|off             spec 134 participant relay (default: off)
      --expect-peers <n>         distinct peers required to pass (default: 1)
      --timeout <seconds>        run duration before giving up (default: 120)
      --log <path>               tee the JSON event lines to this file
    """

  /// Throws `LabOptionsError` rather than exiting, so the caller can print
  /// `RESULT=ERROR` as the last line on the argument-error path too.
  static func parse(_ arguments: [String]) throws -> LabOptions {
    var options = LabOptions()
    var index = 0

    func value(for flag: String) throws -> String {
      index += 1
      guard index < arguments.count else {
        throw LabOptionsError.missingValue(flag)
      }
      return arguments[index]
    }

    while index < arguments.count {
      let flag = arguments[index]
      switch flag {
      case "--event-code":
        options.eventCode = try value(for: flag)
      case "--role":
        let raw = try value(for: flag)
        guard let role = LabRole(rawValue: raw) else {
          throw LabOptionsError.badValue(flag, raw)
        }
        options.role = role
      case "--relay":
        let raw = try value(for: flag)
        switch raw {
        case "on": options.relayEnabled = true
        case "off": options.relayEnabled = false
        default: throw LabOptionsError.badValue(flag, raw)
        }
      case "--expect-peers":
        let raw = try value(for: flag)
        guard let parsed = Int(raw), parsed >= 0 else {
          throw LabOptionsError.badValue(flag, raw)
        }
        options.expectPeers = parsed
      case "--timeout":
        let raw = try value(for: flag)
        guard let parsed = Double(raw), parsed > 0 else {
          throw LabOptionsError.badValue(flag, raw)
        }
        options.timeoutSeconds = parsed
      case "--log":
        options.logPath = try value(for: flag)
      case "-h", "--help":
        throw LabOptionsError.helpRequested
      default:
        throw LabOptionsError.unknownFlag(flag)
      }
      index += 1
    }

    guard !options.eventCode.isEmpty else {
      throw LabOptionsError.badValue("--event-code", "")
    }
    return options
  }

  /// `--log` read straight off the raw argument list.
  ///
  /// The reporter has to exist before parsing, because an argument error still
  /// has to print a `RESULT=` line, and full parsing cannot happen before the
  /// reporter exists without ordering the two the other way round. A hint read
  /// is enough: a malformed `--log` simply produces no log file.
  static func logPathHint(_ arguments: [String]) -> String? {
    guard let flagIndex = arguments.firstIndex(of: "--log"),
      arguments.index(after: flagIndex) < arguments.endIndex
    else {
      return nil
    }
    return arguments[arguments.index(after: flagIndex)]
  }
}

enum LabOptionsError: Error, CustomStringConvertible {
  case unknownFlag(String)
  case missingValue(String)
  case badValue(String, String)
  case helpRequested

  var description: String {
    switch self {
    case .unknownFlag(let flag): return "unknown flag \(flag)"
    case .missingValue(let flag): return "\(flag) needs a value"
    case .badValue(let flag, let raw): return "\(flag) does not accept \(raw.isEmpty ? "an empty value" : raw)"
    case .helpRequested: return "help requested"
    }
  }
}
