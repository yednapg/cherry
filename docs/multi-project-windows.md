# Multi-project windows

Cherry keeps project and window ownership separate:

- A window owns one `ProjectWindowModel` and one `ProjectWindowChromeState`.
- The model can retain multiple `ProjectWorkspaceContext` instances.
- Each context owns the repository, notes, todos, and aggregate agent status for
  one canonical project root.
- Only one context is active in a window at a time, but inactive contexts keep
  their terminal sessions and project-specific selection state.

## Opening and activating projects

`ProjectWindowModel.activate(projectRoot:)` is the entry point for switching a
window to a project or one of its worktrees. Before loading a new context, it
asks `ProjectWindowRegistry` whether another window already owns that project.
If so, the registry focuses the existing window instead of loading the project
twice.

Switching projects saves the outgoing context's note, todo, collapsed-group,
and command selection. The incoming context restores its own selection before
the repository activates a requested worktree. A newly loaded context starts
its configured auto-start commands once.

A project can also be loaded without activation. The sidebar uses this for
background disclosure and command creation so expanding a project does not
replace the window's current selection.

## Registry routing

`ProjectWindowRegistry` remains the application-wide router for menu commands,
deep links, MCP requests, and process lookup. Window registration associates an
`NSWindow` with its `ProjectWindowModel`; project-scoped lookups then resolve a
context through that model.

The model notifies the registry whenever its active project changes. The
registry must not retain windows, models, workspaces, or stores strongly because
closing a window owns their lifetime.

## Hidden projects and activity

Inactive project contexts keep their PTYs alive. `ProjectAggregateStatus`
subscribes to repository, workspace, and session changes so the sidebar can show
working, unread, permission, and error state for hidden projects.

Detached native Ghostty surfaces do not always emit render callbacks. While an
agent is running in a hidden context, the aggregate status performs a one-second
refresh that pulls the session's rendered line count before recomputing status.
This polling is a compatibility path for detached surfaces, not the primary
event-delivery mechanism.

## Closing and removing

Closing a window calls `ProjectWindowModel.closeAllSessions()`, which delegates
to every retained context and stops all of their processes. Removing a project
closes that project's sessions, clears its sidebar state, removes it from
settings, and activates the first remaining configured project with its default
terminal.

When changing this lifecycle, preserve these invariants:

1. A project is active in at most one window.
2. Switching projects does not stop hidden sessions.
3. Closing a window stops sessions from every context it owns.
4. Project-specific selections do not leak between contexts.
5. Loading a background project does not change the active project.
