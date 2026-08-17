test_that("assigns_to recognizes common assignment forms", {
  expect_true(assigns_to("xx <- c(1, 2)", "xx"))
  expect_true(assigns_to("c(1, 2) -> xx", "xx"))
  expect_true(assigns_to("assign('xx', c(1, 2))", "xx"))
  expect_false(assigns_to("yy <- c(1, 2)", "xx"))
})

test_that("call_count counts repeated vector subscripting", {
  expect_equal(call_count("scores[c(2, 4, 6)][c(3, 1)]", "["), 2)
  expect_equal(call_count("scores[2]", "["), 1)
})

test_that("uses_nested_subscript distinguishes chained from separate brackets", {
  expect_true(uses_nested_subscript("scores[c(2, 4, 6)][c(3, 1)]"))
  expect_false(uses_nested_subscript("scores[2]; scores[4]"))
})

test_that("subscript_uses_call requires the named call inside brackets", {
  expect_true(subscript_uses_call("scores[which(scores > 2)]", "which"))
  expect_false(subscript_uses_call("ii <- which(scores > 2); scores[ii]", "which"))
  expect_true(subscript_uses_call("codes[codes %in% wanted_codes]", "%in%"))
})
