# Miscellaneous

## Testing all plugins

```bash
cargo metadata --format-version=1 --no-deps \
  | jq -r '.packages[].name' \
  | grep '^tauri-plugin-' \
  | xargs -P 0 -n1 cargo test --package
```
