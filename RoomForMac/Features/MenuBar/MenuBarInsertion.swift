import SwiftUI

/// The binding behind `MenuBarExtra(isInserted:)` (Ruling 17).
///
/// SwiftUI calls the setter with the current value on every scene update. Apple's documented
/// pattern, an `@AppStorage` flag bound straight to `isInserted`, wrote each time and put the app
/// in an update loop: more than 21,000 `App.body` evaluations in 30 s (research §9). This
/// setter writes only when the value differs from what the getter reports, so a write of
/// `false` from the system (the user took the item out of the menu bar) turns the extra off
/// once, and every other write changes nothing.
enum MenuBarInsertion {
    @MainActor
    static func binding(model: AppModel) -> Binding<Bool> {
        Binding(
            get: { model.menuBarItemShown },
            set: { shown in
                guard shown != model.menuBarItemShown else {
                    return
                }
                model.setMenuBarEnabled(shown)
            }
        )
    }
}
