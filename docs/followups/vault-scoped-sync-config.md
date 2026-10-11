# Follow-up: sync config is not scoped to the vault

## Problem

`WebDAVFolderConfig` is keyed by the folder's **name** (e.g. `drafts`), with no
record of which directory that folder lives in.

On macOS this rarely bites, because there is normally only one directory in play.
It is a latent bug, not a safe design.

## What goes wrong once a second directory can appear

Two directories that each contain a folder called `drafts`:

```
~/Documents/MarkIt/drafts     configured for server A
~/Documents/MarkIt2/drafts    a different folder entirely
```

The second one hits the first one's config:

1. It resolves server A's credentials, including the saved password.
2. The manifest says server A already holds `A.md` and `B.md` -- those belong
   to the *other* directory.
3. Diffing the new directory against that manifest finds nothing to send, so
   new notes never upload.
4. The same manifest sees `A.md` and `B.md` as locally absent, treats them as
   deletions, and removes them from the server.

Step 4 is not recoverable.

## Fix, when it is picked up

Give the config a vault identity and match on the pair:

- A stable ID for the directory (hash of its bookmark / path -- not the raw
  path, which would put user names on disk).
- `WebDAVFolderConfig` gains a `vaultId` field.
- Lookup and the manifest key become `(vaultId, folderPath)`.

Read legacy entries without a `vaultId` as belonging to the current directory,
and stamp it on first write, so upgrading does not cost the user their config.

## Why this is tracked here rather than just in the Android port

The Android port hit this first because switching the storage directory is an
ordinary thing to do on a phone. The same data model was carried across, so
the fix belongs in both places. Fixing Android first means the design decision
lands somewhere it was already thought through.

## Related

- The Android side treats "sync configuration disappears on a directory switch"
  as *invalid*, not *deleted*, so switching back restores it. The Mac side has
  no equivalent switch today.
- WebDAV passwords are stored in plain text in user defaults on both platforms.
  Neither is encrypted at rest. Worth its own change.
