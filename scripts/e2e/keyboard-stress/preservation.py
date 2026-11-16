"""Independent journal checks for conditional edits around synthetic manual input."""

def user_text_damage(entries: list[dict[str, object]], text: str, markers: str) -> list[str]:
    """Check actual preservation, not the retired rule forbidding all edits after input.

    Synthetic vocabulary excludes markers. Whole-field fixture cleanup may intentionally
    change their case, but must not delete/retype unchanged markers or move their identity.
    For a documented case-only edit, every other character is unchanged by definition.
    """
    failures: list[str] = []
    report: tuple[str, str] | None = None
    expected: list[str] = []
    case_edits: dict[str, tuple[str, str]] = {}
    pending_case: list[tuple[str, str, int]] = []

    def marks(value: str) -> list[str]:
        return [char.lower() for char in value if char.lower() in markers]

    def unique_offset(haystack: str, needle: str) -> int | None:
        if not needle:
            return None
        offset = haystack.lower().find(needle.lower())
        if offset < 0 or haystack.lower().find(needle.lower(), offset + 1) >= 0:
            return None
        return offset

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
                case_edits[str(edit.get("id", ""))] = source, target
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
        if isinstance(deletion, int) and deletion > 0:
            consumed = before[-deletion:]
            full = before + after
            # Case-only cleanup can touch only characters explicitly changed by its target.
            matching = [(source, target, offset) for source, target in reversed(tuple(case_edits.values()))
                        if (offset := unique_offset(full, source)) is not None]
            if matching:
                source, target, offset = matching[0]
                start = len(before) - deletion
                if offset <= start and start + deletion <= offset + len(source):
                    for pos in range(start, start + deletion):
                        index = pos - offset
                        if source[index] == target[index]:
                            failures.append(f"case-only cleanup deleted unchanged character {full[pos]!r}")
            for char in consumed:
                if char.lower() not in markers:
                    continue
                authorized = None
                if deletion == 1:
                    pos = len(before) - 1
                    for source, target, offset in matching:
                        index = pos - offset
                        if 0 <= index < len(source) and source[index] == char and target[index] != char and target[index].lower() == char.lower():
                            authorized = source, target, index
                            break
                if authorized is None:
                    failures.append(f"automatic deletion touched protected user character {char!r}")
                else:
                    pending_case.append(authorized)
        if isinstance(insertion, str) and marks(insertion):
            authorized = None
            if len(insertion) == 1:
                for pending in pending_case:
                    source, target, index = pending
                    offset = unique_offset(before + after, source[:index] + source[index + 1:])
                    if offset is not None and len(before) == offset + index and target[index] == insertion:
                        authorized = pending
                        break
            if authorized is None:
                failures.append(f"automatic insertion rewrote or duplicated protected user text {insertion!r}")
            else:
                pending_case.remove(authorized)
    if marks(text) != expected:
        failures.append(f"user character order/identity changed: expected {''.join(expected)!r}, got {''.join(marks(text))!r}")
    return failures
