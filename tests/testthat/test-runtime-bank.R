write_runtime_test_pool <- function(path, labels) {
  lines <- unlist(lapply(labels, function(label) {
    c(
      paste0("```{r ", label, ", exercise=TRUE}"),
      "",
      "```"
    )
  }))
  writeLines(lines, path)
}

write_runtime_test_manifest <- function(path, labels, release = 1L) {
  write.csv(
    data.frame(
      item_label = labels,
      event = rep("exercise_result", length(labels)),
      topic = rep("basics", length(labels)),
      points = rep(1, length(labels)),
      starter_question = rep(FALSE, length(labels)),
      release = rep(release, length(labels)),
      stringsAsFactors = FALSE
    ),
    path,
    row.names = FALSE
  )
}

test_that("manifest comparison uses all.equal without attributes", {
  aa <- data.frame(item_label = "q1", release = 1L)
  bb <- aa
  attr(bb, "arbitrary") <- "ignored"
  expect_true(runtime_manifests_equal(aa, bb))

  bb$release <- 2L
  expect_false(runtime_manifests_equal(aa, bb))
})

test_that("unchanged manifest does not download the runtime pool", {
  root <- tempfile()
  dir.create(root)
  local_manifest <- file.path(root, "local-manifest.csv")
  local_pool <- file.path(root, "local-pool.Rmd")
  remote_manifest <- file.path(root, "remote-manifest.csv")
  remote_pool <- file.path(root, "remote-pool.Rmd")
  cache <- file.path(root, "cache")

  write_runtime_test_manifest(local_manifest, c("q1", "q2"))
  write_runtime_test_pool(local_pool, c("q1", "q2"))
  file.copy(local_manifest, remote_manifest)
  write_runtime_test_pool(remote_pool, c("q1", "q2"))

  downloads <- character()
  downloader <- function(url, path, timeout_sec) {
    downloads <<- c(downloads, url)
    file.copy(if (url == "manifest") remote_manifest else remote_pool, path)
  }

  bank <- refresh_runtime_bank(
    bundled_manifest_path = local_manifest,
    bundled_pool_path = local_pool,
    cache_dir = cache,
    manifest_url = "manifest",
    pool_url = "pool",
    downloader = downloader
  )

  expect_false(bank$updated)
  expect_equal(downloads, "manifest")
})

test_that("changed manifest downloads and installs the matching runtime pool", {
  root <- tempfile()
  dir.create(root)
  local_manifest <- file.path(root, "local-manifest.csv")
  local_pool <- file.path(root, "local-pool.Rmd")
  remote_manifest <- file.path(root, "remote-manifest.csv")
  remote_pool <- file.path(root, "remote-pool.Rmd")
  cache <- file.path(root, "cache")

  write_runtime_test_manifest(local_manifest, "q1", release = 1L)
  write_runtime_test_pool(local_pool, "q1")
  write_runtime_test_manifest(remote_manifest, c("q1", "q2"), release = 2L)
  write_runtime_test_pool(remote_pool, c("q1", "q2"))

  downloads <- character()
  downloader <- function(url, path, timeout_sec) {
    downloads <<- c(downloads, url)
    file.copy(if (url == "manifest") remote_manifest else remote_pool, path)
  }

  bank <- refresh_runtime_bank(
    bundled_manifest_path = local_manifest,
    bundled_pool_path = local_pool,
    cache_dir = cache,
    manifest_url = "manifest",
    pool_url = "pool",
    downloader = downloader
  )

  expect_true(bank$updated)
  expect_equal(downloads, c("manifest", "pool"))
  expect_equal(bank$manifest$item_label, c("q1", "q2"))
})

test_that("hosted refresh replaces the root runtime pair", {
  root <- tempfile()
  dir.create(root)
  local_manifest <- file.path(root, "question_manifest.csv")
  local_pool <- file.path(root, "runtime_question_pool.Rmd")
  remote_manifest <- file.path(root, "remote-manifest.csv")
  remote_pool <- file.path(root, "remote-pool.Rmd")

  write_runtime_test_manifest(local_manifest, "q1", release = 1L)
  write_runtime_test_pool(local_pool, "q1")
  write_runtime_test_manifest(remote_manifest, c("q1", "q2"), release = 2L)
  write_runtime_test_pool(remote_pool, c("q1", "q2"))

  downloader <- function(url, path, timeout_sec) {
    source <- if (url == "manifest") remote_manifest else remote_pool
    if (!file.copy(source, path, overwrite = TRUE)) stop("copy failed")
    invisible(path)
  }

  bank <- refresh_runtime_bank(
    bundled_manifest_path = local_manifest,
    bundled_pool_path = local_pool,
    cache_dir = root,
    manifest_url = "manifest",
    pool_url = "pool",
    downloader = downloader
  )

  expect_true(bank$updated)
  expect_equal(read_runtime_manifest(local_manifest)$item_label, c("q1", "q2"))
  expect_equal(runtime_pool_item_labels(local_pool), c("q1", "q2"))
})

test_that("failed runtime pool update keeps the existing local pair", {
  root <- tempfile()
  dir.create(root)
  local_manifest <- file.path(root, "local-manifest.csv")
  local_pool <- file.path(root, "local-pool.Rmd")
  remote_manifest <- file.path(root, "remote-manifest.csv")
  cache <- file.path(root, "cache")

  write_runtime_test_manifest(local_manifest, "q1", release = 1L)
  write_runtime_test_pool(local_pool, "q1")
  write_runtime_test_manifest(remote_manifest, c("q1", "q2"), release = 2L)

  downloader <- function(url, path, timeout_sec) {
    if (url == "manifest") {
      file.copy(remote_manifest, path)
      return(invisible(path))
    }
    stop("simulated pool failure")
  }

  bank <- refresh_runtime_bank(
    bundled_manifest_path = local_manifest,
    bundled_pool_path = local_pool,
    cache_dir = cache,
    manifest_url = "manifest",
    pool_url = "pool",
    downloader = downloader
  )

  expect_false(bank$updated)
  expect_equal(bank$manifest$item_label, "q1")
  expect_match(bank$notice, "could not download the matching drill file", fixed = TRUE)
})

test_that("manifest and Rmd mismatches warn and use only shared item labels", {
  root <- tempfile()
  dir.create(root)
  manifest_path <- file.path(root, "manifest.csv")
  pool_path <- file.path(root, "pool.Rmd")

  write_runtime_test_manifest(manifest_path, c("q1", "manifest-only"))
  write_runtime_test_pool(pool_path, c("q1", "rmd-only"))

  bank <- runtime_bank_from_pair(manifest_path, pool_path)

  expect_equal(bank$manifest$item_label, "q1")
  expect_equal(bank$mismatch$manifest_only, "manifest-only")
  expect_equal(bank$mismatch$pool_only, "rmd-only")
  expect_match(bank$warning, "copy and paste this entire message into a Teams message", fixed = TRUE)
  expect_match(bank$warning, "manifest-only", fixed = TRUE)
  expect_match(bank$warning, "rmd-only", fixed = TRUE)
})

test_that("hosted bootstrap uses the rmarkdown prerendered app factory", {
  factory <- getFromNamespace("shiny_prerendered_app", "rmarkdown")
  expect_true(is.function(factory))
  expect_true(all(c("input_rmd", "render_args") %in% names(formals(factory))))

  lines <- readLines("app.R", warn = FALSE)
  refresh_line <- grep("DRILLR_BOOT_BANK <- refresh_runtime_bank", lines, fixed = TRUE)
  factory_line <- grep("shiny_prerendered_app", lines, fixed = TRUE)
  expect_length(refresh_line, 1L)
  expect_length(factory_line, 1L)
  expect_lt(refresh_line, factory_line)
})
