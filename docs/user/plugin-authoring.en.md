# Writing Aster Tool Plugins

You can add your own plugins to the Aster toolbox. A plugin is a folder with an `aster-plugin.json` file at its root.
Each "feature" of a plugin shows up on the Tools page of Open Quickly and in the Tools panel.

There are two ways to write a feature:

- **Script tool**: runs a program or script that comes with the plugin (any language) and shows its output.
- **Web tool**: a local web page (HTML + JS + CSS) that runs in a sandbox and talks to Aster through `window.aster`.

Two examples that you can copy are in [plugin-examples](plugin-examples/): `hello-script` (script) and `hello-web` (web).

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
| `features` | 1–32 features. |

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
- `command` is an argument array and **does not go through a shell**. A relative `command[0]` is relative to the plugin
  folder and must be executable (`chmod +x bin/upper.sh`).
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
