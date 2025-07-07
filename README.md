# ttf.zig

A tool to extract ttf/otf subsets.

WIP

### Environment

Before run this porject pls ensure that your local zig version is the latest stable version. I recommend using [`zvm`](https://github.com/tristanisham/zvm) to manager zig version.

### Notes for Developers

- This project uses **Git LFS** to manage large files such as font files (`.ttf`, `.otf`) for testing.
- **Before cloning or pulling this repository, please make sure you have [Git LFS](https://git-lfs.github.com/) installed and initialized:**
  ```sh
  git lfs install
  ```
- Do **not** add font files to `.gitignore` if you want them tracked by LFS.
- When adding new font files, simply use `git add` as usual; LFS will handle them automatically.
- If you encounter issues with missing or corrupted font files after cloning, ensure Git LFS is installed and run:
  ```sh
  git lfs pull
  ```
- Be aware that public Git LFS services (such as GitHub LFS) have storage and bandwidth limits.

### Specifications

- https://developer.apple.com/fonts/TrueType-Reference-Manual/
- https://docs.microsoft.com/en-us/typography/opentype/spec/

### LICENSE

[MIT](./LICENSE)

#### Auth

Kanno
