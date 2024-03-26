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

1. 截至目前(1.78)必须在nightly环境里使用:
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
#[bench]
fn bench(b: &mut Bencher){
  b.iter(||{ ...  })
}
```

## 模拟函数重载
Rust没有函数重载，但我们可以通过`Trait`来模拟

```rust
pub trait Foo<Args> {
    fn invoke(&self, args: Args);
}

struct FooImpl;
impl Foo<i32> for FooImpl {
    fn invoke(&self, i: i32) {
        println!("i32: {}", i);
    }
}

impl Foo<String> for FooImpl {
    fn invoke(&self, s: String) {
        println!("String: {}", s);
    }
}

impl Foo<(i32, i64)> for FooImpl {
    fn invoke(&self, t: (i32, i64)) {
        println!("Tuple: {:?}", t);
    }
}
impl Foo<()> for FooImpl {
    fn invoke(&self, _: ()) {
        println!("Unit");
    }
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test() {
        let foo = FooImpl;
        foo.invoke(42);
        foo.invoke("Hello, World".to_string());
        foo.invoke((42, 62));
        foo.invoke(());
    }
}
```
