//
//  File:      FleetPausedStore.swift
//  Created:   2026-10-05
//  Updated:   2026-10-05
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Machines the user has paused: still listed, but not polled at all until resumed.
//             Unlike removing a machine (FleetHiddenStore), pausing keeps the row, the address,
//             the token and the pinned certificate — it is a viewer-side switch to stop the polling
//             traffic, for a machine that is only watched occasionally or reached over a metered or
//             relayed link.
//  Notes:     Keyed by the pairing key, the same key `FleetPairingStore` and `FleetHiddenStore`
//             use. Persisted so a pause survives relaunches, and Resume is always one context-menu
//             click away.
//
import Foundation

enum FleetPausedStore {
    private static let key = "ai.calidalab.SiliconScope.fleet-paused"

    /// Pairing keys the user has paused. Sorted so callers get a stable order.
    static func all() -> [String] {
        (UserDefaults.standard.array(forKey: key) as? [String] ?? []).sorted()
    }

    static func contains(_ name: String) -> Bool {
        Set(all()).contains(name)
    }

    static func pause(_ name: String) {
        var s = Set(all()); s.insert(name)
        UserDefaults.standard.set(Array(s), forKey: key)
    }

    static func resume(_ name: String) {
        var s = Set(all()); s.remove(name)
        UserDefaults.standard.set(Array(s), forKey: key)
    }
}
