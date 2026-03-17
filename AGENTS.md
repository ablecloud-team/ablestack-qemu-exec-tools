# Repository Rules

- Do not modify binary files under any circumstance unless the user explicitly requests it.
- Treat common binary artifacts as read-only during analysis, validation, and refactoring. This includes files such as `*.gz`, `*.zip`, `*.7z`, `*.xz`, `*.bz2`, `*.iso`, `*.img`, `*.qcow2`, `*.vmdk`, `*.exe`, `*.msi`, `*.dll`, `*.so`, `*.dylib`, `*.jar`, `*.war`, `*.ear`, `*.pdf`, `*.png`, `*.jpg`, `*.jpeg`, `*.gif`, `*.ico`, `*.woff`, `*.woff2`, and similar packaged or compiled artifacts.
- Do not re-encode, normalize line endings, rename, replace, or regenerate such binary files unless the user explicitly asks for that exact change.
- When a task touches paths that may be binary, prefer inspecting metadata only and stop before editing if there is any doubt.
