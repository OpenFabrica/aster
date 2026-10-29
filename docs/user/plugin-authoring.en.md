# Writing Aster Tool Plugins

You can add your own plugins to the Aster toolbox. A plugin is a folder with an `aster-plugin.json` file at its root.
Each "feature" of a plugin shows up on the Tools page of Open Quickly and in the Tools panel.

There are two ways to write a feature:

- **Script tool**: runs a program or script that comes with the plugin (any language) and shows its output.
- **Web tool**: a local web page (HTML + JS + CSS) that runs in a sandbox and talks to Aster through `window.aster`.

A plugin can also attach a status bar or a panel to the window all the time, for example a Git status bar at the bottom of
the terminal. See **Attaching UI to the Window**.

Examples that you can copy are in [plugin-examples](plugin-examples/): `hello-script` (script), `hello-web` (web), and
`hello-bar` (status bar).

## Get Started in Five Minutes

1. Copy `docs/user/plugin-examples/hello-script` to any location, for example `~/Code/hello-script`.
2. Open **Settings → Tools**, click **Add Development Folder…**, and choose that folder.
3. Aster lists the permissions that the plugin asks for. Allow them.
4. Press `⇧⌘O` and then `⌘U`, or open the Tools panel, and search for `hello`.

A development folder is only registered; Aster does not copy its files. When you change a file, Aster scans again and
reloads open web tools. When the plugin is ready, use **Install from Folder…** to install it: Aster copies the folder
into the plugins folder `~/Library/Application Support/Aster/Plugins/<id>/`.

## The Manifest `aster-plugin.json`

```json
{
  "schemaVersion": 1,
  "id": "com.example.jwt",
  "name": "JWT 解析",
  "version": "1.2.0",
  "description": "解析 JWT 的 header 与 payload",
  "author": "Example",
  "homepage": "https://example.com",
  "icon": "icon.svg",
  "ui": { "main": "index.html", "height": 420 },
  "permissions": ["clipboard.write", "terminal.insert"],
  "network": [],
  "features": [
    {
      "code": "decode",
      "title": "解析 JWT",
      "subtitle": "header / payload / 过期时间",
      "keywords": ["jwt", "token"],
      "match": [{ "type": "regex", "label": "解析这个 JWT", "pattern": "^eyJ[\\w-]+\\.[\\w-]+\\.[\\w-]*$" }],
      "action": { "type": "ui" }
    }
  ]
}
```

Aster checks the manifest strictly. If one rule fails, the whole plugin does not load, and **Settings → Tools → Problems**
shows which field is wrong.

| Field | Rule |
| --- | --- |
| `schemaVersion` | Must be `1`. |
| `id` | Lowercase, dot-separated, for example `com.example.jwt`, at most 128 bytes. The `aster.` prefix is reserved for built-in plugins. |
| `name` | 1–64 characters. |
| `version` | Semantic version, for example `1.0.0` or `1.2.0-beta.1`. |
| `description` / `author` | Optional, at most 512 / 128 characters. |
| `homepage` | Optional, must be an `https://` address. |
| `icon` | Optional, a relative path inside the plugin: `svg`, `png`, `jpg`, `jpeg`, or `pdf`. |
| `ui` | Required for web tools. `main` is the relative path of the entry HTML; `height` is the preferred height, 120–800, default 480. |
| `permissions` | The permissions that the plugin uses. See **Permissions** below. |
| `network` | Required when you declare the `network` permission: the host names that the plugin can reach, for example `api.github.com` or `*.example.com`, at most 16. |
| `features` | 1–32 features. A plugin that only attaches UI to the window can leave it out, but it needs at least one feature or one `contributes` view. |
| `contributes` | Optional. `views` declares status bars and panels that are attached to the window. See **Attaching UI to the Window**. |

Other rules:

- Unknown fields are always rejected, so a misspelled field name is an error.
- Paths must be relative paths inside the plugin: they cannot start with `/` and cannot contain `..`.
- Text fields cannot contain control characters.

### Features

| Field | Rule |
| --- | --- |
| `code` | Unique in the plugin: lowercase letters, digits, `_`, and `-`, at most 32 characters. |
| `title` | 1–64 characters; `subtitle` is optional, at most 128. |
| `keywords` | Search keywords, at most 8. Chinese titles also match pinyin and pinyin initials. |
| `match` | Content match rules, at most 8. When pasted content matches, the feature shows up under **Detected**. |
| `action` | How the feature runs: `ui`, `script`, or `builtin` (built-in plugins only). |

Each feature needs at least one keyword or one match rule.

### Content Matching (`match`)

```json
{ "type": "regex", "label": "解析这个 JWT", "pattern": "^eyJ…$", "minLength": 10, "maxLength": 8192 }
{ "type": "text", "label": "统计字数", "exclude": "^\\s*$", "maxLength": 100000 }
{ "type": "files", "label": "压缩图片", "fileType": "file", "extensions": ["png", "jpg"], "maxCount": 20 }
```

- `regex`: a regular expression (`NSRegularExpression` syntax), at most 512 characters. **A pattern that can match the
  empty string is rejected**, for example `.*`. `maxLength` defaults to 10,000; longer content is skipped and the regex does not run.
- `text`: matches any text. Use `exclude` to leave some content out. It only says "can handle text", so it
  comes after the keyword search results. Use `regex` to reach the top when the user pastes specific content.
- `files`: files dropped on the Tools panel. `fileType` is `file` or `directory`; use at most one of `extensions`
  (lowercase, without the dot) and `pattern`.
- `label`: the text on the **Detected** row, at most 64 characters.

## Script Tools

```json
{
  "code": "upper",
  "title": "转成大写",
  "keywords": ["upper"],
  "action": { "type": "script", "command": ["bin/upper.sh"], "output": "text", "stdin": "text", "timeout": 10 }
}
```

- The manifest must declare the `exec` permission.
- `command` is an argument array and **does not go through a shell**. `command[0]` can be written in three ways (see
  **Writing Scripts in Python or Node.js** below). A relative path inside the plugin must point to an executable file
  (`chmod +x bin/upper.sh`).
- Working directory: the directory of the source terminal, or your home folder.
- `timeout`: 1–60 seconds, default 10 (3 for `list`). On timeout Aster sends `SIGTERM`, then `SIGKILL` one second later.

### Input

With `stdin` set to `text` (the default), standard input is the raw text that you typed. With `json` it is:

```json
{
  "code": "upper",
  "query": "hello",
  "input": { "text": "hello", "files": [], "source": "typed" },
  "context": { "workingDirectory": "/Users/me/project", "isRemote": false, "locale": "zh-Hans", "appearance": "dark" }
}
```

The script gets only these environment variables, not the environment of Aster itself:

| Variable | Meaning |
| --- | --- |
| `PATH` | `/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin` |
| `HOME`, `USER`, `LOGNAME`, `LANG`, `TMPDIR`, `SHELL` | Same as your login environment |
| `ASTER_FEATURE` | The feature `code` |
| `ASTER_QUERY` | The text that you typed |
| `ASTER_CWD` | The directory of the source terminal (can be empty) |
| `ASTER_PLUGIN_ID` / `ASTER_PLUGIN_DIR` | Plugin id and plugin folder |
| `ASTER_PLUGIN_DATA` | The private data folder of the plugin, for caches |
| `ASTER_LOCALE` | Interface language, for example `zh-Hans` or `en` |

### Output (`output`)

| Value | What Aster does |
| --- | --- |
| `text` | Standard output is the result text (UTF-8, one trailing newline removed). You can copy it or prefill it into the terminal. |
| `list` | Standard output is `{"items":[{"title":"…","subtitle":"…","value":"…"}]}`. When you continue to type, the script runs again after 300 ms. |
| `none` | Only the exit status counts: success shows "Done", failure shows the error output. |
| `terminal` | Aster does not run it in the background. It runs the command in a new terminal tab, so you see all output. |

Each `list` item: `title` is required (at most 256), `subtitle` at most 512, `value` is what is copied or prefilled
(default: `title`, at most 64 KiB). Only the first 200 items are shown; a `title` or `subtitle` that is too long is
cut short; if any `value` is too long or any `title` is empty, the whole output is rejected.

Limits: standard output 1 MiB and error output 64 KiB; when a limit is exceeded, Aster stops the script and reports an
error. When the exit status is not 0, Aster shows the first 4 KiB of error output.

### Writing Scripts in Python or Node.js

A script can be written in any language. `command[0]` can be written in three ways:

| Form | Example | How Aster finds the program |
| --- | --- | --- |
| Bare name (no `/`) | `["python3", "bin/main.py"]`, `["node", "bin/main.js"]` | Aster first looks for an executable file with that name in the plugin folder. If there is none, it searches the fixed PATH folder by folder. |
| Relative path inside the plugin | `["bin/main.py"]` | Relative to the plugin folder. The file must be executable (`chmod +x`) and start with a shebang, for example `#!/usr/bin/env python3`. The resolved path must stay inside the plugin folder. |
| Absolute path | `["/opt/homebrew/bin/python3", "bin/main.py"]` | Used as it is. |

The fixed PATH is `/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin`. **Aster does not read your shell
configuration** (`.zshrc` and so on), so Python or Node installed with nvm, fnm, volta, or pyenv cannot be found.

- Installing with Homebrew (`brew install python node`) is the easiest way: the programs go to `/opt/homebrew/bin`, and
  the bare name works.
- Or use a shebang with an absolute path, for example `#!/Users/you/.nvm/versions/node/v22.0.0/bin/node`, and write only
  `["bin/main.js"]` in `command`.
- When the program is not found, a status bar view shows a message such as "node is not in PATH". A feature script shows
  the same error.

Input and output work the same way in every language: stdin, environment variables, and stdout. For a Python example, see
`plugin-examples/hello-bar/bin/bar.py`.

## Web Tools

```
my-tool/
  aster-plugin.json   "ui": { "main": "index.html", "height": 420 }
  index.html
  app.js
  style.css
```

The page loads from `aster-plugin://<plugin id>/` and can read only regular files inside the plugin folder. Security limits:

- **Inline scripts do not run.** Put JS in separate files and load them with `<script src="app.js"></script>`. Do not
  use attributes such as `onclick="…"`; use `addEventListener`. `eval` and `new Function` are blocked.
- **No direct network access** (`fetch`, `XMLHttpRequest`, external images, and external fonts are all blocked). To
  reach the network, declare the `network` permission and the domains, then use `aster.net.fetch`.
- The page cannot navigate to addresses outside the plugin. `http(s)` links that you click open in your default browser.
- Each plugin has its own storage, separate from other plugins.
- There is no `alert`, `confirm`, `prompt`, or `<input type=file>`: use `aster.files.pick` to choose files. When the user drops files on the page, the page can read them with the standard `drop` event and the File API.
- WebRTC is turned off.

### `window.aster`

```js
aster.onEnter(({ code, input, context, theme }) => {
  // Called when the tool opens; input.text is the user's input, context.locale is the interface language
});
aster.onQuery((text) => { /* The user continues to type in the Tools panel */ });
aster.onThemeChange(({ appearance }) => { /* "light" or "dark" */ });

await aster.getInput();                    // {code, input, context}
aster.setHeight(360);                      // 120–800
aster.close();

await aster.storage.set("history", [1, 2]); // Private to this plugin, at most 5 MiB in total
await aster.storage.get("history");
await aster.storage.remove("history");
await aster.storage.keys();

await aster.clipboard.writeText("…");      // Needs clipboard.write
await aster.clipboard.readText();          // Needs clipboard.read
await aster.terminal.insert("ls -la");     // Needs terminal.insert: prefills the source terminal, never presses Return
await aster.terminal.selection();          // Needs terminal.read
await aster.files.pick({ extensions: ["json"], multiple: false }); // Needs files.read
await aster.files.read(path, "utf8");      // Only files that were picked or passed in as input
await aster.net.fetch("https://api.github.com/zen", { method: "GET" }); // Needs network
await aster.notify("Done", "Processed 3 files"); // Needs notify
await aster.openURL("https://example.com"); // Asks the user first; returns whether the user agreed
```

`onEnter`, `onQuery`, and `onThemeChange` return a function; call it to unregister.

When an asynchronous method fails, it throws an `AsterError` (check with `err instanceof aster.AsterError`) with a `code` field:

| code | Meaning |
| --- | --- |
| `permission_denied` | The manifest does not declare the permission, or the user did not approve it. |
| `invalid_params` | A parameter has the wrong type or range. |
| `payload_too_large` | A limit was exceeded (2 MiB per message, 1 MiB text, 10 MiB file, 5 MiB network response). |
| `rate_limited` | More than 50 calls per second. |
| `unknown_method` / `unsupported_version` | This version of Aster does not support the method or protocol version. |
| `unavailable` | Not available now, for example because the source terminal is closed. |
| `failed` | Another failure; `message` has the reason. |

The page can also open without Aster, which helps debugging. Check with `if (window.aster) { … }`.

### Appearance and Language

- `document.documentElement.dataset.asterAppearance` is `light` or `dark` and follows Aster live.
  `prefers-color-scheme` also works.
- `context.locale` is the interface language of Aster: `zh-Hans`, `zh-Hant`, `en`, `ja`, `fr`, or `de`.

### Debugging

You can debug web tools from a development folder with the Safari Web Inspector: in Safari, turn on
**Settings → Advanced → Show features for web developers**, then find Aster and your plugin page in the **Develop** menu.
Installed plugins do not allow the inspector.

## Attaching UI to the Window

A plugin can do more than be called from the Tools panel. It can keep a piece of UI on the window all the time, for example
a Git status bar at the bottom of the terminal. Add `contributes.views` to the manifest. There are two kinds of view:

- **Status bar (`bar`)**: a narrow horizontal bar. Your script prints a JSON list of items, and Aster draws them with
  native controls (similar to xbar).
- **Panel (`panel`)**: a web page, written like a web tool, except that its entry is the `main` of the view.

> A plugin that uses `contributes` needs a new version of Aster. Older versions reject the whole plugin when they read
> this section.

### Where It Goes

| Position (`slot`) | Kind | Description | This version |
| --- | --- | --- | --- |
| `tab.top` | Status bar | Above the terminal area | Available |
| `tab.bottom` | Status bar | Below the terminal area | Available |
| `pane.bottom` | Status bar | At the bottom of each terminal pane, one bar per pane. The script gets the directory and the pane ID of that pane. | Available |
| `inspector.panel` | Panel | A tab in the Details panel (Inspector) | Available |
| `window.top` | Status bar | One full row at the very top of the window, in the same row as the traffic lights. When it is present, it owns that row and the path title moves back into the content area. | Available |
| `window.bottom` | Status bar | One full row at the very bottom of the window (below the tab bar in the bottom tab-bar layout) | Available |
| `sidebar.section` | Status bar (vertical list) / Panel | In the vertical tab bar, below the tab list. One block per view, titled with the view `title`. Shown only while the vertical tab bar is visible. | Available |
| `activePane.bottom` | Status bar | Only at the bottom of the focused terminal pane. When the focus moves to another pane, the bar moves with it. The context is the same as for `tab.*`. | Available |
| `pane.header` | Status bar (icons only) | At the top right of each terminal pane, left of the close and zoom buttons. It appears only when the pointer is near the top edge of the pane. Up to 3 icons; the context is the same as for `pane.bottom`. | Available |

`pane.bottom` is shown only on terminal panes (not on tool or file panes). Only the panes of the current tab run the
script. When you switch to another tab, they pause, and they run once when you come back. Moving the focus to another
pane does not run the script again. A `terminal` action on the bar writes to the pane that the bar is in.

`pane.header` shows icons only. Each item needs an `icon` or an `iconFile`; items with only text are not shown. The `text`
becomes the hover tooltip (the `tooltip` is used when you set one). The group shows at most 3 icons; more items are not
shown. The icons float above the terminal and do not take a terminal row. They hide when the pointer leaves the top edge,
and clicks then go to the terminal.

There is only one `activePane.bottom` bar per window. While a file, tool, or web pane has the focus, the bar is hidden;
it comes back when a terminal pane has the focus again. You can use it together with `pane.bottom`; the `pane.bottom` bar
is above it.

Except for `window.top` and `sidebar.section`, users can drag the edge of a horizontal bar to make it taller (up to 8 rows).
The items then wrap into rows and scroll when they do not fit. In a one-row bar, items that do not fit scroll from side to
side. The user decides the height of the bar; the manifest `height` is only the height of one row.

`window.top`, `window.bottom`, and `sidebar.section` take their context from the active pane of the current tab, like
`tab.*`. `window.top` is always 28 pt and stays even when it has no items (the traffic lights are on its left). Drag its
empty area to move the window; double-click it to zoom. In `sidebar.section`, a status bar is a vertical list with one
item per row and at most 32 items (a horizontal bar has at most 12). A panel there uses the manifest `height` (80–400,
default 240). The page can change it with `aster.setHeight()`, which is also limited to 80–400. When the tab bar is not
vertical, or is hidden, sidebar views are not shown and do not run.

Users can turn a view off or move it to another position in **Settings → Tools → Views**. A view can only move to a
position that accepts its kind and is available in this version.

### Manifest

```json
{
  "schemaVersion": 1,
  "id": "aster.gitbar",
  "name": "Git 状态条",
  "version": "1.0.0",
  "permissions": ["exec", "clipboard.write", "terminal.insert"],
  "contributes": {
    "views": [
      {
        "id": "branch",
        "title": "Git 分支",
        "kind": "bar",
        "slot": "activePane.bottom",
        "source": { "type": "script", "command": ["bin/gitbar.sh"], "timeout": 5 },
        "refresh": { "interval": 30, "on": ["cwd", "branch", "activePane"] }
      }
    ]
  }
}
```

This is the built-in Git status bar of Aster. It has no `features`, only a view, which is allowed.

| Field | Rule |
| --- | --- |
| `views` | 1–16 views. |
| `id` / `title` | `id` follows the rules of a feature `code` and is unique in the plugin; `title` is 1–64 characters. |
| `kind` / `slot` | The kind and the position. The position must accept the kind (`inspector.panel` accepts only `panel`; `tab.top` and similar accept only `bar`). |
| `height` | Height of a status bar, 22–28, default 26. |
| `source` | Required for a status bar: `{"type": "script", "command": […], "timeout": seconds}`. `command` follows the rules of script tools, and the manifest must declare `exec`. `timeout` is 1–30, default 5. |
| `refresh` | When a status bar refreshes. `interval` is the timer in seconds: 0 means refresh only on triggers, otherwise 5–3600, default 60. `on` lists the triggers, at most 4: `cwd` (directory changed), `branch` (Git branch changed), `activePane` (another pane became active), `agent` (agent state changed). Default `["cwd"]`. |
| `main` | Required for a panel: the entry HTML, a relative path ending in `.html`. A panel cannot have `source` or `refresh`. |

### Status Bar Scripts

Aster runs your script at suitable times: when the view first appears in a window, when the timer fires, when a trigger
in `on` happens, and when the user clicks refresh. The script does not go through a shell; the rules are the same as for
script tools.

**Input.** stdin is a JSON document:

```json
{ "view": "branch", "trigger": "cwd",
  "context": { "workingDirectory": "/Users/me/repo", "isRemote": false, "locale": "zh-Hans",
               "appearance": "dark", "branch": "main", "tabID": "…", "paneID": "…", "agent": null } }
```

`trigger` is the reason for this run: `initial`, `interval`, `cwd`, `branch`, `activePane`, `agent`, or `manual`.
The environment variables are the same as for script tools (`ASTER_CWD`, `ASTER_LOCALE`, `ASTER_PLUGIN_DIR`, and so on),
plus `ASTER_VIEW`, `ASTER_TRIGGER`, and `ASTER_BRANCH`. When an agent (Claude Code, Codex, and so on) runs in the pane,
`agent` is `{"provider": "codex", "state": "processing", "sessionID": "…"}`: `state` is `processing`, `idle`, or
`awaitingInput`, and `sessionID` is the agent session ID that Aster bound to this pane (`null` until it is bound). The
variables `ASTER_AGENT` and `ASTER_AGENT_SESSION` are also set. The built-in Codex and Claude Code rate bars use this to
read only the session of their own pane. A remote (SSH) tab has no local directory: `isRemote` is `true`
and `ASTER_CWD` is not set.

**Output.** Print one JSON document to stdout, at most 64 KiB:

```json
{
  "items": [
    { "id": "branch", "text": "main", "icon": "arrow.triangle.branch", "tooltip": "Branch main",
      "onClick": { "type": "copy", "text": "main" } },
    { "id": "ahead", "text": "↑2",
      "onClick": { "type": "terminal", "text": "git push", "mode": "insert" } },
    { "id": "dirty", "text": "●3", "color": "warning", "tooltip": "3 files changed" },
    { "id": "refresh", "icon": "arrow.clockwise", "onClick": { "type": "refresh" } }
  ],
  "ttl": 30
}
```

- At most 12 items. Each item needs a `text` (at most 64 characters, one line) or an icon; `tooltip` is at most 256 characters.
- `icon` is the name of an SF Symbol (lowercase letters, digits, and dots, for example `arrow.triangle.branch`). If the
  system has no such symbol, only the text is shown. You can also use `iconFile` to point to an icon file in the plugin.
- `color`: `#RRGGBB`, `#RRGGBBAA`, or `accent`, `success`, `warning`, `error`, `secondary` (these follow the theme and are
  recommended).
- `ttl` (5–3600 seconds) is optional. It tells Aster how long to wait before the next run.
- `{"items": []}` means there is nothing to show now, and the segment is hidden. A non-zero exit status means an error:
  the bar shows a warning, and a click tries again.
- An item with a wrong format is dropped. If the whole JSON is invalid, the whole output is rejected.

**Click actions (`onClick`).** Only the following actions exist; others are ignored. Each action needs a permission, and
it does not run if the manifest does not declare it:

| `type` | Parameters | What it does | Needs |
| --- | --- | --- | --- |
| `copy` | `text`, optional `concealed` | Copies to the clipboard | `clipboard.write` |
| `terminal` | `text`, `mode` is `insert` or `submit` | `insert` prefills the text into the active terminal without pressing Return; `submit` prefills it and runs it | `terminal.insert` |
| `openURL` | `url` (`http` / `https`) | Opens it in the browser; the user must confirm every time | — |
| `openPanel` | `view` | Opens a panel view of the same plugin | — |
| `refresh` | — | Runs the script again now | — |
| `feature` | `code`, optional `text` | Opens a feature of the same plugin in the Tools panel | — |

`submit` is the most sensitive. The text must not contain control characters, and Aster adds "↩ Run: …" to the tooltip so
that the user sees the command before clicking. Use `insert` whenever you can, and let the user press Return.

**How often it runs.** Aster is careful with status bar scripts. They do not run while the window cannot be seen (covered
or minimized), and run once more when it is visible again. After a trigger Aster waits 300 ms; one view runs at most once
every 5 seconds; after 3 failures in a row the interval gets longer. Keep scripts fast, and do not do slow network
requests in them.

**The Git status bar script** (`bin/gitbar.sh`) reads `ASTER_CWD` and uses `git status --porcelain=v2 --branch` to get the
branch, ahead/behind counts, and the number of changed files. When the directory is not a Git repository, `isRemote` is
`true`, or `git` fails, it prints `{"items":[],"ttl":600}`. The script of the built-in plugin is in
`Contents/Resources/tools-builtin/aster.gitbar/` inside the Aster app; you can copy and change it. For a complete minimal
example (in Python), see `plugin-examples/hello-bar`.

### Panels

A `panel` view is a web page. The sandbox and `window.aster` are the same as for web tools, and the entry is the `main` of
the view. There are two extra things:

- `aster.context.get()` returns the context of the current tab (directory, branch, language, appearance, and so on).
- `aster.onContextChange(callback)` receives the new context when the user switches tab, directory, or branch. The page
  is not reloaded.

A panel appears as a tab in the Details panel (with a puzzle-piece icon), and the user clicks the tab to switch to it.

## Permissions

| Permission | What it allows | Risk |
| --- | --- | --- |
| `clipboard.write` | Write to the clipboard | Low |
| `terminal.insert` | Prefill text into the source terminal without Return | Low |
| `notify` | Send system notifications | Low |
| `clipboard.read` | Read the clipboard | Medium |
| `terminal.read` | Read the selected text in the source terminal | Medium |
| `files.read` | Read files that the user picked or passed in as input | Medium |
| `network` | Reach the domains listed in `network` | Medium |
| `exec` | Run programs or scripts that come with the plugin | High |

Before a plugin runs for the first time, Aster lists the permissions it asks for, and the user decides. Aster asks again when:

- A new version asks for more permissions or network domains.
- The files of an installed plugin changed (Aster keeps a digest of the files). Plugins in a development folder are not
  compared, so you can edit and try them freely.

Approvals are stored only in `~/Library/Application Support/Aster/tools-state.json`, not in `settings.json`; importing
settings never brings plugin approvals. Declare only the permissions that you use: the fewer you ask for, the easier
it is for users to allow them.

## Frequently Asked Questions

**My plugin does not show up.** Look at **Settings → Tools → Problems**. It tells you which manifest field is wrong.
After you fix it, click **Rescan**.

**The script cannot run.** Make the script executable: `chmod +x bin/your-script`. Put the interpreter on the first
line, for example `#!/bin/sh` or `#!/usr/bin/env python3`. Remember that `PATH` contains only the folders listed above.

**Buttons on the web page do nothing.** Most likely the page uses an inline script or an `onclick=` attribute, which
the security policy blocks. Move the code to a separate JS file and use `addEventListener`.

**`fetch` fails.** Web pages cannot reach the network directly. Use `aster.net.fetch` and declare the `network`
permission and the domains in the manifest.
