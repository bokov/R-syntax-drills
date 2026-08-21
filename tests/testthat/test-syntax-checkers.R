test_that("equals is rejected only when parsed as assignment", {
  expect_true(uses_assignment_equals("x = 1"))
  expect_true(uses_assignment_equals("x <- (y = 1)"))

  expect_false(uses_assignment_equals("x <- 1"))
  expect_false(uses_assignment_equals("1 -> x"))
  expect_false(uses_assignment_equals("x <<- 1"))
  expect_false(uses_assignment_equals("1 ->> x"))
  expect_false(uses_assignment_equals("mean(x, na.rm = TRUE)"))
  expect_false(uses_assignment_equals("function(x = 1) x"))
})

test_that("global checker carries its own assignment detector", {
  checker <- unserialize(serialize(drillr_exercise_checker, NULL))
  checker_env <- environment(checker)

  expect_false(identical(checker_env, globalenv()))
  expect_true(exists(
    "checker_uses_assignment_equals",
    envir = checker_env,
    inherits = FALSE
  ))

  detector <- get(
    "checker_uses_assignment_equals",
    envir = checker_env,
    inherits = FALSE
  )
  expect_true(detector("x = 1"))
  expect_true(detector("x <- (y = 1)"))
  expect_false(detector("x <- 1"))
  expect_false(detector("1 -> x"))
  expect_false(detector("mean(x, na.rm = TRUE)"))
  expect_false(detector("function(x = 1) x"))
})

test_that("global checker replaces only the grading code for equals assignment", {
  source_text <- paste(
    readLines(
      normalizePath(file.path(test_path(), "..", "..", "R", "syntax_checkers.R")),
      warn = FALSE
    ),
    collapse = "\n"
  )

  expect_match(source_text, "Use <- or -> for assignment.", fixed = TRUE)
  expect_match(
    source_text,
    "Use = only for function arguments or defaults.",
    fixed = TRUE
  )
  expect_match(
    source_text,
    "gradethis::gradethis_exercise_checker",
    fixed = TRUE
  )
})
