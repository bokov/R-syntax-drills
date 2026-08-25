test_that("hosted server code uses the runtime bank from setup", {
  index_path <- testthat::test_path("..", "..", "index.Rmd")
  lines <- readLines(index_path, warn = FALSE)

  expect_false(any(grepl("DRILLR_RENDERED_BANK", lines, fixed = TRUE)))
  expect_true(any(grepl(
    "register_logging_handlers(APP_CONFIG, DRILLR_RUNTIME_BANK$manifest)",
    lines,
    fixed = TRUE
  )))
  expect_true(any(grepl(
    "manifest <- DRILLR_RUNTIME_BANK$manifest",
    lines,
    fixed = TRUE
  )))
})
