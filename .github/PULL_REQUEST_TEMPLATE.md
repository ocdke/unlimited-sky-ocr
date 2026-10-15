## What does this change? / 这个 PR 做了什么

<!-- One or two sentences. 一两句话说明。 -->

## Why? / 为什么

<!-- The problem being solved. 解决的问题是什么。 -->

## How was it verified? / 怎么验证的

<!--
  Please be concrete — "ran X, saw Y".
  Anything perf-related needs before/after numbers.
  请具体说明跑了什么、看到什么结果；性能改动请附前后对比数字。
-->

- [ ] Built the core: `cd core; cargo build --release`
- [ ] Copied `dpg_core.dll` into the app's Release folder
- [ ] Built the app: `cd app; flutter build windows --release`
- [ ] Ran it on a real machine
- [ ] `cargo test --release` passes
- [ ] `flutter analyze` and `flutter test` pass

## Screenshots / 截图

<!-- For UI changes. 界面改动请附截图。 -->

## Checklist / 自查

- [ ] One thing per PR — 一个 PR 只做一件事
- [ ] No new heavy dependencies — 没有引入重型依赖
- [ ] Comments explain *why*, not *what* — 注释写的是「为什么」
- [ ] Kept the UTF-8 BOM on `main.cpp`, `Runner.rc` and `tools/*.ps1`
      — 保留了这些文件的 UTF-8 BOM
