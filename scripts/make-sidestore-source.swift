#!/usr/bin/env swift

import Foundation

struct Source: Encodable {
    var name: String
    var identifier: String
    var sourceURL: String
    var apps: [App]
}

struct App: Encodable {
    var name: String
    var bundleIdentifier: String
    var developerName: String
    var subtitle: String
    var localizedDescription: String
    var iconURL: String
    var tintColor: String
    var permissions: [Permission]
    var version: String
    var versionDate: String
    var versionDescription: String
    var downloadURL: String
    var size: Int64
    var versions: [Version]
}

struct Permission: Encodable {
    var type: String
    var usageDescription: String
}

struct Version: Encodable {
    var version: String
    var date: String
    var localizedDescription: String
    var downloadURL: String
    var size: Int64
    var minOSVersion: String
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

private func options() -> [String: String] {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count.isMultiple(of: 2) else {
        fail("arguments must be --name value pairs")
    }

    var result: [String: String] = [:]
    for index in stride(from: 0, to: arguments.count, by: 2) {
        let name = arguments[index]
        guard name.hasPrefix("--") else { fail("expected an option, got \(name)") }
        result[String(name.dropFirst(2))] = arguments[index + 1]
    }
    return result
}

private func required(_ name: String, in options: [String: String]) -> String {
    guard let value = options[name], !value.isEmpty else { fail("missing --\(name)") }
    return value
}

let values = options()
let repository = required("repository", in: values)
let tag = required("tag", in: values)
let version = required("version", in: values)
let date = required("date", in: values)
let ipaPath = required("ipa", in: values)
let outputPath = required("output", in: values)
let releaseNotes = values["release-notes"] ?? "See the GitHub release notes for changes in this version."

let repositoryParts = repository.split(separator: "/", omittingEmptySubsequences: false)
guard repositoryParts.count == 2,
      repositoryParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) } })
else { fail("repository must use the GitHub OWNER/REPO form") }
guard tag.allSatisfy({ $0.isLetter || $0.isNumber || ".-_".contains($0) }) else {
    fail("tag contains characters that are unsafe in a release URL")
}

let ipaURL = URL(fileURLWithPath: ipaPath)
guard let attributes = try? FileManager.default.attributesOfItem(atPath: ipaURL.path),
      let size = attributes[.size] as? NSNumber
else { fail("IPA does not exist at \(ipaPath)") }

let releaseRoot = "https://github.com/\(repository)/releases"
let latestAssetRoot = "\(releaseRoot)/latest/download"
let downloadURL = "\(releaseRoot)/download/\(tag)/Lyra.ipa"
let sourceURL = "\(latestAssetRoot)/source.json"
let iconURL = "\(latestAssetRoot)/icon.png"

let currentVersion = Version(
    version: version,
    date: date,
    localizedDescription: releaseNotes,
    downloadURL: downloadURL,
    size: size.int64Value,
    minOSVersion: "26.0"
)
let app = App(
    name: "Lyra",
    bundleIdentifier: "care.davinci.lyra",
    developerName: "Lyra Contributors",
    subtitle: "Offline music from folders and WebDAV",
    localizedDescription: "A private iOS music player for local folders and WebDAV libraries, with user-selected offline downloads.",
    iconURL: iconURL,
    tintColor: "#4E249B",
    permissions: [
        Permission(type: "background-audio", usageDescription: "Continues playing music while Lyra is in the background or the device is locked."),
        Permission(type: "network", usageDescription: "Connects only to WebDAV libraries that you add.")
    ],
    // Keep the legacy fields alongside AltSource v2 versions because older
    // SideStore builds still require the top-level download metadata.
    version: version,
    versionDate: date,
    versionDescription: releaseNotes,
    downloadURL: downloadURL,
    size: size.int64Value,
    versions: [currentVersion]
)
let source = Source(
    name: "Lyra Releases",
    identifier: "care.davinci.lyra.source",
    sourceURL: sourceURL,
    apps: [app]
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
var data = try encoder.encode(source)
data.append(0x0A)

let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try data.write(to: outputURL, options: .atomic)
