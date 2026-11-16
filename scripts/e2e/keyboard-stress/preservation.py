"""Independent journal checks for conditional edits around synthetic manual input."""
from dataclasses import dataclass, field


def unique_offset(haystack: str, needle: str) -> int | None:
    if not needle:
        return 0 if not haystack else None
    offset = haystack.lower().find(needle.lower())
    if offset < 0 or haystack.lower().find(needle.lower(), offset + 1) >= 0:
        return None
    return offset


@dataclass
class CaseEdit:
    source: str
    target: str
    missing: set[int] = field(default_factory=set)

    @property
    def slots(self) -> list[int]:
        return [index for index in range(len(self.source)) if index not in self.missing]

    @property
    def current(self) -> str:
        return "".join(self.source[index] for index in self.slots)


def user_text_damage(entries: list[dict[str, object]], text: str, markers: str) -> list[str]:
    """Check actual preservation, not the retired rule forbidding all edits after input.

    Synthetic vocabulary excludes markers. Whole-field fixture cleanup may intentionally
    change their case, but must not delete/retype unchanged markers or move their identity.
    For a documented case-only edit, every other character is unchanged by definition.
    """
    failures: list[str] = []
    report: tuple[str, str] | None = None
    expected: list[str] = []
    case_edits: dict[str, CaseEdit] = {}

    def marks(value: str) -> list[str]:
        return [char.lower() for char in value if char.lower() in markers]

    for row in entries:
        kind = row.get("kind")
        if kind in ("applied", "dropped"):
            case_edits.pop(str(row.get("id", "")), None)
        value = row.get("report")
        if kind == "step" and isinstance(value, dict):
            before, after = value.get("before"), value.get("after")
            if isinstance(before, str) and isinstance(after, str):
                report = before, after
        edit = row.get("edit")
        if kind == "edit" and not row.get("user") and isinstance(edit, dict):
            before, after, target = edit.get("before", ""), edit.get("after", ""), edit.get("target")
            selected = edit.get("selected")
            source = selected if isinstance(selected, str) else before + after if isinstance(before, str) and isinstance(after, str) else None
            if isinstance(source, str) and isinstance(target, str) and len(source) == len(target) and source.lower() == target.lower():
                case_edits[str(edit.get("id", ""))] = CaseEdit(source, target)
        op = row.get("op")
        if kind != "sent" or not isinstance(op, dict):
            continue
        if report is None:
            failures.append("a sent operation has no preceding host report for preservation verification")
            continue
        before, after = report
        insertion = op.get("insert")
        deletion = op.get("delete", 0)
        if row.get("lane") == "user":
            at = len(marks(before))
            if isinstance(deletion, int) and deletion > 0:
                removed = len(marks(before[-deletion:]))
                expected[max(0, at - removed):at] = []
            if isinstance(insertion, str):
                expected[at:at] = marks(insertion)
            continue
        full = before + after
        matching = [(state, offset) for state in reversed(tuple(case_edits.values()))
                    if (offset := unique_offset(full, state.current)) is not None]
        if isinstance(deletion, int) and deletion > 0:
            consumed = before[-deletion:]
            authorized_marker = False
            for state, offset in matching:
                start = len(before) - deletion - offset
                slots = state.slots
                if not 0 <= start <= start + deletion <= len(slots):
                    continue
                # A case hunk can delete several adjacent changed characters before inserting
                # their replacements. Keep the original slots even while those gaps are visible.
                for relative, index in enumerate(slots[start:start + deletion]):
                    char = consumed[relative]
                    changed = state.source[index] != state.target[index]
                    intended = changed and char == state.source[index]
                    if not changed:
                        failures.append(f"case-only cleanup deleted unchanged character {char!r}")
                    elif not intended:
                        failures.append(f"case-only cleanup retyped an already changed character {char!r}")
                    state.missing.add(index)
                    if deletion == 1 and intended and char.lower() in markers:
                        authorized_marker = True
                break
            for char in consumed:
                if char.lower() in markers and not authorized_marker:
                    failures.append(f"automatic deletion touched protected user character {char!r}")
        if isinstance(insertion, str):
            authorized = False
            if len(insertion) == 1:
                for state, offset in matching:
                    slots = state.slots
                    for index in sorted(state.missing):
                        position = sum(slot < index for slot in slots)
                        if (len(before) == offset + position and state.target[index] == insertion
                                and state.source[index] != state.target[index]):
                            state.missing.remove(index)
                            authorized = True
                            break
                    if authorized:
                        break
            if marks(insertion) and not authorized:
                failures.append(f"automatic insertion rewrote or duplicated protected user text {insertion!r}")
    if marks(text) != expected:
        failures.append(f"user character order/identity changed: expected {''.join(expected)!r}, got {''.join(marks(text))!r}")
    return failures
