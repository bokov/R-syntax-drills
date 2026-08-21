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

test_that("global checker survives learnr environment rebinding", {
  checker <- unserialize(serialize(drillr_exercise_checker, NULL))

  # learnr::get_checker_func() evaluates the configured checker and then
  # replaces its environment with the exercise preparation environment.
  environment(checker) <- new.env(parent = globalenv())

  globals <- codetools::findGlobals(checker, merge = TRUE)
  expect_false("checker_uses_assignment_equals" %in% globals)
  expect_false("uses_assignment_equals" %in% globals)
})

test_that("checker installs syntax helpers in gradethis preparation environment", {
  skip_if_not_installed("gradethis")

  checker <- unserialize(serialize(drillr_exercise_checker, NULL))
  environment(checker) <- new.env(parent = globalenv())
  prep <- new.env(parent = globalenv())

  feedback <- checker(
    label = "runtime-helper-test",
    user_code = "vals <- c(1, 2)",
    check_code = paste0(
      "grade_this({ ",
      "if (!uses_call(.user_code, \"c\")) fail(\"missing c\"); ",
      "pass(\"ok\") })"
    ),
    envir_prep = prep,
    stage = "code_check"
  )

  helper_names <- c(
    "parse_student_code",
    "call_head",
    "walk_calls",
    "uses_call",
    "uses_token",
    "call_has_named_arg",
    "uses_assignment_equals"
  )

  expect_true(all(vapply(helper_names, exists, logical(1), envir = prep, inherits = FALSE)))
  expect_true(prep$uses_call("vals <- c(1, 2)", "c"))
  expect_true(isTRUE(feedback$correct))
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
  expect_match(source_text, "envir_prep = envir_prep", fixed = TRUE)
})
