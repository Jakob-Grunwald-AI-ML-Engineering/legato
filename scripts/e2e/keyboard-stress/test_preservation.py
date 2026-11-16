"""Pure contract checks for the stress oracle; no app, simulator or API requests."""
import unittest

from preservation import user_text_damage


def report(before: str, after: str = "") -> dict[str, object]:
    return {"kind": "step", "report": {"before": before, "after": after}}


def sent(lane: str, **op: object) -> dict[str, object]:
    return {"kind": "sent", "lane": lane, "op": op}


class PreservationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.base = [report("a"), sent("user", insert="z")]

    def test_verified_movement_does_not_damage_user_text(self) -> None:
        rows = self.base + [report("az"), sent("edit", move=-1)]
        self.assertEqual(user_text_damage(rows, "az", "zqxj"), [])

    def test_deleting_and_retyping_unchanged_user_text_is_not_a_pass(self) -> None:
        rows = self.base + [report("az"), sent("edit", delete=1), report("a"), sent("edit", insert="z")]
        self.assertTrue(user_text_damage(rows, "az", "zqxj"))

    def test_reordering_user_characters_is_not_a_pass(self) -> None:
        rows = self.base + [report("az"), sent("user", insert="q")]
        self.assertTrue(user_text_damage(rows, "aqz", "zqxj"))

    def test_explicit_case_change_is_preserved_as_an_intended_change(self) -> None:
        rows = self.base + [
            {"kind": "edit", "edit": {"id": "e", "before": "az", "after": "", "target": "AZ"}},
            report("az"), sent("edit", delete=1), report("a"), sent("edit", insert="Z"),
        ]
        self.assertEqual(user_text_damage(rows, "aZ", "zqxj"), [])

    def test_case_only_cleanup_cannot_retype_an_unchanged_character(self) -> None:
        rows = self.base + [
            {"kind": "edit", "edit": {"id": "e", "before": "az", "after": "", "target": "aZ"}},
            report("a", "z"), sent("edit", delete=1),
        ]
        self.assertTrue(user_text_damage(rows, "az", "zqxj"))


if __name__ == "__main__":
    unittest.main()
