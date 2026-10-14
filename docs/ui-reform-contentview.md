# UI Reform - ContentView Specification

## Overview
Proposed improvements to ContentView UI (do NOT edit the file - this is a specification). Focus on clarity, accessibility, and preserving all existing behavior.

## Goals
- Fix "poor UI" with minimal, surgical changes
- Follow macOS HIG, SwiftUI patterns, and accessibility guidelines
- Preserve: freio (scrollHold), sleep timer, diagnóstico, trilho, seguimento (follow reading)
- Never rely on color alone for state
- All controls must have accessibility labels/hints

## Proposed Changes

### 1. Header Bar (Fixed)
- Show document title (filename), current page, voice, and status
- Persistent during reading (never disappears)
- Already partially implemented via PDFDocumentView header

### 2. Play Controls Menu
- Play/pause/stop clearly labeled with printed shortcuts: Enter, ⌘., ⌥←, ⌥→
- Maintain existing keyboard shortcuts
- All buttons have explicit accessibility labels

### 3. Text Disclosure
- Larger, clearer with hint text "Click the phrase to jump to it"
- Improved accessibility (label + hint)
- Preserve clickable phrases behavior

### 4. Status Line (Persistent)
- Show current status from controller (persistent)
- Sleep timer state visible when active
- Resume indication when applicable
- Never rely solely on color for meaning

### 5. Voice Picker with Search (Future)
- Add `.searchable()` to voice picker in Settings/ContentView if needed
- Keep existing grouped sections (Offline/English/Portuguese)
- Avoid breaking current selection behavior

## Constraints
- Do NOT edit ContentView.swift (spec only)
- Do NOT touch the 5 files edited by other agent
- Preserve all engine logic, no audio synthesis changes
- Minimal diffs, no large refactors
- Tests must remain green

## Implementation Priority
1. Accessibility labels/hints (done where possible in free files)
2. Header clarity (PDFDocumentView header added)
3. Text panel hint (done)
4. Empty state clarity (done)

## Conclusion
Improvements focus on information hierarchy and accessibility without changing core behavior (freio/sleep/diagnóstico/trilho/seguimento remain intact).
