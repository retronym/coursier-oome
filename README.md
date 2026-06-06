# `cs resolve --reverse-tree` OOM repro

## Executive summary

`cs resolve --reverse-tree` (and Mill's `showMvnDepsTree --inverse`) throws
`OutOfMemoryError` on dependency sets that are large but not unusually so.
The bug is a **regression introduced in coursier 2.1.17** by the BOM support
PRs ([#3097](https://github.com/coursier/coursier/pull/3097),
[#3143](https://github.com/coursier/coursier/pull/3143)).

The BOM changes restructure the dependency graph in a way that dramatically
increases the fan-out of the `dependees` map used to build the reverse tree.
`Tree.recursivePrint` uses only a path-local `ancestors` set for cycle
detection — it re-expands every node each time it is reached via a different
branch. With higher fan-out this produces an exponentially large tree that
exhausts the heap before a single line is written to output.

Counterintuitively, the BOM changes make the **forward** tree *smaller* (via
better version deduplication) while making the **reverse** tree blow up.

| Version | Forward tree | Reverse tree |
|---------|-------------|--------------|
| ≤ 2.1.16 | 115,314 lines | 36,724 lines — completes |
| 2.1.17+ | 51,636 lines | OOM before completion |

The fix belongs in coursier: `Tree.recursivePrint` needs a global visited set
(not just a path-local one) so nodes reached via multiple branches are printed
once with an elision marker rather than re-expanded.

---

## Reproducing

### Quick start

```bash
# Download the JAR-based launcher (one-time, ~25 kB)
curl -fLo coursier https://github.com/coursier/launchers/raw/master/coursier

./repro-cs.sh        # forward tree line count, then reverse tree → OOM
```

The native `cs` binary ignores `_JAVA_OPTIONS`, so the JAR launcher is
required to cap the heap.

### Testing a specific coursier version

```bash
./repro-with-version.sh 2.1.25-M25   # FAIL — exit 3 (ExitOnOutOfMemoryError)
./repro-with-version.sh 2.1.16       # PASS
```

Downloads the release JAR to `.coursier-jars/` (cached). Runs with
`-Xmx1g -XX:+ExitOnOutOfMemoryError -XX:GCTimeLimit=40`; GC events stream to
stderr so the pressure profile is visible before the crash:

```
[4.523s] GC(91) Concurrent Mark Cycle
[4.535s] GC(92) Pause Young (Normal) (G1 Evacuation Pause) 996M->950M(1024M) 1.537ms
...
[5.037s] GC(107) Pause Full (G1 Compaction Pause) 980M->979M(1024M) 120.958ms
[5.037s] GC Overhead Limit exceeded too often (5).
```

---

## Regression analysis

### What changed in 2.1.17

The BOM support PRs modified `Resolution.scala` and `Dependency.scala` to
propagate `DependencyManagement` overrides transitively. This changes which
edges appear in the resolved dependency graph:

- **Before 2.1.17**: version conflicts are resolved but the graph edges reflect
  what packages directly declared. A common library like `slf4j-api` might have
  20 direct dependees recorded.
- **After 2.1.17**: BOM-managed overrides create additional explicit edges for
  each package whose version was governed by a BOM. The same `slf4j-api` may
  now have 50+ dependees recorded, because every package managed by a BOM that
  transitively depends on `slf4j-api` contributes an explicit edge.

The forward tree shrinks because deduplication is more aggressive. The
`dependees` map explodes because there are far more edges.

### Why this is fatal for `--reverse-tree`

`Tree.recursivePrint` (`Tree.scala:34`) uses an `ancestors: Set[A]` that
tracks only the current root-to-node path:

```scala
val unseenElems = elems.filterNot(ancestors.contains)
// ...
recursivePrint(children(elem), ancestors + elem, ...)
```

This prevents infinite loops through direct cycles, but does **not** prevent
a node from being visited many times via different branches. In the reverse
tree, `slf4j-api` (a root because it is an explicit direct dep) has 50+
dependees; each of those has 10–20 dependees; and so on. Each branch is
expanded fully and independently, producing an exponential node count.

All rendered strings accumulate in a single `ArrayBuffer` in
`Tree.customRender` (`Tree.scala:57`) before `mkString` is called at line 59.
The entire exponentially-expanded tree must fit in heap simultaneously — there
is no streaming.

### Why this dep set triggers it

The trigger condition is: a package is a **reverse-tree root** (a declared
direct dep) **and** has many non-root dependees in the forward tree.

`build.mill` declares low-level packages (`slf4j-api`, `jackson-core`,
`spring-core`, `netty-*`, …) as explicit direct deps alongside the high-level
frameworks (`spring-boot-starter-web`, `spark-sql`, `flink-streaming-java`, …)
that pull those packages in transitively. The low-level packages become roots
with many dependees — precisely the worst case for the path-local guard.

In real projects the same situation arises without explicit duplication: a
large multi-module build that aggregates multiple framework stacks will, after
2.1.17, have many more BOM-management edges, making ubiquitous transitive
packages act as dense reverse-tree roots.

---

## Fix direction

**In coursier (`Tree.recursivePrint`)**: maintain a global `visited` set
alongside the path-local `ancestors` set. When a node is encountered that has
already been visited via a different branch, print an elision marker (e.g.
`(already shown)`) rather than re-expanding. This is the same strategy the
forward tree uses implicitly via shared `DependencyTree` node identity.

**Secondary (independent)**: `Tree.customRender` accumulates all lines in an
`ArrayBuffer` before flushing. Streaming lines directly to output would turn
an OOM into a slow-but-survivable operation and make the problem visible
earlier, even without the global visited fix.

---

## Mill context

This was originally reported in
[com-lihaoyi/mill#6823](https://github.com/com-lihaoyi/mill/issues/6823) as
`mill <module>.showMvnDepsTree --inverse` hanging or OOMing. Mill currently
ships coursier 2.1.25-M25 and so is affected. The `build.mill` and
`.mill-jvm-opts` in this repo reproduce it via Mill, but the bug is entirely
within coursier and reproducible directly with `cs resolve --reverse-tree`.
