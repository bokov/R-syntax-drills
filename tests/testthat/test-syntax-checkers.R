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

test_that("syntax inspection handles omitted subscript arguments", {
  expect_true(uses_call("foo[10:20, ]", "["))
  expect_true(uses_call("foo[, 2:4]", "["))
})

test_that("global checker accepts valid omitted subscript arguments", {
  checker <- unserialize(serialize(drillr_exercise_checker, NULL))
  checker_env <- new.env(parent = globalenv())

  # Isolate Drillr's pre-delegation behavior without adding gradethis as a test
  # dependency. The mock namespace operator returns a function that captures the
  # arguments Drillr would have forwarded to gradethis.
  assign("::", function(...) function(...) list(...), envir = checker_env)
  environment(checker) <- checker_env

  forwarded <- checker(
    user_code = "middle_rows <- airquality[10:20, ]\nmiddle_rows",
    check_code = "original check"
  )

  expect_identical(forwarded$check_code, "original check")
})

test_that("global checker survives learnr environment rebinding", {
  checker <- unserialize(serialize(drillr_exercise_checker, NULL))

  # learnr::get_checker_func() evaluates the configured checker and then
  # replaces its environment with the exercise preparation environment.
  environment(checker) <- new.env(parent = globalenv())

  globals <- codetools::findGlobals(checker, merge = TRUE)
  expect_false("checker_uses_assignment_equals" %in% globals)
  expect_false("uses_assignment_equals" %in% globals)
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
