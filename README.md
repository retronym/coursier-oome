# mill `showMvnDepsTree --inverse` OOM repro

Reproduces the `OutOfMemoryError` reported in
[com-lihaoyi/mill#6823](https://github.com/com-lihaoyi/mill/issues/6823)
when running `mill <module>.showMvnDepsTree --inverse`.

## Reproducing

```
mill cloud.vaadin.showMvnDepsTree --inverse
```

With `.mill-jvm-opts` capping the daemon heap at `-Xmx1g`, the task fails:

```
java.lang.Exception: fatal exception occurred: java.lang.OutOfMemoryError: Java heap space
    at coursier.util.Tree.customRender(Tree.scala:59)
    at coursier.util.Tree.render(Tree.scala:15)
Caused by: java.lang.OutOfMemoryError: Java heap space
```

## Root cause

### How `--inverse` builds the reverse tree

`Print.dependencyTree0` (coursier) calls `ReverseModuleTree.fromDependencyTree`,
which walks the full forward dependency tree once to build a `dependees` map:
every module M → the set of modules that directly depend on M.

It then constructs a `Tree[ReverseModuleTree.Node]` whose roots are the module's
**direct declared dependencies** (returned by
`resolution.dependenciesOf0(coursierDependencyTask())`), and whose `children`
function calls `node.dependees` — the modules that depend on this node — to walk
upward through the graph.

### Why the tree explodes

`Tree.recursivePrint` uses a **path-local** `ancestors: Set[A]` to detect cycles.
It only skips a node that is a literal ancestor on the current root-to-leaf path.
It does **not** maintain a global visited set, so the same module can be visited
many times via different paths.

In a large project this causes exponential blowup in the reverse direction.
`slf4j-api`, `jackson-core`, `netty`, `spring-core`, etc. are depended on by
dozens of packages each. When these low-level packages appear as reverse-tree
roots (because they are declared as explicit direct deps), the tree printer
expands every path upward independently:

```
slf4j-api
├─ logback-classic           (1 path)
│  └─ spring-boot-starter-logging
│     └─ spring-boot-starter
│        └─ spring-boot-starter-web   [root → terminates]
├─ kafka-clients             (1 path)
│  └─ spring-kafka           [root → terminates]
├─ flink-slf4j               (1 path)
│  └─ flink-runtime
│     └─ flink-streaming-java [root → terminates]
...  (dozens more branches, each independently expanded)
```

With ~20 low-level root packages each having 10–50 dependees, which themselves
have 5–15 dependees, the tree grows to millions of nodes before terminating.
All rendered strings accumulate in an `ArrayBuffer` before `mkString` is called
(in `Tree.customRender`, `Tree.scala:59`), so the entire expanded tree must fit
in heap at once.

### Why this dep set is pathological

The trigger condition is: **a package appears as a reverse-tree root AND has
many non-root dependees in the forward tree**.

This happens when low-level packages (`slf4j-api`, `jackson-core`, `spring-core`,
`netty-*`, etc.) are declared as explicit `mvnDeps` at the same time as high-level
frameworks (`spring-boot-starter-web`, `spark-sql`, `flink-streaming-java`, etc.)
that pull those low-level packages in transitively. The low-level packages become
roots *with* many dependees — the worst case for the path-local cycle guard.

In real-world projects the same situation arises without explicit duplication:
a large multi-module build that aggregates many framework stacks will naturally
have ubiquitous transitive packages appearing as roots through version-conflict
resolution forcing them into `minDependencies`.

### Fix direction

`Tree.recursivePrint` should maintain a **global** visited set in addition to the
path-local `ancestors` set. When a node is encountered that has already been
visited via a different branch, it should print an elision marker (e.g.
`(already shown above)`) rather than re-expanding the full subtree. This is the
same strategy the forward tree already uses implicitly (via shared `DependencyTree`
node identity), applied explicitly to the reverse traversal.

Alternatively, `Tree.customRender` should stream lines to the output rather than
accumulating them all in an `ArrayBuffer[String]` before flushing — this would
turn an OOM into a merely very slow operation, and make the slowness visible
earlier.
