import Foundation

/// Which Activity / Attention row the menubar popover has drilled into.
/// Holds ids only so a live `/usage` refresh can replace the payload under
/// the same page; if the row vanishes, the pane says so and Back still works.
enum ServiceDetailSelection: Equatable {
    case activity(String)
    case plausible(String)
    case posthog(String)
    case supabase(String)
    case server(String)
    case build(String)
}
