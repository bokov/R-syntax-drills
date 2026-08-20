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

test_that("question-bank sync stamps every row with one runtime bank version", {
  manifest <- data.frame(
    item_label = c("q1", "q2"),
    event = c("exercise_result", "exercise_result"),
    topic = c("vectors", "lists"),
    points = c(1, 1),
    starter_question = c(TRUE, FALSE),
    question_hash = c("aaa", "bbb"),
    stringsAsFactors = FALSE
  )

  synced <- prepare_question_bank_sync(manifest)

  expect_named(synced, QUESTION_BANK_SYNC_COLUMNS)
  expect_length(unique(synced$bank_version), 1)
  expect_identical(
    unique(synced$bank_version),
    runtime_question_bank_version(manifest)
  )
})
