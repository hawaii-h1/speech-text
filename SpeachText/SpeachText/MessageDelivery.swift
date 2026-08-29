import AppKit
import Carbon.OpenScripting

// MARK: - Channels

/// A place a dictated message can be delivered to.
///
/// Two very different mechanisms hide behind this one enum, and the difference is
/// visible to the user as `DeliveryOutcome`:
///
/// * **Scripted** (Messages, Apple Mail) — the app hands the whole message to a local
///   AppleScript handler and the send completes without touching the UI. Atomic: it
///   either goes out or throws.
/// * **Deep link** (Telegram, WhatsApp) — the app can only open the right conversation
///   with the text already in the input field. Both clients deliberately refuse to send
///   from a URL, so the user presses ⏎ themselves.
enum DeliveryChannel: String, CaseIterable, Codable, Identifiable {
    case imessage
    case mail
    case telegram
    case whatsapp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .imessage: "iMessage"
        case .mail: "Email"
        case .telegram: "Telegram"
        case .whatsapp: "WhatsApp"
        }
    }

    var symbolName: String {
        switch self {
        case .imessage: "message.fill"
        case .mail: "envelope.fill"
        case .telegram: "paperplane.fill"
        case .whatsapp: "bubble.left.and.bubble.right.fill"
        }
    }

    /// Only `.mail` carries one; the others silently ignore it.
    var usesSubject: Bool { self == .mail }

    /// What kind of address this channel can actually be handed.
    var addressKind: AddressKind {
        switch self {
        case .imessage: .phoneOrEmail
        case .mail: .email
        case .telegram: .handleOrPhone
        case .whatsapp: .phone
        }
    }

    enum AddressKind {
        /// iMessage accepts either a phone number or an Apple ID email.
        case phoneOrEmail
        case email
        /// `tg://resolve` takes `domain=<username>` or `phone=<digits>`.
        case handleOrPhone
        case phone
    }

    /// Whether something on this Mac can receive the handoff at all. Checked before the
    /// channel is offered to the model, so it never routes a dictation into a dead end.
    var isAvailable: Bool {
        switch self {
        case .imessage:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") != nil
        case .mail:
            return MessageDelivery.defaultMailClient() != nil
        case .telegram:
            return MessageDelivery.handlerForScheme("tg") != nil
        case .whatsapp:
            return MessageDelivery.handlerForScheme("whatsapp") != nil
        }
    }
}

// MARK: - Recipients

/// One concrete way to reach a person on one channel. Addresses only ever come from
/// Contacts or from something the user literally dictated — never from the LLM, which
/// would happily invent a plausible phone number.
struct RecipientCandidate: Identifiable, Hashable {
    enum Source: Hashable {
        /// Matched against a card in the user's address book.
        case contacts
        /// The user dictated the address itself.
        case literal
    }

    let id = UUID()
    /// Who this is, for display: "Оксана Петренко", or the address when that's all we have.
    let displayName: String
    /// What actually gets handed to the channel.
    let address: String
    /// Contacts label for the address ("mobile", "home", "Telegram"), when there is one.
    let addressLabel: String?
    let source: Source

    /// "Оксана Петренко · mobile · +380…" — the line the confirmation panel shows.
    var detailLine: String {
        [addressLabel, address].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Outcome

enum DeliveryOutcome: Equatable {
    /// Handed to the app and on its way — nothing further for the user to do.
    case sent
    /// The conversation is open with the text in place; the user finishes the send.
    case composed(hint: String)
}

enum DeliveryError: LocalizedError {
    case appNotInstalled(DeliveryChannel)
    case unusableAddress(DeliveryChannel, String)
    case automationDenied(String)
    case scriptFailed(String)
    case couldNotOpen(DeliveryChannel)

    var errorDescription: String? {
        switch self {
        case .appNotInstalled(let channel):
            return "\(channel.displayName) isn't installed on this Mac."
        case .unusableAddress(let channel, let address):
            return "\(channel.displayName) can't use “\(address)” as an address."
        case .automationDenied(let app):
            return "SpeachText isn't allowed to control \(app). Grant it in System Settings › Privacy & Security › Automation."
        case .scriptFailed(let message):
            return message
        case .couldNotOpen(let channel):
            return "macOS refused to open \(channel.displayName)."
        }
    }
}

// MARK: - Service

enum MessageDelivery {

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.messageSendingEnabled)
    }

    /// Channels the model is allowed to route to right now. An uninstalled client is
    /// left out entirely rather than failing after the user already confirmed a send.
    static var availableChannels: [DeliveryChannel] {
        DeliveryChannel.allCases.filter(\.isAvailable)
    }

    /// Delivers `body` and reports whether the send completed or only got staged.
    /// Must be called on the main thread — `NSAppleScript` requires it.
    @MainActor
    static func deliver(body: String,
                        subject: String?,
                        to recipient: RecipientCandidate,
                        via channel: DeliveryChannel) throws -> DeliveryOutcome {
        dlog("Send", "\(channel.rawValue) → \(recipient.address) (\(body.count) chars)")
        switch channel {
        case .imessage: return try sendIMessage(body: body, to: recipient.address)
        case .mail:     return try sendMail(subject: subject ?? "", body: body, to: recipient.address)
        case .telegram: return try openTelegram(body: body, to: recipient.address)
        case .whatsapp: return try openWhatsApp(body: body, to: recipient.address)
        }
    }

    // MARK: Messages (scripted)

    /// `participant … of account …` is the only form the current Messages dictionary
    /// exposes — `buddy` survives as a synonym but the old `service "E:…"` spelling does
    /// not. Group chats are deliberately not attempted: on macOS 26 sending to a chat
    /// reports success and then silently drops the message.
    @MainActor
    private static func sendIMessage(body: String, to address: String) throws -> DeliveryOutcome {
        let source = """
        on speachtextDeliver(theAddress, theBody)
            tell application "Messages"
                set targetService to 1st account whose service type = iMessage
                set targetParticipant to participant theAddress of targetService
                send theBody to targetParticipant
            end tell
        end speachtextDeliver
        """
        try AppleScriptRunner.call(source: source,
                                   handler: "speachtextdeliver",
                                   arguments: [address, body],
                                   appName: "Messages")
        return .sent
    }

    // MARK: Mail (scripted, with a deep-link fallback)

    /// Only Apple Mail is scriptable here. Anyone on Spark/Outlook/Thunderbird gets a
    /// `mailto:` compose window instead — their client, their send button.
    @MainActor
    private static func sendMail(subject: String, body: String, to address: String) throws -> DeliveryOutcome {
        guard let client = defaultMailClient() else { throw DeliveryError.appNotInstalled(.mail) }

        if client.bundleID == "com.apple.mail" {
            let source = """
            on speachtextDeliver(theAddress, theSubject, theBody)
                tell application "Mail"
                    set newMessage to make new outgoing message with properties {subject:theSubject, content:theBody, visible:true}
                    tell newMessage
                        make new to recipient at end of to recipients with properties {address:theAddress}
                    end tell
                    send newMessage
                end tell
            end speachtextDeliver
            """
            try AppleScriptRunner.call(source: source,
                                       handler: "speachtextdeliver",
                                       arguments: [address, subject, body],
                                       appName: "Mail")
            return .sent
        }

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.percentEncodedQuery = encodedQuery(
            [subject.isEmpty ? nil : ("subject", subject), ("body", body)].compactMap { $0 }
        )

        guard let url = components.url, NSWorkspace.shared.open(url) else {
            throw DeliveryError.couldNotOpen(.mail)
        }
        return .composed(hint: "Draft opened in \(client.name) — send it from there.")
    }

    // MARK: Telegram (deep link)

    /// `tg://resolve` takes a public @username or a phone number. A username is by far
    /// the more reliable of the two, so Contacts is mined for one first.
    private static func openTelegram(body: String, to address: String) throws -> DeliveryOutcome {
        guard DeliveryChannel.telegram.isAvailable else { throw DeliveryError.appNotInstalled(.telegram) }

        var components = URLComponents()
        components.scheme = "tg"
        components.host = "resolve"

        if let handle = AddressFormat.telegramHandle(address) {
            components.percentEncodedQuery = encodedQuery([("domain", handle), ("text", body)])
        } else if let phone = AddressFormat.phoneDigits(address) {
            components.percentEncodedQuery = encodedQuery([("phone", phone), ("text", body)])
        } else {
            throw DeliveryError.unusableAddress(.telegram, address)
        }

        guard let url = components.url, NSWorkspace.shared.open(url) else {
            throw DeliveryError.couldNotOpen(.telegram)
        }
        return .composed(hint: "Telegram is open with the text ready — press ⏎ to send.")
    }

    // MARK: WhatsApp (deep link)

    private static func openWhatsApp(body: String, to address: String) throws -> DeliveryOutcome {
        guard DeliveryChannel.whatsapp.isAvailable else { throw DeliveryError.appNotInstalled(.whatsapp) }
        guard let phone = AddressFormat.phoneDigits(address) else {
            throw DeliveryError.unusableAddress(.whatsapp, address)
        }

        var components = URLComponents()
        components.scheme = "whatsapp"
        components.host = "send"
        components.percentEncodedQuery = encodedQuery([("phone", phone), ("text", body)])

        guard let url = components.url, NSWorkspace.shared.open(url) else {
            throw DeliveryError.couldNotOpen(.whatsapp)
        }
        return .composed(hint: "WhatsApp is open with the text ready — press ⏎ to send.")
    }

    /// `URLComponents.queryItems` leaves `+` raw, and both Telegram and WhatsApp decode a
    /// raw `+` in a query back into a space — a dictated "5+3" would arrive as "5 3".
    /// Encoding the values here instead keeps the message byte-for-byte what was confirmed.
    static func encodedQuery(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        return items
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
            .joined(separator: "&")
    }

    // MARK: Handler lookup

    struct MailClient {
        let bundleID: String
        let name: String
    }

    static func defaultMailClient() -> MailClient? {
        guard let url = handlerForScheme("mailto"),
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        return MailClient(bundleID: bundleID, name: name)
    }

    /// The app registered to open `scheme://`, or nil when nothing claims it.
    static func handlerForScheme(_ scheme: String) -> URL? {
        guard let probe = URL(string: "\(scheme)://") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }
}

// MARK: - Address shapes

/// Recognises what a string *is* so a dictated address can be used directly and a
/// Contacts value can be pointed at the right channel.
enum AddressFormat {

    static func isEmail(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(" "), let at = trimmed.firstIndex(of: "@") else { return false }
        let local = trimmed[trimmed.startIndex ..< at]
        let domain = trimmed[trimmed.index(after: at)...]
        return !local.isEmpty && domain.contains(".") && !domain.hasSuffix(".")
    }

    /// `@name` / `name` / `t.me/name` → `name`. Rejects anything that is really an email.
    static func telegramHandle(_ value: String) -> String? {
        var trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !isEmail(trimmed) else { return nil }
        for prefix in ["https://t.me/", "http://t.me/", "t.me/", "@"] {
            if trimmed.hasPrefix(prefix) { trimmed.removeFirst(prefix.count) }
        }
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              trimmed.contains(where: \.isLetter)
        else { return nil }
        return trimmed
    }

    /// Strips spaces, dashes and brackets down to the digits a deep link wants, keeping
    /// a leading `+` off (both `tg://` and `whatsapp://` want bare digits).
    static func phoneDigits(_ value: String) -> String? {
        let digits = value.filter(\.isNumber)
        guard digits.count >= 7, !isEmail(value) else { return nil }
        return digits
    }

    /// True when the string is something we can hand to a channel as-is, rather than a
    /// person's name that still needs looking up.
    static func isLiteralAddress(_ value: String) -> Bool {
        isEmail(value) || phoneDigits(value) != nil || value.hasPrefix("@")
    }
}

// MARK: - AppleScript bridge

/// Calls a handler inside a compiled AppleScript with real string parameters.
///
/// Building the script by interpolating the message text would break on the first quote
/// or newline a dictation contains, so the text is passed as an Apple event parameter
/// instead and never goes through AppleScript's lexer.
enum AppleScriptRunner {

    @MainActor
    static func call(source: String, handler: String, arguments: [String], appName: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw DeliveryError.scriptFailed("Could not build the \(appName) script.")
        }

        var compileError: NSDictionary?
        guard script.compileAndReturnError(&compileError) else {
            throw DeliveryError.scriptFailed(describe(compileError, appName: appName))
        }

        let parameters = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() {
            parameters.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
        }

        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
        guard let target = NSAppleEventDescriptor(descriptorType: typeProcessSerialNumber,
                                                  bytes: &psn,
                                                  length: MemoryLayout<ProcessSerialNumber>.size) else {
            throw DeliveryError.scriptFailed("Could not address the \(appName) script.")
        }

        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
                                           eventID: AEEventID(kASSubroutineEvent),
                                           targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler),
                       forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(parameters, forKeyword: keyDirectObject)

        var executeError: NSDictionary?
        script.executeAppleEvent(event, error: &executeError)
        if executeError != nil {
            throw mapError(executeError, appName: appName)
        }
    }

    /// The two failures worth naming: automation was never granted, and the target app
    /// isn't running. Everything else passes the app's own message through.
    private static func mapError(_ info: NSDictionary?, appName: String) -> DeliveryError {
        let code = (info?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        switch code {
        case Int(errAEEventNotPermitted), -1743:
            return .automationDenied(appName)
        case Int(procNotFound), -600:
            return .scriptFailed("\(appName) isn't running — open it once and try again.")
        default:
            return .scriptFailed(describe(info, appName: appName))
        }
    }

    private static func describe(_ info: NSDictionary?, appName: String) -> String {
        let message = info?[NSAppleScript.errorMessage] as? String
        let code = (info?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        if let message, !message.isEmpty { return "\(appName): \(message)" }
        if let code { return "\(appName) script failed (error \(code))." }
        return "\(appName) script failed."
    }
}
