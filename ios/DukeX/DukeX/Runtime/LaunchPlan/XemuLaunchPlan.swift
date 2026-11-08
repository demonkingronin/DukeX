import Foundation
import Darwin

struct XemuLaunchPlan: Identifiable {
    let id = UUID()
    let configURL: URL
    let arguments: [String]
    let jitMode: RuntimeJITMode
    let requiresJITHandoff: Bool
    let universalJITEnabled: Bool
    let gameName: String
    let titleID: String?
    let isDashboard: Bool
    let xboxCameraEnabled: Bool
    let xboxHeadsetMicEnabled: Bool
    let manicSkinPortraitURL: URL?
    let manicSkinLandscapeURL: URL?

    var commandLine: String {
        arguments.map(Self.shellQuoted).joined(separator: " ")
    }

    static func make(
        documentsURL: URL,
        bios: LibraryFile,
        mcpx: LibraryFile,
        eeprom: LibraryFile?,
        hdd: LibraryFile,
        game: LibraryFile?,
        gamesDirectoryURL: URL,
        universalJITEnabled: Bool,
        networkSettings: NetworkSettings,
        tbCacheSize: TBCacheSize,
        shaderCacheURL: URL,
        xboxCameraEnabled: Bool,
        xboxHeadsetMicEnabled: Bool,
        manicSkinPortraitURL: URL?,
        manicSkinLandscapeURL: URL?
    ) throws -> XemuLaunchPlan {
        let configURL = documentsURL.appendingPathComponent("xemu-ios.toml")
        let launchName = game?.displayName ?? "Xbox Dashboard"
        let titleID = GameLaunchLink.normalizedTitleID(game?.titleID)
        let customConfigURL = game?.customConfigURL
        let jitMode = UniversalJITSupport.currentMode
        let requiresJITHandoff = UniversalJITSupport.requiresJITHandoff(for: universalJITEnabled)
        let effectiveUniversalJITEnabled = UniversalJITSupport.effectiveEnabled(for: universalJITEnabled)
        if customConfigURL == nil {
            let toml = defaultConfigTOML(
                bios: bios,
                mcpx: mcpx,
                eeprom: eeprom,
                hdd: hdd,
                game: game,
                gamesDirectoryURL: gamesDirectoryURL,
                networkSettings: networkSettings
            )
            try toml.write(to: configURL, atomically: true, encoding: .utf8)
        }
        setenv("XEMU_IOS_UNIVERSAL_JIT", effectiveUniversalJITEnabled ? "1" : "0", 1)
        setenv("XEMU_IOS_JIT_MODE", jitMode.environmentValue, 1)
        setenv("XEMU_IOS_VK_PIPELINE_CACHE_PATH", shaderCacheURL.path, 1)
        setenv("XEMU_IOS_FORCE_INSIGNIA_NAT", networkSettings.forceInsigniaNAT ? "1" : "0", 1)
        if let dnsServer = networkSettings.effectiveDNSServer {
            setenv("XEMU_IOS_NAT_DIRECT_DNS", dnsServer, 1)
        } else {
            unsetenv("XEMU_IOS_NAT_DIRECT_DNS")
        }

        let accelOptions: [String] = ([
            "thread=single",
            "tb-size=\(tbCacheSize.launchArgumentValue)",
            jitMode == .wxReprotection ? "split-wx=on" : nil
        ] as [String?]).compactMap { $0 }

        var arguments = [
            "xemu-ios",
            "-accel", "tcg,\(accelOptions.joined(separator: ","))",
            "-config_path", (customConfigURL ?? configURL).path
        ]

        if xboxCameraEnabled {
            arguments.append(contentsOf: [
                "-device", "usb-xbox-camera,port=1.4"
            ])
        }

        return XemuLaunchPlan(
            configURL: customConfigURL ?? configURL,
            arguments: arguments,
            jitMode: jitMode,
            requiresJITHandoff: requiresJITHandoff,
            universalJITEnabled: effectiveUniversalJITEnabled,
            gameName: launchName,
            titleID: titleID,
            isDashboard: game == nil,
            xboxCameraEnabled: xboxCameraEnabled,
            xboxHeadsetMicEnabled: xboxHeadsetMicEnabled,
            manicSkinPortraitURL: manicSkinPortraitURL,
            manicSkinLandscapeURL: manicSkinLandscapeURL
        )
    }

    // Shared launch defaults, also used when a game receives its first
    // game-specific TOML file. Keep launch arguments and system paths identical.
    static func defaultConfigTOML(
        bios: LibraryFile,
        mcpx: LibraryFile,
        eeprom: LibraryFile?,
        hdd: LibraryFile,
        game: LibraryFile?,
        gamesDirectoryURL: URL,
        networkSettings: NetworkSettings
    ) -> String {
        let gamesPath = game?.url.deletingLastPathComponent().path ?? gamesDirectoryURL.path
        let dvdPath = game?.url.path ?? ""
        let eepromPathLine = eeprom.map {
            "eeprom_path = \(tomlQuoted($0.url.path))\n"
        } ?? ""
        return """
        [general]
        show_welcome = false
        skip_boot_anim = false
        games_dir = \(tomlQuoted(gamesPath))

        [display]
        renderer = "VULKAN"

        [display.ui]
        show_menubar = false
        show_notifications = true
        hide_cursor = true

        [perf]
        cache_shaders = true

        [input]
        auto_bind = true
        background_input_capture = true

        [net]
        enable = true
        backend = "nat"

        [[net.nat.forward_ports]]
        host = \(networkSettings.effectiveHostPort)
        guest = \(networkSettings.effectiveGuestPort)
        protocol = \(tomlQuoted(networkSettings.effectivePortProtocol))

        [sys]
        mem_limit = "64"
        avpack = "hdtv"

        [sys.files]
        bootrom_path = \(tomlQuoted(mcpx.url.path))
        flashrom_path = \(tomlQuoted(bios.url.path))
        hdd_path = \(tomlQuoted(hdd.url.path))
        \(eepromPathLine)dvd_path = \(tomlQuoted(dvdPath))
        """
    }

    private static func tomlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func shellQuoted(_ value: String) -> String {
        if value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines) == nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}


enum GameResolutionScaleConfig {
    static let allowedValues = [1, 2, 3]

    static func scale(in toml: String) -> Int {
        var inQuality = false
        for line in toml.components(separatedBy: "\n") {
            if isSectionHeader(line) {
                inQuality = isQualitySection(line)
            } else if inQuality,
                      let value = scaleValue(in: line),
                      let parsed = Int(value),
                      parsed > 0 {
                return parsed
            }
        }
        return 1
    }

    static func setting(_ scale: Int, in toml: String) -> String {
        precondition(allowedValues.contains(scale))
        var lines = toml.components(separatedBy: "\n")
        var qualityStart: Int?
        var qualityEnd = lines.count

        for index in lines.indices where isSectionHeader(lines[index]) {
            if qualityStart != nil {
                qualityEnd = index
                break
            }
            if isQualitySection(lines[index]) {
                qualityStart = index
            }
        }

        guard let qualityStart else {
            var result = toml
            if !result.isEmpty && !result.hasSuffix("\n") {
                result += "\n"
            }
            if !result.isEmpty && !result.hasSuffix("\n\n") {
                result += "\n"
            }
            return result + "[display.quality]\nsurface_scale = \(scale)\n"
        }

        let matchingIndices = ((qualityStart + 1)..<qualityEnd)
            .filter { scaleValue(in: lines[$0]) != nil }
        if let first = matchingIndices.first {
            let oldLine = lines[first]
            let leadingWhitespace = String(oldLine.prefix(while: { $0 == " " || $0 == "\t" }))
            let comment = oldLine.firstIndex(of: "#").map { String(oldLine[$0...]) } ?? ""
            lines[first] = "\(leadingWhitespace)surface_scale = \(scale)" +
                (comment.isEmpty ? "" : " \(comment)")
            // A duplicated TOML key would make the config invalid.
            for extra in matchingIndices.dropFirst().reversed() {
                lines.remove(at: extra)
            }
        } else {
            lines.insert("surface_scale = \(scale)", at: qualityStart + 1)
        }
        return lines.joined(separator: "\n")
    }

    private static func isSectionHeader(_ line: String) -> Bool {
        let key = uncommented(line).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.hasPrefix("[") && key.hasSuffix("]")
    }

    private static func isQualitySection(_ line: String) -> Bool {
        uncommented(line).trimmingCharacters(in: .whitespacesAndNewlines) == "[display.quality]"
    }

    private static func scaleValue(in line: String) -> String? {
        let pieces = uncommented(line).split(
            separator: "=", maxSplits: 1, omittingEmptySubsequences: false
        )
        guard pieces.count == 2,
              pieces[0].trimmingCharacters(in: .whitespacesAndNewlines) == "surface_scale" else {
            return nil
        }
        return pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uncommented(_ line: String) -> String {
        String(line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }
}
