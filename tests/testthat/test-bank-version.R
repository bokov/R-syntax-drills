test_that("runtime bank version is deterministic and runtime-scoped", {
  manifest <- data.frame(
    item_label = c("q2", "q1", "info"),
    event = c("exercise_result", "exercise_result", "question_submission"),
    topic = c("vectors", "vectors", "vectors"),
    points = c(1, 1, 0),
    starter_question = c(FALSE, TRUE, FALSE),
    question_hash = c("bbb", "aaa", "zzz"),
    stringsAsFactors = FALSE
  )

  version <- runtime_question_bank_version(manifest)
  expect_match(version, "^md5-[0-9a-f]{32}$")
  expect_identical(
    runtime_question_bank_version(manifest[3:1, , drop = FALSE]),
    version
  )

  changed_unscored <- manifest
  changed_unscored$question_hash[changed_unscored$item_label == "info"] <- "different"
  expect_identical(runtime_question_bank_version(changed_unscored), version)

  changed_runtime <- manifest
  changed_runtime$question_hash[changed_runtime$item_label == "q1"] <- "different"
  expect_false(identical(runtime_question_bank_version(changed_runtime), version))
})

test_that("runtime support participates in the bank version without changing question hashes", {
  manifest <- data.frame(
    item_label = c("q1", "q2"),
    event = c("exercise_result", "exercise_result"),
    topic = c("vectors", "lists"),
    points = c(1, 1),
    starter_question = c(TRUE, FALSE),
    question_hash = c("aaa", "bbb"),
    stringsAsFactors = FALSE
  )

  legacy <- runtime_question_bank_version(manifest)
  expect_identical(
    runtime_question_bank_version_with_support(manifest, ""),
    legacy
  )

  first <- runtime_question_bank_version_with_support(
    manifest,
    "md5-11111111111111111111111111111111"
  )
  second <- runtime_question_bank_version_with_support(
    manifest,
    "md5-22222222222222222222222222222222"
  )

  expect_match(first, "^md5-[0-9a-f]{32}$")
  expect_false(identical(first, legacy))
  expect_false(identical(first, second))
  expect_identical(manifest$question_hash, c("aaa", "bbb"))
})

test_that("question-bank sync stamps every row with one support-aware bank version", {
  manifest <- data.frame(
    item_label = c("q1", "q2"),
    event = c("exercise_result", "exercise_result"),
    topic = c("vectors", "lists"),
    points = c(1, 1),
    starter_question = c(TRUE, FALSE),
    question_hash = c("aaa", "bbb"),
    stringsAsFactors = FALSE
  )
  support_hash <- "md5-11111111111111111111111111111111"

  synced <- prepare_question_bank_sync_with_support(manifest, support_hash)

  expect_named(synced, QUESTION_BANK_SYNC_COLUMNS)
  expect_length(unique(synced$bank_version), 1)
  expect_identical(
    unique(synced$bank_version),
    runtime_question_bank_version_with_support(manifest, support_hash)
  )
})

test_that("canonical runtime support hash changes when checker behavior changes", {
  root <- tempfile("runtime-support-root-")
  dir.create(file.path(root, "R"), recursive = TRUE)
  checker <- file.path(root, "R", "syntax_checkers.R")
  writeLines("helper <- function() TRUE", checker)

  first <- runtime_support_hash(root)
  writeLines("helper <- function() FALSE", checker)
  second <- runtime_support_hash(root)

  expect_match(first, "^md5-[0-9a-f]{32}$")
  expect_false(identical(first, second))
})
