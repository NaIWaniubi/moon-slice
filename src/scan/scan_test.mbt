// The cache is pure, so these tests pin the exact rule the server relies on:
// a matching stamp and buffer is a hit, anything else is a miss, and files that
// stop appearing are dropped rather than kept for the life of the process.

///|
fn facts_of(path : String) -> @liveness.FileFacts {
  @liveness.collect(path, "fn orphan() -> Int {\n  1\n}\n")
}

///|
fn hits(found : @liveness.FileFacts?) -> Bool {
  match found {
    Some(_) => true
    None => false
  }
}

///|
test "the first scan misses and the second hits" {
  let cache = @scan.Cache::new()
  let stamp = @scan.Stamp::new(10L, 0, 27L)
  let first = cache.begin("/pkg")
  assert_false(hits(first.reuse("/pkg/a.mbt", stamp, None)))
  first.record("/pkg/a.mbt", stamp, None, facts_of("/pkg/a.mbt"))
  cache.commit(first)

  let second = cache.begin("/pkg")
  match second.reuse("/pkg/a.mbt", stamp, None) {
    Some(found) => assert_eq(found.path, "/pkg/a.mbt")
    None => fail("the unchanged file should have been reused")
  }
}

///|
test "every stamp field participates in the match" {
  let cache = @scan.Cache::new()
  let stamp = @scan.Stamp::new(10L, 0, 27L)
  let first = cache.begin("/pkg")
  first.record("/pkg/a.mbt", stamp, None, facts_of("/pkg/a.mbt"))
  cache.commit(first)

  for other in [
    @scan.Stamp::new(11L, 0, 27L),
    @scan.Stamp::new(10L, 1, 27L),
    @scan.Stamp::new(10L, 0, 28L),
  ] {
    let scan = cache.begin("/pkg")
    assert_false(hits(scan.reuse("/pkg/a.mbt", other, None)))
  }
}

///|
test "a changed buffer is a miss even when the file is untouched" {
  let cache = @scan.Cache::new()
  let stamp = @scan.Stamp::new(10L, 0, 27L)
  let original = "fn orphan() -> Int {\n  1\n}\n"
  let edited = "fn orphan() -> Int {\n  2\n}\n"

  let first = cache.begin("/pkg")
  first.record("/pkg/a.mbt", stamp, Some(original), facts_of("/pkg/a.mbt"))
  cache.commit(first)

  let same = cache.begin("/pkg")
  assert_true(hits(same.reuse("/pkg/a.mbt", stamp, Some(original))))
  cache.commit(same)

  let changed = cache.begin("/pkg")
  assert_false(hits(changed.reuse("/pkg/a.mbt", stamp, Some(edited))))
  // A file that was the open buffer but is not any more is a miss too: the
  // facts may have come from text that was never written to disk.
  assert_false(hits(changed.reuse("/pkg/a.mbt", stamp, None)))
}

///|
test "a file that disappears from the scan is dropped" {
  let cache = @scan.Cache::new()
  let stamp = @scan.Stamp::new(10L, 0, 27L)
  let first = cache.begin("/pkg")
  first.record("/pkg/a.mbt", stamp, None, facts_of("/pkg/a.mbt"))
  first.record("/pkg/b.mbt", stamp, None, facts_of("/pkg/b.mbt"))
  cache.commit(first)

  // The next scan only sees `a.mbt`; committing without mentioning `b.mbt`
  // must forget it, or a long session would accumulate every file ever seen.
  let second = cache.begin("/pkg")
  assert_true(hits(second.reuse("/pkg/a.mbt", stamp, None)))
  cache.commit(second)

  let third = cache.begin("/pkg")
  assert_false(hits(third.reuse("/pkg/b.mbt", stamp, None)))
  assert_true(hits(third.reuse("/pkg/a.mbt", stamp, None)))
}

///|
test "directories never share entries" {
  let cache = @scan.Cache::new()
  let stamp = @scan.Stamp::new(10L, 0, 27L)
  let first = cache.begin("/one")
  first.record("/one/a.mbt", stamp, None, facts_of("/one/a.mbt"))
  cache.commit(first)

  let other = cache.begin("/two")
  assert_false(hits(other.reuse("/one/a.mbt", stamp, None)))
}
