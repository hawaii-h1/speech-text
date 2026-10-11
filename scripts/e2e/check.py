# SPDX-FileCopyrightText: 2026 Vladyslav Husakov
# SPDX-License-Identifier: GPL-3.0-or-later

"""scripts/e2e.sh's verdict on one scenario.

Structural checks only — the owner rejected a WER threshold (#80): the text was pasted
once, after the stop, into the document the script opened; a cancel left it empty; an
edit replaced the selection. WER against the clip's `expected` is reported, never judged.

    python3 check.py --name NAME --doc FILE --log FILE --history FILE \
        [--expected TEXT] [--original TEXT] [--pastes N] [--empty] [--refined] [--edit]

Prints one Markdown table row and exits 1 when a check failed.
"""

import argparse
import json
import re
import sys
import unicodedata


def words(text):
    text = unicodedata.normalize("NFC", text).lower().replace("’", "'").replace("ʼ", "'")
    return re.findall(r"[\w']+", text)


def wer(expected, actual):
    ref, hyp = words(expected), words(actual)
    if not ref:
        return None
    row = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, row[0] = row[0], i
        for j, h in enumerate(hyp, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (r != h))
    return row[-1] / len(ref)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--name", required=True)
    p.add_argument("--doc", required=True)
    p.add_argument("--log", required=True)
    p.add_argument("--history", required=True)
    p.add_argument("--expected", default="")
    p.add_argument("--original", default="")
    p.add_argument("--pastes", type=int)
    p.add_argument("--empty", action="store_true")
    p.add_argument("--refined", action="store_true")
    p.add_argument("--edit", action="store_true")
    p.add_argument("--app", default="", help="the app the paste must go to")
    p.add_argument("--untouched", default="", help="another document's text file, which must still be empty")
    p.add_argument("--logged", action="append", default=[], help="a Debug Log line the run must contain")
    p.add_argument("--spaced", action="store_true", help="each paste ends in a space, so the next is not glued on")
    a = p.parse_args()

    doc = open(a.doc, encoding="utf-8").read()
    log = open(a.log, encoding="utf-8", errors="replace").read()
    try:
        records = json.load(open(a.history, encoding="utf-8"))
    except (OSError, ValueError):
        records = []
    latest = records[0] if records else {}
    refinement = latest.get("refinement") or {}

    problems = []
    pastes = log.count("pasteAtCursor:")
    body = doc.strip()

    if a.empty:
        if body != a.original.strip():
            problems.append("the document changed")
    elif a.edit:
        if not body:
            problems.append("the document is empty")
        elif body == a.original.strip():
            problems.append("the selection was not replaced")
        elif a.original.strip() and a.original.strip() in body:
            problems.append("the original text is still there beside the rewrite")
        if not refinement.get("editsSelection"):
            problems.append("History has no edit for it")
    else:
        if not body:
            problems.append("nothing was pasted")
        if a.expected:
            # Twice the words of the clip is a doubled paste, whatever the engine misheard.
            if len(words(body)) > 1.6 * len(words(a.expected)) + 3:
                problems.append(f"{len(words(body))} words for a clip of {len(words(a.expected))} — pasted twice?")
    if a.pastes is not None and pastes != a.pastes:
        problems.append(f"{pastes} pastes, expected {a.pastes}")
    if a.refined and not (refinement.get("outputText") and not refinement.get("errorMessage")):
        problems.append("History has no AI Rewrite for it" + (f" ({refinement['errorMessage']})" if refinement.get("errorMessage") else ""))
    if a.untouched and open(a.untouched, encoding="utf-8").read().strip():
        problems.append("text also landed in the document the dictation started in")
    if a.spaced:
        pasted = re.findall(r'pasteAtCursor: \d+ chars "(.*?)", trusted', log)
        if any(not text.endswith(" ") for text in pasted[:-1]):
            problems.append("a paste did not end in a space — the next one is glued on")
    if not a.edit:
        # Nothing reaches an app before its stop (#75): the n-th paste follows the n-th stop.
        stops = seen = 0
        for line in log.splitlines():
            if "[App] stopRecording" in line:
                stops += 1
            elif "pasteAtCursor:" in line:
                seen += 1
                if seen > stops:
                    problems.append("a paste before its stop")
                    break
    for needle in a.logged:
        if needle not in log:
            problems.append(f"the Debug Log never says “{needle}”")
    targets = re.findall(r"paste target: (.+?)(?: \(started in|$)", log, re.M)
    if a.app and targets and targets[-1].strip() != a.app:
        problems.append(f"pasted into {targets[-1].strip()}, not {a.app} — something took the front")
    if "trusted=false" in log:
        problems.append("the e2e app has no Accessibility (run scripts/e2e.sh --setup)")

    score = wer(a.expected, body) if a.expected and not (a.empty or a.edit or a.refined) else None
    verdict = "FAIL" if problems else "pass"
    shown = body.replace("\n", " ").replace("|", "\\|")
    if len(shown) > 120:
        shown = shown[:117] + "…"
    print(f"| {a.name} | {verdict} | {pastes} | {'' if score is None else f'{score:.0%}'} "
          f"| {'; '.join(problems)} | {shown} |")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
