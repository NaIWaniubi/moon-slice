// Differential testing: run the real pipeline and the reference slicer over the
// same `@core.Program` and compare the answer node by node.
//
// Both sides see exactly the same IR, so a difference is a difference in
// analysis, never in front-end lowering. The reference side never imports the
// passes it checks: the pipeline is `cfg -> defuse -> cdg -> pdg -> slice`, the
// reference is `all-paths + simulation`, and the only thing they share is
// `@core.Program`.

///|
/// Outcome of comparing one reference slice with one pipeline slice.
pub(all) struct DiffResult {
  /// True when the two node sets are equal.
  agree : Bool
  /// Nodes the reference includes and the pipeline does not.
  missing : Array[Int32]
  /// Nodes the pipeline includes and the reference does not.
  extra : Array[Int32]
  /// Size of the reference slice.
  reference_size : Int32
  /// Size of the pipeline slice.
  actual_size : Int32
  /// True when the reference could not be computed exactly (resource bound or a
  /// source that did not parse), so `agree` carries no information.
  truncated : Bool
  /// The criterion node this result is about.
  criterion : Int32
  /// True for a forward slice, false for a backward one.
  forward : Bool
}

///|
/// Node-level comparison of the two dependence relations, independent of any
/// particular slice. Useful when a slice disagrees and the cause has to be
/// localized to data flow or control flow.
pub(all) struct RelationDiff {
  data_missing : Array[(Int32, Int32)]
  data_extra : Array[(Int32, Int32)]
  control_missing : Array[(Int32, Int32)]
  control_extra : Array[(Int32, Int32)]
}

///|
/// Aggregate outcome of a batch of generated programs.
pub(all) struct BatchResult {
  /// Programs that were generated and checked.
  mut programs : Int32
  /// Individual slice comparisons performed (every node, both directions).
  mut comparisons : Int32
  /// Comparisons whose node sets were equal.
  mut agreeing : Int32
  /// Comparisons the reference could not decide (truncated or unparseable).
  mut skipped : Int32
  /// One line per disagreement, naming the seed, criterion and direction.
  failures : Array[String]
}

///|
/// True when `items` contains `needle`.
fn diff_member(items : Array[Int32], needle : Int32) -> Bool {
  let mut i = 0
  let mut found = false
  while i < items.length() {
    if items[i] == needle {
      found = true
    }
    i = i + 1
  }
  found
}

///|
/// Set difference `left \ right`, in `left`'s order.
fn diff_without(left : Array[Int32], right : Array[Int32]) -> Array[Int32] {
  let out : Array[Int32] = []
  for item in left {
    if !diff_member(right, item) {
      out.push(item)
    }
  }
  out
}

///|
/// True when `items` contains `needle`.
fn diff_has_pair(items : Array[(Int32, Int32)], needle : (Int32, Int32)) -> Bool {
  let mut i = 0
  let mut found = false
  while i < items.length() {
    if items[i].0 == needle.0 && items[i].1 == needle.1 {
      found = true
    }
    i = i + 1
  }
  found
}

///|
/// Set difference over pairs, in `left`'s order.
fn diff_pairs_without(
  left : Array[(Int32, Int32)],
  right : Array[(Int32, Int32)],
) -> Array[(Int32, Int32)] {
  let out : Array[(Int32, Int32)] = []
  for item in left {
    if !diff_has_pair(right, item) {
      out.push(item)
    }
  }
  out
}

///|
/// Parse `source` with the production front end. Errors are reported through the
/// program's `errors` field; the caller decides whether that is fatal.
pub fn parse(source : String) -> @core.Program {
  @parser_adapter.parse_source(source, "oracle.mbt")
}

///|
/// The pipeline's data and control dependence relations for `program`.
///
/// This is the only place in the package that calls the passes under test, and
/// it is what makes swapping the pipeline out (for example for `build_precise`)
/// a one-line change when a mission wants to compare against that instead.
pub fn pipeline_relations(
  program : @core.Program,
) -> (@core.DefUse, @core.Cdg) {
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = @cdg.build(program, cfg)
  (defuse, cdg)
}

///|
/// The pipeline's slice of `target`.
pub fn pipeline_slice(program : @core.Program, target : Int32, forward : Bool) -> Array[Int32] {
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = @cdg.build(program, cfg)
  let pdg = @pdg.build(defuse, cdg)
  let result = if forward {
    @slice.forward(pdg, target)
  } else {
    @slice.backward(pdg, target)
  }
  result.nodes
}

///|
/// Compare a reference relation with the pipeline's relation, pair by pair.
pub fn differential_relations(source : String) -> RelationDiff {
  let program = parse(source)
  let reference = reference_dependences(program)
  let (defuse, cdg) = pipeline_relations(program)
  {
    data_missing: diff_pairs_without(reference.data, defuse.reaching),
    data_extra: diff_pairs_without(defuse.reaching, reference.data),
    control_missing: diff_pairs_without(reference.control, cdg.edges),
    control_extra: diff_pairs_without(cdg.edges, reference.control),
  }
}

///|
/// Compare one slice. `missing` is what the reference sees and the pipeline does
/// not; `extra` is what the pipeline adds.
fn compare_slices(
  reference : Array[Int32],
  actual : Array[Int32],
  criterion : Int32,
  forward : Bool,
  truncated : Bool,
) -> DiffResult {
  let missing = diff_without(reference, actual)
  let extra = diff_without(actual, reference)
  {
    agree: missing.length() == 0 && extra.length() == 0,
    missing,
    extra,
    reference_size: reference.length(),
    actual_size: actual.length(),
    truncated,
    criterion,
    forward,
  }
}

///|
/// Differential check of one criterion and direction.
///
/// A source that fails to parse yields `truncated = true` with empty diffs: the
/// oracle has nothing to say about it, and silently reporting agreement would be
/// worse than saying so. In this repository every input comes from the parser
/// adapter itself, so a parse failure means the input, not the analysis, is
/// broken.
pub fn differential_check_at(
  source : String,
  target : Int32,
  forward : Bool,
) -> DiffResult {
  let program = parse(source)
  if program.errors.length() > 0 {
    return {
      agree: false,
      missing: [],
      extra: [],
      reference_size: 0,
      actual_size: 0,
      truncated: true,
      criterion: target,
      forward,
    }
  }
  let deps = reference_dependences(program)
  let reference = ref_slice(deps, target, forward)
  let actual = pipeline_slice(program, target, forward)
  compare_slices(reference, actual, target, forward, deps.truncated)
}

///|
/// The criterion `differential_check` uses: the last statement of the first
/// function, which is the function's result expression in the shapes the
/// adapter emits, and never a synthetic exit node.
pub fn default_criterion(program : @core.Program) -> Int32 {
  let exits : Array[Int32] = []
  for function in program.functions {
    exits.push(function.exit)
  }
  let mut best = -1
  let mut fallback = -1
  for node in program.nodes {
    if node.id > fallback {
      fallback = node.id
    }
    if !diff_member(exits, node.id) && node.id > best {
      best = node.id
    }
  }
  if best >= 0 {
    best
  } else {
    fallback
  }
}

///|
/// Differential check of the default criterion, backward.
///
/// This is the form a batch uses: parse once, compare a slice whose criterion is
/// always a real statement, so a disagreement cannot be an artefact of comparing
/// a synthetic boundary node nothing depends on.
pub fn differential_check(source : String) -> DiffResult {
  let program = parse(source)
  let target = default_criterion(program)
  differential_check_at(source, target, false)
}

///|
/// Differential check of every node, in both directions.
///
/// `program.errors` non-empty gives one truncated result, so a caller can tell
/// "nothing to compare" from "everything agreed".
pub fn differential_check_all(source : String) -> Array[DiffResult] {
  let program = parse(source)
  if program.errors.length() > 0 {
    return [
      {
        agree: false,
        missing: [],
        extra: [],
        reference_size: 0,
        actual_size: 0,
        truncated: true,
        criterion: -1,
        forward: false,
      },
    ]
  }
  let deps = reference_dependences(program)
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = @cdg.build(program, cfg)
  let pdg = @pdg.build(defuse, cdg)
  let ids : Array[Int32] = []
  for node in program.nodes {
    if !diff_member(ids, node.id) {
      ids.push(node.id)
    }
  }
  ids.sort()
  let out : Array[DiffResult] = []
  for id in ids {
    out.push(
      compare_slices(
        ref_slice(deps, id, false),
        @slice.backward(pdg, id).nodes,
        id,
        false,
        deps.truncated,
      ),
    )
    out.push(
      compare_slices(
        ref_slice(deps, id, true),
        @slice.forward(pdg, id).nodes,
        id,
        true,
        deps.truncated,
      ),
    )
  }
  out
}

///|
/// Run one generated program through `differential_check_all` and fold the
/// outcome into `batch`.
fn batch_add(batch : BatchResult, seed : Int32, results : Array[DiffResult]) -> Unit {
  for result in results {
    batch.comparisons = batch.comparisons + 1
    if result.truncated {
      batch.skipped = batch.skipped + 1
    } else if result.agree {
      batch.agreeing = batch.agreeing + 1
    } else {
      let direction = if result.forward { "forward" } else { "backward" }
      batch.failures.push(
        "seed=\{seed} criterion=\{result.criterion} direction=\{direction} missing=\{result.missing.length()} extra=\{result.extra.length()}",
      )
    }
  }
}

///|
/// Batch differential check: generate one program per seed and compare every
/// slice of it.
///
/// The returned counts are over individual slice comparisons, not over programs,
/// because a program with 40 nodes gives 80 independent answers. `skipped`
/// counts comparisons the reference could not decide, so an honest agreement
/// rate is `agreeing / (comparisons - skipped)`.
pub fn batch_check(seeds : Array[Int32]) -> BatchResult {
  let batch : BatchResult = {
    programs: 0,
    comparisons: 0,
    agreeing: 0,
    skipped: 0,
    failures: [],
  }
  for seed in seeds {
    let source = generate(seed)
    let results = differential_check_all(source)
    batch_add(batch, seed, results)
    batch.programs = batch.programs + 1
  }
  batch
}

///|
/// Fraction of decided comparisons that agreed, in `0.0 … 1.0`. A batch with no
/// decided comparison reports `0.0`, never a misleading `1.0`.
pub fn agreement_rate(batch : BatchResult) -> Double {
  let decided = batch.comparisons - batch.skipped
  if decided <= 0 {
    return 0.0
  }
  batch.agreeing.to_double() / decided.to_double()
}
