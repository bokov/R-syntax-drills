test_that("Apps Script FSRS and review-history helpers pass their JavaScript unit tests", {
  node <- Sys.which("node")
  skip_if(!nzchar(node), "Node.js is not installed")

  root <- normalizePath(file.path(test_path(), "..", ".."))
  script <- file.path(root, "tests", "js", "test-fsrs.js")

  output <- system2(node, script, stdout = TRUE, stderr = TRUE)
  status <- attr(output, "status")
  if (is.null(status)) status <- 0L

  expect_equal(
    status,
    0L,
    info = paste(output, collapse = "\n")
  )
})
