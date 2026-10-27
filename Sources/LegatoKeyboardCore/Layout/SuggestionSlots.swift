/// Where ranked suggestions sit in the keyboard's three slots: the best in the middle, the second on the
/// left, the third on the right ("2 | 1 | 3"), like the system keyboard.
public enum SuggestionSlots {
    /// The three slots, left to right, for `ranked` (best first); a slot without a suggestion is `nil`.
    public static func arrange(_ ranked: [String]) -> [String?] {
        [1, 0, 2].map { rank in rank < ranked.count ? ranked[rank] : nil }
    }
}
