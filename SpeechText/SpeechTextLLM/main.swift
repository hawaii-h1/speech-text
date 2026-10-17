// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

let delegate = LocalChatServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
