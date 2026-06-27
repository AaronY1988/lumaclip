// UndoRegistry.swift
// LumaClip - macOS Clipboard Manager
//
// In-memory undo/redo stack for the clipboard history UI.
//
// A misplaced click in a clipboard manager is particularly painful —
// deleting the wrong clip loses data that can't easily be reconstructed.
// This registry captures the inverse of each destructive action so
// `Cmd+Z` can walk the history back, and `Cmd+Shift+Z` replays it
// forward. Only mutations with cheap inverses are recorded: soft
// delete, pin toggle, favorite toggle, and category change. Permanent
// deletes and Empty-Trash are *not* tracked — those are communicated
// to the user as irreversible in the UI.
//
// The stack is intentionally session-scoped (not persisted) because
// undoing across restarts would introduce confusing semantics and
// couple the registry to database migration.

import Foundation

// MARK: - Undoable Action

/// A reversible mutation, captured with enough state to replay or
/// reverse it without re-querying the database. Actions are pushed
/// *before* the mutation is applied so the inverse can be reconstructed
/// from the pre-mutation state.
enum UndoableAction: Equatable {
    /// A soft-delete. Inverse is `restore`.
    case deletion(itemID: UUID)

    /// A pin toggle. `previousValue` is the state *before* the toggle
    /// so undo can re-toggle back to it (not just flip, which would
    /// double-apply if the state changed via another path).
    case pinToggle(itemID: UUID, previousValue: Bool)

    /// A favorite toggle. Same `previousValue` semantics as pin.
    case favoriteToggle(itemID: UUID, previousValue: Bool)

    /// A category change. Unlike pin/favorite — which are booleans and
    /// therefore redo-derivable from their previous value — a category
    /// change needs both sides captured so redo can re-apply the
    /// original target without a second database lookup.
    case categoryChange(itemID: UUID, previousCategoryId: UUID?, newCategoryId: UUID?)
}

// MARK: - Registry

/// Bounded undo/redo stack. Thread-unsafe by design — all clipboard
/// mutations are driven from the main actor, so the registry is only
/// ever touched there.
struct UndoRegistry {

    /// Depth cap. 25 actions covers "I was just dragging things around"
    /// without letting the stack grow unbounded in long sessions. Hitting
    /// the cap drops the *oldest* action, matching typical macOS undo.
    static let maxDepth = 25

    private(set) var undoStack: [UndoableAction] = []
    private(set) var redoStack: [UndoableAction] = []

    // MARK: - Observability

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Peek at the top undoable action without popping. Useful for
    /// menu-item labels ("Undo Delete", "Undo Pin", etc.).
    var peekUndo: UndoableAction? { undoStack.last }
    var peekRedo: UndoableAction? { redoStack.last }

    // MARK: - Recording

    /// Push a new action. Called *before* applying the mutation so the
    /// inverse is derivable from the captured state. A fresh action
    /// clears the redo stack — the user has taken a new branch and the
    /// previously redo-available future is no longer reachable (same as
    /// every undo stack in every editor).
    mutating func record(_ action: UndoableAction) {
        undoStack.append(action)
        if undoStack.count > Self.maxDepth {
            undoStack.removeFirst(undoStack.count - Self.maxDepth)
        }
        redoStack.removeAll()
    }

    // MARK: - Walking

    /// Pop an action for undo, also pushing it onto the redo stack so
    /// `Cmd+Shift+Z` can replay it. Returns `nil` when the stack is empty.
    mutating func popForUndo() -> UndoableAction? {
        guard let action = undoStack.popLast() else { return nil }
        redoStack.append(action)
        return action
    }

    /// Pop an action for redo, also pushing it back onto the undo stack.
    mutating func popForRedo() -> UndoableAction? {
        guard let action = redoStack.popLast() else { return nil }
        undoStack.append(action)
        return action
    }

    /// Drop the entire history. Called when the user performs an
    /// irreversible action (empty trash, reset all) so stale undo
    /// entries pointing at now-gone item IDs can't fire.
    mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
