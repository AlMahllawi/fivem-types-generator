<div align="center">

  <img src="https://raw.githubusercontent.com/AlMahllawi/fivem-lua-definitions/main/assets/banner.png" alt="FiveM Lua Definitions Banner" width="100%" />

  [![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
  [![VS Code Extension](https://img.shields.io/badge/VS_Code-Extension-007ACC?logo=visualstudiocode&logoColor=white)](https://marketplace.visualstudio.com/items?itemName=AlMahllawi.fivem-lua-definitions)
  [![CLI Tool](https://img.shields.io/badge/CLI-Standalone_Lua-000080?logo=lua&logoColor=white)](#command-line-usage)
  [![Release Workflow](https://github.com/AlMahllawi/fivem-lua-definitions/actions/workflows/release.yml/badge.svg)](https://github.com/AlMahllawi/fivem-lua-definitions/actions/workflows/release.yml)
  [![GitHub Release](https://img.shields.io/github/v/release/AlMahllawi/fivem-lua-definitions?include_prereleases&logo=github)](https://github.com/AlMahllawi/fivem-lua-definitions/releases)
</div>

---

A standalone Lua tool and **VS Code Extension** that leverages the internal AST parser of the [Lua Language Server (LuaLS)](https://github.com/LuaLS/lua-language-server) to generate `.d.lua` type definitions for FiveM resources.

Unlike naive regex-based parsers, this tool runs your resource through LuaLS's actual parser, perfectly extracting classes, enums, aliases, overloads, and dynamic exports natively.

<p align="center">
  <img src="https://raw.githubusercontent.com/AlMahllawi/fivem-lua-definitions/main/assets/vscode-intellisense.png" alt="FiveM Lua Definitions IntelliSense Demo" width="90%" />
</p>

## Features

- **Automatic VS Code Integration:** Integrated diagnostics (Problems tab) and background generation upon saving manifests.
- **Dynamic Exports Generation:** Parses `fxmanifest.lua` (or `__resource.lua`) and intelligently generates `Exports:xyz()` definitions, including resolving `exports("xyz", function)`.
- **Standalone Document Preservation:** Accurately extracts `---@class`, `---@enum` (including the source table), and `---@alias` annotations without corrupting them.
- **Global Variable AST Parsing:** Extracts complete documentation blocks attached to `setglobal` nodes and function declarations (including `---@overload`s).
- **Fallback Type Inference:** Automatically deduces runtime types for global variables lacking explicit annotations using LuaLS's internal `vm.getInfer()` engine.
- **FiveM Syntax Support:** Natively supports nonstandard FiveM Lua operators like Jenkins hash backticks (`` `hash` ``) and compound assignments (`+=`, `-=`, etc).
- **Workspace Ignore Directory:** Automatically registers the output folder to your Lua extension config (`Lua.workspace.ignoreDir`) so your IDE avoids duplicate symbol warnings!

## Prerequisites

**For VS Code Users (Recommended):**
- You must have the [Lua](https://marketplace.visualstudio.com/items?itemName=sumneko.lua) extension installed in VS Code.

**For CLI Users:**
- A pre-compiled `lua-language-server` binary installed on your system.
  - Download it from the [LuaLS Releases page](https://github.com/LuaLS/lua-language-server/releases).

## Usage

### VS Code Extension (Recommended)

1. **Install the Extension:** Download the latest `.vsix` file from the [GitHub Releases](https://github.com/AlMahllawi/fivem-lua-definitions/releases), then install it in VS Code via the Command Palette: **Extensions: Install from VSIX...**
2. **Automatic Generation:** Once installed, saving any `fxmanifest.lua` or `__resource.lua` file within your workspace will automatically regenerate the definitions in the background. Errors and warnings will show in your VS Code **Problems** tab.
3. **Manual Generation:** Open the Command Palette (`Ctrl+Shift+P` or `Cmd+Shift+P`) and run **FiveM: Generate Lua Definitions**.

<p align="center">
  <img src="https://raw.githubusercontent.com/AlMahllawi/fivem-lua-definitions/main/assets/vscode-command.png" alt="VS Code Command Palette" width="85%" />
  <img src="https://raw.githubusercontent.com/AlMahllawi/fivem-lua-definitions/main/assets/vscode-problem.png" alt="VS Code Problems Diagnostics" width="85%" />
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/AlMahllawi/fivem-lua-definitions/main/assets/vscode-status-bar-quick-pick.png" alt="VS Code Status Bar Configuration" width="85%" />
</p>

#### Extension Settings

| Setting | Type | Default | Description |
|---|---|---|---|
| `fivemLuaDefinitions.generateOnSave` | `boolean` | `true` | Automatically regenerate definitions when saving `fxmanifest.lua` or `__resource.lua`. |

### Command Line Usage

Run the `lua-language-server` binary and pass this script as its first argument, followed by the path to your FiveM resource, and optionally the output directory.

```bash
/path/to/lua-language-server /path/to/fivem-lua-definitions/generator.lua [--name <resource_name>] <resource_directory> [output_directory]
```

**Examples:**

```bash
# Output defaults to ./my_resource/definitions/
$ lua-language-server generator.lua ./my_resource
Generating FiveM lua definitions for: /absolute/path/to/my_resource
Output directory: /absolute/path/to/my_resource/definitions

# Specifying a custom output directory:
$ lua-language-server generator.lua ./my_resource ./my_resource/out_definitions
Generating FiveM lua definitions for: /absolute/path/to/my_resource
Output directory: /absolute/path/to/my_resource/out_definitions

# Specifying a custom resource name for exports:
$ lua-language-server generator.lua --name "my-custom-name" ./my_resource
Generating FiveM lua definitions for: /absolute/path/to/my_resource
Output directory: /absolute/path/to/my_resource/definitions

# Output as JSON for tooling:
$ lua-language-server generator.lua --json ./my_resource
{"success":true,"warnings":[],"errors":[]}
```

### GitHub Actions (Reusable Workflow & Action)

#### 1. Reusable Workflow (One-Click Setup)
In your FiveM resource repository, create `.github/workflows/generate.yml`:

```yaml
name: Generate Lua Definitions

on:
  push:
    branches: [ main, master ]
  pull_request:
  workflow_dispatch:

jobs:
  definitions:
    uses: AlMahllawi/fivem-lua-definitions/.github/workflows/generate.yml@v1.0.0
    permissions:
      contents: write
    with:
      resource-path: '.'
      output-path: './definitions'
      resource-name: 'my-resource' # Optional, defaults to directory name
      commit-changes: true
```

#### 2. Composite Action
If you want to invoke only the generator step within your own custom workflow jobs:

```yaml
- name: Generate FiveM Definitions
  id: definitions
  uses: AlMahllawi/fivem-lua-definitions/.github/actions/generate@v1.0.0
  with:
    resource-path: '.'
    output-path: './definitions'
    resource-name: 'my-resource' # Optional, defaults to directory name
```

## Custom Manifest Properties

To configure the generator, you can add custom arrays to your `fxmanifest.lua` or `__resource.lua` file:

- `generate_definitions` (or `generate_definition`): Files containing type definitions that should be exported and shared across your resource via AST extraction.
- `copy_definitions` (or `copy_definition`): Hand-written `.d.lua` files that should be directly copied to the output directory without AST processing.

The tool uses standard glob matching (supporting recursive wildcards like `**/*.lua`), evaluating paths relative to your resource directory:

```lua
-- fxmanifest.lua
fx_version 'cerulean'
game 'gta5'

-- Standard FiveM exports
exports {
    'GetPlayerMoney',
    'SetPlayerMoney'
}

-- Custom property for type definitions generation via AST
-- (Default behavior: mirrors exact folder structure in the output directory)

-- Singular property for a single file
generate_definition 'single/file.lua'

-- Singular property with a custom output path
generate_definition 'single/file.lua' 'custom/output.d.lua'

-- Array property for multiple files
generate_definitions {
    'imports/*.lua'
}

-- You can optionally specify a custom output file path to bundle extracted definitions
generate_definitions {
    'imports/definitions.lua',
    'modules/**/definitions/*.lua'
} 'external/definitions.d.lua'

-- Directly copy a single definition file to the output directory
copy_definition 'single/manual_definitions.d.lua'

-- Singular property to copy with a custom output path
copy_definition 'single/manual_definitions.d.lua' 'custom_manual_definitions.d.lua'

-- Array property to copy multiple definition files
copy_definitions {
    'manual_definitions.d.lua',
    'libs/**/*.d.lua'
}

-- You can also specify a custom output path to bundle/merge copied definitions!
copy_definitions {
    'libs/a.d.lua',
    'libs/b.d.lua'
} 'bundled_libs.d.lua'
```

> [!NOTE]
> **Custom Output Paths are relative to the generator's output directory.**
> Since the default `out_dir` is already `definitions/`, there's no need to prepend `definitions/` to your custom output paths in the manifest. For example, specifying `'definitions/external/definitions.d.lua'` would result in `'definitions/definitions/external/definitions.d.lua'` in the final output.

> [!TIP]
> **When to use `copy_definitions`:**
> This should not be used for regular definitions! It is designed for edge cases or manually defining definitions that the AST generator cannot infer:
> 
> 1. **State Bags (`GlobalState` / `Player.state`):** State Bags are dynamic network properties managed by the FiveM C++ engine. Because you assign them dynamically at runtime (e.g. `Player(1).state.isDead = true`), static AST cannot figure out what custom properties exist on your state bags.
> 2. **C# or JavaScript Exports:** The Lua Language Server AST can only parse `.lua` files. If you have a C# or JS script in your resource that registers an export, you have to write a manual `.d.lua` stub so Lua scripts get IntelliSense for it.
> 3. **Third-Party External Libraries:** If your resource relies on another resource, but you want to provide typing for it out-of-the-box without forcing the user to download the external dependency into their workspace, you can manually ship a `.d.lua` stub.
> 4. **Extreme Metatable Magic:** If your framework dynamically generates its classes using `__index` loops, database queries, or `load()` strings at runtime, the static AST parser won't be able to "see" the resulting structure.

<p align="center">
  <img src="https://raw.githubusercontent.com/AlMahllawi/fivem-lua-definitions/main/assets/generated-output.png" alt="Generated Output Structure and Definitions" width="85%" />
</p>

## Lua Definitions Sync

You can automatically sync and download Lua definitions from other GitHub repositories using a `lua-definitions.json` configuration file. This is useful for pulling in definitions from external frameworks or libraries without checking them into your own repository.

### Configuration

Create a `lua-definitions.json` file in your resource root directory:

```json
{
  "target_dir": "./definitions_vendor",
  "sources": [
    {
      "id": "my-library-definitions",
      "owner": "SomeOwner",
      "repo": "SomeRepo",
      "ref": "main",
      "paths": [
        { "path": "definitions", "pattern": "*.lua", "recursive": true }
      ]
    }
  ]
}
```

#### Configuration Reference

| Field | Required | Default | Description |
|---|---|---|---|
| `target_dir` | No | `./definitions_vendor` | Root directory where all synced definitions are written. Keep it separate from the generator's output directory (`definitions` by default), which is replaced on every generation. |
| `sources[].id` | Yes | — | Unique identifier for the source, shown in logs. |
| `sources[].owner` | Yes | — | GitHub repository owner (user or organization). |
| `sources[].repo` | Yes | — | GitHub repository name. |
| `sources[].ref` | No | `main` | Branch, tag, or commit SHA to fetch from. |
| `sources[].dest` | No | value of `id` | Subfolder inside `target_dir` to write this source's files to. |
| `sources[].paths[].path` | Yes | — | File or directory path inside the repository. |
| `sources[].paths[].pattern` | No | `*.lua` | Glob pattern that file names must match. |
| `sources[].paths[].recursive` | No | `false` | Descend into subdirectories when `path` is a directory. |

#### Advanced Example

Pull from multiple repositories, pin one to a release tag, mix directory and single-file paths, and control each source's output folder with `dest`:

```json
{
  "target_dir": "./definitions_vendor",
  "sources": [
    {
      "id": "core-engine",
      "owner": "organization-name",
      "repo": "engine-core",
      "ref": "main",
      "paths": [
        { "path": "api/definitions", "recursive": true },
        { "path": "runtime/definitions.d.lua" }
      ],
      "dest": "core"
    },
    {
      "id": "ui-library",
      "owner": "organization-name",
      "repo": "ui-framework",
      "ref": "v2.1.0",
      "paths": [
        { "path": "definitions", "pattern": "*.lua" }
      ],
      "dest": "ui"
    }
  ]
}
```

This produces:

```text
definitions_vendor/
├── core/   # api/definitions/** and runtime/definitions.d.lua from engine-core@main
└── ui/     # definitions/*.lua from ui-framework@v2.1.0
```

#### How Syncing Updates Files

Each sync is a clean replace, so files removed or renamed upstream don't linger:

- **Per-source replace:** Each source is downloaded into a temporary folder first. Only if every file downloads successfully is the source's `dest` folder deleted and swapped for the new copy. If anything fails (rate limit, bad `ref`, network error), the previous files are kept untouched.
- **Removed sources are cleaned up:** The synced folders are recorded in `<target_dir>/.lua-definitions-sync`. When a source is removed from the config (or its `dest` changes), its old folder is deleted on the next sync.
- **Everything else is left alone:** Only folders that sync created are ever deleted, so other files in `target_dir` are safe. Don't hand-edit files inside a source's `dest` folder, since they will be overwritten.
- **Safety checks:** A `dest` must be a relative path inside `target_dir` (no `..`, `.`, or absolute paths), and two sources can't share a `dest` or nest one inside another. Sources that break these rules are skipped with an error.

> [!TIP]
> The sync scripts use the GitHub REST API, which is rate-limited for unauthenticated requests. Set a `GITHUB_TOKEN` environment variable to raise the limit or to sync from private repositories.

#### Version Control

**Gitignore `definitions_vendor/`, but commit `lua-definitions.json`.** Like `node_modules`, synced definitions are fully reproducible from the config, so committing them only adds noisy diffs and copies of other people's code. Anyone cloning the resource runs the sync once to get them. Pin each source's `ref` to a tag or commit SHA if you want everyone to get identical files.

**Do commit the generator's `definitions/`.** That folder is what other resources sync from your repository, so it has to be in Git.

```gitignore
# Synced third-party definitions (restore with the sync script)
definitions_vendor/

# Temporary folder left behind if a generator run is interrupted
.definitions.tmp-*/
```

> [!NOTE]
> Commit `definitions_vendor/` instead only if the resource must work without running sync, e.g. teammates without `curl`/`jq`, offline setups, or sources that may disappear upstream. If you do, commit `.lua-definitions-sync` too, so removed sources are still cleaned up on the next sync.

### Usage

**For VS Code Users:**
Open the Command Palette (`Ctrl+Shift+P` or `Cmd+Shift+P`) and run **FiveM: Sync Lua Definitions**. This will automatically detect your OS and run the appropriate sync script inside a new terminal.

**For CLI Users:**
You can run the sync scripts directly from your terminal. Make sure your terminal's current working directory is the folder containing your `lua-definitions.json`.

If you have the repository cloned locally:
**Linux / macOS:**
```bash
bash /path/to/fivem-lua-definitions/sync.sh
```

**Windows:**
```powershell
powershell -ExecutionPolicy Bypass -File "C:\path\to\fivem-lua-definitions\sync.ps1"
```

If you don't have the repository cloned, you can run it directly from the internet using a one-liner:

**Linux / macOS (via curl):**
```bash
curl -sL https://raw.githubusercontent.com/AlMahllawi/fivem-lua-definitions/main/sync.sh | bash
```

**Windows (via PowerShell):**
```powershell
Invoke-Expression (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/AlMahllawi/fivem-lua-definitions/main/sync.ps1" -UseBasicParsing).Content
```

## Custom Behaviors & Edge Cases

When running the generator, it applies the following logic seamlessly:

1. **Exports Extraction:** It executes the manifest file inside an isolated sandbox to extract registered `exports`, `server_exports`, and `client_exports`. It then uses **static AST analysis** (without executing the code) to scan the source files for functions assigned to these names, or defined explicitly via `exports("xyz", function)`. *(Note: Because the source scripts are only statically read and never executed, exports assigned via dynamic variables like `exports[myVar]` cannot be resolved.)*
2. **Definition Mirroring:** Every file matched by the `generate_definitions` globs will generate a corresponding `.d.lua` clone mirroring its exact structure inside the output directory (e.g. `imports/definitions.lua` -> `definitions/imports/definitions.d.lua`).
3. **Atomic Output Replacement:** Definitions are first written to a temporary folder next to the output directory (e.g. `.definitions.tmp-*`). Only after everything is generated successfully is the previous output directory deleted and replaced, so a failed run leaves your existing definitions untouched. Leftover temporary folders from interrupted runs are cleaned up automatically on the next run.
4. **Output Directory Is Fully Managed:** Every successful run replaces the entire output directory, so anything else placed inside it (including files from [Lua Definitions Sync](#lua-definitions-sync)) is removed. Sync writes to `definitions_vendor/` by default to stay out of the way; if a `lua-definitions.json` in the resource sets a `target_dir` that overlaps the output directory, generation stops with an error before anything is deleted.
