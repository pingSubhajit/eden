import Foundation

// Who makes Eden, and the addresses that belong to it, in one place.
//
// Eden began as a fork of Search by Office Commun (MIT). Everything here is
// Eden's own; nothing points at Office Commun's site, feed or mailbox. The
// values still to be decided are marked TODO, and listed in TODO.md.

enum Brand {
    /// The name people see: the menu bar, the Dock, About, every sentence.
    static let name = "Eden"
    /// Who makes it, under the version in Settings. Its builds are signed
    /// with team HMJX9736KN.
    static let publisher = "Subhajit Kundu"

    /// Where people find out about Eden and download it. The repository for
    /// now.
    /// TODO(site): Eden's own site, once there is one.
    static let website = URL(string: "https://github.com/pingSubhajit/eden")!

    /// Where Found something wrong? addresses its draft. Nil: the draft opens
    /// with no recipient, and the person fills one in.
    /// TODO(contact): a mailbox for feedback.
    static let feedbackEmail: String? = nil

    /// Whether this build looks for a newer one. Off until Eden has a
    /// signed feed of its own: with it off, nothing is fetched, the Check for
    /// Updates… item and the Updates rows in Settings are not shown, and the
    /// AI add-on's engine, which arrives through the same feed, isn't offered.
    /// TODO(updates): host build.sh's appcast at `updateFeed`, then turn on.
    static let updatesEnabled = false

    /// The folder build.sh's appcast.json, Eden.zip and Eden.dmg are served
    /// from. The Intel build's are in its intel/ folder.
    /// TODO(updates): Eden's own address.
    static let updateFeed = URL(string: "https://pingsubhajit.github.io/eden/updates/")!

    /// The address OpenRouter sends a sign-in back to (AISignIn). It is never
    /// loaded: Eden takes it as the tab is about to go there. Kept on a
    /// host that belongs to Eden all the same.
    /// TODO(site): move to Eden's own domain with the site.
    static let aiCallback = URL(string: "https://pingsubhajit.github.io/eden/ai/callback")!
}
