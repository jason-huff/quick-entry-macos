#!/usr/bin/env python3
"""Sync only reviewed viewer components from another QuickEntry.swift.

Usage: python3 scripts/sync-viewer.py /path/to/QuickEntry.swift [--check]
Never copies storage, agent prompts, user configuration, or capture/writing code.
"""
import argparse
from pathlib import Path

COMPONENTS = [
    ("private enum TodoLayout {", "\nenum ModeTextRollDirection"),
    ("private func firstURLAndTitle(", "\nprivate func conciseMetadata"),
    ("final class CASEMenuHeaderView:", "\nfinal class CASEMenuEmptyView"),
    ("final class CASELogbookRowView:", "\nfinal class CASECheckboxView"),
    ("final class CASELinkButton:", "\nfinal class CASESpinnerView"),
    ("final class CASEShimmerLabel:", "\nfinal class CASEModeTabs"),
    ("final class CASEContextRowView:", "\nfinal class CASEMenuActionView"),
]

def block(text, start, end):
    left = text.index(start)
    return left, text.index(end, left)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    target = Path(__file__).resolve().parents[1] / 'QuickEntry.swift'
    incoming, current = args.source.read_text(), target.read_text()
    updated = current
    for start, end in COMPONENTS:
        a, b = block(incoming, start, end)
        if start not in updated and start in {'private enum TodoLayout {', 'final class CASEContextRowView:'}:
            marker = end
            updated = updated.replace(marker, '\n' + incoming[a:b] + marker, 1)
        else:
            c, d = block(updated, start, end)
            updated = updated[:c] + incoming[a:b] + updated[d:]
    if args.check:
        if updated != current:
            raise SystemExit('Viewer components differ; review and sync them.')
        print('Viewer components match.')
    else:
        target.write_text(updated)
        print('Synced allowlisted viewer components only.')
