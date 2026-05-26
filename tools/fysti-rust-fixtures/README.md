# fysti Rust Fixtures

This helper crate uses the local BurntSushi `fst` checkout at
`/private/tmp/codex-project-state/memex/fysti/fst`.

Generate Rust-written fixture declarations:

```sh
cargo run --manifest-path tools/fysti-rust-fixtures/Cargo.toml
```

Check Zig-written bytes with upstream Rust `fst`:

```sh
cargo run --manifest-path tools/fysti-rust-fixtures/Cargo.toml -- check-zig
```
