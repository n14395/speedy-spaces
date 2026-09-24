// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A single macOS Space (virtual desktop) as reported by the window server.
/// Identity is the stable `uuid`; ManagedSpaceID can change across reboots.
struct Space: Identifiable, Equatable {
    let uuid: String
    let managedSpaceID: Int
    /// 0 == user desktop, 4 == full-screen app space.
    let type: Int
    /// Index of the display this space belongs to (order from the window server).
    let displayIndex: Int
    let displayIdentifier: String
    /// Position of this space within its display's ordered space list.
    let ordinalOnDisplay: Int
    var isCurrent: Bool
    /// For fullscreen spaces (type 4): the pid of the app whose window owns the space,
    /// straight from the window server's space dictionary. nil for desktops.
    var fullscreenPID: pid_t? = nil

    var id: String { uuid }
    var isFullscreen: Bool { type == 4 }
}
