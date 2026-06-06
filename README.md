# `cs resolve --reverse-tree` / `showMvnDepsTree --inverse` OOM repro

Reproduces the `OutOfMemoryError` reported in
[com-lihaoyi/mill#6823](https://github.com/com-lihaoyi/mill/issues/6823)
when running `mill <module>.showMvnDepsTree --inverse`, and traces it to a
regression in **coursier 2.1.17** in the BOM support.

## Reproducing

### Via the coursier CLI (`repro-cs.sh`)

The bug lives in coursier's `Tree.recursivePrint`, so it is reproducible
without Mill. `repro-cs.sh` uses the JAR-based coursier launcher (required
because the native `cs` binary does not honour `_JAVA_OPTIONS`):

```bash
# Download the JAR-based launcher (one-time, ~25 kB)
curl -fLo coursier https://github.com/coursier/launchers/raw/master/coursier

./repro-cs.sh        # runs forward tree then reverse tree; OOMs with -Xmx1g
```

### With a specific coursier version (`repro-with-version.sh`)

Downloads the given release JAR to `.coursier-jars/` (cached) and runs the
reverse-tree repro with `-Xmx1g -XX:GCTimeLimit=40` for a faster, cleaner
failure and a GC log (`gc-<version>.log`):

```bash
./repro-with-version.sh 2.1.25-M25   # FAIL — exit 3 (ExitOnOutOfMemoryError)
./repro-with-version.sh 2.1.16       # PASS
```

The GC log shows the heap pressure leading up to failure:

```
[4.523s] GC(91) Concurrent Mark Cycle
[4.535s] GC(92) Pause Young (Normal) (G1 Evacuation Pause) 996M->950M(1024M) 1.537ms
...
[4.916s] GC(106) Pause Full (G1 Compaction Pause) 1019M->980M(1024M) 69.351ms
[5.037s] GC(107) Pause Full (G1 Compaction Pause) 980M->979M(1024M) 120.958ms
[5.037s] GC Overhead Limit exceeded too often (5).
```

### Via Mill (`build.mill`)

```
mill cloud.vaadin.showMvnDepsTree --inverse
```

`.mill-jvm-opts` caps the daemon heap at `-Xmx1g`. The task fails with:

```
java.lang.Exception: fatal exception occurred: java.lang.OutOfMemoryError: Java heap space
    at coursier.util.Tree.customRender(Tree.scala:59)
    at coursier.util.Tree.render(Tree.scala:15)
Caused by: java.lang.OutOfMemoryError: Java heap space
```

Mill currently uses coursier 2.1.25-M25.

## Regression history

The bug was introduced in **coursier 2.1.17** (released 2024-11-07).

| Version | Reverse tree |
|---------|-------------|
| ≤ 2.1.16 | PASS |
| 2.1.17 | **FAIL** (OOM, exit 3) |
| 2.1.24 | FAIL |
| 2.1.25-M25 | FAIL |

The regression was caused by the BOM (Bill of Materials) support added in
[coursier#3097](https://github.com/coursier/coursier/pull/3097) and
[coursier#3143](https://github.com/coursier/coursier/pull/3143), which
introduced `DependencyManagement.{Key,Values}`, propagated dep-mgmt overrides
transitively, and modified `Resolution.scala` and `Dependency.scala`.

The effect on tree sizes (reduced dep set: slf4j-api + jackson-databind +
spring-core + spring-boot-starter-web + spark-sql):

| Version | Forward tree lines | Reverse tree |
|---------|--------------------|--------------|
| 2.1.16  | 115,314 | 36,724 lines, completes |
| 2.1.17  |  51,636 | OOM before completion |

The BOM changes make the **forward** tree smaller (better deduplication of
resolved versions), but they add new BOM-management edges to the dependency
graph that dramatically increase the fan-out of the `dependees` map used to
build the reverse tree. With more dependees per node, `Tree.recursivePrint`'s
path-local cycle detection is insufficient and the reverse tree blows up
exponentially.

## Root cause

### How `--reverse-tree` / `--inverse` works

`Print.dependencyTree0` calls `ReverseModuleTree.fromDependencyTree`, which
walks the full forward dependency tree once to build a `dependees` map:
every module M → the set of modules that directly depend on M.

It then constructs a `Tree[ReverseModuleTree.Node]` whose roots are the
declared direct dependencies of the module, and whose `children` function
calls `node.dependees` — the modules that depend on this node — to walk
upward through the graph toward the root.

### Why the tree explodes

`Tree.recursivePrint` uses a **path-local** `ancestors: Set[A]` to detect
cycles. It only skips a node that is a literal ancestor on the current
root-to-leaf path. It does **not** maintain a global visited set, so the
same module is re-expanded every time it is reached via a different branch.

When a low-level package (`slf4j-api`, `jackson-core`, `spring-core`,
`netty-*`, etc.) appears as a reverse-tree root — because it is declared as
an explicit direct dep — and has many dependees in the forward tree, every
path upward is independently expanded:

```
slf4j-api
├─ logback-classic
│  └─ spring-boot-starter-logging
│     └─ spring-boot-starter
│        └─ spring-boot-starter-web   [root → terminates]
├─ kafka-clients
│  └─ spring-kafka   [root → terminates]
├─ flink-slf4j
│  └─ flink-runtime
│     └─ flink-streaming-java   [root → terminates]
...  (dozens more branches, each fully expanded independently)
```

With ~20 low-level root packages each having 10–50 dependees, which
themselves have 5–15 dependees, the tree grows to millions of nodes.
All rendered strings accumulate in an `ArrayBuffer` before `mkString` is
called (`Tree.customRender`, `Tree.scala:59`), so the entire expanded tree
must fit in heap simultaneously.

### Why this dep set is pathological

The trigger condition is: **a package appears as a reverse-tree root AND
has many non-root dependees in the forward tree**.

This happens in `build.mill` because low-level packages (`slf4j-api`,
`jackson-core`, `spring-core`, etc.) are declared as explicit `mvnDeps`
alongside high-level frameworks (`spring-boot-starter-web`, `spark-sql`,
`flink-streaming-java`) that pull those same packages in transitively.
The low-level packages become roots *with* many dependees — the worst
case for the path-local cycle guard.

In real-world projects the same situation arises naturally: a large
multi-module build aggregating many framework stacks will have ubiquitous
transitive packages (especially after 2.1.17 added BOM management edges)
appearing as roots through version-conflict resolution.

## Fix direction

`Tree.recursivePrint` should maintain a **global** visited set in addition
to the path-local `ancestors` set. When a node has already been visited via
a different branch it should print an elision marker (e.g.
`(already shown above)`) rather than re-expanding the full subtree. This is
the same strategy the forward tree already uses implicitly (via shared
`DependencyTree` node identity), applied explicitly to the reverse traversal.

Alternatively (or additionally), `Tree.customRender` should stream lines to
the output rather than accumulating everything in an `ArrayBuffer[String]`
before flushing — this turns an OOM into a slow-but-survivable operation and
makes the problem visible earlier.
