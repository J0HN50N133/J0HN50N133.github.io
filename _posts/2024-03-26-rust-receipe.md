---
title: Rust Receipe
date: 2024-03-26 16:03
math: true
category:
  - Rust
tag:
  - Rust
---

## 开启Cargo Bench
1. 截至目前(1.78)必须在nightly环境里使用

```bash
rustup override set nightly
```

2. 在需要使用`bench`的`mod`里放置下面两行代码:

```rust
#![feature(test)]
extern crate test;
```

3. `bench`代码示例:

```rust
#[cfg(test)]
mod tests{
  use super::*;

  #[bench]
  fn bench(b: &mut Bencher){
    b.iter(||{
      ...
    })
  }
}
```
