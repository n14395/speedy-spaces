// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import ServiceManagement

/// Manages "Open at Login" via the modern ServiceManagement API (macOS 13+).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns true on success. On failure, `error` describes why (e.g. the app must
    /// live in a stable location like /Applications, and be signed, to register).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> (ok: Bool, error: String?) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
