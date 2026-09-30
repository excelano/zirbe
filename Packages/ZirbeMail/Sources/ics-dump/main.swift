// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Dump the raw iCalendar parts of recent messages to files, as parser fixtures.
// macOS only; not part of any app. Credentials come from the environment, never
// the command line or source, the way imap-demo takes them:
//
//   IMAP_HOST=outlook.office365.com \
//   IMAP_USER=you@example.com \
//   IMAP_PASS='app-specific-password' \
//   IMAP_MAILBOX=INBOX \
//   IMAP_LIMIT=200 \
//   ICS_OUT=./ics-dump \
//   swift run ics-dump
//
// Every `text/calendar` part (or an `.ics` file attachment) among the newest
// IMAP_LIMIT messages is written as `<uid>-<method>.ics`, redacted: email
// addresses become numbered placeholders that keep the domain, and CN= names
// become "Person N" matching them, so organizer and attendees stay distinct
// without naming anyone. Descriptions are left as they are; read each file
// before it enters the repo. With file paths as arguments the command only
// re-redacts those files in place, no IMAP:
//
//   swift run ics-dump ../../ics-dump/*.ics

import Foundation
import SwiftMail

func env(_ key: String) -> String? {
    guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
    return value
}

// Files on the command line: re-redact them in place and stop, no IMAP.
let files = Array(CommandLine.arguments.dropFirst())
if !files.isEmpty {
    for path in files {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write(Data("unreadable: \(path)\n".utf8))
            continue
        }
        try redact(text).write(toFile: path, atomically: true, encoding: .utf8)
        print("redacted \(path)")
    }
    exit(0)
}

guard let host = env("IMAP_HOST"), let user = env("IMAP_USER"), let pass = env("IMAP_PASS") else {
    FileHandle.standardError.write(Data("Missing required env: set IMAP_HOST, IMAP_USER, IMAP_PASS (see file header).\n".utf8))
    exit(2)
}
let mailbox = env("IMAP_MAILBOX") ?? "INBOX"
let port = env("IMAP_PORT").flatMap(Int.init) ?? 993
let limit = env("IMAP_LIMIT").flatMap(Int.init) ?? 200
let outDir = URL(fileURLWithPath: env("ICS_OUT") ?? "./ics-dump")

/// Redact a calendar body for use as a fixture. Lines are unfolded first so an
/// address split across a fold can't slip through, then re-folded at 75
/// octets as RFC 5545 asks, so the fixture still exercises folding. Every
/// email address becomes a numbered placeholder that keeps its domain, the
/// same placeholder for the same address, so organizer and attendees stay
/// distinct; every `CN=` name becomes "Person N" matching that placeholder. A
/// UID is left alone even when it looks like an address (Google's do), since
/// two meetings must never collapse into one identity.
func redact(_ text: String) -> String {
    let addressPattern = #"[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})"#
    guard let addresses = try? NSRegularExpression(pattern: addressPattern),
          let names = try? NSRegularExpression(pattern: #"CN=("[^"]*"|[^;:]*)"#) else { return text }
    var placeholders: [String: String] = [:]
    func placeholder(for address: String, domain: String) -> String {
        let key = address.lowercased()
        if let known = placeholders[key] { return known }
        let made = "user\(placeholders.count + 1)@\(domain)"
        placeholders[key] = made
        return made
    }

    var out: [String] = []
    for line in unfold(text) {
        if line.uppercased().hasPrefix("UID:") { out.append(line); continue }
        var redacted = line
        for match in addresses.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
            guard let whole = Range(match.range, in: line), let domainRange = Range(match.range(at: 1), in: line) else { continue }
            redacted.replaceSubrange(whole, with: placeholder(for: String(line[whole]), domain: String(line[domainRange])))
        }
        // A name is tied to the address on the same property when there is
        // one, so "Person 2" is always the same person as user2@.
        let address = addresses.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
            .flatMap { Range($0.range, in: line) }.map { String(line[$0]) }
        let number = address.flatMap { placeholders[$0.lowercased()] }?.drop { !$0.isNumber }.prefix { $0.isNumber }
        let person = number.map { "Person \($0)" } ?? "Person"
        redacted = names.stringByReplacingMatches(in: redacted, range: NSRange(redacted.startIndex..., in: redacted), withTemplate: "CN=\(person)")
        out.append(contentsOf: fold(redacted))
    }
    return out.joined(separator: "\r\n") + "\r\n"
}

/// Join folded continuation lines and drop blank ones.
func unfold(_ text: String) -> [String] {
    var lines: [String] = []
    for raw in text.components(separatedBy: .newlines) {
        if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
            lines[lines.count - 1] += raw.dropFirst()
        } else if !raw.isEmpty {
            lines.append(raw)
        }
    }
    return lines
}

/// Fold one logical line at 75 octets, continuation lines led by a space.
func fold(_ line: String) -> [String] {
    var pieces: [String] = []
    var current = ""
    var budget = 75
    for ch in line {
        let width = String(ch).utf8.count
        if current.utf8.count + width > budget {
            pieces.append(current)
            current = " "
            budget = 75
        }
        current.append(ch)
    }
    pieces.append(current)
    return pieces
}

func isCalendar(_ part: MessagePart) -> Bool {
    let type = part.contentType.lowercased()
    if type.hasPrefix("text/calendar") || type.hasPrefix("application/ics") { return true }
    return part.filename?.lowercased().hasSuffix(".ics") == true
}

let server = IMAPServer(host: host, port: port, transportSecurity: port == 993 ? .implicitTLS : .startTLS)
do {
    try await server.connect()
    try await server.login(username: user, password: pass)
    let selection = try await server.selectMailbox(mailbox)
    guard let identifiers = selection.latest(limit) else {
        print("mailbox is empty")
        exit(0)
    }
    let infos = try await server.fetchMessageInfosBulk(using: identifiers)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    var written = 0
    for info in infos {
        guard let uid = info.uid else { continue }
        let structure = try await server.fetchStructure(uid)
        let parts = structure.filter(isCalendar)
        guard !parts.isEmpty else { continue }
        let fetched = try await server.fetchPartsPipelined(parts: parts.map { (uid, $0.section) })
        for part in parts {
            guard let raw = fetched[uid]?.first(where: { $0.section == part.section })?.data else { continue }
            var filled = part
            filled.data = raw
            guard let data = filled.decodedData(), let text = String(data: data, encoding: .utf8) else { continue }
            let method = text.split(whereSeparator: \.isNewline)
                .first { $0.uppercased().hasPrefix("METHOD:") }
                .map { String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces).lowercased() } ?? "none"
            let file = outDir.appendingPathComponent("\(uid.value)-\(method).ics")
            try redact(text).write(to: file, atomically: true, encoding: .utf8)
            print("wrote \(file.lastPathComponent)  \(info.subject ?? "(no subject)")")
            written += 1
        }
    }
    print("\(written) calendar part(s) from the newest \(infos.count) message(s) in \(mailbox)")
    try? await server.disconnect()
} catch {
    FileHandle.standardError.write(Data("ics-dump failed: \(error)\n".utf8))
    try? await server.disconnect()
    exit(1)
}
