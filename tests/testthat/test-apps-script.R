test_that("Apps Script helper suites pass their JavaScript unit tests", {
  node <- Sys.which("node")
  skip_if(!nzchar(node), "Node.js is not installed")

  root <- normalizePath(file.path(test_path(), "..", ".."))
  scripts <- file.path(
    root,
    "tests",
    "js",
    c(
      "test-fsrs.js",
      "test-performance.js",
      "test-concurrency.js",
      "test-bank-handshake.js"
    )
  )

  for (script in scripts) {
    output <- system2(node, script, stdout = TRUE, stderr = TRUE)
    status <- attr(output, "status")
    if (is.null(status)) status <- 0L

    expect_equal(
      status,
      0L,
      info = paste(basename(script), paste(output, collapse = "\n"), sep = "\n")
    )
  }
})
